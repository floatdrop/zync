//! Block signatures of a basis file. The destination generates one from `old`
//! and sends it; the sender uses it to find reusable blocks in `new`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Rolling = @import("rolling.zig").Rolling;
const strong = @import("../hash/strong.zig");

pub const Block = struct {
    weak: u32,
    strong: [16]u8,
};

pub const Signature = struct {
    block_size: u32,
    file_len: u64,
    /// One entry per block, covering `old[i*S ..]`. The final block may be
    /// shorter than `block_size` (see `fullBlockCount`).
    blocks: []Block,

    pub fn deinit(self: *Signature, gpa: Allocator) void {
        gpa.free(self.blocks);
        self.* = undefined;
    }

    /// Number of full-size blocks. Only these are matchable by COPY, because a
    /// COPY(index) reconstructs exactly `old[index*S ..][0..S]`. The trailing
    /// short block (if any) is present in `blocks` for completeness but is not
    /// yet matched — those bytes fall through to literals (still correct, just
    /// not yet optimal). TODO(step 2+): match the short tail block too.
    pub fn fullBlockCount(self: Signature) usize {
        return @intCast(self.file_len / self.block_size);
    }
};

/// `S ≈ sqrt(len)` clamped to a sane range. Smaller blocks match finer but cost
/// a bigger signature and more probes; larger blocks do the reverse.
pub fn chooseBlockSize(len: u64) u32 {
    const min_bs: u64 = 2 * 1024;
    const max_bs: u64 = 128 * 1024;
    const s: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(len))));
    return @intCast(std.math.clamp(s, min_bs, max_bs));
}

pub fn generate(gpa: Allocator, old: []const u8, block_size: u32) !Signature {
    std.debug.assert(block_size > 0);
    const s = block_size;
    const n = old.len;
    const block_count = if (n == 0) 0 else (n + s - 1) / s;

    const blocks = try gpa.alloc(Block, block_count);
    errdefer gpa.free(blocks);

    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        const start = i * s;
        const end = @min(start + s, n);
        const chunk = old[start..end];
        blocks[i] = .{ .weak = Rolling.init(chunk).digest(), .strong = strong.block(chunk) };
    }

    return .{ .block_size = s, .file_len = n, .blocks = blocks };
}

/// Like `generate`, but reads the basis file block-by-block via positional
/// reads instead of requiring it all in memory. `block_size` must be chosen
/// from the file's length (e.g. via `chooseBlockSize`).
pub fn generatePositional(gpa: Allocator, io: Io, file: File, block_size: u32) !Signature {
    std.debug.assert(block_size > 0);
    const s = block_size;

    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(gpa);

    const buf = try gpa.alloc(u8, s);
    defer gpa.free(buf);

    var off: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, buf, off);
        if (n == 0) break;
        try blocks.append(gpa, .{
            .weak = Rolling.init(buf[0..n]).digest(),
            .strong = strong.block(buf[0..n]),
        });
        off += n;
        if (n < s) break; // short final block
    }

    return .{ .block_size = s, .file_len = off, .blocks = try blocks.toOwnedSlice(gpa) };
}

test "block count and tail" {
    const gpa = std.testing.allocator;
    var sig = try generate(gpa, "0123456789", 4); // len 10, S 4 -> 3 blocks, 2 full
    defer sig.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), sig.blocks.len);
    try std.testing.expectEqual(@as(usize, 2), sig.fullBlockCount());
}
