//! relate — the `search` verb: compression-as-search over the live corpus.
//!
//!   relate search <text> [--top N] [--json] [ROOT...]
//!       which files would describe this text most cheaply? Two stages, one
//!       theory: the persisted trigram codebook nominates candidates by
//!       corpus-priced evidence, then the suffix-automaton cross-parse over
//!       bounded query-bearing windows decides (the ΔAb shape of "Language
//!       Trees and Zipping", without rebuilding the corpus per query).
//!
//! The score surfaced is coding GAIN: 1 − cost/cold. One means the reference
//! makes the query nearly free; zero means it costs the literal baseline; a
//! negative score is possible when short copy factors into a large reference
//! cost more than literals. Higher = closer (the inverse orientation of
//! `similar`'s distance, because search asks "how much is already paid?" not
//! "how far apart?").
//!
//! Corpus policy: the index corpus (`corpus.load`), same as every relate verb.
//! Results on stdout (`--json` = NDJSON), diagnostics + timing on stderr.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const lexicon = @import("../../../kernel/kinship/recall/lexicon.zig");
const retrieval = @import("../../exec/cold/engine/retrieval.zig");
const zipper = @import("../../../kernel/kinship/recall/zipper.zig");
const kinship = @import("kinship.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");

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
    if (try retrieval.retrieve(gpa, io, query, roots.items, o.top, .load)) |indexed_value| {
        var indexed = indexed_value;
        defer indexed.deinit();
        const cold = zipper.coldBits(query);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        for (indexed.hits) |h| {
            const gain = if (cold > 0.0) 1.0 - h.cost.bits / cold else 0.0;
            emit.emitRow(&buf, gpa, o.json, .{
                .{ "path", "s", h.path },
                .{ "gain", "d:.4", gain },
                .{ "cost_bits", "d:.1", h.cost.bits },
                .{ "bits_saved", "d:.1", h.evidence_bits },
                .{ "factors", "d", h.cost.factors },
                .{ "literals", "d", h.cost.literals },
            }, "{d:.4}  {s}\n", .{ gain, h.path });
        }
        corpus_mod.emitStdout(buf.items);
        std.debug.print("search: {d} files indexed · {d} candidate(s) · {d} refreshed · {d} hit(s) · query {d:.0} ms\n", .{
            indexed.indexed_files, indexed.candidates, indexed.refreshed, indexed.hits.len, ms(nowNs(io) - t0),
        });
        return;
    }

    const rr = try flags.rootsOf(gpa, roots.items);
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
        emit.emitRow(&buf, gpa, o.json, .{
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
