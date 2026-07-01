//! Parallel push over multiple SSH connections.
//!
//! One *control* connection creates the directory tree + symlinks and carries
//! the delete keep-set; N *worker* connections each transfer a shard of the
//! files. The control connection finalizes (directory/root metadata, then
//! `--delete`) only after every worker has finished — writing files re-dirties
//! directory mtimes, and a premature delete could race real files.
//!
//! Only push is handled here (source is local). Pull sharding is future work.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Reader = Io.Reader;
const Writer = Io.Writer;
const session = @import("session.zig");
const prune = @import("../fs/prune.zig");
const meta = @import("../fs/meta.zig");
const special = @import("../fs/special.zig");
const Filter = @import("filter.zig").Filter;

const buf_size = 64 * 1024;

/// One SSH subprocess plus its stdio reader/writer. Heap-stable so the
/// reader/writer can point at the inline buffers.
const Conn = struct {
    child: std.process.Child = undefined,
    in_buf: [buf_size]u8 = undefined,
    out_buf: [buf_size]u8 = undefined,
    wr: Io.File.Writer = undefined,
    rd: Io.File.Reader = undefined,

    fn setup(self: *Conn, io: Io) void {
        self.wr = .init(self.child.stdin.?, io, &self.out_buf);
        self.rd = .init(self.child.stdout.?, io, &self.in_buf);
    }
    fn writer(self: *Conn) *Writer {
        return &self.wr.interface;
    }
    fn reader(self: *Conn) *Reader {
        return &self.rd.interface;
    }
    fn close(self: *Conn, io: Io) !std.process.Child.Term {
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        return self.child.wait(io);
    }
};

const FileEnt = struct { path: []const u8, size: u64 };

const Worker = struct {
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    conn: *Conn,
    opts: session.Options,
    shard: []const []const u8,
    stats: session.SenderStats = .{},
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        self.stats = session.runFileShard(
            self.io,
            self.gpa,
            self.src_dir,
            self.conn.reader(),
            self.conn.writer(),
            self.opts,
            .initiator,
            self.shard,
        ) catch |e| {
            self.err = e;
            return;
        };
    }
};

fn spawnChild(io: Io, argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
}

// ---------------------------------------------------------------------------
// Parallel pull (N sharded server-senders → one merged client receiver)
// ---------------------------------------------------------------------------

const PullShard = struct {
    io: Io,
    gpa: Allocator,
    dst_dir: Dir,
    conn: *Conn,
    opts: session.Options,
    kept: prune.KeptSet = .empty,
    dirmeta: std.ArrayList(meta.DirMeta) = .empty,
    stats: session.ReceiverStats = .{},
    err: ?anyerror = null,

    fn run(self: *PullShard) void {
        self.stats = session.runReceiverShard(
            self.io,
            self.gpa,
            self.dst_dir,
            self.conn.reader(),
            self.conn.writer(),
            .initiator,
            self.opts,
            &self.kept,
            &self.dirmeta,
        ) catch |e| {
            self.err = e;
            return;
        };
    }
};

pub fn pullParallel(
    io: Io,
    gpa: Allocator,
    dst_dir: Dir,
    rsh: []const u8,
    host: []const u8,
    remote_zync: []const u8,
    src_path: []const u8,
    opts: session.Options,
    conns: usize,
) !session.ReceiverStats {
    const n = @max(1, conns);

    const cs = try gpa.alloc(Conn, n);
    defer gpa.free(cs);
    const shard_strs = try gpa.alloc([]u8, n);
    defer {
        for (shard_strs) |s| gpa.free(s);
        gpa.free(shard_strs);
    }

    var spawned: usize = 0;
    errdefer for (cs[0..spawned]) |*c| {
        _ = c.close(io) catch {};
    };
    for (0..n) |k| {
        shard_strs[k] = try std.fmt.allocPrint(gpa, "{d}/{d}", .{ k, n });
        const argv = [_][]const u8{ rsh, host, remote_zync, "--server", "--sender", "--shard", shard_strs[k], src_path };
        cs[k].child = try spawnChild(io, &argv);
        cs[k].setup(io);
        spawned += 1;
    }

    const shards = try gpa.alloc(PullShard, n);
    defer {
        for (shards) |*s| {
            prune.freeKept(gpa, &s.kept);
            session.freeDirMeta(gpa, &s.dirmeta);
        }
        gpa.free(shards);
    }
    for (0..n) |k| shards[k] = .{ .io = io, .gpa = gpa, .dst_dir = dst_dir, .conn = &cs[k], .opts = opts };

    var group: Io.Group = .init;
    for (shards[1..]) |*s| group.concurrent(io, PullShard.run, .{s}) catch s.run();
    shards[0].run();
    try group.await(io);

    var failed = false;
    for (shards) |s| if (s.err != null) {
        failed = true;
    };

    var deleted: u64 = 0;
    if (!failed) {
        // Delete first, then set directory metadata last — deleting an entry
        // re-dirties its parent's mtime, so metadata must be applied after.
        if (opts.delete) {
            const kepts = try gpa.alloc(prune.KeptSet, n);
            defer gpa.free(kepts);
            for (0..n) |k| kepts[k] = shards[k].kept;
            deleted = try prune.deleteExtraneousMulti(io, gpa, dst_dir, kepts);
        }
        // Directory/root metadata after all writes (only shard 0 has any).
        for (shards) |*s| meta.applyDirs(io, dst_dir, s.dirmeta.items);
    }

    for (cs) |*c| {
        const term = c.close(io) catch {
            failed = true;
            continue;
        };
        if (!failed and (term != .exited or term.exited != 0)) failed = true;
    }

    if (failed) return error.RemoteFailed;

    var total: session.ReceiverStats = .{ .deleted = deleted };
    for (shards) |s| {
        total.dirs += s.stats.dirs;
        total.symlinks += s.stats.symlinks;
        total.files_written += s.stats.files_written;
        total.files_skipped += s.stats.files_skipped;
    }
    return total;
}

pub fn pushParallel(
    io: Io,
    gpa: Allocator,
    src_dir: Dir,
    argv: []const []const u8,
    opts: session.Options,
    conns: usize,
) !session.SenderStats {
    // --- scan the source tree (paths + file sizes for balancing) --------
    var dirs: std.ArrayList([]const u8) = .empty;
    var symlinks: std.ArrayList([]const u8) = .empty;
    var specials: std.ArrayList(session.SpecialEnt) = .empty;
    var files: std.ArrayList(FileEnt) = .empty;
    defer {
        for (dirs.items) |p| gpa.free(p);
        for (symlinks.items) |p| gpa.free(p);
        for (specials.items) |s| gpa.free(s.path);
        for (files.items) |f| gpa.free(f.path);
        dirs.deinit(gpa);
        symlinks.deinit(gpa);
        specials.deinit(gpa);
        files.deinit(gpa);
    }
    const filter: Filter = .{ .patterns = opts.excludes };
    {
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (filter.skip(&walker, io, e.path, e.kind)) continue;
            switch (e.kind) {
                .directory => try dirs.append(gpa, try gpa.dupe(u8, e.path)),
                .sym_link => try symlinks.append(gpa, try gpa.dupe(u8, e.path)),
                .file => {
                    const st = src_dir.statFile(io, e.path, .{}) catch continue;
                    try files.append(gpa, .{ .path = try gpa.dupe(u8, e.path), .size = st.size });
                },
                else => if (special.fromFileKind(e.kind)) |sk|
                    try specials.append(gpa, .{ .path = try gpa.dupe(u8, e.path), .kind = sk }),
            }
        }
    }

    // Keep-set for --delete is every file path (order irrelevant).
    const all_paths = try gpa.alloc([]const u8, files.items.len);
    defer gpa.free(all_paths);
    for (files.items, 0..) |f, i| all_paths[i] = f.path;

    // --- partition files across workers (LPT: largest first, least-loaded) ---
    const nw = @min(conns, files.items.len);
    var shards = try gpa.alloc(std.ArrayList([]const u8), nw);
    defer {
        for (shards) |*s| s.deinit(gpa);
        gpa.free(shards);
    }
    for (shards) |*s| s.* = .empty;

    if (nw > 0) {
        std.mem.sort(FileEnt, files.items, {}, struct {
            fn desc(_: void, a: FileEnt, b: FileEnt) bool {
                return a.size > b.size;
            }
        }.desc);
        const loads = try gpa.alloc(u64, nw);
        defer gpa.free(loads);
        @memset(loads, 0);
        for (files.items) |f| {
            var k: usize = 0;
            for (loads[1..], 1..) |l, i| if (l < loads[k]) {
                k = i;
            };
            try shards[k].append(gpa, f.path);
            loads[k] += f.size;
        }
    }

    // --- spawn connections: [0] control, [1..] workers ------------------
    const cs = try gpa.alloc(Conn, nw + 1);
    defer gpa.free(cs);
    var spawned: usize = 0;
    errdefer for (cs[0..spawned]) |*c| {
        _ = c.close(io) catch {};
    };
    for (cs) |*c| {
        c.child = try spawnChild(io, argv);
        c.setup(io);
        spawned += 1;
    }

    // --- run: workers concurrently, control structure on this thread ----
    var wopts = opts;
    wopts.delete = false; // only the control connection prunes

    const workers = try gpa.alloc(Worker, nw);
    defer gpa.free(workers);
    for (0..nw) |k| workers[k] = .{
        .io = io,
        .gpa = gpa,
        .src_dir = src_dir,
        .conn = &cs[k + 1],
        .opts = wopts,
        .shard = shards[k].items,
    };

    var group: Io.Group = .init;
    for (workers) |*wk| group.concurrent(io, Worker.run, .{wk}) catch wk.run();

    var control_err: ?anyerror = null;
    const control_stats = session.runStructure(
        io,
        gpa,
        src_dir,
        cs[0].reader(),
        cs[0].writer(),
        opts,
        .initiator,
        dirs.items,
        symlinks.items,
        specials.items,
        all_paths,
    ) catch |e| blk: {
        control_err = e;
        break :blk session.SenderStats{};
    };

    try group.await(io);

    // --- finalize only if everything succeeded --------------------------
    var failed = control_err != null;
    for (workers) |wk| if (wk.err != null) {
        failed = true;
    };

    // Wait for the worker *server* processes to exit before finalizing: a client
    // task returning only means its data was sent, not that the server has
    // finished writing. The control's applyDirs/prune must run strictly after
    // all files have landed.
    for (cs[1..]) |*c| {
        const term = c.close(io) catch {
            failed = true;
            continue;
        };
        if (!failed and (term != .exited or term.exited != 0)) failed = true;
    }

    // Now finalize on the control connection (closing its stdin without `done`
    // leaves the server at EOF, so it won't prune an incomplete transfer).
    if (!failed) session.finishStructure(cs[0].writer()) catch {
        failed = true;
    };
    if (cs[0].close(io)) |term| {
        if (!failed and (term != .exited or term.exited != 0)) failed = true;
    } else |_| {
        failed = true;
    }
    spawned = 0; // all children reaped; disable the spawn-phase errdefer

    if (failed) return control_err orelse error.RemoteFailed;

    // --- aggregate ------------------------------------------------------
    var total = control_stats;
    for (workers) |wk| {
        total.files_total += wk.stats.files_total;
        total.files_sent += wk.stats.files_sent;
        total.files_skipped += wk.stats.files_skipped;
        total.entries_ignored += wk.stats.entries_ignored;
        total.literal_bytes += wk.stats.literal_bytes;
        total.matched_bytes += wk.stats.matched_bytes;
    }
    return total;
}
