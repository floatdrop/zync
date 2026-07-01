//! Extended-attribute (xattr) preservation for regular files. Opt-in (`-X`),
//! best-effort: filesystems or namespaces that reject an attribute are skipped
//! rather than failing the transfer.
//!
//! fd-based via the raw Linux xattr syscalls (the Io layer has no xattr API).
//! Directory and symlink xattrs are not handled yet.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Fd = std.posix.fd_t;

pub const Pair = struct { name: [:0]u8, value: []u8 };

pub const Set = struct {
    pairs: []Pair = &.{},

    pub fn deinit(self: *Set, gpa: Allocator) void {
        for (self.pairs) |p| {
            gpa.free(p.name);
            gpa.free(p.value);
        }
        gpa.free(self.pairs);
        self.* = .{};
    }
};

fn okLen(rc: usize) ?usize {
    return switch (std.posix.errno(rc)) {
        .SUCCESS => rc,
        else => null,
    };
}

/// Reads all xattrs of the open file `fd`. Returns an empty set on any error
/// (e.g. the filesystem doesn't support xattrs).
pub fn readFd(gpa: Allocator, fd: Fd) !Set {
    if (builtin.os.tag != .linux) return .{};

    const list_len = okLen(linux.flistxattr(fd, undefined, 0)) orelse return .{};
    if (list_len == 0) return .{};

    const names = try gpa.alloc(u8, list_len);
    defer gpa.free(names);
    const got = okLen(linux.flistxattr(fd, names.ptr, names.len)) orelse return .{};

    var pairs: std.ArrayList(Pair) = .empty;
    errdefer {
        for (pairs.items) |p| {
            gpa.free(p.name);
            gpa.free(p.value);
        }
        pairs.deinit(gpa);
    }

    var i: usize = 0;
    while (i < got) {
        const start = i;
        while (i < got and names[i] != 0) i += 1;
        const name = names[start..i];
        i += 1; // skip the separating NUL
        if (name.len == 0) continue;

        // `names` is NUL-separated, so the name is already NUL-terminated.
        const name_z: [*:0]const u8 = @ptrCast(names.ptr + start);
        const vlen = okLen(linux.fgetxattr(fd, name_z, undefined, 0)) orelse continue;

        var value = try gpa.alloc(u8, vlen);
        errdefer gpa.free(value);
        const vgot = okLen(linux.fgetxattr(fd, name_z, value.ptr, value.len)) orelse {
            gpa.free(value);
            continue;
        };
        if (vgot != value.len) value = try gpa.realloc(value, vgot);

        const name_dup = try gpa.dupeZ(u8, name);
        errdefer gpa.free(name_dup);
        try pairs.append(gpa, .{ .name = name_dup, .value = value });
    }

    return .{ .pairs = try pairs.toOwnedSlice(gpa) };
}

/// Best-effort: applies each attribute to the open file `fd`.
pub fn applyFd(fd: Fd, set: Set) void {
    if (builtin.os.tag != .linux) return;
    for (set.pairs) |p| {
        _ = linux.fsetxattr(fd, p.name.ptr, p.value.ptr, p.value.len, 0);
    }
}
