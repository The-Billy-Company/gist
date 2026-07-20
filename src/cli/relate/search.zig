//! relate — the `search` verb: compression-as-search over the live corpus.
//!
//!   relate search <text> [--top N] [--json] [ROOT...]
//!       which files would describe this text most cheaply? Two stages, one
//!       theory (see lexicon.zig + zipper.zig): the corpus-priced fingerprint
//!       lexicon nominates candidates (recall — no doc bytes touched), the
//!       suffix-automaton cross-parse decides (precision — the exact ΔAb of
//!       "Language Trees and Zipping" with no compressor run).
//!
//! The score surfaced is the coding GAIN: 1 − cost/cold ∈ [0, 1] — the
//! fraction of the query's cold description length this doc pre-paid.
//! 0 = the doc has seen none of it; →1 = the doc contains it verbatim.
//! Higher = closer (the inverse orientation of `similar`'s distance, because
//! search asks "how much is already paid?" not "how far apart?").
//!
//! Corpus policy: the index corpus (`corpus.load`), same as every relate verb.
//! Results on stdout (`--json` = NDJSON), diagnostics + timing on stderr.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");
const cli_args = @import("../../runtime/cold/argv/args.zig");
const lexicon = @import("../../search/similarity/lexicon.zig");
const zipper = @import("../../search/similarity/zipper.zig");
const kinship = @import("kinship.zig");

const die = cli_args.die;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;

pub fn runSearch(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 10 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{ .positional = true });
    const query = o.arg orelse die("usage: relate search <text> [--top N] [--json] [ROOT...]\n", .{});
    if (query.len == 0) die("relate search: empty query\n", .{});

    const t0 = nowNs(io);
    const rr = try kinship.rootsOf(gpa, roots.items);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items);
    defer corpus.deinit();

    var lex = try lexicon.Lexicon.build(gpa, corpus.docs);
    defer lex.deinit();
    const built_ns = nowNs(io);

    const hits = try lex.retrieve(gpa, query, o.top);
    defer gpa.free(hits);

    const cold = zipper.coldBits(query);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (hits) |h| {
        const gain = if (cold > 0.0) 1.0 - h.cost.bits / cold else 0.0;
        kinship.emitRow(&buf, gpa, o.json, .{
            .{ "path", "s", corpus.paths[h.doc] },
            .{ "gain", "d:.4", gain },
            .{ "cost_bits", "d:.1", h.cost.bits },
            .{ "bits_saved", "d:.1", h.bits_saved },
            .{ "factors", "d", h.cost.factors },
            .{ "literals", "d", h.cost.literals },
        }, "{d:.4}  {s}\n", .{ gain, corpus.paths[h.doc] });
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("search: {d} files indexed · {d} hit(s) · index {d:.0} ms · query {d:.0} ms\n", .{
        corpus.docs.len, hits.len, ms(built_ns - t0), ms(nowNs(io) - built_ns),
    });
}
