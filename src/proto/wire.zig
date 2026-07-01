//! Low-level wire primitives shared by both peers: message tags, LEB128
//! varints, and length-prefixed byte strings, written over `std.Io` streams.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const magic = "ZYNC";
pub const version: u64 = 1;

pub const Tag = enum(u8) {
    hello = 1,
    mkdir = 2,
    file = 3,
    sig = 4,
    skip = 5,
    literal = 6,
    copy = 7,
    end = 8,
    done = 9,
    symlink = 10,
    /// Adds a path to the receiver's keep-set without creating anything; used
    /// by the parallel-push control connection so `--delete` sees every file.
    keep = 11,
    /// A special file (FIFO/socket/device): kind + perms + device number.
    special = 12,
    /// A hardlink: path + the path of the already-sent file it links to.
    hardlink = 13,
};

pub const Error = error{ BadTag, StringTooLong } || Reader.Error || Writer.Error || Allocator.Error;

/// Cap on a single length-prefixed string, to bound allocation from a peer.
pub const max_string: u64 = 1 << 32;

pub fn putTag(w: *Writer, tag: Tag) Writer.Error!void {
    try w.writeByte(@intFromEnum(tag));
}

pub fn getTag(r: *Reader) error{ BadTag, ReadFailed, EndOfStream }!Tag {
    const b = try r.takeByte();
    return switch (b) {
        1...13 => @enumFromInt(b),
        else => error.BadTag,
    };
}

pub fn putUvarint(w: *Writer, value: u64) Writer.Error!void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) {
        try w.writeByte(@as(u8, @truncate(v)) | 0x80);
    }
    try w.writeByte(@truncate(v));
}

pub fn getUvarint(r: *Reader) error{ ReadFailed, EndOfStream, Overflow }!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const b = try r.takeByte();
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift = std.math.add(u6, shift, 7) catch return error.Overflow;
    }
}

pub fn putZigzag(w: *Writer, value: i64) Writer.Error!void {
    const zz: u64 = @bitCast((value << 1) ^ (value >> 63));
    try putUvarint(w, zz);
}

pub fn getZigzag(r: *Reader) error{ ReadFailed, EndOfStream, Overflow }!i64 {
    const zz = try getUvarint(r);
    return @bitCast((zz >> 1) ^ (~(zz & 1) +% 1));
}

pub fn putBytes(w: *Writer, bytes: []const u8) Writer.Error!void {
    try putUvarint(w, bytes.len);
    try w.writeAll(bytes);
}

/// Reads a length-prefixed string into a freshly allocated buffer (caller owns).
pub fn getBytesAlloc(r: *Reader, gpa: Allocator) Error![]u8 {
    const len = getUvarint(r) catch |e| return switch (e) {
        error.Overflow => error.StringTooLong,
        else => |x| x,
    };
    if (len > max_string) return error.StringTooLong;
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    try r.readSliceAll(buf);
    return buf;
}
