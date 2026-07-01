//! Symlink replication helpers, shared by local sync and the wire receiver.
//!
//! zync preserves symlinks verbatim (like rsync's default, without `-L`): the
//! link's target string is copied, not the file it points to.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const max_target = Dir.max_path_bytes;

/// Reads a symlink's target into `buf` and returns the slice.
pub fn readTarget(io: Io, dir: Dir, path: []const u8, buf: []u8) ![]const u8 {
    const n = try dir.readLink(io, path, buf);
    return buf[0..n];
}

/// Creates (or updates) the symlink `path` -> `target` under `dir`, creating
/// parent directories as needed and replacing an existing link whose target
/// differs.
pub fn place(io: Io, dir: Dir, path: []const u8, target: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);

    dir.symLink(io, target, path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var buf: [max_target]u8 = undefined;
            if (dir.readLink(io, path, &buf)) |n| {
                if (std.mem.eql(u8, buf[0..n], target)) return; // already correct
            } else |_| {}
            try dir.deleteFile(io, path);
            try dir.symLink(io, target, path, .{});
        },
        else => return err,
    };
}
