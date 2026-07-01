//! The two data roles of a transfer, speaking the wire protocol over a duplex
//! stream (`*std.Io.Reader` + `*std.Io.Writer`).
//!
//!   sender   — holds the source: walks the tree, computes deltas, sends them
//!   receiver — holds the destination: makes signatures, patches, writes
//!
//! These are orthogonal to who opened the connection, captured by `Role`:
//!   initiator (the client) sends HELLO first; responder (the server) replies.
//!
//! Push  = client is sender  + initiator, server is receiver + responder.
//! Pull  = client is receiver + initiator, server is sender   + responder.
//!
//! Per file the sender sends a FILE header; the receiver quick-checks it and
//! replies SKIP or a SIG; the sender streams LITERAL/COPY ops + END (whole-file
//! hash); the receiver reconstructs, verifies, and writes atomically.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Reader = Io.Reader;
const Writer = Io.Writer;

const wire = @import("../proto/wire.zig");
const zip = @import("../proto/zip.zig");
const signature = @import("../delta/signature.zig");
const stream = @import("../delta/stream.zig");
const link = @import("../fs/link.zig");
const special = @import("../fs/special.zig");
const hardlink = @import("../fs/hardlink.zig");
const Filter = @import("filter.zig").Filter;
const prune = @import("../fs/prune.zig");
const meta = @import("../fs/meta.zig");
const owner = @import("../fs/owner.zig");
const xattr = @import("../fs/xattr.zig");

const Perm = Io.File.Permissions;
const PermInt = std.meta.Tag(Perm);

pub const Role = enum { initiator, responder };

pub const ProtocolError = error{
    BadMagic,
    VersionMismatch,
    UnexpectedTag,
    VerificationFailed,
};

pub const Options = struct {
    verbose: bool = false,
    /// Delete destination entries the source didn't offer (mirror mode).
    delete: bool = false,
    /// Preserve owning user / group (best-effort; needs privilege).
    owner: bool = false,
    group: bool = false,
    /// Preserve extended attributes of regular files (best-effort).
    xattrs: bool = false,
    /// Preserve hardlinks (single-connection transfers only).
    hard_links: bool = false,
    /// Exclude patterns applied by whichever side walks the source.
    excludes: []const []const u8 = &.{},
    /// Compress the wire (single-connection transfers only).
    compress: bool = false,
};

/// Session flags exchanged in the handshake. The initiator (client) sets them
/// from the user's intent; the responder (server) learns them this way.
const Flags = struct {
    delete: bool = false,
    owner: bool = false,
    group: bool = false,
    xattrs: bool = false,
    hard_links: bool = false,
    compress: bool = false,

    fn fromOpts(o: Options) Flags {
        return .{ .delete = o.delete, .owner = o.owner, .group = o.group, .xattrs = o.xattrs, .hard_links = o.hard_links, .compress = o.compress };
    }
    fn encode(f: Flags) u64 {
        return @as(u64, @intFromBool(f.delete)) |
            (@as(u64, @intFromBool(f.owner)) << 1) |
            (@as(u64, @intFromBool(f.group)) << 2) |
            (@as(u64, @intFromBool(f.xattrs)) << 3) |
            (@as(u64, @intFromBool(f.hard_links)) << 4) |
            (@as(u64, @intFromBool(f.compress)) << 5);
    }
    fn decode(bits: u64) Flags {
        return .{
            .delete = bits & 1 != 0,
            .owner = bits & 2 != 0,
            .group = bits & 4 != 0,
            .xattrs = bits & 8 != 0,
            .hard_links = bits & 16 != 0,
            .compress = bits & 32 != 0,
        };
    }
    fn preserveIds(f: Flags) bool {
        return f.owner or f.group;
    }
};

fn putXattrs(w: *Writer, set: xattr.Set) !void {
    try wire.putUvarint(w, set.pairs.len);
    for (set.pairs) |p| {
        try wire.putBytes(w, p.name);
        try wire.putBytes(w, p.value);
    }
}

fn getXattrs(gpa: Allocator, r: *Reader) !xattr.Set {
    const n = try wire.getUvarint(r);
    var pairs = try gpa.alloc(xattr.Pair, @intCast(n));
    errdefer gpa.free(pairs);
    var made: usize = 0;
    errdefer for (pairs[0..made]) |p| {
        gpa.free(p.name);
        gpa.free(p.value);
    };
    while (made < pairs.len) : (made += 1) {
        const name = try wire.getBytesAlloc(r, gpa);
        defer gpa.free(name);
        pairs[made] = .{ .name = try gpa.dupeZ(u8, name), .value = try wire.getBytesAlloc(r, gpa) };
    }
    return .{ .pairs = pairs };
}

const Negotiated = struct {
    flags: Flags,
    /// Owned. The exclude patterns the walking side should apply.
    excludes: [][]u8,
};

/// After the handshake, the effective session flags and exclude patterns are the
/// *initiator's* (the client drives intent); the responder adopts what it
/// received. Excludes are exchanged so the responder — when it is the one that
/// walks the source (pull) — filters correctly.
fn negotiate(gpa: Allocator, r: *Reader, w: *Writer, role: Role, opts: Options) !Negotiated {
    const mine = Flags.fromOpts(opts);
    const peer = try handshake(r, w, role, mine);
    const flags = if (role == .initiator) mine else peer;
    const excludes = switch (role) {
        .initiator => blk: {
            try sendExcludes(w, opts.excludes);
            break :blk try dupeExcludes(gpa, opts.excludes);
        },
        .responder => try recvExcludes(gpa, r),
    };
    return .{ .flags = flags, .excludes = excludes };
}

fn freeExcludes(gpa: Allocator, ex: [][]u8) void {
    for (ex) |e| gpa.free(e);
    gpa.free(ex);
}

fn dupeExcludes(gpa: Allocator, src: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |e| gpa.free(e);
        gpa.free(out);
    }
    while (n < src.len) : (n += 1) out[n] = try gpa.dupe(u8, src[n]);
    return out;
}

fn sendExcludes(w: *Writer, ex: []const []const u8) !void {
    try wire.putUvarint(w, ex.len);
    for (ex) |e| try wire.putBytes(w, e);
    try w.flush();
}

fn recvExcludes(gpa: Allocator, r: *Reader) ![][]u8 {
    const n = try wire.getUvarint(r);
    const out = try gpa.alloc([]u8, @intCast(n));
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |e| gpa.free(e);
        gpa.free(out);
    }
    while (made < out.len) : (made += 1) out[made] = try wire.getBytesAlloc(r, gpa);
    return out;
}

/// Streaming-matcher sink for the sender: writes ops directly to the wire.
const WireSink = struct {
    gpa: Allocator,
    w: *Writer,
    block_size: u32,
    file_len: u64,
    compress: bool = false,
    literal_bytes: u64 = 0,
    matched_bytes: u64 = 0,

    pub fn emitLiteral(self: *WireSink, bytes: []const u8) !void {
        self.literal_bytes += bytes.len;
        if (self.compress) {
            // Compressed literal: orig_len, then the (len-prefixed) payload,
            // which is compressed iff it is shorter than orig_len.
            const payload: ?[]u8 = try zip.deflate(self.gpa, bytes);
            defer if (payload) |p| self.gpa.free(p);
            try wire.putTag(self.w, .literal);
            try wire.putUvarint(self.w, bytes.len);
            try wire.putBytes(self.w, payload orelse bytes);
            return;
        }
        try wire.putTag(self.w, .literal);
        try wire.putBytes(self.w, bytes);
    }
    pub fn emitCopy(self: *WireSink, idx: u32) !void {
        try wire.putTag(self.w, .copy);
        try wire.putUvarint(self.w, idx);
        const start = @as(usize, idx) * self.block_size;
        self.matched_bytes += @min(@as(usize, self.block_size), @as(usize, @intCast(self.file_len)) - start);
    }
};

/// Sends a directory's metadata (a `mkdir` message). Used for both tree
/// directories and the root itself (path ".").
fn sendDir(io: Io, gpa: Allocator, w: *Writer, src_dir: Dir, path: []const u8, eff: Flags) !void {
    const st = try src_dir.statFile(io, path, .{});
    try wire.putTag(w, .mkdir);
    try wire.putBytes(w, path);
    try wire.putUvarint(w, @intFromEnum(st.permissions));
    try wire.putZigzag(w, @intCast(st.mtime.nanoseconds));
    if (eff.preserveIds()) try putIds(w, src_dir, path);
    if (eff.xattrs) {
        var xs = meta.readDirXattrs(gpa, io, src_dir, path);
        defer xs.deinit(gpa);
        try putXattrs(w, xs);
    }
    try w.flush();
}

fn sendSymlink(io: Io, w: *Writer, src_dir: Dir, path: []const u8, eff: Flags) !void {
    var buf: [link.max_target]u8 = undefined;
    const target = try link.readTarget(io, src_dir, path, &buf);
    try wire.putTag(w, .symlink);
    try wire.putBytes(w, path);
    try wire.putBytes(w, target);
    if (eff.preserveIds()) try putIds(w, src_dir, path);
    try w.flush();
}

fn sendKeep(w: *Writer, path: []const u8) !void {
    try wire.putTag(w, .keep);
    try wire.putBytes(w, path);
}

fn sendHardlink(w: *Writer, path: []const u8, master: []const u8) !void {
    try wire.putTag(w, .hardlink);
    try wire.putBytes(w, path);
    try wire.putBytes(w, master);
    try w.flush();
}

/// If `path` is a hardlink to an already-seen inode, sends a `hardlink` message
/// and returns true; otherwise records it as the master and returns false so the
/// caller transfers it as a regular file.
fn isHardlinkNotFirst(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    path: []const u8,
    inodes: *std.AutoHashMapUnmanaged(hardlink.Key, []u8),
    w: *Writer,
) !bool {
    const st = try src_dir.statFile(io, path, .{});
    if (st.nlink <= 1) return false;
    const k = hardlink.key(src_dir, path, @intCast(st.inode));
    if (inodes.get(k)) |master| {
        try sendHardlink(w, path, master);
        return true;
    }
    try inodes.put(gpa, k, try gpa.dupe(u8, path));
    return false;
}

fn sendSpecial(w: *Writer, src_dir: Dir, path: []const u8, kind: special.Kind) !void {
    const info = try special.read(src_dir, path, kind);
    try wire.putTag(w, .special);
    try wire.putBytes(w, path);
    try wire.putUvarint(w, @intFromEnum(info.kind));
    try wire.putUvarint(w, info.perm);
    try wire.putUvarint(w, info.major);
    try wire.putUvarint(w, info.minor);
    try w.flush();
}

fn putIds(w: *Writer, src_dir: Dir, path: []const u8) !void {
    const ids = try owner.read(src_dir, path);
    try wire.putUvarint(w, ids.uid);
    try wire.putUvarint(w, ids.gid);
}

fn getIds(r: *Reader) !owner.Ids {
    return .{
        .uid = @intCast(try wire.getUvarint(r)),
        .gid = @intCast(try wire.getUvarint(r)),
    };
}

/// Applies the received owner to `path`, gated by which of owner/group the
/// session negotiated.
fn applyIds(io: Io, dst_dir: Dir, path: []const u8, ids: owner.Ids, eff: Flags, follow: bool) void {
    owner.apply(io, dst_dir, path, if (eff.owner) ids.uid else null, if (eff.group) ids.gid else null, follow);
}

pub const SenderStats = struct {
    dirs: u64 = 0,
    symlinks: u64 = 0,
    specials: u64 = 0,
    hardlinks: u64 = 0,
    files_total: u64 = 0,
    files_sent: u64 = 0,
    files_skipped: u64 = 0,
    entries_ignored: u64 = 0,
    literal_bytes: u64 = 0,
    matched_bytes: u64 = 0,
};

pub const ReceiverStats = struct {
    dirs: u64 = 0,
    symlinks: u64 = 0,
    specials: u64 = 0,
    hardlinks: u64 = 0,
    files_written: u64 = 0,
    files_skipped: u64 = 0,
    deleted: u64 = 0,
};

/// Exchanges HELLOs and returns the peer's flags. The initiator speaks first.
fn handshake(r: *Reader, w: *Writer, role: Role, mine: Flags) !Flags {
    switch (role) {
        .initiator => {
            try sendHello(w, mine);
            return recvHello(r);
        },
        .responder => {
            const peer = try recvHello(r);
            try sendHello(w, mine);
            return peer;
        },
    }
}

fn sendHello(w: *Writer, flags: Flags) !void {
    try wire.putTag(w, .hello);
    try w.writeAll(wire.magic);
    try wire.putUvarint(w, wire.version);
    try wire.putUvarint(w, flags.encode());
    try w.flush();
}

fn recvHello(r: *Reader) !Flags {
    if (try wire.getTag(r) != .hello) return ProtocolError.UnexpectedTag;
    var m: [wire.magic.len]u8 = undefined;
    try r.readSliceAll(&m);
    if (!std.mem.eql(u8, &m, wire.magic)) return ProtocolError.BadMagic;
    if (try wire.getUvarint(r) != wire.version) return ProtocolError.VersionMismatch;
    return Flags.decode(try wire.getUvarint(r));
}

// ---------------------------------------------------------------------------
// Sender (source side)
// ---------------------------------------------------------------------------

/// One shard of a sharded pull. Files are assigned by a stable hash of their
/// path (walk order is undefined, so index-based sharding would be unsafe), so
/// every file is sent by exactly one shard. Shard 0 additionally sends the
/// directory tree, symlinks, and root metadata.
pub const Shard = struct {
    index: u32,
    count: u32,

    fn hasFile(self: Shard, path: []const u8) bool {
        return std.hash.Wyhash.hash(0, path) % self.count == self.index;
    }
    fn hasStructure(self: Shard) bool {
        return self.index == 0;
    }
};

pub fn runSender(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    r: *Reader,
    w: *Writer,
    opts: Options,
    role: Role,
    shard: ?Shard,
) !SenderStats {
    const neg = try negotiate(gpa, r, w, role, opts);
    defer freeExcludes(gpa, neg.excludes);
    return senderWalk(io, gpa, src_dir, r, w, neg.flags, neg.excludes, opts, shard);
}

fn senderWalk(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    r: *Reader,
    w: *Writer,
    eff: Flags,
    excludes: []const []const u8,
    opts: Options,
    shard: ?Shard,
) !SenderStats {
    const structure = shard == null or shard.?.hasStructure();
    // Hardlink detection is single-connection only (sharding would split an
    // inode group across independent walks).
    const detect_hl = eff.hard_links and shard == null;

    var stats: SenderStats = .{};

    // Maps a file identity to the first path seen for it (the master). Values
    // are owned here.
    var inodes: std.AutoHashMapUnmanaged(hardlink.Key, []u8) = .empty;
    defer {
        var it = inodes.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        inodes.deinit(gpa);
    }

    const filter: Filter = .{ .patterns = excludes };

    // Preserve the destination root's own metadata (like rsync -a).
    if (structure) try sendDir(io, gpa, w, src_dir, ".", eff);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (filter.skip(&walker, io, entry.path, entry.kind)) continue;
        switch (entry.kind) {
            .directory => if (structure) {
                try sendDir(io, gpa, w, src_dir, entry.path, eff);
                stats.dirs += 1;
            },
            .sym_link => if (structure) {
                try sendSymlink(io, w, src_dir, entry.path, eff);
                stats.symlinks += 1;
            },
            .file => if (shard == null or shard.?.hasFile(entry.path)) {
                if (detect_hl and try isHardlinkNotFirst(io, gpa, src_dir, entry.path, &inodes, w)) {
                    stats.hardlinks += 1;
                } else {
                    try sendFile(io, gpa, src_dir, entry.path, r, w, &stats, opts, eff);
                }
            },
            else => if (special.fromFileKind(entry.kind)) |sk| {
                if (structure) {
                    try sendSpecial(w, src_dir, entry.path, sk);
                    stats.specials += 1;
                }
            } else {
                stats.entries_ignored += 1;
                if (opts.verbose) std.log.info("ignored {s} ({s})", .{ entry.path, @tagName(entry.kind) });
            },
        }
    }

    try wire.putTag(w, .done);
    try w.flush();
    return stats;
}

// ---------------------------------------------------------------------------
// Parallel push (one control connection + N file-shard workers)
// ---------------------------------------------------------------------------

/// A worker connection: transfers a shard of files. `opts.delete` must be false
/// (workers never prune). Does not send the structure or finalize.
pub fn runFileShard(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    r: *Reader,
    w: *Writer,
    opts: Options,
    role: Role,
    paths: []const []const u8,
) !SenderStats {
    const neg = try negotiate(gpa, r, w, role, opts);
    defer freeExcludes(gpa, neg.excludes);
    const eff = neg.flags;
    var stats: SenderStats = .{};
    for (paths) |p| try sendFile(io, gpa, src_dir, p, r, w, &stats, opts, eff);
    try wire.putTag(w, .done);
    try w.flush();
    return stats;
}

/// The control connection: creates the directory tree + symlinks and, when
/// deleting, records every file path in the keep-set. Metadata and `--delete`
/// happen when the caller later sends `done` via `finishStructure` — which must
/// be after all workers have finished writing.
pub const SpecialEnt = struct { path: []const u8, kind: special.Kind };

pub fn runStructure(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    r: *Reader,
    w: *Writer,
    opts: Options,
    role: Role,
    dirs: []const []const u8,
    symlinks: []const []const u8,
    specials: []const SpecialEnt,
    keep_files: []const []const u8,
) !SenderStats {
    const neg = try negotiate(gpa, r, w, role, opts);
    defer freeExcludes(gpa, neg.excludes);
    const eff = neg.flags;
    var stats: SenderStats = .{};

    try sendDir(io, gpa, w, src_dir, ".", eff); // root metadata
    for (dirs) |d| {
        try sendDir(io, gpa, w, src_dir, d, eff);
        stats.dirs += 1;
    }
    for (symlinks) |l| {
        try sendSymlink(io, w, src_dir, l, eff);
        stats.symlinks += 1;
    }
    for (specials) |s| {
        try sendSpecial(w, src_dir, s.path, s.kind);
        stats.specials += 1;
    }
    if (opts.delete) for (keep_files) |f| try sendKeep(w, f);
    try w.flush();
    return stats;
}

/// Tells the control connection to finalize (apply directory metadata and run
/// `--delete`). Call only after every worker connection has completed.
pub fn finishStructure(w: *Writer) !void {
    try wire.putTag(w, .done);
    try w.flush();
}

fn sendFile(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    path: []const u8,
    r: *Reader,
    w: *Writer,
    stats: *SenderStats,
    opts: Options,
    eff: Flags,
) !void {
    stats.files_total += 1;

    var f = try src_dir.openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    var xset: xattr.Set = .{};
    if (eff.xattrs) xset = xattr.readFd(gpa, f.handle) catch .{};
    defer xset.deinit(gpa);

    try wire.putTag(w, .file);
    try wire.putBytes(w, path);
    try wire.putUvarint(w, @intFromEnum(st.permissions));
    try wire.putZigzag(w, @intCast(st.mtime.nanoseconds));
    try wire.putUvarint(w, st.size);
    if (eff.preserveIds()) try putIds(w, src_dir, path);
    if (eff.xattrs) try putXattrs(w, xset);
    try w.flush();

    switch (try wire.getTag(r)) {
        .skip => {
            stats.files_skipped += 1;
            if (opts.verbose) std.log.info("skip  {s}", .{path});
            return;
        },
        .sig => {},
        else => return ProtocolError.UnexpectedTag,
    }

    var sig = try readSignature(gpa, r);
    defer sig.deinit(gpa);

    // Stream the source through the matcher, emitting ops straight to the wire
    // and hashing it for end-to-end verification. Constant memory.
    var rbuf: [64 * 1024]u8 = undefined;
    var freader = f.reader(io, &rbuf);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var sink: WireSink = .{ .gpa = gpa, .w = w, .block_size = sig.block_size, .file_len = sig.file_len, .compress = eff.compress };
    try stream.match(gpa, sig, &freader.interface, &hasher, &sink);

    try wire.putTag(w, .end);
    var whole: [32]u8 = undefined;
    hasher.final(&whole);
    try w.writeAll(&whole);
    try w.flush();

    stats.literal_bytes += sink.literal_bytes;
    stats.matched_bytes += sink.matched_bytes;
    stats.files_sent += 1;
    if (opts.verbose) std.log.info("delta {s}", .{path});
}

fn readSignature(gpa: Allocator, r: *Reader) !signature.Signature {
    const block_size: u32 = @intCast(try wire.getUvarint(r));
    const file_len = try wire.getUvarint(r);
    const count = try wire.getUvarint(r);

    const blocks = try gpa.alloc(signature.Block, @intCast(count));
    errdefer gpa.free(blocks);
    for (blocks) |*b| {
        b.weak = @intCast(try wire.getUvarint(r));
        try r.readSliceAll(&b.strong);
    }
    return .{ .block_size = block_size, .file_len = file_len, .blocks = blocks };
}

// ---------------------------------------------------------------------------
// Receiver (destination side)
// ---------------------------------------------------------------------------

/// Frees a directory-metadata list produced by the receive loop.
pub fn freeDirMeta(gpa: Allocator, dirmeta: *std.ArrayList(meta.DirMeta)) void {
    for (dirmeta.items) |*m| {
        gpa.free(m.path);
        m.xattrs.deinit(gpa);
    }
    dirmeta.deinit(gpa);
}

pub fn runReceiver(io: Io, gpa: Allocator, dst_dir: Dir, r: *Reader, w: *Writer, role: Role, opts: Options) !ReceiverStats {
    const neg = try negotiate(gpa, r, w, role, opts);
    defer freeExcludes(gpa, neg.excludes);
    const eff = neg.flags;

    var kept: prune.KeptSet = .empty;
    defer prune.freeKept(gpa, &kept);
    var dirmeta: std.ArrayList(meta.DirMeta) = .empty;
    defer freeDirMeta(gpa, &dirmeta);

    var stats: ReceiverStats = .{};
    const completed = try receiveLoop(io, gpa, dst_dir, r, w, eff, &kept, &dirmeta, &stats);

    // Prune only after a clean `done`; a dropped connection (EOF) leaves the
    // transfer incomplete, so deleting "extras" then could remove real files.
    if (completed and eff.delete) stats.deleted = try prune.deleteExtraneous(io, gpa, dst_dir, &kept);
    // Directory perms/mtime last: after writes and deletions stopped touching them.
    meta.applyDirs(io, dst_dir, dirmeta.items);
    return stats;
}

/// Like `runReceiver` but accumulates into caller-owned `kept`/`dirmeta` and
/// does NOT finalize (no prune, no `applyDirs`). Used for sharded pull, where
/// the client merges N shards' state and finalizes once. Returns `.deleted = 0`.
pub fn runReceiverShard(
    io: Io,
    gpa: Allocator,
    dst_dir: Dir,
    r: *Reader,
    w: *Writer,
    role: Role,
    opts: Options,
    kept: *prune.KeptSet,
    dirmeta: *std.ArrayList(meta.DirMeta),
) !ReceiverStats {
    const neg = try negotiate(gpa, r, w, role, opts);
    defer freeExcludes(gpa, neg.excludes);
    const eff = neg.flags;
    var stats: ReceiverStats = .{};
    _ = try receiveLoop(io, gpa, dst_dir, r, w, eff, kept, dirmeta, &stats);
    return stats;
}

/// Processes messages until `done`/EOF, applying files/dirs/symlinks and
/// recording paths into `kept` and directory metadata into `dirmeta`. Returns
/// whether a clean `done` was seen (finalization is the caller's job).
fn receiveLoop(
    io: Io,
    gpa: Allocator,
    dst_dir: Dir,
    r: *Reader,
    w: *Writer,
    eff: Flags,
    kept: *prune.KeptSet,
    dirmeta: *std.ArrayList(meta.DirMeta),
    stats: *ReceiverStats,
) !bool {
    var completed = false;
    while (true) {
        const tag = wire.getTag(r) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        switch (tag) {
            .keep => {
                const path = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(path);
                try prune.keep(gpa, kept, path);
            },
            .special => {
                const path = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(path);
                const info: special.Info = .{
                    .kind = @enumFromInt(@as(u8, @intCast(try wire.getUvarint(r)))),
                    .perm = @intCast(try wire.getUvarint(r)),
                    .major = @intCast(try wire.getUvarint(r)),
                    .minor = @intCast(try wire.getUvarint(r)),
                };
                if (std.fs.path.dirname(path)) |p| try dst_dir.createDirPath(io, p);
                special.place(dst_dir, info, path);
                try prune.keep(gpa, kept, path);
                stats.specials += 1;
            },
            .mkdir => {
                const path = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(path);
                const perm: Perm = @enumFromInt(@as(PermInt, @intCast(try wire.getUvarint(r))));
                const mtime_ns = try wire.getZigzag(r);
                const ids: ?owner.Ids = if (eff.preserveIds()) try getIds(r) else null;
                const xs: xattr.Set = if (eff.xattrs) try getXattrs(gpa, r) else .{};
                // "." is the destination root: don't create or delete it, just
                // record its metadata.
                const is_root = std.mem.eql(u8, path, ".");
                if (!is_root) {
                    try dst_dir.createDirPath(io, path);
                    try prune.keep(gpa, kept, path);
                    stats.dirs += 1;
                }
                try dirmeta.append(gpa, .{
                    .path = try gpa.dupe(u8, path),
                    .perm = perm,
                    .mtime_ns = mtime_ns,
                    .uid = if (ids != null and eff.owner) ids.?.uid else null,
                    .gid = if (ids != null and eff.group) ids.?.gid else null,
                    .xattrs = xs,
                });
            },
            .symlink => {
                const path = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(path);
                const target = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(target);
                const ids: ?owner.Ids = if (eff.preserveIds()) try getIds(r) else null;
                try link.place(io, dst_dir, path, target);
                if (ids) |i| applyIds(io, dst_dir, path, i, eff, false);
                try prune.keep(gpa, kept, path);
                stats.symlinks += 1;
            },
            .hardlink => {
                const path = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(path);
                const master = try wire.getBytesAlloc(r, gpa);
                defer gpa.free(master);
                // The master was sent (and written) before this message.
                hardlink.place(io, dst_dir, master, path);
                try prune.keep(gpa, kept, path);
                stats.hardlinks += 1;
            },
            .file => try receiveFile(io, gpa, dst_dir, r, w, stats, kept, eff),
            .done => {
                completed = true;
                break;
            },
            else => return ProtocolError.UnexpectedTag,
        }
    }
    return completed;
}

fn receiveFile(io: Io, gpa: Allocator, dst_dir: Dir, r: *Reader, w: *Writer, stats: *ReceiverStats, kept: *prune.KeptSet, eff: Flags) !void {
    const path = try wire.getBytesAlloc(r, gpa);
    defer gpa.free(path);
    try prune.keep(gpa, kept, path);
    const perm: Perm = @enumFromInt(@as(PermInt, @intCast(try wire.getUvarint(r))));
    const mtime_ns = try wire.getZigzag(r);
    const src_size = try wire.getUvarint(r);
    const ids: ?owner.Ids = if (eff.preserveIds()) try getIds(r) else null;
    var xset: xattr.Set = if (eff.xattrs) try getXattrs(gpa, r) else .{};
    defer xset.deinit(gpa);

    // Quick-check against our current copy, if any.
    const cur = dst_dir.statFile(io, path, .{}) catch null;
    if (cur) |c| {
        if (c.size == src_size and c.mtime.nanoseconds == mtime_ns and c.permissions == perm) {
            try wire.putTag(w, .skip);
            try w.flush();
            stats.files_skipped += 1;
            return;
        }
    }

    // Open the basis for positional reads instead of loading it. Its signature
    // is generated block-by-block, and COPY ops pread individual blocks.
    var basis_file: ?Io.File = null;
    defer if (basis_file) |bf| bf.close(io);
    var basis_len: u64 = 0;
    if (cur != null) {
        const bf = try dst_dir.openFile(io, path, .{});
        basis_file = bf;
        basis_len = (try bf.stat(io)).size;
    }

    const block_size = signature.chooseBlockSize(basis_len);
    var sig = if (basis_file) |bf|
        try signature.generatePositional(gpa, io, bf, block_size)
    else
        try signature.generate(gpa, &.{}, block_size);
    defer sig.deinit(gpa);

    try wire.putTag(w, .sig);
    try wire.putUvarint(w, block_size);
    try wire.putUvarint(w, basis_len);
    try wire.putUvarint(w, sig.blocks.len);
    for (sig.blocks) |b| {
        try wire.putUvarint(w, b.weak);
        try w.writeAll(&b.strong);
    }
    try w.flush();

    // Stream the reconstruction straight to the atomic temp file, hashing as we
    // go. If verification fails we simply don't replace, so the temp is discarded.
    var af = try dst_dir.createFileAtomic(io, path, .{
        .permissions = perm,
        .make_path = true,
        .replace = true,
    });
    defer af.deinit(io);

    var wbuf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &wbuf);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var cbuf: [64 * 1024]u8 = undefined;
    const blockbuf = try gpa.alloc(u8, block_size);
    defer gpa.free(blockbuf);
    var expected: [32]u8 = undefined;

    while (true) {
        switch (try wire.getTag(r)) {
            .literal => {
                // With -z: orig_len, then the payload; payload shorter than
                // orig_len means it is compressed.
                const orig_len = if (eff.compress) try wire.getUvarint(r) else null;
                var remaining = try wire.getUvarint(r);
                if (orig_len) |ol| if (remaining < ol) {
                    const comp = try gpa.alloc(u8, @intCast(remaining));
                    defer gpa.free(comp);
                    try r.readSliceAll(comp);
                    const out = try zip.inflate(gpa, comp, @intCast(ol));
                    defer gpa.free(out);
                    try fw.interface.writeAll(out);
                    hasher.update(out);
                    continue;
                };
                while (remaining > 0) {
                    const take: usize = @intCast(@min(remaining, cbuf.len));
                    try r.readSliceAll(cbuf[0..take]);
                    try fw.interface.writeAll(cbuf[0..take]);
                    hasher.update(cbuf[0..take]);
                    remaining -= take;
                }
            },
            .copy => {
                const idx = try wire.getUvarint(r);
                const start = @as(u64, @intCast(idx)) * block_size;
                const want: usize = @intCast(@min(@as(u64, block_size), basis_len - start));
                const got = try basis_file.?.readPositionalAll(io, blockbuf[0..want], start);
                try fw.interface.writeAll(blockbuf[0..got]);
                hasher.update(blockbuf[0..got]);
            },
            .end => {
                try r.readSliceAll(&expected);
                break;
            },
            else => return ProtocolError.UnexpectedTag,
        }
    }
    try fw.interface.flush();

    var got: [32]u8 = undefined;
    hasher.final(&got);
    if (!std.mem.eql(u8, &got, &expected)) return ProtocolError.VerificationFailed;

    try af.file.setTimestamps(io, .{
        .modify_timestamp = .{ .new = .fromNanoseconds(mtime_ns) },
    });
    try af.replace(io);

    if (ids) |i| {
        applyIds(io, dst_dir, path, i, eff, false);
        // Restore perms in case chown cleared set-uid/gid on a regular file.
        const masked: Perm = @enumFromInt(@intFromEnum(perm) & 0o7777);
        dst_dir.setFilePermissions(io, path, masked, .{}) catch {};
    }
    if (xset.pairs.len > 0) {
        if (dst_dir.openFile(io, path, .{})) |df| {
            xattr.applyFd(df.handle, xset);
            df.close(io);
        } else |_| {}
    }

    stats.files_written += 1;
}
