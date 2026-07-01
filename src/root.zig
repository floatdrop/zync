//! zync public library API.
//!
//! Keeping all logic in this module (rather than in the executable) makes it
//! testable and embeddable, per the split described in build.zig.

const std = @import("std");

pub const sync = @import("core/sync.zig");
pub const session = @import("core/session.zig");
pub const parallel = @import("core/parallel.zig");
pub const cli = @import("cli/args.zig");
pub const wire = @import("proto/wire.zig");
pub const Endpoint = @import("core/endpoint.zig").Endpoint;

/// Delta transfer engine (rsync-style rolling checksum + strong hash).
pub const delta = struct {
    pub const Rolling = @import("delta/rolling.zig").Rolling;
    pub const Signature = @import("delta/signature.zig").Signature;
    pub const generate = @import("delta/signature.zig").generate;
    pub const chooseBlockSize = @import("delta/signature.zig").chooseBlockSize;
    pub const Op = @import("delta/delta.zig").Op;
    pub const compute = @import("delta/delta.zig").compute;
    pub const apply = @import("delta/patch.zig").apply;
    pub const applyVerified = @import("delta/patch.zig").applyVerified;
};

pub const hash = struct {
    pub const strong = @import("hash/strong.zig");
};

test {
    // Pull in tests from referenced files so `zig build test` runs them.
    _ = @import("core/endpoint.zig");
    _ = @import("cli/args.zig");
    _ = @import("core/sync.zig");
    _ = @import("core/session.zig");
    _ = @import("core/parallel.zig");
    _ = @import("core/filter.zig");
    _ = @import("proto/wire.zig");
    _ = @import("proto/zip.zig");
    _ = @import("fs/link.zig");
    _ = @import("fs/special.zig");
    _ = @import("fs/hardlink.zig");
    _ = @import("fs/prune.zig");
    _ = @import("fs/meta.zig");
    _ = @import("fs/owner.zig");
    _ = @import("fs/xattr.zig");
    _ = @import("delta/rolling.zig");
    _ = @import("delta/signature.zig");
    _ = @import("delta/delta.zig");
    _ = @import("delta/patch.zig");
    _ = @import("delta/table.zig");
    _ = @import("delta/stream.zig");
    _ = @import("delta/tests.zig");
    _ = @import("hash/strong.zig");
}
