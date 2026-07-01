//! Local sync driver with three per-file paths:
//!   * skip       — quick-check (size + mtime + perms) says destination is fresh
//!   * delta      — destination exists and differs: rebuild it from the delta
//!   * whole-file — destination is new, or `-W`
//!
//! Locally the delta path saves no disk I/O (both files are read anyway); it is
//! wired in here to exercise the real-file pipeline (map → signature → compute
//! → stream to atomic write) that the remote receiver runs, and to report how
//! many bytes the delta would have had to send over a wire. Files are mmap'd
//! (demand-paged), so there is no size limit.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

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

pub const Options = struct {
    verbose: bool = false,
    /// Force whole-file copies even when a basis exists (disables delta).
    whole_file: bool = false,
    /// Worker count for the file pass. 0 means auto (one per CPU).
    jobs: usize = 0,
    /// Delete destination entries the source didn't offer (mirror mode).
    delete: bool = false,
    /// Preserve owning user / group (best-effort; needs privilege).
    owner: bool = false,
    group: bool = false,
    /// Preserve extended attributes of regular files (best-effort).
    xattrs: bool = false,
    /// Preserve hardlinks (transfer shared content once).
    hard_links: bool = false,
    /// Exclude patterns (skip matching source paths).
    excludes: []const []const u8 = &.{},
};

/// Best-effort: applies xattrs to a just-written destination file.
fn applyXattrs(io: Io, dst_dir: Dir, path: []const u8, set: xattr.Set) void {
    if (set.pairs.len == 0) return;
    if (dst_dir.openFile(io, path, .{})) |df| {
        xattr.applyFd(df.handle, set);
        df.close(io);
    } else |_| {}
}

const ResolvedIds = struct { uid: ?owner.Uid = null, gid: ?owner.Gid = null };

/// The uid/gid to apply for `path`, gated by which of owner/group is requested.
fn resolveIds(opts: Options, src_dir: Dir, path: []const u8) ResolvedIds {
    if (!opts.owner and !opts.group) return .{};
    const ids = owner.read(src_dir, path) catch return .{};
    return .{
        .uid = if (opts.owner) ids.uid else null,
        .gid = if (opts.group) ids.gid else null,
    };
}

/// Applies owner to a freshly written file and restores its perms, since chown
/// can clear set-uid/gid bits on a regular file.
fn applyFileOwner(io: Io, opts: Options, src_dir: Dir, dst_dir: Dir, path: []const u8, perm: Io.File.Permissions) void {
    const ids = resolveIds(opts, src_dir, path);
    if (ids.uid == null and ids.gid == null) return;
    owner.apply(io, dst_dir, path, ids.uid, ids.gid, false);
    const masked: Io.File.Permissions = @enumFromInt(@intFromEnum(perm) & 0o7777);
    dst_dir.setFilePermissions(io, path, masked, .{}) catch {};
}

pub const Stats = struct {
    dirs: u64 = 0,
    symlinks: u64 = 0,
    specials: u64 = 0,
    hardlinks: u64 = 0,
    files_total: u64 = 0,
    files_created: u64 = 0, // destination did not exist
    files_delta: u64 = 0, // existed & changed, rebuilt via delta
    files_whole: u64 = 0, // existed & changed, copied whole (fallback)
    files_skipped: u64 = 0, // quick-check fresh
    entries_ignored: u64 = 0, // devices/fifos/... (not handled yet)
    errors: u64 = 0, // files that failed to transfer
    deleted: u64 = 0, // extraneous destination entries removed
    bytes_written: u64 = 0, // bytes landed in the destination
    delta_literal_bytes: u64 = 0, // bytes the delta path would send over a wire
    delta_matched_bytes: u64 = 0, // bytes the delta path reused from the basis

    fn merge(self: *Stats, other: Stats) void {
        inline for (@typeInfo(Stats).@"struct".fields) |f| {
            if (f.type == u64) @field(self, f.name) += @field(other, f.name);
        }
    }
};

/// A pool worker: pulls file indices off a shared atomic counter and transfers
/// each into its own private `Stats` (merged after the group joins, so no
/// locking on the hot path).
const Worker = struct {
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    dst_dir: Dir,
    files: []const []const u8,
    next: *std.atomic.Value(usize),
    opts: Options,
    stats: Stats,

    fn run(self: *Worker) void {
        while (true) {
            const idx = self.next.fetchAdd(1, .monotonic);
            if (idx >= self.files.len) return;
            const path = self.files[idx];
            transferFile(self.io, self.gpa, self.src_dir, path, self.dst_dir, path, self.opts, &self.stats) catch |err| {
                self.stats.errors += 1;
                std.log.err("{s}: {s}", .{ path, @errorName(err) });
            };
        }
    }
};

pub fn syncLocal(
    io: Io,
    gpa: Allocator,
    src_path: []const u8,
    dst_path: []const u8,
    opts: Options,
) !Stats {
    const cwd = Dir.cwd();

    const src_stat = try cwd.statFile(io, src_path, .{});
    if (src_stat.kind != .directory) {
        var stats: Stats = .{};
        try transferFile(io, gpa, cwd, src_path, cwd, dst_path, opts, &stats);
        return stats;
    }

    var src_dir = try cwd.openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    try cwd.createDirPath(io, dst_path);
    var dst_dir = try cwd.openDir(io, dst_path, .{ .iterate = true });
    defer dst_dir.close(io);

    var stats: Stats = .{};

    // `kept` owns a duped copy of every source relative path (dirs, files,
    // links); `files` aliases the file entries for the work-list, so it must
    // not free them.
    var kept: prune.KeptSet = .empty;
    defer prune.freeKept(gpa, &kept);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    // Hardlink bookkeeping (only used with `-H`). `inodes` maps a file identity
    // to its master path; `links` are the non-master paths, made after the file
    // pass. All paths alias `kept` keys.
    var inodes: std.AutoHashMapUnmanaged(hardlink.Key, []const u8) = .empty;
    defer inodes.deinit(gpa);
    const Link = struct { path: []const u8, master: []const u8 };
    var links: std.ArrayList(Link) = .empty;
    defer links.deinit(gpa);
    // Directory metadata to re-apply at the end (paths alias `kept` keys or are
    // static; the owned xattr sets are freed here).
    var dirmeta: std.ArrayList(meta.DirMeta) = .empty;
    defer {
        for (dirmeta.items) |*m| m.xattrs.deinit(gpa);
        dirmeta.deinit(gpa);
    }

    const filter: Filter = .{ .patterns = opts.excludes };

    // Phase 1 (sequential): replicate dirs and symlinks, collect files.
    {
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (filter.skip(&walker, io, entry.path, entry.kind)) continue;
            switch (entry.kind) {
                .directory => {
                    const dup = try gpa.dupe(u8, entry.path);
                    try kept.put(gpa, dup, {});
                    try dst_dir.createDirPath(io, entry.path);
                    const st = try src_dir.statFile(io, entry.path, .{});
                    const ids = resolveIds(opts, src_dir, entry.path);
                    try dirmeta.append(gpa, .{
                        .path = dup,
                        .perm = st.permissions,
                        .mtime_ns = @intCast(st.mtime.nanoseconds),
                        .uid = ids.uid,
                        .gid = ids.gid,
                        .xattrs = if (opts.xattrs) meta.readDirXattrs(gpa, io, src_dir, entry.path) else .{},
                    });
                    stats.dirs += 1;
                },
                .file => {
                    const dup = try gpa.dupe(u8, entry.path);
                    try kept.put(gpa, dup, {});
                    // With -H, route later hardlinks to their master instead of
                    // copying content again.
                    if (opts.hard_links) {
                        const st = try src_dir.statFile(io, entry.path, .{});
                        if (st.nlink > 1) {
                            const k = hardlink.key(src_dir, entry.path, @intCast(st.inode));
                            if (inodes.get(k)) |master| {
                                try links.append(gpa, .{ .path = dup, .master = master });
                                continue;
                            }
                            try inodes.put(gpa, k, dup);
                        }
                    }
                    try files.append(gpa, dup);
                },
                .sym_link => {
                    var buf: [link.max_target]u8 = undefined;
                    const target = try link.readTarget(io, src_dir, entry.path, &buf);
                    try link.place(io, dst_dir, entry.path, target);
                    const ids = resolveIds(opts, src_dir, entry.path);
                    owner.apply(io, dst_dir, entry.path, ids.uid, ids.gid, false);
                    try prune.keep(gpa, &kept, entry.path);
                    stats.symlinks += 1;
                    if (opts.verbose) std.log.info("link  {s} -> {s}", .{ entry.path, target });
                },
                else => if (special.fromFileKind(entry.kind)) |sk| {
                    const info = try special.read(src_dir, entry.path, sk);
                    if (std.fs.path.dirname(entry.path)) |p| try dst_dir.createDirPath(io, p);
                    special.place(dst_dir, info, entry.path);
                    try prune.keep(gpa, &kept, entry.path);
                    stats.specials += 1;
                } else {
                    stats.entries_ignored += 1;
                    if (opts.verbose) std.log.info("ignored {s} ({s})", .{ entry.path, @tagName(entry.kind) });
                },
            }
        }
    }

    // The destination root's own metadata (like rsync -a preserves the top dir).
    {
        const rst = try src_dir.statFile(io, ".", .{});
        const rids = resolveIds(opts, src_dir, ".");
        try dirmeta.append(gpa, .{
            .path = ".",
            .perm = rst.permissions,
            .mtime_ns = @intCast(rst.mtime.nanoseconds),
            .uid = rids.uid,
            .gid = rids.gid,
            .xattrs = if (opts.xattrs) meta.readDirXattrs(gpa, io, src_dir, ".") else .{},
        });
    }

    if (files.items.len != 0) try runFilePass(io, gpa, src_dir, dst_dir, files.items, opts, &stats);
    // Hardlinks after the masters are written (they dirty parent mtimes, so
    // before applyDirs).
    for (links.items) |l| {
        hardlink.place(io, dst_dir, l.master, l.path);
        stats.hardlinks += 1;
    }
    if (opts.delete) stats.deleted = try prune.deleteExtraneous(io, gpa, dst_dir, &kept);
    // Directory perms/mtime last: after writes and deletions stopped touching them.
    meta.applyDirs(io, dst_dir, dirmeta.items);
    return stats;
}

fn runFilePass(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    dst_dir: Dir,
    files: []const []const u8,
    opts: Options,
    stats: *Stats,
) !void {
    // Each file is independent, so fan them out across a bounded pool. Files
    // land atomically, so concurrent writers don't clash.
    const njobs = resolveJobs(opts.jobs, files.len);
    const workers = try gpa.alloc(Worker, njobs);
    defer gpa.free(workers);

    var next = std.atomic.Value(usize).init(0);
    for (workers) |*wk| wk.* = .{
        .io = io,
        .gpa = gpa,
        .src_dir = src_dir,
        .dst_dir = dst_dir,
        .files = files,
        .next = &next,
        .opts = opts,
        .stats = .{},
    };

    var group: Io.Group = .init;
    // Spawn all but one onto the pool; run the last inline so the calling
    // thread participates instead of idling in `await`.
    for (workers[1..]) |*wk| {
        group.concurrent(io, Worker.run, .{wk}) catch wk.run();
    }
    workers[0].run();
    try group.await(io);

    for (workers) |wk| stats.merge(wk.stats);
}

fn resolveJobs(requested: usize, file_count: usize) usize {
    const base = if (requested != 0)
        requested
    else
        (std.Thread.getCpuCount() catch 1);
    return @max(1, @min(base, file_count));
}

fn transferFile(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    src_rel: []const u8,
    dst_dir: Dir,
    dst_rel: []const u8,
    opts: Options,
    stats: *Stats,
) !void {
    stats.files_total += 1;

    var src_file = try src_dir.openFile(io, src_rel, .{});
    defer src_file.close(io);
    const src_stat = try src_file.stat(io);

    var xset: xattr.Set = .{};
    defer xset.deinit(gpa);
    if (opts.xattrs) xset = xattr.readFd(gpa, src_file.handle) catch .{};

    const dst_stat: ?Io.File.Stat = blk: {
        var f = dst_dir.openFile(io, dst_rel, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk null,
            else => |e| return e,
        };
        defer f.close(io);
        break :blk try f.stat(io);
    };

    if (dst_stat) |d| {
        if (src_stat.size == d.size and
            src_stat.mtime.nanoseconds == d.mtime.nanoseconds and
            src_stat.permissions == d.permissions)
        {
            stats.files_skipped += 1;
            if (opts.verbose) std.log.info("skip  {s}", .{src_rel});
            return;
        }

        // A basis exists: use the delta path (files are mmap'd, so size is not
        // a memory concern). Empty basis has nothing to match, so copy whole.
        if (!opts.whole_file and d.size > 0) {
            try deltaTransfer(io, gpa, src_dir, src_rel, dst_dir, dst_rel, src_stat, opts, stats);
            applyXattrs(io, dst_dir, dst_rel, xset); // owner applied inside deltaTransfer
            return;
        }
    }

    // New destination, or a change we won't delta: whole-file copy.
    _ = try src_dir.updateFile(io, src_rel, dst_dir, dst_rel, .{});
    applyFileOwner(io, opts, src_dir, dst_dir, dst_rel, src_stat.permissions);
    applyXattrs(io, dst_dir, dst_rel, xset);
    stats.bytes_written += src_stat.size;
    if (dst_stat == null) {
        stats.files_created += 1;
        if (opts.verbose) std.log.info("new   {s}", .{src_rel});
    } else {
        stats.files_whole += 1;
        if (opts.verbose) std.log.info("whole {s}", .{src_rel});
    }
}

fn deltaTransfer(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    src_rel: []const u8,
    dst_dir: Dir,
    dst_rel: []const u8,
    src_stat: Io.File.Stat,
    opts: Options,
    stats: *Stats,
) !void {
    // Positional reads on the basis + a streaming scan of the source keep memory
    // bounded regardless of file size.
    var dst_file = try dst_dir.openFile(io, dst_rel, .{});
    defer dst_file.close(io);
    const basis_len = (try dst_file.stat(io)).size;

    var src_file = try src_dir.openFile(io, src_rel, .{});
    defer src_file.close(io);

    const block_size = signature.chooseBlockSize(basis_len);
    var sig = try signature.generatePositional(gpa, io, dst_file, block_size);
    defer sig.deinit(gpa);

    var af = try dst_dir.createFileAtomic(io, dst_rel, .{
        .permissions = src_stat.permissions,
        .make_path = true,
        .replace = true,
    });
    defer af.deinit(io);

    var wbuf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &wbuf);

    const blockbuf = try gpa.alloc(u8, block_size);
    defer gpa.free(blockbuf);

    // Stream the source through the matcher; the sink copies basis blocks (by
    // positional read) and literal runs straight to the output. No verify needed
    // locally: the result is `new` by construction (round-trip is tested).
    var rbuf: [64 * 1024]u8 = undefined;
    var freader = src_file.reader(io, &rbuf);
    var sink: LocalSink = .{
        .io = io,
        .basis = dst_file,
        .basis_len = basis_len,
        .block_size = block_size,
        .fw = &fw,
        .blockbuf = blockbuf,
    };
    try stream.match(gpa, sig, &freader.interface, null, &sink);

    try fw.interface.flush();
    try af.file.setTimestamps(io, .{
        .access_timestamp = .init(src_stat.atime),
        .modify_timestamp = .init(src_stat.mtime),
    });
    try af.replace(io);
    applyFileOwner(io, opts, src_dir, dst_dir, dst_rel, src_stat.permissions);

    stats.files_delta += 1;
    stats.bytes_written += @as(u64, @intCast(src_stat.size));
    stats.delta_literal_bytes += sink.literal;
    stats.delta_matched_bytes += sink.matched;
    if (opts.verbose) std.log.info("delta {s} (sent {d}, reused {d})", .{ src_rel, sink.literal, sink.matched });
}

/// Streaming-matcher sink for local sync: expands ops directly into the output
/// file, reading reused blocks from the basis by positional read.
const LocalSink = struct {
    io: Io,
    basis: Io.File,
    basis_len: u64,
    block_size: u32,
    fw: *Io.File.Writer,
    blockbuf: []u8,
    literal: u64 = 0,
    matched: u64 = 0,

    pub fn emitLiteral(self: *LocalSink, bytes: []const u8) !void {
        try self.fw.interface.writeAll(bytes);
        self.literal += bytes.len;
    }
    pub fn emitCopy(self: *LocalSink, idx: u32) !void {
        const start = @as(u64, idx) * self.block_size;
        const want: usize = @intCast(@min(@as(u64, self.block_size), self.basis_len - start));
        const got = try self.basis.readPositionalAll(self.io, self.blockbuf[0..want], start);
        try self.fw.interface.writeAll(self.blockbuf[0..got]);
        self.matched += got;
    }
};
