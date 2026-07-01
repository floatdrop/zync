//! Owner (uid/gid) preservation. Opt-in (`-o`/`-g`) and best-effort: applying an
//! arbitrary owner needs privilege, so failures are ignored rather than fatal.
//!
//! The Io layer exposes `setFileOwner` (fchownat) but no owner *read*, so uid/gid
//! are read from a raw stat. Linux goes through the `statx` syscall directly (no
//! libc); macOS goes through libSystem's `fstatat`/`fchownat`. Other platforms
//! report the attribute as unsupported and are simply skipped.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;

pub const Uid = Io.File.Uid;
pub const Gid = Io.File.Gid;

pub const Ids = struct { uid: Uid, gid: Gid };

/// Reads the uid/gid of `path` (relative to `dir`), operating on the entry
/// itself (never dereferencing a final symlink).
pub fn read(dir: Dir, path: []const u8) !Ids {
    const path_z = try std.posix.toPosixPath(path);
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(dir.handle, &path_z, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .GID = true }, &stx);
            return switch (std.posix.errno(rc)) {
                .SUCCESS => .{ .uid = stx.uid, .gid = stx.gid },
                else => |e| std.posix.unexpectedErrno(e),
            };
        },
        .macos => {
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(dir.handle, &path_z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.Unsupported;
            return .{ .uid = st.uid, .gid = st.gid };
        },
        else => return error.Unsupported,
    }
}

/// Best-effort chown of `path` under `dir`. No-op if both ids are null.
///
/// Uses `fchownat` directly (raw syscall on Linux, libSystem on macOS): the Io
/// wrapper `Dir.setFileOwner` has a return-type bug in this std (declares
/// `SetOwnerError` but the vtable call yields the wider `SetFileOwnerError`), so
/// it fails to compile when used.
pub fn apply(io: Io, dir: Dir, path: []const u8, uid: ?Uid, gid: ?Gid, follow: bool) void {
    _ = io;
    if (uid == null and gid == null) return;
    const path_z = std.posix.toPosixPath(path) catch return;
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            // -1 (all bits set) means "leave unchanged".
            const u: linux.uid_t = uid orelse ~@as(linux.uid_t, 0);
            const g: linux.gid_t = gid orelse ~@as(linux.gid_t, 0);
            const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
            _ = linux.fchownat(dir.handle, &path_z, u, g, flags); // best-effort
        },
        .macos => {
            const u = uid orelse ~@as(Uid, 0);
            const g = gid orelse ~@as(Gid, 0);
            const flags: c_uint = if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW;
            _ = std.c.fchownat(dir.handle, &path_z, u, g, flags); // best-effort
        },
        else => {},
    }
}
