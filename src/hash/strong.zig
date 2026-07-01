//! Strong content hashes. BLAKE3 is used as an XOF: 16 bytes per block (enough
//! to make collisions negligible while keeping signatures compact) and 32 bytes
//! for the end-to-end whole-file verification.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

/// Per-block strong hash (128-bit).
pub fn block(data: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    Blake3.hash(data, &out, .{});
    return out;
}

/// Whole-file hash (256-bit) used to verify a reconstructed file.
pub fn wholeFile(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Blake3.hash(data, &out, .{});
    return out;
}
