//! Deletion of extraneous destination entries (rsync's `--delete`): anything in
//! the destination that the source did not offer is removed, making the
//! destination an exact mirror.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub const KeptSet = std.StringHashMapUnmanaged(void);

/// Adds `path` (duplicated) to `set` if not already present. The set owns its
/// keys; free them with `freeKept`.
pub fn keep(gpa: Allocator, set: *KeptSet, path: []const u8) !void {
    if (set.contains(path)) return;
    const dup = try gpa.dupe(u8, path);
    errdefer gpa.free(dup);
    try set.put(gpa, dup, {});
}

pub fn freeKept(gpa: Allocator, set: *KeptSet) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit(gpa);
}

fn containedIn(kepts: []const KeptSet, path: []const u8) bool {
    for (kepts) |k| if (k.contains(path)) return true;
    return false;
}

/// Walks `dir` and deletes every entry whose relative path is absent from
/// `kept`. Only boundary entries (whose parent survives) are deleted — a whole
/// extraneous subdirectory is removed with one `deleteTree`, so the count is
/// accurate and children aren't touched twice. `dir` must be iterable.
pub fn deleteExtraneous(io: Io, gpa: Allocator, dir: Dir, kept: *const KeptSet) !u64 {
    return deleteExtraneousMulti(io, gpa, dir, kept[0..1]);
}

/// Like `deleteExtraneous`, but a path survives if it is present in *any* of the
/// keep-sets. Used by sharded pull, where each connection accumulates its own
/// keep-set and the client prunes once against their union.
pub fn deleteExtraneousMulti(io: Io, gpa: Allocator, dir: Dir, kepts: []const KeptSet) !u64 {
    const Extra = struct { path: []u8, is_dir: bool };

    var extras: std.ArrayList(Extra) = .empty;
    defer {
        for (extras.items) |e| gpa.free(e.path);
        extras.deinit(gpa);
    }

    {
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (containedIn(kepts, entry.path)) continue;
            // Delete only where the parent survives; deeper extraneous entries
            // are swept as part of their ancestor's subtree.
            const parent_kept = if (std.fs.path.dirname(entry.path)) |p|
                containedIn(kepts, p)
            else
                true;
            if (!parent_kept) continue;
            try extras.append(gpa, .{
                .path = try gpa.dupe(u8, entry.path),
                .is_dir = entry.kind == .directory,
            });
        }
    }

    var deleted: u64 = 0;
    for (extras.items) |e| {
        if (e.is_dir) {
            // deleteTree treats an already-absent path as success.
            try dir.deleteTree(io, e.path);
        } else {
            dir.deleteFile(io, e.path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
        }
        deleted += 1;
    }
    return deleted;
}
