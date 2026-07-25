//! relate — the `pack` verb: anti-redundant context packing.
//!
//!   relate pack <text> [--top N] [--json] [ROOT...]
//!       the SET of files that jointly describes <text> cheapest — greedy
//!       max-coverage over corpus-priced query chunks, each pick scored by
//!       the bits it adds BEYOND what the picks before it already covered.
//!
//! Why this is a different question from `search`: any top-K retriever
//! (embeddings included) ranks documents independently, so near-duplicate
//! files all rank high and the caller pays for the same information K times.
//! An agent assembling context wants marginal novelty, not K copies of the
//! best answer. Coverage over priced fingerprints is submodular — the
//! marginal gain of a doc can only shrink as the picked set grows — so the
//! classic greedy sweep (Nemhauser–Wolsey–Fisher 1978) is within (1−1/e) of
//! the optimal set, and the lazy-greedy evaluation order (Minoux 1978) skips
//! docs whose stale bound already loses to the current best. Exact, model-
//! free, deterministic; the same persisted trigram-codebook pricing lane
//! `search` rides (query chunks price at −log2(df/N) bits).
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
const retrieval = @import("../../exec/cold/engine/retrieval.zig");
const kinship = @import("kinship.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");

const die = cli_args.die;

pub fn runPack(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 8 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{ .positional = true });
    const query = o.arg orelse die("usage: relate pack <text> [--top N] [--json] [ROOT...]\n", .{});
    if (query.len == 0) die("relate pack: empty query\n", .{});

    var run = assay.Run.open(gpa, io, o.json);
    if (try retrieval.pack(gpa, io, query, roots.items, o.top, .load)) |indexed_value| {
        var indexed = indexed_value;
        defer indexed.deinit();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        for (indexed.picks, 1..) |pick, rank| {
            const cumulative = if (indexed.total_bits > 0.0) pick.covered_bits / indexed.total_bits else 0.0;
            emit.emitRow(&buf, gpa, o.json, .{
                .{ "rank", "d", rank },
                .{ "path", "s", pick.path },
                .{ "marginal_bits", "d:.1", pick.marginal_bits },
                .{ "coverage", "d:.4", cumulative },
            }, "+{d:.1} bits  {d:.4}  {s}\n", .{ pick.marginal_bits, cumulative, pick.path });
        }
        corpus_mod.emitStdout(buf.items);
        const covered_pct = if (indexed.picks.len > 0 and indexed.total_bits > 0.0)
            indexed.picks[indexed.picks.len - 1].covered_bits / indexed.total_bits * 100.0
        else
            0.0;
        const dur = run.elapsed().ms();
        run.emit("pack: {d} files indexed · {d} candidate(s) · {d} refreshed · {d} pick(s) cover {d:.1}% of {d:.1} priced bits · {d} foreign chunk(s) · {d:.0} ms\n", .{
            indexed.indexed_files,
            indexed.candidates,
            indexed.refreshed,
            indexed.picks.len,
            covered_pct,
            indexed.total_bits,
            indexed.foreign,
            dur,
        }, .{
            .{ "verb", "s", "pack" },
            .{ "indexed_files", "d", indexed.indexed_files },
            .{ "candidates", "d", indexed.candidates },
            .{ "refreshed", "d", indexed.refreshed },
            .{ "picks", "d", indexed.picks.len },
            .{ "coverage_pct", "d:.1", covered_pct },
            .{ "priced_bits", "d:.1", indexed.total_bits },
            .{ "foreign", "d", indexed.foreign },
            .{ "ms", "d:.0", dur },
        });
        return;
    }
    if (query.len < lexicon.gram)
        die("relate pack: query shorter than the live fingerprint floor ({d} bytes) and no persisted trigram index is available\n", .{lexicon.gram});

    const rr = try flags.rootsOf(gpa, roots.items);
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
        emit.emitRow(&buf, gpa, o.json, .{
            .{ "rank", "d", rank },
            .{ "path", "s", corpus.paths[p.doc] },
            .{ "marginal_bits", "d:.1", p.marginal_bits },
            .{ "coverage", "d:.4", cum },
        }, "+{d:.1} bits  {d:.4}  {s}\n", .{ p.marginal_bits, cum, corpus.paths[p.doc] });
    }
    corpus_mod.emitStdout(buf.items);
    const covered_pct = if (picks.len > 0 and total_bits > 0.0) picks[picks.len - 1].covered_bits / total_bits * 100.0 else 0.0;
    const pack_dur = run.elapsed().ms();
    run.emit("pack: {d} files indexed · {d} pick(s) cover {d:.1}% of {d:.1} priced bits · {d} foreign fingerprint(s) · index {d:.0} ms · pack {d:.0} ms\n", .{
        corpus.docs.len, picks.len, covered_pct, total_bits, foreign, index_dur.ms(), pack_dur,
    }, .{
        .{ "verb", "s", "pack" },
        .{ "indexed_files", "d", corpus.docs.len },
        .{ "picks", "d", picks.len },
        .{ "coverage_pct", "d:.1", covered_pct },
        .{ "priced_bits", "d:.1", total_bits },
        .{ "foreign", "d", foreign },
        .{ "index_ms", "d:.0", index_dur.ms() },
        .{ "pack_ms", "d:.0", pack_dur },
    });
}
