//! Per-payload DEFLATE compression (rsync's `-z`). Literal runs — the bulk of
//! what a delta sends — are compressed one payload at a time, so no streaming
//! flush coordination is needed (which would deadlock a request/response
//! protocol). Control messages stay uncompressed. Linux/std `flate`.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

/// Compresses `src`. Returns the compressed bytes (caller owns), or null if it
/// did not get smaller (so the caller sends it uncompressed).
pub fn deflate(gpa: Allocator, src: []const u8) !?[]u8 {
    if (src.len == 0) return null;

    const dst = try gpa.alloc(u8, src.len); // capacity = original size
    errdefer gpa.free(dst);
    const win = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(win);

    var fw = std.Io.Writer.fixed(dst);
    var c = flate.Compress.init(&fw, win, .raw, .default) catch {
        gpa.free(dst);
        return null;
    };
    // If the output overflows `dst`, it isn't compressible — bail to uncompressed.
    c.writer.writeAll(src) catch {
        gpa.free(dst);
        return null;
    };
    c.finish() catch {
        gpa.free(dst);
        return null;
    };

    const out = fw.buffered();
    if (out.len >= src.len) {
        gpa.free(dst);
        return null;
    }
    return dst[0..out.len];
}

/// Decompresses `src` into exactly `orig_len` bytes (caller owns).
pub fn inflate(gpa: Allocator, src: []const u8, orig_len: usize) ![]u8 {
    const out = try gpa.alloc(u8, orig_len);
    errdefer gpa.free(out);
    const win = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(win);

    var fr = std.Io.Reader.fixed(src);
    var d = flate.Decompress.init(&fr, .raw, win);
    try d.reader.readSliceAll(out);
    return out;
}
