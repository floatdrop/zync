//! Extended-attribute (xattr) preservation for regular files and directories.
//! Opt-in (`-X`), best-effort: filesystems or namespaces that reject an
//! attribute are skipped rather than failing the transfer.
//!
//! fd-based. Linux uses the raw `flistxattr`/`fgetxattr`/`fsetxattr` syscalls
//! (no libc); macOS uses the libSystem equivalents, whose signatures carry the
//! extra `position`/`options` arguments. Both back-ends return the attribute
//! names as a single NUL-separated list, so the parsing below is shared.
//! Symlink xattrs are not handled yet.

const std = @import("std");
const builtin = @import("builtin");
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

/// macOS libSystem xattr entry points (position + options over the Linux form).
const mac = if (builtin.os.tag == .macos) struct {
    extern "c" fn flistxattr(fd: c_int, namebuf: ?[*]u8, size: usize, options: c_int) isize;
    extern "c" fn fgetxattr(fd: c_int, name: [*:0]const u8, value: ?*anyopaque, size: usize, position: u32, options: c_int) isize;
    extern "c" fn fsetxattr(fd: c_int, name: [*:0]const u8, value: ?*const anyopaque, size: usize, position: u32, options: c_int) c_int;
} else struct {};

/// Whether xattr preservation is implemented for this platform at all.
pub const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;

fn okLenLinux(rc: usize) ?usize {
    return switch (std.posix.errno(rc)) {
        .SUCCESS => rc,
        else => null,
    };
}

fn okLenDarwin(rc: isize) ?usize {
    return if (rc < 0) null else @intCast(rc);
}

/// Lists an fd's attribute names into `buf` (or queries the needed size when
/// `buf` is null). Returns the byte length, or null on error.
fn listNames(fd: Fd, buf: ?[]u8) ?usize {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            if (buf) |b| return okLenLinux(linux.flistxattr(fd, b.ptr, b.len));
            return okLenLinux(linux.flistxattr(fd, undefined, 0));
        },
        .macos => {
            if (buf) |b| return okLenDarwin(mac.flistxattr(fd, b.ptr, b.len, 0));
            return okLenDarwin(mac.flistxattr(fd, null, 0, 0));
        },
        else => return null,
    }
}

/// Reads attribute `name` into `buf` (or queries its size when `buf` is null).
fn getValue(fd: Fd, name: [*:0]const u8, buf: ?[]u8) ?usize {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            if (buf) |b| return okLenLinux(linux.fgetxattr(fd, name, b.ptr, b.len));
            return okLenLinux(linux.fgetxattr(fd, name, undefined, 0));
        },
        .macos => {
            if (buf) |b| return okLenDarwin(mac.fgetxattr(fd, name, b.ptr, b.len, 0, 0));
            return okLenDarwin(mac.fgetxattr(fd, name, null, 0, 0, 0));
        },
        else => return null,
    }
}

fn setValue(fd: Fd, name: [*:0]const u8, value: []const u8) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.fsetxattr(fd, name, value.ptr, value.len, 0),
        .macos => _ = mac.fsetxattr(fd, name, value.ptr, value.len, 0, 0),
        else => {},
    }
}

/// Reads all xattrs of the open file `fd`. Returns an empty set on any error
/// (e.g. the filesystem doesn't support xattrs).
pub fn readFd(gpa: Allocator, fd: Fd) !Set {
    if (!supported) return .{};

    const list_len = listNames(fd, null) orelse return .{};
    if (list_len == 0) return .{};

    const names = try gpa.alloc(u8, list_len);
    defer gpa.free(names);
    const got = listNames(fd, names) orelse return .{};

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
        const vlen = getValue(fd, name_z, null) orelse continue;

        var value = try gpa.alloc(u8, vlen);
        errdefer gpa.free(value);
        const vgot = getValue(fd, name_z, value) orelse {
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
    if (!supported) return;
    for (set.pairs) |p| setValue(fd, p.name.ptr, p.value);
}
