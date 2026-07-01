//! Delta computation: slide a window over `new`, reusing blocks from the basis
//! file wherever the weak checksum (then strong hash) confirms a match. Emits a
//! stream of ops that `patch.zig` replays against `old` to rebuild `new`.
//!
//! Two window sizes run in lockstep: the full block size `S` (for the many
//! equal-size blocks) and, when the basis file's length isn't a multiple of
//! `S`, the shorter length `T` of its final block. A full match is preferred
//! over a tail match at the same offset because it reuses more bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rolling = @import("rolling.zig").Rolling;
const strong = @import("../hash/strong.zig");
const Signature = @import("signature.zig").Signature;

pub const Op = union(enum) {
    /// Bytes taken verbatim from `new` (slice borrows `new`; copy before wire).
    literal: []const u8,
    /// Reuse block `index` of the basis file. Its length is `S` for a full
    /// block and the shorter remainder for the trailing block.
    copy: u32,
};

/// A (weak, block-index) row, sorted by weak so equal-weak candidates form a
/// contiguous range we can binary-search.
const Entry = struct {
    weak: u32,
    index: u32,
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return a.weak < b.weak;
    }
};

pub fn compute(gpa: Allocator, sig: Signature, new: []const u8, ops: *std.ArrayList(Op)) !void {
    const s: usize = sig.block_size;
    const full = sig.fullBlockCount();
    const has_tail = sig.blocks.len > full;
    const tail_idx: u32 = @intCast(full);
    const tail_len: usize = if (has_tail)
        @intCast(sig.file_len - @as(u64, full) * sig.block_size)
    else
        0;

    // Smallest window we could ever match. If nothing fits, it's all literal.
    const min_win: usize = if (has_tail) tail_len else s;
    if (s == 0 or (full == 0 and !has_tail) or new.len < min_win) {
        if (new.len > 0) try ops.append(gpa, .{ .literal = new });
        return;
    }

    // Sorted weak table over the full blocks (the tail block is matched
    // directly against its single stored checksum, so it needs no table).
    var entries = try gpa.alloc(Entry, full);
    defer gpa.free(entries);
    for (0..full) |i| entries[i] = .{ .weak = sig.blocks[i].weak, .index = @intCast(i) };
    std.mem.sort(Entry, entries, {}, Entry.lessThan);

    var lit_start: usize = 0;
    var p: usize = 0;

    var rs: Rolling = undefined;
    var rs_valid = full > 0 and p + s <= new.len;
    if (rs_valid) rs = Rolling.init(new[p..][0..s]);

    var rt: Rolling = undefined;
    var rt_valid = has_tail and p + tail_len <= new.len;
    if (rt_valid) rt = Rolling.init(new[p..][0..tail_len]);

    while (rs_valid or rt_valid) {
        var hit_idx: ?u32 = null;
        var hit_len: usize = 0;

        // Prefer a full-block match (more reuse) over the tail block.
        if (rs_valid) {
            if (equalRange(entries, rs.digest())) |r| {
                const w = strong.block(new[p..][0..s]);
                for (entries[r.start..r.end]) |e| {
                    if (std.mem.eql(u8, &w, &sig.blocks[e.index].strong)) {
                        hit_idx = e.index;
                        hit_len = s;
                        break;
                    }
                }
            }
        }
        if (hit_idx == null and rt_valid and rt.digest() == sig.blocks[tail_idx].weak) {
            const w = strong.block(new[p..][0..tail_len]);
            if (std.mem.eql(u8, &w, &sig.blocks[tail_idx].strong)) {
                hit_idx = tail_idx;
                hit_len = tail_len;
            }
        }

        if (hit_idx) |idx| {
            if (p > lit_start) try ops.append(gpa, .{ .literal = new[lit_start..p] });
            try ops.append(gpa, .{ .copy = idx });
            p += hit_len;
            lit_start = p;
            rs_valid = full > 0 and p + s <= new.len;
            if (rs_valid) rs = Rolling.init(new[p..][0..s]);
            rt_valid = has_tail and p + tail_len <= new.len;
            if (rt_valid) rt = Rolling.init(new[p..][0..tail_len]);
        } else {
            const np = p + 1;
            if (rs_valid) {
                if (np + s <= new.len) rs.roll(new[p], new[p + s]) else rs_valid = false;
            }
            if (rt_valid) {
                if (np + tail_len <= new.len) rt.roll(new[p], new[p + tail_len]) else rt_valid = false;
            }
            p = np;
        }
    }

    if (lit_start < new.len) try ops.append(gpa, .{ .literal = new[lit_start..] });
}

const Range = struct { start: usize, end: usize };

/// Contiguous range of entries whose weak == `weak`, or null.
fn equalRange(entries: []const Entry, weak: u32) ?Range {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].weak < weak) lo = mid + 1 else hi = mid;
    }
    if (lo >= entries.len or entries[lo].weak != weak) return null;
    var end = lo;
    while (end < entries.len and entries[end].weak == weak) end += 1;
    return .{ .start = lo, .end = end };
}
