//! Parsing of sync endpoints. An endpoint is either a local path or a remote
//! `[user@]host:path` spec. Step 1 only implements local endpoints; remote
//! parsing is wired up now so the CLI surface is stable when SSH transport lands.

const std = @import("std");

pub const Endpoint = struct {
    /// `null` means the endpoint is local. Otherwise the `[user@]host` portion.
    host: ?[]const u8,
    /// Filesystem path on the endpoint.
    path: []const u8,

    pub fn parse(spec: []const u8) Endpoint {
        if (hostSeparator(spec)) |i| {
            return .{ .host = spec[0..i], .path = spec[i + 1 ..] };
        }
        return .{ .host = null, .path = spec };
    }

    pub fn isLocal(self: Endpoint) bool {
        return self.host == null;
    }
};

/// Returns the index of the ':' that separates host from path, following
/// rsync's rule: a ':' is only a host separator if it appears before the
/// first '/'. This keeps relative paths containing ':' (rare, but legal)
/// from being misread as remote specs.
fn hostSeparator(spec: []const u8) ?usize {
    for (spec, 0..) |c, i| {
        switch (c) {
            '/' => return null,
            ':' => return i,
            else => {},
        }
    }
    return null;
}

test "local paths" {
    const e = Endpoint.parse("./src");
    try std.testing.expect(e.isLocal());
    try std.testing.expectEqualStrings("./src", e.path);
}

test "colon after slash stays local" {
    const e = Endpoint.parse("./weird:name");
    try std.testing.expect(e.isLocal());
}

test "remote spec" {
    const e = Endpoint.parse("user@host:/var/data");
    try std.testing.expect(!e.isLocal());
    try std.testing.expectEqualStrings("user@host", e.host.?);
    try std.testing.expectEqualStrings("/var/data", e.path);
}
