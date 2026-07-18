//! gist status — read-only introspection of the persisted index.
//!
//! The question this answers, that no search verb should have to: *am I ready to
//! search fast, and how fresh is what I'd search?* Before an agent commits to a
//! query it can ask `gist status` and learn whether an index exists, how much it
//! covers (files, distinct trigrams, postings), what it costs on disk, how long
//! ago it was built (vs the freshness anchor the cold path reads), and which
//! roots it spans — all without running a single trigram query or reading a
//! candidate file. A missing index is reported as an actionable state (run
//! `index`), never an error, so this is safe to call blind.
//!
//! Everything here is derived from the same two mmap'd artifacts the query path
//! loads (`persist.loadQuiet`) plus the freshness anchor (`fresh.readAnchor`).
//! One `Snapshot` feeds both the byte-compatible human report and `--json`, so
//! machine consumers never need to scrape prose and the two views cannot drift.

const std = @import("std");
const persist = @import("../../../kernel/index/persist.zig");
const fresh = @import("../../../kernel/index/fresh.zig");
const corpus_mod = @import("../../../../corpus/corpus.zig");
const Dir = std.Io.Dir;

/// Version of the `--json` machine contract; bumped only on a breaking field
/// change (see `Snapshot`).
pub const schema_version = 1;

/// Whether a loadable index pair exists. `unavailable` is an actionable state
/// (run `gist index`), never an error — status must be safe to call blind.
pub const State = enum {
    ready,
    unavailable,
};

/// Everything the persisted index pair reveals about itself: coverage,
/// cardinality, and on-disk cost. Present only when `state == .ready`.
pub const Index = struct {
    path: []const u8,
    paths_file: []const u8,
    files_indexed: usize,
    distinct_trigrams: usize,
    postings: u64,
    index_bytes: u64,
    paths_bytes: u64,
};

/// The freshness anchor the cold path folds changed files in against; both
/// fields are null when no anchor was published (pre-overlay index).
pub const Freshness = struct {
    anchor_unix_ns: ?i64,
    age_seconds: ?f64,
};

/// Stable lifecycle/introspection model. Additive fields may be introduced
/// within a schema version; changing or removing a field requires a bump.
pub const Snapshot = struct {
    schema_version: u8 = schema_version,
    state: State,
    index: ?Index,
    freshness: Freshness,
    roots: []const []const u8,
};

/// The on-disk byte size of `path`, or 0 if it can't be stat'd (treated as
/// absent — this is a report, never a hard failure).
fn fileSize(io: std.Io, path: []const u8) u64 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @intCast(st.size);
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

/// Collect once for every presentation. A missing, incomplete, or invalid pair
/// is an introspectable state rather than an error, matching historical status.
pub fn collect(gpa: std.mem.Allocator, io: std.Io) !Snapshot {
    var p = (try persist.loadQuiet(gpa, io)) orelse return .{
        .state = .unavailable,
        .index = null,
        .freshness = .{ .anchor_unix_ns = null, .age_seconds = null },
        .roots = &corpus_mod.default_roots,
    };
    defer p.deinit();

    const built_ns = fresh.readAnchor(gpa, io);
    // Sample after readAnchor's own future-anchor validation so a concurrent
    // index publish cannot produce a negative age in the machine contract.
    const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
    return .{
        .state = .ready,
        .index = .{
            .path = persist.index_file,
            .paths_file = persist.paths_file,
            .files_indexed = p.paths.items.len,
            .distinct_trigrams = p.idx.dir_tri.len,
            .postings = p.idx.posting_count,
            .index_bytes = fileSize(io, persist.index_file),
            .paths_bytes = fileSize(io, persist.paths_file),
        },
        .freshness = .{
            .anchor_unix_ns = if (built_ns) |ns| @intCast(ns) else null,
            .age_seconds = if (built_ns) |ns| @as(f64, @floatFromInt(now_ns - ns)) / std.time.ns_per_s else null,
        },
        .roots = &corpus_mod.default_roots,
    };
}

fn renderHuman(gpa: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const index = snapshot.index orelse {
        try buf.appendSlice(gpa, "no index at " ++ persist.index_file ++ " — run `gist index` first\n");
        return buf.toOwnedSlice(gpa);
    };
    const avg_per_file: f64 = if (index.files_indexed == 0) 0 else @as(f64, @floatFromInt(index.postings)) / @as(f64, @floatFromInt(index.files_indexed));
    try buf.print(gpa,
        \\gist index — {s}
        \\  files indexed     {d}
        \\  distinct trigrams {d}
        \\  postings          {d}  ({d:.0} trigram·doc pairs per file)
        \\  on disk           {d:.1} MiB index + {d:.1} MiB paths
        \\
    , .{
        index.path,
        index.files_indexed,
        index.distinct_trigrams,
        index.postings,
        avg_per_file,
        mib(index.index_bytes),
        mib(index.paths_bytes),
    });

    if (snapshot.freshness.age_seconds) |age_s| {
        try buf.print(gpa, "  built            {d:.0} s ago (freshness anchor set — new/edited files are folded in per query)\n", .{age_s});
    } else {
        try buf.appendSlice(gpa, "  built            (no freshness anchor — rebuild with `index` to enable the freshness overlay)\n");
    }

    try buf.appendSlice(gpa, "  roots           ");
    for (snapshot.roots) |r| try buf.print(gpa, " {s}", .{r});
    try buf.append(gpa, '\n');
    return buf.toOwnedSlice(gpa);
}

fn renderJson(gpa: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    var out = try std.json.Stringify.valueAlloc(gpa, snapshot, .{});
    errdefer gpa.free(out);
    out = try gpa.realloc(out, out.len + 1);
    out[out.len - 1] = '\n';
    return out;
}

/// Emit status to stdout. JSON is compact, newline-terminated, and contains no
/// human diagnostics, including when the index is unavailable.
pub fn run(gpa: std.mem.Allocator, io: std.Io, json: bool) !void {
    const snapshot = try collect(gpa, io);
    const output = if (json) try renderJson(gpa, snapshot) else try renderHuman(gpa, snapshot);
    defer gpa.free(output);
    corpus_mod.emitStdout(output);
}

test "human renderer preserves the established report bytes" {
    const t = std.testing;
    const output = try renderHuman(t.allocator, .{
        .state = .ready,
        .index = .{
            .path = ".local/gist-verify/index.gist",
            .paths_file = ".local/gist-verify/paths.list",
            .files_indexed = 2,
            .distinct_trigrams = 3,
            .postings = 4,
            .index_bytes = 1 << 20,
            .paths_bytes = 524_288,
        },
        .freshness = .{ .anchor_unix_ns = 1, .age_seconds = 7.4 },
        .roots = &.{ "services", "libs" },
    });
    defer t.allocator.free(output);
    try t.expectEqualStrings(
        \\gist index — .local/gist-verify/index.gist
        \\  files indexed     2
        \\  distinct trigrams 3
        \\  postings          4  (2 trigram·doc pairs per file)
        \\  on disk           1.0 MiB index + 0.5 MiB paths
        \\  built            7 s ago (freshness anchor set — new/edited files are folded in per query)
        \\  roots            services libs
        \\
    , output);
}

test "JSON renderer exposes the stable ready contract" {
    const t = std.testing;
    const output = try renderJson(t.allocator, .{
        .state = .ready,
        .index = .{
            .path = "index.gist",
            .paths_file = "paths.list",
            .files_indexed = 2,
            .distinct_trigrams = 3,
            .postings = 5,
            .index_bytes = 8,
            .paths_bytes = 13,
        },
        .freshness = .{ .anchor_unix_ns = 1_000, .age_seconds = 2.5 },
        .roots = &.{"libs"},
    });
    defer t.allocator.free(output);
    try t.expectEqualStrings(
        "{\"schema_version\":1,\"state\":\"ready\",\"index\":{\"path\":\"index.gist\",\"paths_file\":\"paths.list\",\"files_indexed\":2,\"distinct_trigrams\":3,\"postings\":5,\"index_bytes\":8,\"paths_bytes\":13},\"freshness\":{\"anchor_unix_ns\":1000,\"age_seconds\":2.5},\"roots\":[\"libs\"]}\n",
        output,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, output, .{});
    defer parsed.deinit();
}

test "JSON unavailable state stays valid and null-bearing" {
    const t = std.testing;
    const output = try renderJson(t.allocator, .{
        .state = .unavailable,
        .index = null,
        .freshness = .{ .anchor_unix_ns = null, .age_seconds = null },
        .roots = &.{"libs"},
    });
    defer t.allocator.free(output);
    try t.expectEqualStrings(
        "{\"schema_version\":1,\"state\":\"unavailable\",\"index\":null,\"freshness\":{\"anchor_unix_ns\":null,\"age_seconds\":null},\"roots\":[\"libs\"]}\n",
        output,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, output, .{});
    defer parsed.deinit();
}
