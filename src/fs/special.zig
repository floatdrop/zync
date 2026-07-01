//! Special files: named pipes (FIFOs), sockets, and character/block devices.
//! These carry no data — only a type, permission bits, and (for devices) a
//! device number — so they are replicated with a single `mknodat`. Best-effort:
//! device nodes need privilege, so failures are skipped (Linux-only).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

pub const Kind = enum(u8) { fifo = 0, sock = 1, chr = 2, blk = 3 };

pub const Info = struct {
    kind: Kind,
    perm: u32,
    major: u32 = 0,
    minor: u32 = 0,
};

/// Maps a walker entry kind to a special kind, or null if it isn't special.
pub fn fromFileKind(k: Io.File.Kind) ?Kind {
    return switch (k) {
        .named_pipe => .fifo,
        .unix_domain_socket => .sock,
        .character_device => .chr,
        .block_device => .blk,
        else => null,
    };
}

/// Reads a special file's permission bits and (for devices) device number.
pub fn read(dir: Dir, path: []const u8, kind: Kind) !Info {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    const path_z = try std.posix.toPosixPath(path);
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dir.handle, &path_z, linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true }, &stx);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => .{ .kind = kind, .perm = stx.mode & 0o7777, .major = stx.rdev_major, .minor = stx.rdev_minor },
        else => |e| std.posix.unexpectedErrno(e),
    };
}

/// Best-effort creation of the node. An already-present node is left as-is.
pub fn place(dir: Dir, info: Info, path: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    const path_z = std.posix.toPosixPath(path) catch return;
    const type_bits: u32 = switch (info.kind) {
        .fifo => linux.S.IFIFO,
        .sock => linux.S.IFSOCK,
        .chr => linux.S.IFCHR,
        .blk => linux.S.IFBLK,
    };
    const dev: u32 = switch (info.kind) {
        .chr, .blk => makedev(info.major, info.minor),
        else => 0,
    };
    _ = linux.mknodat(dir.handle, &path_z, type_bits | (info.perm & 0o7777), dev);
}

fn makedev(major: u32, minor: u32) u32 {
    return (minor & 0xff) | (major << 8) | ((minor & ~@as(u32, 0xff)) << 12);
}
