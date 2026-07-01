//! Round-trip property tests for the delta engine:
//!   patch(old, delta(signature(old), new)) == new
//! over many randomised edits (copies, deletes, inserts, substitutions).

const std = @import("std");
const signature = @import("signature.zig");
const delta = @import("delta.zig");
const patch = @import("patch.zig");
const stream = @import("stream.zig");
const strong = @import("../hash/strong.zig");

/// Reconstructs `new` on the fly from the streaming matcher's ops, so the test
/// checks the exact same emit path the real transports use.
const StreamSink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    old: []const u8,
    block_size: u32,

    pub fn emitLiteral(self: *StreamSink, bytes: []const u8) !void {
        try self.out.appendSlice(self.gpa, bytes);
    }
    pub fn emitCopy(self: *StreamSink, idx: u32) !void {
        const start = @as(usize, idx) * self.block_size;
        const end = @min(start + self.block_size, self.old.len);
        try self.out.appendSlice(self.gpa, self.old[start..end]);
    }
};

test "streaming matcher round-trips over random edits" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5723A9);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 300) : (iter += 1) {
        const old = try gpa.alloc(u8, rand.intRangeAtMost(usize, 0, 6000));
        defer gpa.free(old);
        rand.bytes(old);

        var new_list: std.ArrayList(u8) = .empty;
        defer new_list.deinit(gpa);
        var pos: usize = 0;
        while (pos < old.len) {
            const remaining = old.len - pos;
            switch (rand.intRangeAtMost(u8, 0, 3)) {
                0 => {
                    const run = rand.intRangeAtMost(usize, 1, remaining);
                    try new_list.appendSlice(gpa, old[pos..][0..run]);
                    pos += run;
                },
                1 => pos += rand.intRangeAtMost(usize, 1, remaining),
                2 => {
                    var b: [200]u8 = undefined;
                    const run = rand.intRangeAtMost(usize, 1, b.len);
                    rand.bytes(b[0..run]);
                    try new_list.appendSlice(gpa, b[0..run]);
                },
                else => {
                    try new_list.append(gpa, old[pos] ^ 0xFF);
                    pos += 1;
                },
            }
        }
        const new = new_list.items;

        const block_size = rand.intRangeAtMost(u32, 2, 300);
        var sig = try signature.generate(gpa, old, block_size);
        defer sig.deinit(gpa);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var sink: StreamSink = .{ .gpa = gpa, .out = &out, .old = old, .block_size = block_size };
        var hasher = std.crypto.hash.Blake3.init(.{});
        var reader = std.Io.Reader.fixed(new);
        try stream.match(gpa, sig, &reader, &hasher, &sink);

        try std.testing.expectEqualSlices(u8, new, out.items);

        var got: [32]u8 = undefined;
        hasher.final(&got);
        try std.testing.expectEqualSlices(u8, &strong.wholeFile(new), &got);
    }
}

test "delta round-trips over random edits" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 300) : (iter += 1) {
        const old = try gpa.alloc(u8, rand.intRangeAtMost(usize, 0, 4096));
        defer gpa.free(old);
        rand.bytes(old);

        // Derive `new` from `old` with random edits so real matches exist.
        var new_list: std.ArrayList(u8) = .empty;
        defer new_list.deinit(gpa);
        var pos: usize = 0;
        while (pos < old.len) {
            const remaining = old.len - pos;
            switch (rand.intRangeAtMost(u8, 0, 3)) {
                0 => { // copy a run verbatim
                    const run = rand.intRangeAtMost(usize, 1, remaining);
                    try new_list.appendSlice(gpa, old[pos..][0..run]);
                    pos += run;
                },
                1 => pos += rand.intRangeAtMost(usize, 1, remaining), // delete a run
                2 => { // insert random bytes
                    var buf: [64]u8 = undefined;
                    const run = rand.intRangeAtMost(usize, 1, buf.len);
                    rand.bytes(buf[0..run]);
                    try new_list.appendSlice(gpa, buf[0..run]);
                },
                else => { // substitute one byte
                    try new_list.append(gpa, old[pos] ^ 0xFF);
                    pos += 1;
                },
            }
        }
        const new = new_list.items;

        const block_size = rand.intRangeAtMost(u32, 2, 64);
        var sig = try signature.generate(gpa, old, block_size);
        defer sig.deinit(gpa);

        var ops: std.ArrayList(delta.Op) = .empty;
        defer ops.deinit(gpa);
        try delta.compute(gpa, sig, new, &ops);

        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        try patch.applyVerified(gpa, old, block_size, ops.items, strong.wholeFile(new), &rebuilt);

        try std.testing.expectEqualSlices(u8, new, rebuilt.items);
    }
}

test "identical file with a short tail is fully reused" {
    const gpa = std.testing.allocator;
    const old = "abcdefghij"; // 10 bytes, S=4 -> blocks "abcd","efgh" + tail "ij"
    const block_size: u32 = 4;

    var sig = try signature.generate(gpa, old, block_size);
    defer sig.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), sig.fullBlockCount());

    var ops: std.ArrayList(delta.Op) = .empty;
    defer ops.deinit(gpa);
    try delta.compute(gpa, sig, old, &ops);

    var copies: usize = 0;
    var literals: usize = 0;
    for (ops.items) |op| switch (op) {
        .copy => copies += 1,
        .literal => literals += 1,
    };
    try std.testing.expectEqual(@as(usize, 3), copies); // 2 full + 1 tail
    try std.testing.expectEqual(@as(usize, 0), literals);

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    try patch.apply(gpa, old, block_size, ops.items, &rebuilt);
    try std.testing.expectEqualSlices(u8, old, rebuilt.items);
}

test "basis smaller than block size still matches (single tail block)" {
    const gpa = std.testing.allocator;
    const old = "abc"; // len 3 < S
    const block_size: u32 = 8;

    var sig = try signature.generate(gpa, old, block_size);
    defer sig.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sig.fullBlockCount());

    var ops: std.ArrayList(delta.Op) = .empty;
    defer ops.deinit(gpa);
    // "abc" appears inside `new`; the tail block should be reused.
    try delta.compute(gpa, sig, "xxabcyy", &ops);

    var copies: usize = 0;
    for (ops.items) |op| switch (op) {
        .copy => copies += 1,
        .literal => {},
    };
    try std.testing.expectEqual(@as(usize, 1), copies);

    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    try patch.apply(gpa, old, block_size, ops.items, &rebuilt);
    try std.testing.expectEqualSlices(u8, "xxabcyy", rebuilt.items);
}

test "identical file compresses to pure copies" {
    const gpa = std.testing.allocator;
    const old = "abcdefghabcdefghabcdefgh"; // 24 bytes
    const block_size: u32 = 8; // 3 full blocks

    var sig = try signature.generate(gpa, old, block_size);
    defer sig.deinit(gpa);

    var ops: std.ArrayList(delta.Op) = .empty;
    defer ops.deinit(gpa);
    try delta.compute(gpa, sig, old, &ops);

    var copies: usize = 0;
    var literals: usize = 0;
    for (ops.items) |op| switch (op) {
        .copy => copies += 1,
        .literal => literals += 1,
    };
    try std.testing.expectEqual(@as(usize, 3), copies);
    try std.testing.expectEqual(@as(usize, 0), literals);
}
