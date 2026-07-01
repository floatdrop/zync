//! Directory metadata preservation (permissions + mtime), applied in a final
//! pass. Files carry their own metadata as they are written; directories can't,
//! because writing files into a directory re-dirties its mtime. So directory
//! metadata is captured up front and re-applied only after every file has
//! landed and any deletions have happened.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const owner = @import("owner.zig");
const xattr = @import("xattr.zig");

pub const Perm = Io.File.Permissions;

pub const DirMeta = struct {
    /// Path relative to the destination root ("." is the root itself).
    path: []const u8,
    perm: Perm,
    mtime_ns: i64,
    /// Owner to apply, or null when not preserving it.
    uid: ?owner.Uid = null,
    gid: ?owner.Gid = null,
    /// Extended attributes to apply (empty when not preserving them).
    xattrs: xattr.Set = .{},
};

/// Re-applies permissions, owner, xattrs and mtime to each directory.
/// Best-effort: a metadata failure (e.g. not the owner) is skipped rather than
/// aborting the transfer. Order among directories doesn't matter — setting a
/// directory's own metadata never changes another directory's mtime.
pub fn applyDirs(io: Io, dst_dir: Dir, dirs: []const DirMeta) void {
    for (dirs) |m| {
        // Owner before perms: chown can clear set-uid/gid bits (though Linux
        // spares directories), so apply it first.
        owner.apply(io, dst_dir, m.path, m.uid, m.gid, false);
        // Path-based fchmodat: a directory opened non-iterably is O_PATH and
        // cannot be fchmod'd, so set permissions by path.
        const perm: Perm = @enumFromInt(@intFromEnum(m.perm) & 0o7777);
        dst_dir.setFilePermissions(io, m.path, perm, .{}) catch {};
        // xattrs need a real (iterable) fd — an O_PATH handle can't be fsetxattr'd.
        if (m.xattrs.pairs.len > 0) {
            if (dst_dir.openDir(io, m.path, .{ .iterate = true })) |d| {
                xattr.applyFd(d.handle, m.xattrs);
                d.close(io);
            } else |_| {}
        }
        // mtime last, so it is the value that sticks.
        dst_dir.setTimestamps(io, m.path, .{
            .modify_timestamp = .{ .new = .fromNanoseconds(m.mtime_ns) },
        }) catch {};
    }
}

/// Reads a directory's own xattrs (via an iterable fd). Empty set on any error.
pub fn readDirXattrs(gpa: std.mem.Allocator, io: Io, dir: Dir, sub_path: []const u8) xattr.Set {
    var d = dir.openDir(io, sub_path, .{ .iterate = true }) catch return .{};
    defer d.close(io);
    return xattr.readFd(gpa, d.handle) catch .{};
}
