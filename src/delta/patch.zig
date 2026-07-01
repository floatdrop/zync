//! Apply a delta (ops + basis file) to reconstruct the target, then verify.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Op = @import("delta.zig").Op;
const strong = @import("../hash/strong.zig");

pub const Error = error{VerificationFailed} || Allocator.Error;

/// Rebuild `new` from `old` and `ops` into `out`.
pub fn apply(
    gpa: Allocator,
    old: []const u8,
    block_size: u32,
    ops: []const Op,
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    for (ops) |op| switch (op) {
        .literal => |bytes| try out.appendSlice(gpa, bytes),
        .copy => |idx| {
            // The trailing block may be shorter than `block_size`.
            const start = @as(usize, idx) * block_size;
            const end = @min(start + block_size, old.len);
            try out.appendSlice(gpa, old[start..end]);
        },
    };
}

/// Rebuild and check against the sender's whole-file hash. On mismatch the
/// caller should fall back to a whole-file transfer (as rsync does).
pub fn applyVerified(
    gpa: Allocator,
    old: []const u8,
    block_size: u32,
    ops: []const Op,
    whole_file: [32]u8,
    out: *std.ArrayList(u8),
) Error!void {
    try apply(gpa, old, block_size, ops, out);
    if (!std.mem.eql(u8, &strong.wholeFile(out.items), &whole_file)) {
        return error.VerificationFailed;
    }
}
