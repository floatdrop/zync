//! Weak rolling checksum (rsync's Adler-style variant).
//!
//! Its only job is to be an O(1)-updatable filter so the sender can test every
//! byte offset cheaply before paying for a strong hash. It is deliberately NOT
//! collision resistant — the strong hash confirms real matches.
//!
//! For a window X[0..L):
//!   a = (Σ X[i])           mod M
//!   b = (Σ (L - i)·X[i])   mod M
//!   digest = (b << 16) | a
//! with M = 2^16. Rolling one byte forward (drop `out`, add `in`) is O(1).

const std = @import("std");

pub const modulus: u32 = 1 << 16;

pub const Rolling = struct {
    a: u32,
    b: u32,
    len: u32,

    /// Compute the checksum of a window from scratch.
    pub fn init(data: []const u8) Rolling {
        var a: u64 = 0;
        var b: u64 = 0;
        const l = data.len;
        for (data, 0..) |x, i| {
            a += x;
            b += @as(u64, l - i) * x;
        }
        return .{
            .a = @intCast(a % modulus),
            .b = @intCast(b % modulus),
            .len = @intCast(l),
        };
    }

    pub fn digest(self: Rolling) u32 {
        return (self.b << 16) | self.a;
    }

    /// Slide the window one byte forward: `out` leaves the front, `in` joins the
    /// back. The window length stays the same.
    pub fn roll(self: *Rolling, out: u8, in: u8) void {
        const m = modulus;
        self.a = (self.a + m - out + in) % m;
        const t: u32 = @intCast((@as(u64, self.len) * out) % m);
        self.b = (self.b + m - t + self.a) % m;
    }
};

test "roll matches recompute" {
    const data = "the quick brown fox jumps over the lazy dog, twice over.";
    const win: usize = 8;
    var r = Rolling.init(data[0..win]);
    var p: usize = 0;
    while (p + win < data.len) : (p += 1) {
        r.roll(data[p], data[p + win]);
        const fresh = Rolling.init(data[p + 1 ..][0..win]);
        try std.testing.expectEqual(fresh.digest(), r.digest());
    }
}
