//! gist status — read-only introspection of the persisted index.
//!
//! The question this answers, that no search verb should have to: *am I ready to
//! search fast, and how fresh is what I'd search?* Before an agent commits to a
//! query it can ask `gist status` and learn whether an index exists, how much it
//! covers (files, distinct trigrams, postings), what it costs on disk, how long
//! ago it was built (vs the freshness anchor the cold path reads), which
//! roots it spans, and which build is answering at the rendezvous — all without
//! running a single trigram query or reading a candidate file. A missing index
//! is reported as an actionable state (run `index`), never an error, so this is
//! safe to call blind.
//!
//! Both accelerators report the same way: the numbers stay true while the
//! acceleration is off, so every state where nothing is warm gets a line of its
//! own — `bound_here` for artifacts built over another tree, `resident` for a
//! daemon this binary refuses to trust.
//!
//! Everything here is derived from the same two mmap'd artifacts the query path
//! loads (`persist.loadQuiet`) plus the freshness anchor as recorded
//! (`fresh.anchorOnDisk` — status reports what is on disk and says separately
//! whether it binds here, so a foreign directory reads as what it is).
//! One `Snapshot` feeds both the byte-compatible human report and `--json`, so
//! machine consumers never need to scrape prose and the two views cannot drift.

const std = @import("std");
const persist = @import("irregex").persist;
const fresh = @import("irregex").fresh;
const frame = @import("irregex").inner.corpus.frame;
const corpus_mod = @import("irregex").corpus;
const charter_mod = @import("irregex").commands.scope.charter;
const preference = @import("irregex").preference;
const client = @import("../../../../exec/session/daemon/client/client.zig");
const Dir = std.Io.Dir;

/// Which build is answering at the rendezvous — `client.Residency`, re-exported
/// so a caller of status binds to status's contract rather than reaching into
/// the daemon client for a type it only ever reads.
pub const Residency = client.Residency;

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

/// The persisted layers in force. This is not index state, but it is the same
/// question status exists to answer — *what is in force for this tree?* — and
/// it is what decided the `roots` reported above. A configuration you cannot
/// interrogate is the actual defect in ripgrep's version of this feature; here
/// the answer is one blind-safe call away.
pub const Config = struct {
    /// The committed `.irregex.toml` governing this directory, if one does.
    charter: ?[]const u8 = null,
    /// The personal preferences file that was found and parsed, if any.
    preferences: ?[]const u8 = null,
    /// Whether those preferences reach THIS run. False off an interactive
    /// terminal — the distinction that makes the file safe, and the one a
    /// reader most needs spelled out when their terminal behaves differently
    /// from their script.
    preferences_in_force: bool = false,
    /// `--no-config` or `GIST_NO_CONFIG` — both layers ignored.
    suppressed: bool = false,
    /// A persisted file that exists but could not be read. Surfaced here
    /// because a malformed PREFERENCES file is otherwise invisible to exactly
    /// the reader who needs to know: it is skipped without complaint off a
    /// terminal, so a script whose author never sees the terminal message
    /// would have no way to learn the file is broken.
    malformed: ?[]const u8 = null,
};

/// Stable lifecycle/introspection model. Additive fields may be introduced
/// within a schema version; changing or removing a field requires a bump.
pub const Snapshot = struct {
    schema_version: u8 = schema_version,
    state: State,
    index: ?Index,
    freshness: Freshness,
    roots: []const []const u8,
    /// Do these artifacts describe the directory being searched? False for a
    /// `GIST_DIR` aimed at another checkout, and for a pre-binding build that
    /// records no origin at all. Every accelerator declines in either state
    /// (`frame.boundHere`), so answers stay right and nothing is ever warm —
    /// which is invisible from the numbers above, hence this field.
    bound_here: bool = true,
    /// The tree the artifacts say they were built over, when they say. Naming
    /// it is the difference between a diagnosable state and a silent one.
    built_over: ?[]const u8 = null,
    config: Config = .{},
    /// Whether the daemon at the rendezvous is one this binary will use. A
    /// foreign build frames identically and answers from an engine this binary
    /// no longer shares, so a skew costs every eligible query its warm path
    /// while changing nothing in the numbers above — the same invisibility
    /// `bound_here` exists to break, one layer up.
    resident: Residency = .none,
};

/// What the two persisted layers are doing right now. Borrowed paths — both
/// layers cache for the process lifetime, so neither string outlives its owner.
fn configNow(io: std.Io) Config {
    // `inspect`, not `governing`: status reports on the world, and a report
    // that exits rather than describing a broken file is the least useful
    // possible response to the question being asked. Suppression is reported
    // ALONGSIDE the files rather than instead of them, for the same reason —
    // "there is a charter and this run ignores it" is the answer; "no charter"
    // would be a lie told at the one moment it matters.
    return .{
        .suppressed = charter_mod.suppressedNow(),
        .charter = if (charter_mod.inspect()) |c| c.path else null,
        .preferences = if (preference.loaded()) |p| p.path else null,
        .preferences_in_force = preference.forThisRun(io).len > 0,
        .malformed = if (charter_mod.faulted()) |f| f.path //
        else if (preference.faulted()) |f| f.path else null,
    };
}

/// The on-disk byte size of `path`, or 0 if it can't be stat'd (treated as
/// absent — this is a report, never a hard failure).
fn fileSize(io: std.Io, path: []const u8) u64 {
    return @intCast((Dir.cwd().statFile(io, path, .{}) catch return 0).size);
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

/// Collect once for every presentation. A missing, incomplete, or invalid pair
/// is an introspectable state rather than an error, matching historical status.
/// `roots` in the returned snapshot are owned by `gpa` — release with
/// `corpus_mod.freeRoots` (a ready index reports the roots it was BUILT over;
/// an unavailable one reports what a build here WOULD cover).
pub fn collect(gpa: std.mem.Allocator, io: std.Io, socket_path: ?[]const u8) !Snapshot {
    const bound = frame.boundHere();
    // The warm tier is the other half of "am I ready to search fast", and the
    // only half whose failure is silent. Probed once, before either return.
    const resident = if (socket_path) |s| client.residency(gpa, io, s) else .none;
    var p = (try persist.loadQuiet(gpa, io)) orelse return .{
        .state = .unavailable,
        .index = null,
        .freshness = .{ .anchor_unix_ns = null, .age_seconds = null },
        .roots = try corpus_mod.resolveRoots(gpa),
        .bound_here = bound,
        .built_over = frame.treeBinding(gpa),
        .config = configNow(io),
        .resident = resident,
    };
    defer p.deinit();

    const roots = try gpa.alloc([]const u8, p.roots.items.len);
    errdefer gpa.free(roots);
    var duped: usize = 0;
    errdefer for (roots[0..duped]) |r| gpa.free(r);
    for (p.roots.items, roots) |src, *dst| {
        dst.* = try gpa.dupe(u8, src);
        duped += 1;
    }

    // What the artifact RECORDS, not what a query may trust: a foreign
    // directory has a perfectly real build instant, and reporting it as absent
    // would hide the anchor behind the very confusion `bound_here` exists to
    // name (`fresh.anchorOnDisk`).
    const built_ns = fresh.anchorOnDisk(gpa, io);
    // Sample after its own future-anchor validation so a concurrent
    // index publish cannot produce a negative age in the machine contract.
    const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
    return .{
        .state = .ready,
        .index = .{
            .path = persist.indexFile(),
            .paths_file = persist.pathsFile(),
            .files_indexed = p.paths.items.len,
            .distinct_trigrams = p.idx.dir_tri.len,
            .postings = p.idx.posting_count,
            .index_bytes = fileSize(io, persist.indexFile()),
            .paths_bytes = fileSize(io, persist.pathsFile()),
        },
        .freshness = .{
            .anchor_unix_ns = if (built_ns) |a| @intCast(a.ns()) else null,
            .age_seconds = if (built_ns) |a| @as(f64, @floatFromInt(now_ns - a.ns())) / std.time.ns_per_s else null,
        },
        .roots = roots,
        .bound_here = bound,
        .built_over = frame.treeBinding(gpa),
        .config = configNow(io),
        .resident = resident,
    };
}

fn renderHuman(gpa: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const index = snapshot.index orelse {
        try buf.print(gpa, "no index at {s} — run `gist index` first\n", .{persist.indexFile()});
        try renderConfig(gpa, &buf, snapshot.config);
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
        // An anchor dates the files of the tree it was minted in, so an
        // unbound one proves nothing here however recent it reads.
        try buf.print(gpa, "  built            {d:.0} s ago ({s})\n", .{ age_s, if (snapshot.bound_here)
            "freshness anchor set — new/edited files are folded in per query"
        else
            "anchor dates another tree — nothing here can be proven unchanged" });
    } else {
        try buf.appendSlice(gpa, "  built            (no freshness anchor — rebuild with `index` to enable the freshness overlay)\n");
    }

    try buf.appendSlice(gpa, "  roots           ");
    for (snapshot.roots) |r| try buf.print(gpa, " {s}", .{r});
    try buf.append(gpa, '\n');

    // The one state where every number above is real yet none of it describes
    // the tree the caller is standing in — say so, and name the other tree
    // when the artifacts recorded one, rather than let a healthy-looking
    // report leave them wondering why nothing is ever warm.
    if (!snapshot.bound_here) {
        if (snapshot.built_over) |tree|
            try buf.print(gpa, "  built over        {s} — not this tree; every accelerator stays off until `gist index`\n", .{tree})
        else
            try buf.appendSlice(gpa, "  built over        (unrecorded) — these artifacts name no tree; every accelerator stays off until `gist index`\n");
    }
    try renderResident(gpa, &buf, snapshot.resident);
    try renderConfig(gpa, &buf, snapshot.config);
    return buf.toOwnedSlice(gpa);
}

/// The resident daemon, and silence when there is none — a tree whose first
/// query has yet to fork one is the ordinary state, not a finding. The skew
/// line is the point of this whole report field: a foreign build answers the
/// handshake, declines every query, and leaves nothing in the output to say
/// why the warm tier went quiet.
fn renderResident(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), r: Residency) !void {
    try buf.appendSlice(gpa, switch (r) {
        .none => return,
        .ours => "  resident          this build — eligible queries answer warm\n",
        .foreign => "  resident          another build is answering — eligible queries run cold until the next one retires it\n",
    });
}

/// The persisted layers, and silence when there are none — which is the common
/// case and must cost the reader nothing. Preferences are reported even when
/// they are NOT in force, because "I set that and it isn't happening" is the
/// question the TTY gate creates and therefore the one this line must answer.
fn renderConfig(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), c: Config) !void {
    if (c.suppressed) return buf.appendSlice(gpa, "  config            ignored for this run (--no-config)\n");
    if (c.charter) |path| try buf.print(gpa, "  charter           {s} — roots, skips, and types come from here\n", .{path});
    if (c.preferences) |path| try buf.print(gpa, "  preferences       {s} ({s})\n", .{
        path,
        if (c.preferences_in_force) "in force — stdout is a terminal" else "not in force — preferences apply only to an interactive terminal",
    });
    if (c.malformed) |path| try buf.print(gpa, "  malformed         {s} — `gist config check` says why\n", .{path});
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
pub fn run(gpa: std.mem.Allocator, io: std.Io, json: bool, socket_path: ?[]const u8) !void {
    const snapshot = try collect(gpa, io, socket_path);
    defer corpus_mod.freeRoots(gpa, snapshot.roots);
    defer if (snapshot.built_over) |t| gpa.free(t);
    const output = if (json) try renderJson(gpa, snapshot) else try renderHuman(gpa, snapshot);
    defer gpa.free(output);
    corpus_mod.emitStdout(output);
}

test "human renderer preserves the established report bytes" {
    const t = std.testing;
    const output = try renderHuman(t.allocator, .{
        .state = .ready,
        .index = .{
            .path = ".gist/index.gist",
            .paths_file = ".gist/paths.list",
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
        \\gist index — .gist/index.gist
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
        "{\"schema_version\":1,\"state\":\"ready\",\"index\":{\"path\":\"index.gist\",\"paths_file\":\"paths.list\",\"files_indexed\":2,\"distinct_trigrams\":3,\"postings\":5,\"index_bytes\":8,\"paths_bytes\":13},\"freshness\":{\"anchor_unix_ns\":1000,\"age_seconds\":2.5},\"roots\":[\"libs\"],\"bound_here\":true,\"built_over\":null,\"config\":{\"charter\":null,\"preferences\":null,\"preferences_in_force\":false,\"suppressed\":false,\"malformed\":null},\"resident\":\"none\"}\n",
        output,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, output, .{});
    defer parsed.deinit();
}

test "an unbound artifact directory reports which tree it does describe" {
    const t = std.testing;
    const foreign: Index = .{
        .path = "/tmp/other/.d/index.gist",
        .paths_file = "/tmp/other/.d/paths.list",
        .files_indexed = 2,
        .distinct_trigrams = 3,
        .postings = 4,
        .index_bytes = 1 << 20,
        .paths_bytes = 524_288,
    };
    const named = try renderHuman(t.allocator, .{
        .state = .ready,
        .index = foreign,
        .freshness = .{ .anchor_unix_ns = 1, .age_seconds = 7.4 },
        .roots = &.{"."},
        .bound_here = false,
        .built_over = "/tmp/other",
    });
    defer t.allocator.free(named);
    // Every count above is real; these two lines are the only thing saying
    // none of it describes the tree the caller is standing in.
    try t.expect(std.mem.containsAtLeast(u8, named, 1, "anchor dates another tree"));
    try t.expect(std.mem.endsWith(
        u8,
        named,
        "  built over        /tmp/other — not this tree; every accelerator stays off until `gist index`\n",
    ));

    // Pre-binding artifacts record no origin — still cold, but there is no
    // other tree to point at, and claiming one would be a fresh lie.
    const anonymous = try renderHuman(t.allocator, .{
        .state = .ready,
        .index = foreign,
        .freshness = .{ .anchor_unix_ns = 1, .age_seconds = 7.4 },
        .roots = &.{"."},
        .bound_here = false,
    });
    defer t.allocator.free(anonymous);
    try t.expect(std.mem.endsWith(
        u8,
        anonymous,
        "  built over        (unrecorded) — these artifacts name no tree; every accelerator stays off until `gist index`\n",
    ));
}

test "the persisted layers are silent when absent and named when present" {
    const t = std.testing;
    const ready: Snapshot = .{
        .state = .ready,
        .index = .{
            .path = "i",
            .paths_file = "p",
            .files_indexed = 1,
            .distinct_trigrams = 1,
            .postings = 1,
            .index_bytes = 0,
            .paths_bytes = 0,
        },
        .freshness = .{ .anchor_unix_ns = 1, .age_seconds = 1 },
        .roots = &.{"."},
    };

    // Having no configuration is the common case and costs the reader nothing.
    const bare = try renderHuman(t.allocator, ready);
    defer t.allocator.free(bare);
    try t.expect(std.mem.indexOf(u8, bare, "charter") == null);
    try t.expect(std.mem.indexOf(u8, bare, "preferences") == null);

    // A preferences file that exists but is NOT reaching this run is the state
    // the TTY gate creates, so it is the one the report must not stay quiet
    // about — otherwise "I set that and it isn't happening" has no answer.
    var gated = ready;
    gated.config = .{ .charter = ".irregex.toml", .preferences = "~/.config/gist/preferences" };
    const shown = try renderHuman(t.allocator, gated);
    defer t.allocator.free(shown);
    try t.expect(std.mem.containsAtLeast(u8, shown, 1, "charter           .irregex.toml"));
    try t.expect(std.mem.containsAtLeast(u8, shown, 1, "not in force"));

    // Suppression replaces both lines rather than listing files it ignored.
    var off = ready;
    off.config = .{ .suppressed = true };
    const muted = try renderHuman(t.allocator, off);
    defer t.allocator.free(muted);
    try t.expect(std.mem.endsWith(u8, muted, "  config            ignored for this run (--no-config)\n"));

    // An unavailable index does not hide the configuration question: roots may
    // be the very thing a first `gist index` is about to get wrong.
    var none = gated;
    none.index = null;
    const indexless = try renderHuman(t.allocator, none);
    defer t.allocator.free(indexless);
    try t.expect(std.mem.containsAtLeast(u8, indexless, 1, "charter"));

    // A broken preferences file is skipped without complaint off a terminal —
    // correct, since nothing would have used it, but it would leave the file
    // invisible to the one reader who has to repair it. Status is where that
    // reader finds out, and it points at the verb that explains why.
    var broken = ready;
    broken.config = .{ .preferences = "~/.config/gist/preferences", .malformed = "~/.config/gist/preferences" };
    const flagged = try renderHuman(t.allocator, broken);
    defer t.allocator.free(flagged);
    try t.expect(std.mem.containsAtLeast(u8, flagged, 1, "malformed"));
    try t.expect(std.mem.containsAtLeast(u8, flagged, 1, "gist config check"));
}

test "a skewed resident is named, and an absent one costs the reader nothing" {
    const t = std.testing;
    const ready: Snapshot = .{
        .state = .ready,
        .index = .{
            .path = "i",
            .paths_file = "p",
            .files_indexed = 1,
            .distinct_trigrams = 1,
            .postings = 1,
            .index_bytes = 0,
            .paths_bytes = 0,
        },
        .freshness = .{ .anchor_unix_ns = 1, .age_seconds = 1 },
        .roots = &.{"."},
    };

    // No daemon is the ordinary state of a tree whose first query hasn't run.
    const quiet = try renderHuman(t.allocator, ready);
    defer t.allocator.free(quiet);
    try t.expect(std.mem.indexOf(u8, quiet, "resident") == null);

    // The state this field exists for: every number above is real, the index
    // is fresh, and every eligible query is silently running cold anyway.
    var skewed = ready;
    skewed.resident = .foreign;
    const named = try renderHuman(t.allocator, skewed);
    defer t.allocator.free(named);
    try t.expect(std.mem.containsAtLeast(u8, named, 1, "another build is answering"));
    try t.expect(std.mem.containsAtLeast(u8, named, 1, "run cold"));

    // And the positive answer to the question status exists to answer.
    var warm = ready;
    warm.resident = .ours;
    const healthy = try renderHuman(t.allocator, warm);
    defer t.allocator.free(healthy);
    try t.expect(std.mem.containsAtLeast(u8, healthy, 1, "resident          this build"));
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
        "{\"schema_version\":1,\"state\":\"unavailable\",\"index\":null,\"freshness\":{\"anchor_unix_ns\":null,\"age_seconds\":null},\"roots\":[\"libs\"],\"bound_here\":true,\"built_over\":null,\"config\":{\"charter\":null,\"preferences\":null,\"preferences_in_force\":false,\"suppressed\":false,\"malformed\":null},\"resident\":\"none\"}\n",
        output,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, output, .{});
    defer parsed.deinit();
}
