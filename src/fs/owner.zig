//! Owner (uid/gid) preservation. Opt-in (`-o`/`-g`) and best-effort: applying an
//! arbitrary owner needs privilege, so failures are ignored rather than fatal.
//!
//! The Io layer exposes `setFileOwner` (fchownat) but no owner *read*, so uid/gid
//! are read via the raw Linux `statx` syscall. This is Linux-only, consistent
//! with the rest of zync's POSIX/SSH assumptions.

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
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    const path_z = try std.posix.toPosixPath(path);
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dir.handle, &path_z, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .GID = true }, &stx);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => .{ .uid = stx.uid, .gid = stx.gid },
        else => |e| std.posix.unexpectedErrno(e),
    };
}

/// Best-effort chown of `path` under `dir`. No-op if both ids are null.
///
/// Uses the raw `fchownat` syscall: the Io wrapper `Dir.setFileOwner` has a
/// return-type bug in this std (declares `SetOwnerError` but the vtable call
/// yields the wider `SetFileOwnerError`), so it fails to compile when used.
pub fn apply(io: Io, dir: Dir, path: []const u8, uid: ?Uid, gid: ?Gid, follow: bool) void {
    _ = io;
    if (builtin.os.tag != .linux) return;
    if (uid == null and gid == null) return;
    const linux = std.os.linux;
    const path_z = std.posix.toPosixPath(path) catch return;
    // -1 (all bits set) means "leave unchanged".
    const u: linux.uid_t = uid orelse ~@as(linux.uid_t, 0);
    const g: linux.gid_t = gid orelse ~@as(linux.gid_t, 0);
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    _ = linux.fchownat(dir.handle, &path_z, u, g, flags); // best-effort
}
