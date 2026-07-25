//! relate — the `similar` verb: what else is like this one thing?
//!
//!   relate similar <path> [--as copies|twins|shapes|any] [--top N]
//!                  [--min-grade G] [--json] [--no-index] [ROOT...]
//!
//! The probe query: one file in hand, rank the corpus by kinship to it. The
//! channel picks what "like" means — `copies` (LZJD over raw bytes, the
//! vocabulary-true default), `shapes` (normalized structure, so renamed twins
//! surface), `twins` (how much MORE shape than vocabulary a pair shares), or
//! `any` (closest in either channel).
//!
//! **A distance is not an answer.** Ranking always returns rows, so a probe
//! with no real kin still prints its five nearest strangers and reads exactly
//! like a hit. Every row therefore carries a calibrated grade
//! (`surface/cli/grade.zig`), `--min-grade` withholds rows that are only
//! background, and a whole answer made of background explains itself on
//! stderr in gist's hint grammar instead of quietly looking like a result.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const kinship = @import("kinship.zig");
const flags = @import("../../cli/flags.zig");
const grade = @import("../../cli/grade.zig");
const emit = @import("../../cli/emit.zig");

const die = cli_args.die;
const oom = cli_args.oom;

const usage_msg = "usage: relate similar <path> [--as copies|twins|shapes|any] [--top N] [--min-grade G] [--json] [--no-index] [ROOT...]\n";

/// One scored neighbor, for the sort.
const Scored = struct {
    score: f64,
    idx: u32,

    /// What the order needs beyond the two rows: the tiebreak paths, and which
    /// polarity "stronger" has on this channel.
    const Order = struct { paths: []const []const u8, gap: bool };

    /// Stronger first, then path — a total order either polarity.
    fn less(ctx: Order, x: Scored, y: Scored) bool {
        if (x.score != y.score) return if (ctx.gap) x.score > y.score else x.score < y.score;
        return std.mem.order(u8, ctx.paths[x.idx], ctx.paths[y.idx]) == .lt;
    }
};

pub fn runSimilar(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 20 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{
        .no_index = true,
        .channel = true,
        .min_grade = true,
        .positional = true,
    });
    const target = o.arg orelse die(usage_msg, .{});

    const run = assay.Run.open(gpa, io, o.json);
    const body = std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(corpus_mod.per_file_cap)) catch |e|
        die("cannot read {s}: {s}\n", .{ target, @errorName(e) });
    defer gpa.free(body);
    var probe_sketch = sketch.build(gpa, body) catch oom();
    var probe_sil: silhouette_mod.Silhouette = if (o.channel != .copies)
        silhouette_mod.build(gpa, body) catch oom()
    else
        .empty;

    var view = try kinship.resolve(gpa, io, roots.items, o.no_index, kinship.wantsOf(o.channel));
    defer view.deinit();

    // Self-exclusion compares canonical shapes: a corpus path under an
    // explicit `.` root arrives `./`-prefixed while the arg may not (or vice
    // versa), and byte equality would leave the target ranked first at 0.0.
    const norm_target = flags.stripDotSlash(target);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (view.sketches, 0..) |*s, d| {
        if (std.mem.eql(u8, flags.stripDotSlash(view.paths[d]), norm_target)) continue; // self
        const ds = if (o.channel == .copies) 0 else silhouette_mod.distance(&probe_sil, &view.silhouettes[d]);
        const value = o.channel.score(sketch.distance(&probe_sketch, s), ds);
        try scored.append(gpa, .{ .score = value, .idx = @intCast(d) });
    }
    const order = Scored.Order{ .paths = view.paths, .gap = o.channel.polarity() == .gap };
    std.mem.sort(Scored, scored.items, order, Scored.less);

    // `similar` ranks rather than admits, so the numeric floor never applies —
    // only an explicit `--min-grade` withholds a row. The strongest score is
    // recorded before withholding, so the verdict can report what was there.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var verdict = grade.Verdict{
        .channel = o.channel,
        .scored = scored.items.len,
        .floor = o.min_grade,
        .scoped = roots.items.len > 0,
    };
    for (scored.items) |sc| {
        if (verdict.shown >= o.top) break;
        if (!view.gate(sc.idx)) continue; // deleted since the atlas anchor
        if (verdict.best == null) verdict.best = sc.score;
        const g = grade.of(o.channel, sc.score);
        if (o.min_grade) |floor| if (!g.meets(floor)) {
            verdict.withheld += 1;
            continue;
        };
        verdict.shown += 1;
        emit.emitRow(&buf, gpa, o.json, .{
            .{ "path", "s", view.paths[sc.idx] },
            .{ "distance", "d:.4", sc.score },
            .{ "grade", "s", g.label() },
            .{ "channel", "s", @tagName(o.channel) },
        }, "{d:.4}  {s}\n", .{ sc.score, view.paths[sc.idx] });
    }
    corpus_mod.emitStdout(buf.items);
    grade.report("relate", target, verdict);

    const dur = run.elapsed().ms();
    run.emit("similar: {d} sketches ({s}{d} refreshed) · as {s} · {d:.0} ms\n", .{
        view.sketches.len, view.provenance(), view.refreshed, @tagName(o.channel), dur,
    }, .{
        .{ "verb", "s", "similar" },
        .{ "sketches", "d", view.sketches.len },
        .{ "source", "s", view.source() },
        .{ "refreshed", "d", view.refreshed },
        .{ "channel", "s", @tagName(o.channel) },
        .{ "metric", "s", o.channel.metric() },
        .{ "ms", "d:.0", dur },
    });
    grade.settle(verdict);
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "Scored.less is a total order in both polarities" {
    const paths = [_][]const u8{ "a", "b" };
    const near = Scored{ .score = 0.10, .idx = 0 };
    const far = Scored{ .score = 0.90, .idx = 1 };
    const by_distance = Scored.Order{ .paths = &paths, .gap = false };
    const by_gap = Scored.Order{ .paths = &paths, .gap = true };
    // A distance channel ranks the smaller score first…
    try t.expect(Scored.less(by_distance, near, far));
    try t.expect(!Scored.less(by_distance, far, near));
    // …a gap channel ranks the larger one first.
    try t.expect(Scored.less(by_gap, far, near));
    // Ties break on path, and nothing is ever less than itself.
    const tie_a = Scored{ .score = 0.5, .idx = 0 };
    const tie_b = Scored{ .score = 0.5, .idx = 1 };
    try t.expect(Scored.less(by_distance, tie_a, tie_b));
    try t.expect(!Scored.less(by_distance, tie_a, tie_a));
}
