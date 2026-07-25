//! relate — the `pack` verb: anti-redundant context packing.
//!
//!   relate pack <text> [--matching PAT]... [--match any|all] [-F] [-i]
//!                      [--top N] [--json] [ROOT...]
//!       the SET of files that jointly describes <text> cheapest — greedy
//!       max-coverage over corpus-priced query chunks, each pick scored by
//!       the bits it adds BEYOND what the picks before it already covered.
//!
//! Why this is a different question from ranking: any top-K retriever
//! (embeddings included) ranks documents independently, so near-duplicate
//! files all rank high and the caller pays for the same information K times.
//! An agent assembling context wants marginal novelty, not K copies of the
//! best answer. Coverage over priced fingerprints is submodular — the
//! marginal gain of a doc can only shrink as the picked set grows — so the
//! classic greedy sweep (Nemhauser–Wolsey–Fisher 1978) is within (1−1/e) of
//! the optimal set, and the lazy-greedy evaluation order (Minoux 1978) skips
//! docs whose stale bound already loses to the current best. Exact, model-
//! free, deterministic; the same persisted trigram-codebook pricing lane
//! `similar`'s recall channel rides (query chunks price at −log2(df/N) bits).
//!
//! `--matching PAT` prices novelty inside the exact filter instead of over the
//! whole corpus: the patterns select the candidate docs, the lexicon is built
//! from ONLY those, and each pick carries the patterns that admitted it. This
//! is what `irregex context` was — a verb for a modifier, which meant the
//! composed shape could not be combined with anything else pack learned.
//! Whole-corpus packing surfaces the near-duplicate high-coverage file
//! regardless of intent; narrowing first makes "the reading set among files
//! that actually mention X" a single query (ADR-367). The two scores stay in
//! separate columns — the admitting patterns and the marginal bits — and are
//! never fused into one relevance number.
//!
//! The score story stays honest: `coverage` is the fraction of the query's
//! PRICED description the picks jointly hold — fingerprints the corpus has
//! never seen carry zero price (nothing could cover them) and are reported
//! separately as `foreign`. A pick's `marginal_bits` is exactly the priced
//! bits it added; picking stops at `--top` files or when nothing adds bits.
//!
//! Corpus policy: the index corpus. Nomination reuses Gist's mmap-backed
//! trigram codebook and shared freshness fold; a missing index falls back to
//! the live fingerprint oracle. Results stdout, diagnostics stderr.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const lexicon = @import("../../../kernel/kinship/recall/lexicon.zig");
const coverage = @import("../../../kernel/kinship/recall/coverage.zig");
const compose = @import("../../../kernel/compose/context.zig");
const retrieval = @import("../../exec/cold/engine/retrieval.zig");
const options = @import("options.zig");
const units = @import("units.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");

const die = cli_args.die;
const oom = cli_args.oom;

const usage = "usage: relate pack <text> [--matching PAT]... [--match any|all] [-F] [-i] [--top N] [--json] [ROOT...]\n";

pub fn runPack(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: options.Opts = .{ .top = 8 };
    defer o.deinit(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try options.parse(gpa, argv, &o, &roots, .{ .matching = true, .positional = true });
    const query = o.arg orelse die(usage, .{});
    if (query.len == 0) die("relate pack: empty query\n", .{});

    var run = assay.Run.open(gpa, io, o.json);
    if (o.narrow()) |narrow| return narrowed(gpa, io, &o, roots.items, narrow, query, &run);
    if (try warm(gpa, io, &o, roots.items, query, &run)) return;
    try live(gpa, io, &o, roots.items, query, &run);
}

/// One pick, three rungs, one row shape — so a `--json` consumer never has to
/// know which lane answered. `pats` is empty unless an exact filter ran.
fn pick(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    o: *const options.Opts,
    rank: usize,
    path: []const u8,
    marginal_bits: f64,
    covered: f64,
    pats: []const []const u8,
) void {
    if (pats.len == 0) {
        emit.emitRow(buf, gpa, o.json, .{
            .{ "rank", "d", rank },
            .{ "path", "s", path },
            .{ "marginal_bits", "d:.1", marginal_bits },
            .{ "coverage", "d:.4", covered },
        }, "+{d:.1} bits  {d:.4}  {s}\n", .{ marginal_bits, covered, path });
        return;
    }
    if (o.json) {
        buf.print(gpa, "{{\"rank\":{d},\"path\":", .{rank}) catch oom();
        emit.jsonStr(buf, gpa, path);
        buf.print(gpa, ",\"marginal_bits\":{d:.1},\"coverage\":{d:.4},\"patterns\":[", .{ marginal_bits, covered }) catch oom();
        for (pats, 0..) |p, k| {
            if (k != 0) buf.append(gpa, ',') catch oom();
            emit.jsonStr(buf, gpa, p);
        }
        buf.appendSlice(gpa, "]}\n") catch oom();
        return;
    }
    buf.print(gpa, "+{d:.1} bits  {d:.4}  {s}  [", .{ marginal_bits, covered, path }) catch oom();
    for (pats, 0..) |p, k| {
        if (k != 0) buf.appendSlice(gpa, ", ") catch oom();
        buf.appendSlice(gpa, p) catch oom();
    }
    buf.appendSlice(gpa, "]\n") catch oom();
}

/// The percentage of priced query bits the last pick had cumulatively covered.
fn coveredPct(covered_bits: f64, total_bits: f64, any: bool) f64 {
    return if (any and total_bits > 0.0) covered_bits / total_bits * 100.0 else 0.0;
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var picks: usize = 0;
    var total_bits: f64 = 0.0;
    var foreign: usize = 0;
    var covered: f64 = 0.0;

    // No candidate, no pack: an empty answer is the honest one, and building a
    // lexicon over zero docs would price every fingerprint as foreign.
    if (exact.admitted() > 0) {
        var found = try compose.pack(gpa, exact.corpus.docs, exact.corpus.paths, &exact.cset, query, o.top);
        defer found.deinit();
        total_bits = found.total_bits;
        foreign = found.foreign;
        picks = found.picks.len;
        for (found.picks, 1..) |p, rank| {
            var by = units.decode(gpa, narrow.patterns, p.mask);
            defer by.deinit();
            covered = p.coverage;
            pick(&buf, gpa, o, rank, exact.corpus.paths[p.doc], p.marginal_bits, p.coverage, by.items);
        }
    }
    corpus_mod.emitStdout(buf.items);

    const dur = run.elapsed().ms();
    run.emit("pack: {d} file(s) · {d} candidate(s) [{s}] · {d} pick(s) cover {d:.1}% of {d:.1} priced bits · {d} foreign chunk(s) · load {d:.0} ms · pack {d:.0} ms\n", .{
        exact.corpus.docs.len, exact.admitted(), @tagName(narrow.match), picks,
        covered * 100.0,       total_bits,       foreign,                load_dur.ms(),
        dur - load_dur.ms(),
    }, .{
        .{ "verb", "s", "pack" },
        .{ "files", "d", exact.corpus.docs.len },
        .{ "candidates", "d", exact.admitted() },
        .{ "match", "s", @tagName(narrow.match) },
        .{ "picks", "d", picks },
        .{ "coverage_pct", "d:.1", covered * 100.0 },
        .{ "priced_bits", "d:.1", total_bits },
        .{ "foreign", "d", foreign },
        .{ "load_ms", "d:.0", load_dur.ms() },
        .{ "ms", "d:.0", dur },
    });
}

// ── the warm rung: the persisted trigram codebook ──

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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (indexed.picks, 1..) |p, rank| {
        const cum = if (indexed.total_bits > 0.0) p.covered_bits / indexed.total_bits else 0.0;
        pick(&buf, gpa, o, rank, p.path, p.marginal_bits, cum, &.{});
    }
    corpus_mod.emitStdout(buf.items);

    const pct = coveredPct(
        if (indexed.picks.len > 0) indexed.picks[indexed.picks.len - 1].covered_bits else 0.0,
        indexed.total_bits,
        indexed.picks.len > 0,
    );
    const dur = run.elapsed().ms();
    run.emit("pack: {d} files indexed · {d} candidate(s) · {d} refreshed · {d} pick(s) cover {d:.1}% of {d:.1} priced bits · {d} foreign chunk(s) · {d:.0} ms\n", .{
        indexed.indexed_files, indexed.candidates, indexed.refreshed, indexed.picks.len,
        pct,                   indexed.total_bits, indexed.foreign,   dur,
    }, .{
        .{ "verb", "s", "pack" },
        .{ "indexed_files", "d", indexed.indexed_files },
        .{ "candidates", "d", indexed.candidates },
        .{ "refreshed", "d", indexed.refreshed },
        .{ "picks", "d", indexed.picks.len },
        .{ "coverage_pct", "d:.1", pct },
        .{ "priced_bits", "d:.1", indexed.total_bits },
        .{ "foreign", "d", indexed.foreign },
        .{ "ms", "d:.0", dur },
    });
    return true;
}

// ── the live rung: build the lexicon for this invocation ──

fn live(
    gpa: std.mem.Allocator,
    io: std.Io,
    o: *const options.Opts,
    roots: []const []const u8,
    query: []const u8,
    run: *assay.Run,
) !void {
    if (query.len < lexicon.gram)
        die("relate pack: query shorter than the live fingerprint floor ({d} bytes) and no persisted trigram index is available\n", .{lexicon.gram});

    const rr = try flags.rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items);
    defer corpus.deinit();
    var lex = try lexicon.Lexicon.build(gpa, corpus.docs);
    defer lex.deinit();
    const index_dur = run.lap();

    const qfps = try lexicon.fingerprints(gpa, query);
    defer gpa.free(qfps);

    // The coverable total: priced query bits (df > 0). Foreign fingerprints
    // (df == 0) cannot be covered by anything and are reported, not hidden.
    var total_bits: f64 = 0.0;
    var foreign: usize = 0;
    for (qfps) |fp| {
        const b = lex.fingerprintBits(fp);
        if (b > 0.0) total_bits += b else if (lex.fingerprintFrequency(fp) == 0) foreign += 1;
    }

    const picks = try coverage.greedyPack(gpa, &lex, corpus.paths, qfps, o.top);
    defer gpa.free(picks);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (picks, 1..) |p, rank| {
        const cum = if (total_bits > 0.0) p.covered_bits / total_bits else 0.0;
        pick(&buf, gpa, o, rank, corpus.paths[p.doc], p.marginal_bits, cum, &.{});
    }
    corpus_mod.emitStdout(buf.items);

    const pct = coveredPct(
        if (picks.len > 0) picks[picks.len - 1].covered_bits else 0.0,
        total_bits,
        picks.len > 0,
    );
    const pack_dur = run.elapsed().ms();
    run.emit("pack: {d} files indexed · {d} pick(s) cover {d:.1}% of {d:.1} priced bits · {d} foreign fingerprint(s) · index {d:.0} ms · pack {d:.0} ms\n", .{
        corpus.docs.len, picks.len, pct, total_bits, foreign, index_dur.ms(), pack_dur,
    }, .{
        .{ "verb", "s", "pack" },
        .{ "indexed_files", "d", corpus.docs.len },
        .{ "picks", "d", picks.len },
        .{ "coverage_pct", "d:.1", pct },
        .{ "priced_bits", "d:.1", total_bits },
        .{ "foreign", "d", foreign },
        .{ "index_ms", "d:.0", index_dur.ms() },
        .{ "pack_ms", "d:.0", pack_dur },
    });
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "coverage percent is zero without a pick, never a division by the total" {
    try t.expectEqual(@as(f64, 0.0), coveredPct(0.0, 0.0, false));
    try t.expectEqual(@as(f64, 0.0), coveredPct(12.0, 0.0, true));
    try t.expectApproxEqAbs(@as(f64, 75.0), coveredPct(30.0, 40.0, true), 1e-9);
}

test "a narrowed pick names the patterns that admitted it; an unnarrowed one has no such column" {
    const gpa = t.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const o = options.Opts{ .top = 8 };

    pick(&buf, gpa, &o, 1, "a.zig", 12.5, 0.5, &.{});
    try t.expectEqualStrings("+12.5 bits  0.5000  a.zig\n", buf.items);

    buf.clearRetainingCapacity();
    pick(&buf, gpa, &o, 1, "a.zig", 12.5, 0.5, &.{ "grant", "wallet" });
    try t.expectEqualStrings("+12.5 bits  0.5000  a.zig  [grant, wallet]\n", buf.items);

    // The JSON row carries the exact evidence as its own array — never folded
    // into the compression number beside it.
    buf.clearRetainingCapacity();
    var js = options.Opts{ .top = 8 };
    js.json = true;
    pick(&buf, gpa, &js, 2, "b.zig", 3.0, 0.75, &.{"grant"});
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, buf.items, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("grant", parsed.value.object.get("patterns").?.array.items[0].string);
    try t.expectEqual(@as(i64, 2), parsed.value.object.get("rank").?.integer);
}
