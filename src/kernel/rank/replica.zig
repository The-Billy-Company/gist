//! Cached-source mirror ranking: identify incidental snapshot paths, fingerprint
//! their bytes, and resolve an exact non-mirror duplicate for display. These
//! signals only reorder or annotate results; they never change the match set.

const std = @import("std");

/// Is `path` inside a known source-mirroring cache or VCS snapshot? Markers are
/// narrow because ordinary `build/` and `target/` folders can contain source.
pub fn isPath(path: []const u8) bool {
    var normalized = path;
    while (std.mem.startsWith(u8, normalized, "./")) normalized = normalized[2..];
    const roots = [_][]const u8{ "target/semver-checks/", ".git/worktrees/", ".cache/", "node_modules/.cache/" };
    for (roots) |root| if (std.mem.startsWith(u8, normalized, root)) return true;
    const nested = [_][]const u8{ "/target/semver-checks/", "/.git/worktrees/", "/.cache/", "/node_modules/.cache/" };
    for (nested) |marker| if (std.mem.indexOf(u8, normalized, marker) != null) return true;
    return false;
}

pub fn fingerprint(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

/// Return the id of the first exact authored duplicate. `T` is structural,
/// keeping this module independent of the RRF kernel.
pub fn canonical(comptime T: type, docs: []const T, source: T) ?u32 {
    for (docs) |doc| {
        if (doc.id != source.id and !doc.is_mirror and !doc.is_generated and
            doc.content_len == source.content_len and doc.content_hash == source.content_hash) return doc.id;
    }
    return null;
}

test "source snapshots are mirrors, ordinary target folders are not" {
    try std.testing.expect(isPath("./target/semver-checks/git-origin_main/deadbeef/src/main.rs"));
    try std.testing.expect(isPath("repo/.git/worktrees/feature/src/main.rs"));
    try std.testing.expect(isPath("packages/app/node_modules/.cache/tool/source.ts"));
    try std.testing.expect(isPath("repo/.cache/copied/source.py"));
    try std.testing.expect(!isPath("services/compiler/target/source.rs"));
    try std.testing.expect(!isPath("pkg/tools/support/graph.zig"));
}

test "canonical resolves only exact authored duplicates" {
    const Doc = struct { id: u32, is_mirror: bool, is_generated: bool, content_hash: u64, content_len: usize };
    const docs = [_]Doc{
        .{ .id = 0, .is_mirror = true, .is_generated = false, .content_hash = fingerprint("same"), .content_len = 4 },
        .{ .id = 1, .is_mirror = false, .is_generated = false, .content_hash = fingerprint("same"), .content_len = 4 },
        .{ .id = 2, .is_mirror = false, .is_generated = false, .content_hash = fingerprint("other"), .content_len = 5 },
    };
    try std.testing.expectEqual(@as(?u32, 1), canonical(Doc, &docs, docs[0]));
    try std.testing.expectEqual(@as(?u32, null), canonical(Doc, &docs, docs[1]));
}
