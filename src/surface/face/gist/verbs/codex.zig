//! gist `codex` — the exact existence/count tier over the compressed self-index.
//!
//! Four verbs over one persisted artifact (`codex.shelf`: the FM-index shelf
//! from `src/corpus/index/shelf/shelf.zig`, built over the SAME corpus policy as `gist
//! index`):
//!
//!   gist codex build                    build + persist the shelf (`codex.shelf`)
//!   gist codex count <text>  [--json]   corpus-wide occurrence count — O(|text|),
//!                                       ZERO corpus I/O, zero false positives
//!   gist codex tally <text>  [--top N] [--json]   per-file counts, heaviest first
//!   gist codex status        [--json]   is a shelf ready, how big, how fresh
//!
//! Why this exists beside the trigram index: the trigram tier nominates
//! CANDIDATE files (it can false-positive; a read verifies), while the codex
//! answers the count itself — `count == 0` with a clean freshness walk is a
//! PROOF of absence across the corpus, no file opened. That's the query agents
//! ask constantly ("is this name taken? how many call sites?") priced at
//! microseconds instead of a tree scan.
//!
//! Freshness is reported, never silently assumed: every query verb stat-walks
//! the corpus roots against the shelf's own build anchor (the same
//! conservative T3 walk the trigram overlay uses — `fresh.changedSince`) and
//! says how many files have changed since the build. Counts are exact as of
//! the anchor; a nonzero changed set downgrades "absent" from proof to
//! as-of-snapshot, and the report says so.

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const outcome = @import("../../../cli/outcome.zig");
const Outcome = outcome.Outcome;
const shelf_mod = @import("../../../../corpus/index/shelf/shelf.zig");
const assay = @import("../../../../assay/assay.zig");
const Dir = std.Io.Dir;

const shelfFile = shelf_mod.shelfFile;

/// Version of the `--json` machine contracts below; bump on breaking change.
const schema_version = 1;

fn dieUsage() noreturn {
    assay.diag(
        \\usage:
        \\  gist codex build                   build + persist the self-index shelf
        \\  gist codex count <text>  [--json]  exact corpus-wide occurrence count (zero corpus I/O)
        \\  gist codex tally <text>  [--top N] [--json]  per-file counts, heaviest first
        \\  gist codex status        [--json]  is a shelf ready, how big, how fresh
        \\
    , .{});
    std.process.exit(2);
}

/// `gist codex build` — load the index corpus, build the shelf, persist
/// atomically. The anchor is captured BEFORE the corpus read (T3 convention)
/// so a file touched mid-build reports as changed on the next query.
fn runBuild(gpa: std.mem.Allocator, io: std.Io) !void {
    const build_run = assay.Run.open(gpa, io, false);
    const built_ns: i64 = @intCast(assay.anchor(io).ns());
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots, .contiguous);
    defer corpus.deinit();

    const shelf = try shelf_mod.persist(gpa, io, corpus.docs, corpus.paths, built_ns);
    const dur = build_run.elapsed().ms();
    build_run.emit("codex: {d} files · {d:.1} MiB corpus → {d:.1} MiB shelf ({d:.2} bits/char) · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(shelf.bytes)) / (1 << 20),
        shelf.bits_per_char,
        dur,
        shelfFile(),
    }, .{
        .{ "artifact", "s", "codex" },
        .{ "files", "d", corpus.docs.len },
        .{ "corpus_mib", "d:.1", @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20) },
        .{ "shelf_mib", "d:.1", @as(f64, @floatFromInt(shelf.bytes)) / (1 << 20) },
        .{ "bits_per_char", "d:.2", shelf.bits_per_char },
        .{ "ms", "d:.0", dur },
        .{ "path", "s", shelfFile() },
    });
}

/// The shelf, or exit 2 naming this face's build command. `relate quote` and
/// `irregex provenance` read the same artifact and each name their own.
fn openShelf(gpa: std.mem.Allocator, io: std.Io) shelf_mod.Shelf {
    return shelf_mod.open(gpa, io) catch |e|
        outcome.needArtifact(e, "codex shelf", shelfFile(), "`gist codex build`");
}

const Report = struct {
    schema_version: u8 = schema_version,
    pattern: []const u8,
    count: usize,
    files: usize,
    stale_files: usize,
    built_unix_ns: i64,
};

/// `count`/`tally` share one collection pass; `top == 0` skips locate entirely
/// (count never touches the samples — pure backward search).
fn runQuery(gpa: std.mem.Allocator, io: std.Io, pattern: []const u8, top: ?usize, json: bool) !void {
    var shelf = openShelf(gpa, io);
    defer shelf.deinit(gpa);
    const total = shelf.count(pattern);
    const stale = shelf_mod.staleCount(gpa, io, shelf.built_ns);

    var tallies: []shelf_mod.DocCount = &.{};
    defer gpa.free(tallies);
    // A mark-less shelf still counts; it just cannot say which file. Leaving
    // `tallies` empty reports zero files rather than aborting the count.
    if (top != null and total > 0) switch (try shelf.tally(gpa, pattern)) {
        .declined => {},
        .got => |t| tallies = t,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (json) {
        const report = Report{
            .pattern = pattern,
            .count = total,
            .files = tallies.len,
            .stale_files = stale,
            .built_unix_ns = shelf.built_ns,
        };
        const body = try std.json.Stringify.valueAlloc(gpa, report, .{});
        defer gpa.free(body);
        // count: one report object; tally: NDJSON — report line then one per file
        try out.print(gpa, "{s}\n", .{body});
        if (top != null) for (tallies[0..@min(tallies.len, top.?)]) |dc| {
            const row = try std.json.Stringify.valueAlloc(gpa, .{ .path = shelf.paths[dc.doc], .count = dc.count }, .{});
            defer gpa.free(row);
            try out.print(gpa, "{s}\n", .{row});
        };
    } else {
        try out.print(gpa, "{d}\n", .{total});
        for (tallies[0..@min(tallies.len, top orelse 0)]) |dc|
            try out.print(gpa, "{d}\t{s}\n", .{ dc.count, shelf.paths[dc.doc] });
    }
    corpus_mod.emitStdout(out.items);
    if (stale > 0)
        assay.diag("codex: {d} file(s) changed since the shelf was built — exact as of the anchor; `gist codex build` refreshes\n", .{stale});
    (Outcome{ .matched = total > 0 }).exit();
}

const Status = struct {
    schema_version: u8 = schema_version,
    state: enum { ready, unavailable },
    shelf_bytes: u64,
    files: usize,
    corpus_bytes: usize,
    bits_per_char: f64,
    stale_files: usize,
    built_unix_ns: i64,
};

fn runStatus(gpa: std.mem.Allocator, io: std.Io, json: bool) !void {
    const stat = Dir.cwd().statFile(io, shelfFile(), .{}) catch {
        if (json) {
            corpus_mod.emitStdout("{\"schema_version\":1,\"state\":\"unavailable\"}\n");
        } else {
            assay.diag("no codex shelf at {s} — run `gist codex build` first\n", .{shelfFile()});
        }
        std.process.exit(1);
    };
    var shelf = openShelf(gpa, io);
    defer shelf.deinit(gpa);
    const st = Status{
        .state = .ready,
        .shelf_bytes = @intCast(stat.size),
        .files = shelf.paths.len,
        .corpus_bytes = shelf.cx.len(),
        .bits_per_char = shelf.cx.stats.bitsPerChar(),
        .stale_files = shelf_mod.staleCount(gpa, io, shelf.built_ns),
        .built_unix_ns = shelf.built_ns,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (json) {
        const body = try std.json.Stringify.valueAlloc(gpa, st, .{});
        defer gpa.free(body);
        try out.print(gpa, "{s}\n", .{body});
    } else {
        try out.print(gpa,
            \\gist codex — {s}
            \\  files indexed  {d}
            \\  corpus         {d:.1} MiB held at {d:.2} bits/char ({d:.1} MiB shelf)
            \\  changed since  {d} file(s)
            \\
        , .{
            shelfFile(),
            st.files,
            @as(f64, @floatFromInt(st.corpus_bytes)) / (1 << 20),
            st.bits_per_char,
            @as(f64, @floatFromInt(st.shelf_bytes)) / (1 << 20),
            st.stale_files,
        });
    }
    corpus_mod.emitStdout(out.items);
}

/// Dispatch `gist codex <verb> …` (argv excludes the `codex` token itself).
pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    if (argv.len == 0) dieUsage();
    const verb = std.meta.stringToEnum(enum { build, status, count, tally }, argv[0]) orelse dieUsage();
    var json = false;
    var top: ?usize = null;
    var pattern: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) dieUsage();
            top = std.fmt.parseInt(usize, argv[i], 10) catch dieUsage();
        } else if (pattern == null) {
            pattern = arg;
        } else dieUsage();
    }

    switch (verb) {
        .build => {
            if (pattern != null or json or top != null) dieUsage();
            return runBuild(gpa, io);
        },
        .status => {
            if (pattern != null or top != null) dieUsage();
            return runStatus(gpa, io, json);
        },
        .count => {
            if (top != null) dieUsage();
            return runQuery(gpa, io, pattern orelse dieUsage(), null, json);
        },
        .tally => return runQuery(gpa, io, pattern orelse dieUsage(), top orelse 20, json),
    }
}
