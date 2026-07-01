//! zync CLI entry point. Thin by design: parse args, pick a mode, dispatch into
//! the library. All real work lives in the `zync` module (src/root.zig).

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const zync = @import("zync");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = zync.cli.parse(args) catch |err| switch (err) {
        error.HelpRequested => {
            try stderr.writeAll(zync.cli.usage);
            try stderr.flush();
            return;
        },
        error.MissingArgs => return fail(stderr, "expected <src> and <dst>"),
        error.TooManyArgs => return fail(stderr, "too many paths"),
        error.UnknownFlag => return fail(stderr, "unknown flag"),
        error.MissingValue => return fail(stderr, "option is missing its value"),
        error.BadValue => return fail(stderr, "invalid option value"),
    };

    switch (parsed.mode) {
        .server => |s| {
            if (s.sender) try serveSender(io, gpa, s.path, s.shard) else try serveReceiver(io, gpa, s.path);
        },
        .transfer => |t| try runTransfer(io, gpa, stderr, parsed, t.src, t.dst),
    }
}

// --- server (remote peer) roles ------------------------------------------------

fn serveReceiver(io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, path);
    var dst_dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dst_dir.close(io);

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), io, &in_buf);
    var out: Io.File.Writer = .init(.stdout(), io, &out_buf);
    // The `--delete` intent arrives from the sender via the handshake.
    _ = try zync.session.runReceiver(io, gpa, dst_dir, &in.interface, &out.interface, .responder, .{});
}

fn serveSender(io: Io, gpa: std.mem.Allocator, path: []const u8, shard_spec: ?zync.cli.ShardSpec) !void {
    var src_dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer src_dir.close(io);

    const shard: ?zync.session.Shard = if (shard_spec) |s| .{ .index = s.index, .count = s.count } else null;

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var in: Io.File.Reader = .init(.stdin(), io, &in_buf);
    var out: Io.File.Writer = .init(.stdout(), io, &out_buf);
    _ = try zync.session.runSender(io, gpa, src_dir, &in.interface, &out.interface, .{}, .responder, shard);
}

// --- local invocation ----------------------------------------------------------

fn runTransfer(
    io: Io,
    gpa: std.mem.Allocator,
    stderr: *Io.Writer,
    parsed: zync.cli.Parsed,
    src_spec: []const u8,
    dst_spec: []const u8,
) !void {
    const src = zync.Endpoint.parse(src_spec);
    const dst = zync.Endpoint.parse(dst_spec);

    if (src.isLocal() and dst.isLocal()) {
        const stats = try zync.sync.syncLocal(io, gpa, src.path, dst.path, .{
            .verbose = parsed.verbose or parsed.progress,
            .whole_file = parsed.whole_file,
            .jobs = parsed.jobs,
            .delete = parsed.delete,
            .owner = parsed.owner,
            .group = parsed.group,
            .xattrs = parsed.xattrs,
            .hard_links = parsed.hard_links,
            .excludes = parsed.excludes(),
        });
        if (parsed.json) {
            try jsonLine(io, "{{\"mode\":\"local\",\"dirs\":{d},\"symlinks\":{d},\"specials\":{d},\"hardlinks\":{d},\"files\":{d},\"new\":{d},\"delta\":{d},\"whole\":{d},\"skipped\":{d},\"ignored\":{d},\"errors\":{d},\"bytes_written\":{d},\"delta_sent\":{d},\"delta_reused\":{d},\"deleted\":{d}}}", .{
                stats.dirs,                stats.symlinks,            stats.specials,    stats.hardlinks,
                stats.files_total,         stats.files_created,       stats.files_delta, stats.files_whole,
                stats.files_skipped,       stats.entries_ignored,     stats.errors,      stats.bytes_written,
                stats.delta_literal_bytes, stats.delta_matched_bytes, stats.deleted,
            });
        } else {
            try stderr.print(
                "zync: {d} dirs, {d} links, {d} specials, {d} hardlinks, {d} files ({d} new, {d} delta, {d} whole, {d} skipped, {d} ignored, {d} errors)\n" ++
                    "      {d} bytes written; delta sent {d}, reused {d}; {d} deleted\n",
                .{
                    stats.dirs,          stats.symlinks,      stats.specials,            stats.hardlinks,           stats.files_total,
                    stats.files_created, stats.files_delta,   stats.files_whole,         stats.files_skipped,       stats.entries_ignored,
                    stats.errors,        stats.bytes_written, stats.delta_literal_bytes, stats.delta_matched_bytes, stats.deleted,
                },
            );
            try stderr.flush();
        }
        if (stats.errors != 0) return error.SyncErrors;
        return;
    }

    if (!src.isLocal() and !dst.isLocal()) return fail(stderr, "at least one endpoint must be local");

    if (src.isLocal()) {
        try runPush(io, gpa, stderr, parsed, src.path, dst);
    } else {
        try runPull(io, gpa, stderr, parsed, src, dst.path);
    }
}

fn runPush(io: Io, gpa: std.mem.Allocator, stderr: *Io.Writer, parsed: zync.cli.Parsed, src_path: []const u8, dst: zync.Endpoint) !void {
    if (parsed.hard_links and parsed.conns > 1) return fail(stderr, "--hard-links is not supported with --conns > 1");
    if (parsed.compress and parsed.conns > 1) return fail(stderr, "--compress is not supported with --conns > 1");

    var src_dir = try Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    const argv = [_][]const u8{ parsed.rsh, dst.host.?, parsed.remote_zync, "--server", dst.path };
    const opts: zync.session.Options = .{
        .verbose = parsed.verbose or parsed.progress,
        .delete = parsed.delete,
        .owner = parsed.owner,
        .group = parsed.group,
        .xattrs = parsed.xattrs,
        .hard_links = parsed.hard_links,
        .compress = parsed.compress,
        .excludes = parsed.excludes(),
    };

    const stats = if (parsed.conns > 1)
        try zync.parallel.pushParallel(io, gpa, src_dir, &argv, opts, parsed.conns)
    else blk: {
        var child = try spawnRemote(io, &argv);
        var to_buf: [64 * 1024]u8 = undefined;
        var from_buf: [64 * 1024]u8 = undefined;
        var to_child: Io.File.Writer = .init(child.stdin.?, io, &to_buf);
        var from_child: Io.File.Reader = .init(child.stdout.?, io, &from_buf);
        const s = try zync.session.runSender(io, gpa, src_dir, &from_child.interface, &to_child.interface, opts, .initiator, null);
        const term = try finishRemote(io, &child);
        if (term != .exited or term.exited != 0) return error.RemoteFailed;
        break :blk s;
    };

    if (parsed.json) {
        try jsonLine(io, "{{\"mode\":\"push\",\"dirs\":{d},\"symlinks\":{d},\"specials\":{d},\"hardlinks\":{d},\"files\":{d},\"sent\":{d},\"skipped\":{d},\"ignored\":{d},\"delta_sent\":{d},\"delta_reused\":{d}}}", .{
            stats.dirs,       stats.symlinks,      stats.specials,        stats.hardlinks,     stats.files_total,
            stats.files_sent, stats.files_skipped, stats.entries_ignored, stats.literal_bytes, stats.matched_bytes,
        });
    } else {
        try stderr.print(
            "zync: pushed {d} dirs, {d} links, {d} specials, {d} hardlinks, {d} files ({d} sent, {d} skipped, {d} ignored)\n" ++
                "      delta sent {d}, reused {d}\n",
            .{
                stats.dirs,       stats.symlinks,      stats.specials,        stats.hardlinks,     stats.files_total,
                stats.files_sent, stats.files_skipped, stats.entries_ignored, stats.literal_bytes, stats.matched_bytes,
            },
        );
        try stderr.flush();
    }
}

fn runPull(io: Io, gpa: std.mem.Allocator, stderr: *Io.Writer, parsed: zync.cli.Parsed, src: zync.Endpoint, dst_path: []const u8) !void {
    if (parsed.hard_links and parsed.conns > 1) return fail(stderr, "--hard-links is not supported with --conns > 1");
    if (parsed.compress and parsed.conns > 1) return fail(stderr, "--compress is not supported with --conns > 1");

    const cwd = Dir.cwd();
    try cwd.createDirPath(io, dst_path);
    var dst_dir = try cwd.openDir(io, dst_path, .{ .iterate = true });
    defer dst_dir.close(io);

    const opts: zync.session.Options = .{
        .verbose = parsed.verbose or parsed.progress,
        .delete = parsed.delete,
        .owner = parsed.owner,
        .group = parsed.group,
        .xattrs = parsed.xattrs,
        .hard_links = parsed.hard_links,
        .compress = parsed.compress,
        .excludes = parsed.excludes(),
    };

    const stats = if (parsed.conns > 1)
        try zync.parallel.pullParallel(io, gpa, dst_dir, parsed.rsh, src.host.?, parsed.remote_zync, src.path, opts, parsed.conns)
    else blk: {
        const argv = [_][]const u8{ parsed.rsh, src.host.?, parsed.remote_zync, "--server", "--sender", src.path };
        var child = try spawnRemote(io, &argv);
        var to_buf: [64 * 1024]u8 = undefined;
        var from_buf: [64 * 1024]u8 = undefined;
        var to_child: Io.File.Writer = .init(child.stdin.?, io, &to_buf);
        var from_child: Io.File.Reader = .init(child.stdout.?, io, &from_buf);
        const s = try zync.session.runReceiver(io, gpa, dst_dir, &from_child.interface, &to_child.interface, .initiator, opts);
        const term = try finishRemote(io, &child);
        if (term != .exited or term.exited != 0) return error.RemoteFailed;
        break :blk s;
    };

    if (parsed.json) {
        try jsonLine(io, "{{\"mode\":\"pull\",\"dirs\":{d},\"symlinks\":{d},\"specials\":{d},\"hardlinks\":{d},\"files_written\":{d},\"skipped\":{d},\"deleted\":{d}}}", .{
            stats.dirs, stats.symlinks, stats.specials, stats.hardlinks, stats.files_written, stats.files_skipped, stats.deleted,
        });
    } else {
        try stderr.print(
            "zync: pulled {d} dirs, {d} links, {d} specials, {d} hardlinks, {d} files written, {d} skipped, {d} deleted\n",
            .{ stats.dirs, stats.symlinks, stats.specials, stats.hardlinks, stats.files_written, stats.files_skipped, stats.deleted },
        );
        try stderr.flush();
    }
}

fn spawnRemote(io: Io, argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
}

fn finishRemote(io: Io, child: *std.process.Child) !std.process.Child.Term {
    child.stdin.?.close(io);
    child.stdin = null;
    return child.wait(io);
}

fn jsonLine(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var sw: Io.File.Writer = .init(.stdout(), io, &buf);
    try sw.interface.print(fmt ++ "\n", args);
    try sw.interface.flush();
}

fn fail(stderr: *Io.Writer, msg: []const u8) error{Usage}!void {
    stderr.print("zync: error: {s}\n\n", .{msg}) catch {};
    stderr.writeAll(zync.cli.usage) catch {};
    stderr.flush() catch {};
    return error.Usage;
}
