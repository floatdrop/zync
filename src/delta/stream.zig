//! Streaming delta matcher: slides a bounded window over `reader` (the source
//! file) and emits copy/literal ops to a `sink`, never holding more than a
//! window-sized buffer plus the block table. This is what makes transfers of
//! files larger than memory possible.
//!
//! `sink` is any value with:
//!     emitLiteral(self, bytes: []const u8) !void
//!     emitCopy(self, block_index: u32) !void
//! Literal `bytes` borrow the internal buffer and are only valid for the call.
//!
//! If `hasher` is non-null it receives every byte read, yielding the whole-file
//! hash of the source (used for end-to-end verification).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Blake3 = std.crypto.hash.Blake3;
const Rolling = @import("rolling.zig").Rolling;
const strong = @import("../hash/strong.zig");
const Signature = @import("signature.zig").Signature;
const Table = @import("table.zig").Table;

/// Bytes scanned between buffer refills; the buffer is this plus one block.
const read_window: usize = 256 * 1024;

pub fn match(gpa: Allocator, sig: Signature, reader: *Reader, hasher: ?*Blake3, sink: anytype) !void {
    const s: usize = sig.block_size;
    const full = sig.fullBlockCount();
    const has_tail = sig.blocks.len > full;
    const tail_idx: u32 = @intCast(full);
    const tail_len: usize = if (has_tail)
        @intCast(sig.file_len - @as(u64, full) * sig.block_size)
    else
        0;

    var table = try Table.build(gpa, sig);
    defer table.deinit(gpa);

    const buf = try gpa.alloc(u8, read_window + s);
    defer gpa.free(buf);

    var sc: Scan = .{ .buf = buf, .reader = reader, .hasher = hasher };
    try sc.refill();

    // The rolling windows describe the bytes at `pos`; because compaction moves
    // that content without changing it, they stay valid across refills.
    var rs: Rolling = undefined;
    var rs_ok = false;
    var rt: Rolling = undefined;
    var rt_ok = false;

    while (true) {
        try sc.ensure(s + 1, sink);
        const avail = sc.len - sc.pos;
        if (avail == 0) break;

        var hit: ?u32 = null;
        var hit_len: usize = 0;

        if (full > 0 and avail >= s) {
            if (!rs_ok) {
                rs = Rolling.init(sc.buf[sc.pos..][0..s]);
                rs_ok = true;
            }
            const cands = table.find(rs.digest());
            if (cands.len != 0) {
                const w = strong.block(sc.buf[sc.pos..][0..s]);
                for (cands) |e| {
                    if (std.mem.eql(u8, &w, &sig.blocks[e.index].strong)) {
                        hit = e.index;
                        hit_len = s;
                        break;
                    }
                }
            }
        }
        if (hit == null and has_tail and avail >= tail_len) {
            if (!rt_ok) {
                rt = Rolling.init(sc.buf[sc.pos..][0..tail_len]);
                rt_ok = true;
            }
            if (rt.digest() == sig.blocks[tail_idx].weak) {
                const w = strong.block(sc.buf[sc.pos..][0..tail_len]);
                if (std.mem.eql(u8, &w, &sig.blocks[tail_idx].strong)) {
                    hit = tail_idx;
                    hit_len = tail_len;
                }
            }
        }

        if (hit) |idx| {
            try sc.flushLiteral(sink);
            try sink.emitCopy(idx);
            sc.pos += hit_len;
            sc.lit = sc.pos;
            rs_ok = false;
            rt_ok = false;
        } else {
            if (rs_ok) {
                if (sc.pos + s < sc.len) rs.roll(sc.buf[sc.pos], sc.buf[sc.pos + s]) else rs_ok = false;
            }
            if (rt_ok) {
                if (sc.pos + tail_len < sc.len) rt.roll(sc.buf[sc.pos], sc.buf[sc.pos + tail_len]) else rt_ok = false;
            }
            sc.pos += 1;
        }
    }
    try sc.flushLiteral(sink);
}

const Scan = struct {
    buf: []u8,
    len: usize = 0, // valid bytes in buf
    pos: usize = 0, // scan cursor (start of the current window)
    lit: usize = 0, // start of the pending literal run (<= pos)
    eof: bool = false,
    reader: *Reader,
    hasher: ?*Blake3,

    /// Reads from the source until the buffer is full or EOF, hashing new bytes.
    fn refill(sc: *Scan) !void {
        while (sc.len < sc.buf.len and !sc.eof) {
            const n = try sc.reader.readSliceShort(sc.buf[sc.len..]);
            if (n == 0) {
                sc.eof = true;
                break;
            }
            if (sc.hasher) |h| h.update(sc.buf[sc.len..][0..n]);
            sc.len += n;
        }
    }

    /// Guarantees at least `need` bytes are available from `pos` (unless EOF).
    /// Confirmed-literal bytes before `pos` are flushed and the window bytes are
    /// compacted to the front to make room.
    fn ensure(sc: *Scan, need: usize, sink: anytype) !void {
        if (sc.len - sc.pos >= need or sc.eof) return;
        try sc.flushLiteral(sink);
        const keep = sc.len - sc.pos;
        std.mem.copyForwards(u8, sc.buf[0..keep], sc.buf[sc.pos..sc.len]);
        sc.pos = 0;
        sc.lit = 0;
        sc.len = keep;
        try sc.refill();
    }

    fn flushLiteral(sc: *Scan, sink: anytype) !void {
        if (sc.pos > sc.lit) {
            try sink.emitLiteral(sc.buf[sc.lit..sc.pos]);
            sc.lit = sc.pos;
        }
    }
};
