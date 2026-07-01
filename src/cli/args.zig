//! Command-line parsing.
//!
//!   zync [opts] <src> <dst>     push/sync (dst may be [user@]host:path)
//!   zync --server <path>        remote peer, speaks the protocol over stdio

const std = @import("std");

pub const usage =
    \\zync — a modern file sync tool
    \\
    \\usage: zync [options] <src> <dst>
    \\       zync --server <path>          (internal: remote peer)
    \\
    \\  <src>            local path
    \\  <dst>            local path or [user@]host:path
    \\
    \\options:
    \\  -v, --verbose         log each file as it is sent or skipped
    \\  -P, --progress        show each file as it transfers
    \\      --json            print the final summary as JSON
    \\  -W, --whole-file      disable delta; always copy changed files whole
    \\      --delete          delete destination entries missing from the source
    \\  -o, --owner           preserve owning user  (best-effort; needs privilege)
    \\  -g, --group           preserve owning group (best-effort; needs privilege)
    \\  -X, --xattrs          preserve extended attributes of files (best-effort)
    \\  -H, --hard-links      preserve hardlinks (not with --conns > 1)
    \\  -z, --compress        compress the wire (remote; not with --conns > 1)
    \\      --exclude <pat>   skip paths matching <pat> (repeatable)
    \\  -j, --jobs <n>        parallel workers for local sync (default: CPU count)
    \\      --conns <n>       parallel SSH connections for remote push (default: 1)
    \\      --rsh <cmd>       remote shell program (default: ssh)
    \\      --remote-zync <p> zync program name on the remote (default: zync)
    \\  -h, --help            show this help and exit
    \\
;

pub const ShardSpec = struct { index: u32, count: u32 };

pub const Mode = union(enum) {
    /// Local invocation: transfer between src and dst (either may be remote).
    transfer: struct { src: []const u8, dst: []const u8 },
    /// Remote peer, driven over stdio. `sender` = we hold the source; `shard`
    /// restricts a sender to one slice of the tree (sharded pull).
    server: struct { path: []const u8, sender: bool, shard: ?ShardSpec },
};

pub const Parsed = struct {
    mode: Mode,
    verbose: bool = false,
    progress: bool = false,
    json: bool = false,
    whole_file: bool = false,
    delete: bool = false,
    owner: bool = false,
    group: bool = false,
    xattrs: bool = false,
    hard_links: bool = false,
    compress: bool = false,
    jobs: usize = 0,
    conns: usize = 1,
    rsh: []const u8 = "ssh",
    remote_zync: []const u8 = "zync",
    exclude_buf: [max_excludes][]const u8 = undefined,
    exclude_n: usize = 0,

    pub fn excludes(self: *const Parsed) []const []const u8 {
        return self.exclude_buf[0..self.exclude_n];
    }
};

pub const max_excludes = 256;

pub const ParseError = error{
    HelpRequested,
    MissingArgs,
    TooManyArgs,
    UnknownFlag,
    MissingValue,
    BadValue,
};

pub fn parse(args: []const []const u8) ParseError!Parsed {
    var out: Parsed = .{ .mode = undefined };
    var server = false;
    var sender = false;
    var shard: ?ShardSpec = null;
    var positionals: [2][]const u8 = undefined;
    var n: usize = 0;

    var i: usize = @min(1, args.len);
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(arg, "-h", "--help")) {
            return error.HelpRequested;
        } else if (eq(arg, "-v", "--verbose")) {
            out.verbose = true;
        } else if (eq(arg, "-P", "--progress")) {
            out.progress = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
        } else if (eq(arg, "-W", "--whole-file")) {
            out.whole_file = true;
        } else if (std.mem.eql(u8, arg, "--delete")) {
            out.delete = true;
        } else if (eq(arg, "-o", "--owner")) {
            out.owner = true;
        } else if (eq(arg, "-g", "--group")) {
            out.group = true;
        } else if (eq(arg, "-X", "--xattrs")) {
            out.xattrs = true;
        } else if (eq(arg, "-H", "--hard-links")) {
            out.hard_links = true;
        } else if (eq(arg, "-z", "--compress")) {
            out.compress = true;
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            const pat = try value(args, &i);
            if (out.exclude_n >= max_excludes) return error.TooManyArgs;
            out.exclude_buf[out.exclude_n] = pat;
            out.exclude_n += 1;
        } else if (eq(arg, "-j", "--jobs")) {
            out.jobs = parseJobs(try value(args, &i)) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "-j") and arg.len > 2) {
            out.jobs = parseJobs(arg[2..]) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            out.jobs = parseJobs(arg["--jobs=".len..]) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--conns")) {
            out.conns = parseJobs(try value(args, &i)) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, arg, "--conns=")) {
            out.conns = parseJobs(arg["--conns=".len..]) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--server")) {
            server = true;
        } else if (std.mem.eql(u8, arg, "--sender")) {
            sender = true;
        } else if (std.mem.eql(u8, arg, "--shard")) {
            shard = parseShard(try value(args, &i)) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--rsh")) {
            out.rsh = try value(args, &i);
        } else if (std.mem.eql(u8, arg, "--remote-zync")) {
            out.remote_zync = try value(args, &i);
        } else if (arg.len > 1 and arg[0] == '-') {
            return error.UnknownFlag;
        } else {
            if (n == positionals.len) return error.TooManyArgs;
            positionals[n] = arg;
            n += 1;
        }
    }

    if (server) {
        if (n < 1) return error.MissingArgs;
        if (n > 1) return error.TooManyArgs;
        out.mode = .{ .server = .{ .path = positionals[0], .sender = sender, .shard = shard } };
    } else {
        if (n < 2) return error.MissingArgs;
        out.mode = .{ .transfer = .{ .src = positionals[0], .dst = positionals[1] } };
    }
    return out;
}

fn eq(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn parseJobs(s: []const u8) !usize {
    return std.fmt.parseInt(usize, s, 10);
}

fn parseShard(s: []const u8) !ShardSpec {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.BadShard;
    const index = try std.fmt.parseInt(u32, s[0..slash], 10);
    const count = try std.fmt.parseInt(u32, s[slash + 1 ..], 10);
    if (count == 0 or index >= count) return error.BadShard;
    return .{ .index = index, .count = count };
}

fn value(args: []const []const u8, i: *usize) ParseError![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingValue;
    i.* += 1;
    return args[i.*];
}

test "parses transfer src and dst" {
    const p = try parse(&.{ "zync", "a", "b" });
    try std.testing.expectEqualStrings("a", p.mode.transfer.src);
    try std.testing.expectEqualStrings("b", p.mode.transfer.dst);
    try std.testing.expect(!p.verbose);
}

test "flags and value options" {
    const p = try parse(&.{ "zync", "-v", "--rsh", "myssh", "a", "host:/b" });
    try std.testing.expect(p.verbose);
    try std.testing.expectEqualStrings("myssh", p.rsh);
    try std.testing.expectEqualStrings("host:/b", p.mode.transfer.dst);
}

test "server receiver and sender modes" {
    const recv = try parse(&.{ "zync", "--server", "/dst" });
    try std.testing.expectEqualStrings("/dst", recv.mode.server.path);
    try std.testing.expect(!recv.mode.server.sender);

    const send = try parse(&.{ "zync", "--server", "--sender", "/src" });
    try std.testing.expectEqualStrings("/src", send.mode.server.path);
    try std.testing.expect(send.mode.server.sender);
}

test "jobs: separated, glued, and long forms" {
    try std.testing.expectEqual(@as(usize, 1), (try parse(&.{ "zync", "-j", "1", "a", "b" })).jobs);
    try std.testing.expectEqual(@as(usize, 4), (try parse(&.{ "zync", "-j4", "a", "b" })).jobs);
    try std.testing.expectEqual(@as(usize, 8), (try parse(&.{ "zync", "--jobs=8", "a", "b" })).jobs);
    try std.testing.expectError(error.BadValue, parse(&.{ "zync", "-jx", "a", "b" }));
}

test "missing value" {
    try std.testing.expectError(error.MissingValue, parse(&.{ "zync", "a", "b", "--rsh" }));
}

test "missing args" {
    try std.testing.expectError(error.MissingArgs, parse(&.{ "zync", "a" }));
}
