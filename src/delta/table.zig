//! Weak-checksum → block-index lookup over a signature's full-size blocks.
//! Shared by the streaming matcher; equal-weak candidates form a contiguous
//! range in the sorted array.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Signature = @import("signature.zig").Signature;

pub const Table = struct {
    pub const Entry = struct { weak: u32, index: u32 };

    entries: []Entry,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return a.weak < b.weak;
    }

    pub fn build(gpa: Allocator, sig: Signature) !Table {
        const full = sig.fullBlockCount();
        const entries = try gpa.alloc(Entry, full);
        for (0..full) |i| entries[i] = .{ .weak = sig.blocks[i].weak, .index = @intCast(i) };
        std.mem.sort(Entry, entries, {}, lessThan);
        return .{ .entries = entries };
    }

    pub fn deinit(self: *Table, gpa: Allocator) void {
        gpa.free(self.entries);
        self.* = undefined;
    }

    /// Candidates whose weak checksum equals `weak` (empty slice if none).
    pub fn find(self: Table, weak: u32) []const Entry {
        const e = self.entries;
        var lo: usize = 0;
        var hi: usize = e.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (e[mid].weak < weak) lo = mid + 1 else hi = mid;
        }
        if (lo >= e.len or e[lo].weak != weak) return e[0..0];
        var end = lo;
        while (end < e.len and e[end].weak == weak) end += 1;
        return e[lo..end];
    }
};
