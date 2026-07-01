//! Hardlink detection and replication (rsync's `-H`). Files that share an inode
//! are transferred once (the first-seen path is the "master") and the rest are
//! recreated as hardlinks to it. Opt-in; supported for local and single
//! connection transfers (not `--conns > 1`, which would need cross-shard
//! master coordination).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

/// A file's identity. `dev` distinguishes inodes that collide across mounts
/// within one tree (real hardlinks can't cross filesystems).
pub const Key = struct { dev: u64, ino: u64 };

/// Combines a stat's inode with the file's device (read via stat). Falls back
/// to dev 0 (inode-only) if the stat is unavailable — fine for a single-fs tree.
pub fn key(dir: Dir, path: []const u8, inode: u64) Key {
    const fallback: Key = .{ .dev = 0, .ino = inode };
    const path_z = std.posix.toPosixPath(path) catch return fallback;
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(dir.handle, &path_z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
            const dev: u64 = switch (std.posix.errno(rc)) {
                .SUCCESS => (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
                else => return fallback,
            };
            return .{ .dev = dev, .ino = inode };
        },
        .macos => {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(dir.handle, &path_z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return fallback;
            const dev: u32 = @bitCast(st.dev);
            return .{ .dev = dev, .ino = st.ino };
        },
        else => return fallback,
    }
}

/// Best-effort creation of a hardlink `path` → `master` under `dir`. Idempotent:
/// if `path` already shares `master`'s inode, nothing changes (so re-syncs don't
/// churn). Requires `master` to already exist.
pub fn place(io: Io, dir: Dir, master: []const u8, path: []const u8) void {
    if (std.fs.path.dirname(path)) |p| dir.createDirPath(io, p) catch {};
    dir.hardLink(master, dir, path, io, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const pi = (dir.statFile(io, path, .{}) catch return).inode;
            const mi = (dir.statFile(io, master, .{}) catch return).inode;
            if (pi == mi) return; // already the same inode
            dir.deleteFile(io, path) catch return;
            dir.hardLink(master, dir, path, io, .{}) catch {};
        },
        else => {},
    };
}
