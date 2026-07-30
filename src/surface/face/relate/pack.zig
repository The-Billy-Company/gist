//! relate — the `pack` verb: the reading set for a task, priced in bits.
//!
//!   relate pack <text> [--matching PAT]... [--match any|all] [-F] [-i]
//!                      [--min-grade G] [--top N] [--json] [ROOT...]
//!       the SET of files that jointly explains <text> best — greedy graded
//!       coverage over corpus-priced query aspects, each pick scored by the
//!       bits it adds BEYOND what the picks before it already explained, and
//!       named for the aspects it is there for.
//!
//! Why this is a different question from ranking: any top-K retriever
//! (embeddings included) ranks documents independently, so near-duplicate
//! files all rank high and the caller pays for the same information K times.
//! An agent assembling context wants marginal novelty, not K copies of the
//! best answer. Coverage over priced aspects is submodular — the marginal gain
//! of a doc can only shrink as the picked set grows — so the classic greedy
//! sweep (Nemhauser–Wolsey–Fisher 1978) is within (1−1/e) of the optimal set.
//! Exact, model-free, deterministic.
//!
//! **What "explains" means, and why it is graded.** The first version covered
//! an aspect the moment a document contained its literal, which made pack
//! degenerate at the query lengths agents type: a six-word query has ~5 priced
//! aspects, so the first file mentioning all six reported 100% coverage from
//! one pick and the submodular machinery never engaged — and "mentions the
//! word" is not "explains the thing", so a changelog that name-dropped every
//! term beat the module the query was about. Coverage is now the saturating
//! density of Lin & Bilmes' facility-location objective (ACL 2011) over BM25's
//! length-normalized term frequency: a file that merely mentions an aspect
//! leaves most of its bits for a later pick that is really about it. Full
//! derivation in `kernel/kinship/recall/coverage.zig`.
//!
//! **A score is not an answer** — the property `similar` had and this verb did
//! not. Coverage is graded on the `context` channel's calibrated bands, the
//! answer's grade is the PACK's (a reading set is one answer, not N
//! independent rows), `--min-grade` withholds a pack made of background, and a
//! thin pack explains itself on stderr in gist's hint grammar. Every pick also
//! names the aspects that account for its gain, which is the justification a
//! bits number alone cannot give.
//!
//! `--matching PAT` prices novelty inside the exact filter instead of over the
//! whole corpus: the patterns select the candidate docs, aspects are priced
//! from ONLY those, and each pick carries the patterns that admitted it. This
//! is what `irregex context` was — a verb for a modifier, which meant the
//! composed shape could not be combined with anything else pack learned.
//! Whole-corpus packing surfaces whatever the corpus finds cheap regardless of
//! intent; narrowing first makes "the reading set among files that actually
//! mention X" a single query (ADR-367). The two scores stay in separate
//! columns — the admitting patterns and the compression bits — and are never
//! fused into one relevance number.
//!
//! The score story stays honest: `coverage` is the fraction of the query's
//! PRICED description the picks jointly hold. Aspects no document contains are
//! `foreign` and aspects every document contains are `glue`; both price at zero
//! for opposite reasons, are reported separately, and never pad the
//! denominator so coverage can only be a fraction of what the corpus could
//! actually pay.
//!
//! Corpus policy: the index corpus. Nomination reuses Gist's mmap-backed
//! trigram codebook and shared freshness fold, then reads a bounded pool
//! because only bytes distinguish mention from subject; a missing index falls
//! back to the live corpus scan. Results stdout, diagnostics stderr.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const assay = @import("../../../assay/assay.zig");
const coverage = @import("../../../kernel/kinship/recall/coverage.zig");
const compose = @import("../../../kernel/compose/context.zig");
const retrieval = @import("../../../exec/retrieval/retrieval.zig");
const options = @import("options.zig");
const units = @import("units.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");
const grade = @import("../../cli/grade.zig");

const die = @import("../../cli/outcome.zig").die;
const oom = @import("../../cli/outcome.zig").oom;

const usage = "usage: relate pack <text> [--matching PAT]... [--match any|all] [-F] [-i] [--min-grade G] [--top N] [--json] [ROOT...]\n";

pub fn runPack(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: options.Opts = .{ .top = 8 };
    defer o.deinit(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try options.parse(gpa, argv, &o, &roots, .{
        .min_grade = true,
        .matching = true,
        .positional = true,
    });
    const query = o.arg orelse die(usage, .{});
    if (query.len == 0) die("relate pack: empty query\n", .{});

    var run = assay.Run.open(gpa, io, o.json);
    if (o.narrow()) |narrow| return narrowed(gpa, io, &o, roots.items, narrow, query, &run);
    if (try warm(gpa, io, &o, roots.items, query, &run)) return;
    try live(gpa, io, &o, roots.items, query, &run);
}

// ── the answer, one shape for all three rungs ──

/// What a rung measured, ready to render. Keeping this separate from the three
/// lanes is what makes the rungs interchangeable: a `--json` consumer never has
/// to know whether the index, the live scan, or an exact filter answered.
const Answer = struct {
    aspects: []const coverage.Aspect,
    total_bits: f64,
    foreign: usize,
    glue: usize,
    /// Cumulative coverage after the last pick — the whole answer's score.
    covered: f64 = 0.0,
    picks: usize = 0,
};

/// One pick, one row shape. `explains` is the aspect mask the kernel
/// attributed this pick's gain to; `pats` is empty unless an exact filter ran.
fn pick(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    o: *const options.Opts,
    answer: *const Answer,
    rank: usize,
    path: []const u8,
    marginal_bits: f64,
    solo: f64,
    covered: f64,
    explains: u64,
    pats: []const []const u8,
) void {
    if (!o.json) {
        buf.print(gpa, "+{d:.1} bits  {d:.2}  {s}", .{ marginal_bits, covered, emit.anchor(gpa, path) }) catch oom();
        var first = true;
        for (answer.aspects, 0..) |aspect, a| {
            if (explains & (@as(u64, 1) << @intCast(a)) == 0) continue;
            buf.appendSlice(gpa, if (first) "  " else " · ") catch oom();
            buf.appendSlice(gpa, aspect.term) catch oom();
            first = false;
        }
        if (pats.len > 0) {
            buf.appendSlice(gpa, "  [") catch oom();
            for (pats, 0..) |p, k| {
                if (k != 0) buf.appendSlice(gpa, ", ") catch oom();
                buf.appendSlice(gpa, p) catch oom();
            }
            buf.append(gpa, ']') catch oom();
        }
        buf.append(gpa, '\n') catch oom();
        return;
    }
    buf.print(gpa, "{{\"rank\":{d},\"path\":", .{rank}) catch oom();
    emit.jsonStr(buf, gpa, path);
    buf.print(gpa, ",\"marginal_bits\":{d:.1},\"coverage\":{d:.4},\"solo_coverage\":{d:.4},\"explains\":[", .{
        marginal_bits, covered, solo,
    }) catch oom();
    var first = true;
    for (answer.aspects, 0..) |aspect, a| {
        if (explains & (@as(u64, 1) << @intCast(a)) == 0) continue;
        if (!first) buf.append(gpa, ',') catch oom();
        emit.jsonStr(buf, gpa, aspect.term);
        first = false;
    }
    buf.append(gpa, ']') catch oom();
    if (pats.len > 0) {
        buf.appendSlice(gpa, ",\"patterns\":[") catch oom();
        for (pats, 0..) |p, k| {
            if (k != 0) buf.append(gpa, ',') catch oom();
            emit.jsonStr(buf, gpa, p);
        }
        buf.append(gpa, ']') catch oom();
    }
    buf.appendSlice(gpa, "}\n") catch oom();
}

/// The fraction of the query's priced description a pick's own bits amount to.
fn share(bits: f64, total_bits: f64) f64 {
    return if (total_bits > 0.0) bits / total_bits else 0.0;
}

/// Withhold the whole pack when its coverage does not meet `--min-grade`. A
/// reading set is ONE answer: emitting its strongest half under a floor the
/// answer failed would be the same laundering the floor exists to prevent.
fn withheld(o: *const options.Opts, covered: f64, picks: usize) bool {
    const floor = o.min_grade orelse return false;
    return picks > 0 and !grade.of(.context, covered).meets(floor);
}

/// The verdict every rung settles with: the pack's own coverage is the score,
/// so `best` is the answer's grade rather than any one row's.
fn settle(o: *const options.Opts, answer: *const Answer, scored: usize, scoped: bool, narrow: bool, query: []const u8) void {
    var v: grade.Verdict = .{
        .channel = .context,
        .scored = scored,
        .floor = o.min_grade,
        .scoped = scoped,
        .narrowed = narrow,
    };
    if (answer.picks > 0) v.best = answer.covered;
    if (withheld(o, answer.covered, answer.picks))
        v.withheld = answer.picks
    else
        v.shown = answer.picks;
    grade.report("relate", query, v);
    grade.settle(v);
}

// ── the narrowed rung: pack inside the exact filter ──

fn narrowed(
    gpa: std.mem.Allocator,
    io: std.Io,
    o: *const options.Opts,
    roots: []const []const u8,
    narrow: units.Narrow,
    query: []const u8,
    run: *assay.Run,
) !void {
    var exact = try units.Narrowed.open(gpa, io, roots, narrow);
    defer exact.deinit();
    const load_dur = run.lap();

    const terms = try coverage.decompose(gpa, query);
    defer gpa.free(terms);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var answer: Answer = .{ .aspects = &.{}, .total_bits = 0.0, .foreign = 0, .glue = 0 };

    // No candidate, no pack: an empty answer is the honest one, and pricing
    // aspects over zero docs would call every one of them foreign.
    var found: ?compose.Packed = if (exact.admitted() > 0)
        try compose.pack(gpa, exact.corpus.docs, exact.corpus.paths, &exact.cset, terms, o.top)
    else
        null;
    defer if (found) |*f| f.deinit();

    if (found) |*f| {
        answer = .{
            .aspects = f.aspects,
            .total_bits = f.total_bits,
            .foreign = f.foreign,
            .glue = f.glue,
            .covered = if (f.picks.len > 0) f.picks[f.picks.len - 1].coverage else 0.0,
            .picks = f.picks.len,
        };
        if (!withheld(o, answer.covered, answer.picks)) for (f.picks, 1..) |p, rank| {
            var by = units.decode(gpa, narrow.patterns, p.mask);
            defer by.deinit();
            pick(&buf, gpa, o, &answer, rank, exact.corpus.paths[p.doc], p.marginal_bits, share(p.marginal_bits, f.total_bits), p.coverage, p.owns, by.items);
        };
    }
    corpus_mod.emitStdout(buf.items);

    const dur = run.elapsed().ms();
    run.emit("pack: {d} file(s) · {d} candidate(s) [{s}] · {d} pick(s) explain {d:.1}% of {d:.1} priced bits · {d} glue · {d} foreign aspect(s) · load {d:.0} ms · pack {d:.0} ms\n", .{
        exact.corpus.docs.len,  exact.admitted(),    @tagName(narrow.match), answer.picks,
        answer.covered * 100.0, answer.total_bits,   answer.glue,            answer.foreign,
        load_dur.ms(),          dur - load_dur.ms(),
    }, .{
        .{ "verb", "s", "pack" },
        .{ "files", "d", exact.corpus.docs.len },
        .{ "candidates", "d", exact.admitted() },
        .{ "match", "s", @tagName(narrow.match) },
        .{ "picks", "d", answer.picks },
        .{ "coverage", "d:.4", answer.covered },
        .{ "priced_bits", "d:.1", answer.total_bits },
        .{ "glue", "d", answer.glue },
        .{ "foreign", "d", answer.foreign },
        .{ "load_ms", "d:.0", load_dur.ms() },
        .{ "ms", "d:.0", dur },
    });
    settle(o, &answer, exact.admitted(), roots.len > 0, true, query);
}

// ── the warm rung: the persisted trigram codebook + a bounded read pool ──

fn warm(
    gpa: std.mem.Allocator,
    io: std.Io,
    o: *const options.Opts,
    roots: []const []const u8,
    query: []const u8,
    run: *assay.Run,
) !bool {
    var indexed = try retrieval.pack(gpa, io, query, roots, o.top, .load) orelse return false;
    defer indexed.deinit();

    var answer: Answer = .{
        .aspects = indexed.aspects,
        .total_bits = indexed.total_bits,
        .foreign = indexed.foreign,
        .glue = indexed.glue,
        .covered = if (indexed.picks.len > 0) share(indexed.picks[indexed.picks.len - 1].covered_bits, indexed.total_bits) else 0.0,
        .picks = indexed.picks.len,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (!withheld(o, answer.covered, answer.picks)) for (indexed.picks, 1..) |p, rank| {
        pick(&buf, gpa, o, &answer, rank, p.path, p.marginal_bits, share(p.solo_bits, indexed.total_bits), share(p.covered_bits, indexed.total_bits), p.owns, &.{});
    };
    corpus_mod.emitStdout(buf.items);

    const dur = run.elapsed().ms();
    run.emit("pack: {d} files indexed · {d} candidate(s) · {d} read · {d} refreshed · {d} pick(s) explain {d:.1}% of {d:.1} priced bits · {d} glue · {d} foreign aspect(s) · {d:.0} ms\n", .{
        indexed.indexed_files, indexed.candidates,     indexed.pool,      indexed.refreshed,
        answer.picks,          answer.covered * 100.0, answer.total_bits, answer.glue,
        answer.foreign,        dur,
    }, .{
        .{ "verb", "s", "pack" },
        .{ "indexed_files", "d", indexed.indexed_files },
        .{ "candidates", "d", indexed.candidates },
        .{ "pool", "d", indexed.pool },
        .{ "refreshed", "d", indexed.refreshed },
        .{ "picks", "d", answer.picks },
        .{ "coverage", "d:.4", answer.covered },
        .{ "priced_bits", "d:.1", answer.total_bits },
        .{ "glue", "d", answer.glue },
        .{ "foreign", "d", answer.foreign },
        .{ "ms", "d:.0", dur },
    });
    settle(o, &answer, indexed.candidates, roots.len > 0, false, query);
    return true;
}

// ── the live rung: price and grade the whole corpus for this invocation ──

fn live(
    gpa: std.mem.Allocator,
    io: std.Io,
    o: *const options.Opts,
    roots: []const []const u8,
    query: []const u8,
    run: *assay.Run,
) !void {
    const terms = try coverage.decompose(gpa, query);
    defer gpa.free(terms);
    if (terms.len == 0)
        die("relate pack: query shorter than the term floor ({d} bytes) and no persisted trigram index is available\n", .{coverage.min_term});

    const rr = try flags.rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items, .contiguous);
    defer corpus.deinit();

    // One pass yields both the document frequency that prices each aspect and
    // the term frequency that grades every doc on it — so this rung never
    // builds a fingerprint lexicon it would only use for pricing.
    var table = try coverage.measure(gpa, terms, corpus.docs);
    defer table.deinit();
    const index_dur = run.lap();

    const total_bits = coverage.pricedBits(table.aspects);
    const picks = try coverage.greedy(gpa, table.aspects, table.candidates, corpus.paths, o.top, compose.minGain(total_bits));
    defer gpa.free(picks);

    var answer: Answer = .{
        .aspects = table.aspects,
        .total_bits = total_bits,
        .foreign = table.count(.foreign),
        .glue = table.count(.glue),
        .covered = if (picks.len > 0) share(picks[picks.len - 1].covered_bits, total_bits) else 0.0,
        .picks = picks.len,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (!withheld(o, answer.covered, answer.picks)) for (picks, 1..) |p, rank| {
        pick(&buf, gpa, o, &answer, rank, corpus.paths[p.doc], p.marginal_bits, share(p.solo_bits, total_bits), share(p.covered_bits, total_bits), p.owns, &.{});
    };
    corpus_mod.emitStdout(buf.items);

    const pack_dur = run.elapsed().ms();
    run.emit("pack: {d} files scanned · {d} pick(s) explain {d:.1}% of {d:.1} priced bits · {d} glue · {d} foreign aspect(s) · measure {d:.0} ms · pack {d:.0} ms\n", .{
        corpus.docs.len, answer.picks,   answer.covered * 100.0, answer.total_bits,
        answer.glue,     answer.foreign, index_dur.ms(),         pack_dur - index_dur.ms(),
    }, .{
        .{ "verb", "s", "pack" },
        .{ "scanned_files", "d", corpus.docs.len },
        .{ "picks", "d", answer.picks },
        .{ "coverage", "d:.4", answer.covered },
        .{ "priced_bits", "d:.1", answer.total_bits },
        .{ "glue", "d", answer.glue },
        .{ "foreign", "d", answer.foreign },
        .{ "measure_ms", "d:.0", index_dur.ms() },
        .{ "pack_ms", "d:.0", pack_dur },
    });
    settle(o, &answer, corpus.docs.len, roots.len > 0, false, query);
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "a pick names the aspects it is there for, and the patterns that admitted it" {
    const gpa = t.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const o = options.Opts{ .top = 8 };
    const aspects = [_]coverage.Aspect{
        .{ .term = "freshness", .bits = 9.0, .df = 40, .kind = .priced },
        .{ .term = "mtime", .bits = 11.0, .df = 10, .kind = .priced },
    };
    const answer: Answer = .{ .aspects = &aspects, .total_bits = 20.0, .foreign = 0, .glue = 0 };

    pick(&buf, gpa, &o, &answer, 1, "fresh.zig", 12.5, 0.62, 0.62, 0b11, &.{});
    try t.expectEqualStrings("+12.5 bits  0.62  fresh.zig  freshness · mtime\n", buf.items);

    // The exact evidence is its own column and never folded into the bits.
    buf.clearRetainingCapacity();
    pick(&buf, gpa, &o, &answer, 2, "persist.zig", 3.0, 0.15, 0.77, 0b10, &.{ "grant", "wallet" });
    try t.expectEqualStrings("+3.0 bits  0.77  persist.zig  mtime  [grant, wallet]\n", buf.items);

    // A pick attributed to no single aspect still renders — its gain was spread
    // too thin for any one term to claim it, which is itself information.
    buf.clearRetainingCapacity();
    pick(&buf, gpa, &o, &answer, 3, "spread.zig", 1.0, 0.05, 0.82, 0, &.{});
    try t.expectEqualStrings("+1.0 bits  0.82  spread.zig\n", buf.items);
}

test "the JSON row carries the aspects and the patterns as separate arrays" {
    const gpa = t.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var js = options.Opts{ .top = 8 };
    js.json = true;
    const aspects = [_]coverage.Aspect{.{ .term = "freshness", .bits = 9.0, .df = 40, .kind = .priced }};
    const answer: Answer = .{ .aspects = &aspects, .total_bits = 9.0, .foreign = 0, .glue = 0 };

    pick(&buf, gpa, &js, &answer, 2, "b.zig", 3.0, 0.33, 0.75, 0b1, &.{"grant"});
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, buf.items, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 2), parsed.value.object.get("rank").?.integer);
    try t.expectEqualStrings("freshness", parsed.value.object.get("explains").?.array.items[0].string);
    try t.expectEqualStrings("grant", parsed.value.object.get("patterns").?.array.items[0].string);
}

test "share never divides by a total the corpus could not pay" {
    try t.expectEqual(@as(f64, 0.0), share(12.0, 0.0));
    try t.expectApproxEqAbs(@as(f64, 0.75), share(30.0, 40.0), 1e-9);
}

test "--min-grade withholds the whole pack, not its weakest rows" {
    // A reading set is ONE answer: emitting the strongest half of a pack that
    // failed the floor is the laundering the floor exists to prevent.
    var floored = options.Opts{ .top = 8 };
    floored.min_grade = .strong;
    try t.expect(withheld(&floored, 0.30, 3));
    try t.expect(!withheld(&floored, 0.72, 3));
    // Nothing to withhold when nothing was packed.
    try t.expect(!withheld(&floored, 0.0, 0));
    // No floor, no withholding.
    const bare = options.Opts{ .top = 8 };
    try t.expect(!withheld(&bare, 0.01, 3));
}
