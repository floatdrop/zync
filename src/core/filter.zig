//! Exclude filters (rsync's `--exclude`). A practical subset of rsync's glob
//! rules:
//!   *   any run of characters      ?   a single character      **  (same as *)
//!   trailing `/`  → matches directories only
//!   leading  `/`  → anchored to the transfer root (matches the full path)
//!   a `/` elsewhere → matches the full relative path; otherwise the basename
//!
//! `*` currently also crosses `/` (a simplification); basename matching covers
//! the common slash-free patterns (`node_modules`, `*.log`) correctly.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const Filter = struct {
    patterns: []const []const u8 = &.{},

    pub fn excluded(self: Filter, path: []const u8, is_dir: bool) bool {
        for (self.patterns) |p| if (matchPattern(p, path, is_dir)) return true;
        return false;
    }

    /// Checks an entry during a walk; if excluded, skips a directory's whole
    /// subtree (by leaving it) and returns true.
    pub fn skip(self: Filter, walker: *Dir.Walker, io: Io, path: []const u8, kind: Io.File.Kind) bool {
        if (self.excluded(path, kind == .directory)) {
            if (kind == .directory) walker.leave(io);
            return true;
        }
        return false;
    }
};

fn matchPattern(pattern: []const u8, path: []const u8, is_dir: bool) bool {
    var pat = pattern;
    if (pat.len > 0 and pat[pat.len - 1] == '/') {
        if (!is_dir) return false;
        pat = pat[0 .. pat.len - 1];
    }
    if (pat.len == 0) return false;

    if (pat[0] == '/') return globMatch(pat[1..], path); // anchored: full path
    if (std.mem.indexOfScalar(u8, pat, '/') != null) return globMatch(pat, path); // full path
    return globMatch(pat, std.fs.path.basename(path)); // basename
}

/// Whole-string wildcard match (`*` and `?`).
fn globMatch(pat: []const u8, str: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var star_s: usize = 0;
    while (s < str.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == str[s])) {
            p += 1;
            s += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            star_s = s;
            p += 1;
        } else if (star) |sp| {
            p = sp + 1;
            star_s += 1;
            s = star_s;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

test "glob and patterns" {
    const t = std.testing;
    try t.expect(globMatch("*.log", "err.log"));
    try t.expect(!globMatch("*.log", "err.txt"));
    try t.expect(globMatch("a?c", "abc"));

    const f: Filter = .{ .patterns = &.{ "node_modules", "*.tmp", "/build", "cache/" } };
    try t.expect(f.excluded("node_modules", true));
    try t.expect(f.excluded("src/node_modules", true)); // basename, any depth
    try t.expect(f.excluded("a/b/x.tmp", false));
    try t.expect(f.excluded("build", true)); // anchored top-level
    try t.expect(!f.excluded("src/build", true)); // not anchored here
    try t.expect(f.excluded("cache", true)); // dir-only
    try t.expect(!f.excluded("cache", false)); // trailing / requires dir
    try t.expect(!f.excluded("src/main.zig", false));
}
