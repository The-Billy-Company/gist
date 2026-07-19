//! hydra — the `search` verb: compression-as-search over the live corpus.
//!
//!   hydra search <text> [--top N] [--json] [ROOT...]
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
//! Corpus policy: the index corpus (`corpus.load`), same as every hydra verb.
//! Results on stdout (`--json` = NDJSON), diagnostics + timing on stderr.

const std = @import("std");
const corpus_mod = @import("../../runtime/corpus/corpus.zig");
const cli_args = @import("../gist/search/argv/args.zig");
const scope = @import("../../runtime/scope/glob.zig");
const lexicon = @import("../../search/similarity/lexicon.zig");
const zipper = @import("../../search/similarity/zipper.zig");

const die = cli_args.die;
const oom = cli_args.oom;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;

/// Append `s` JSON-string-escaped (quotes included). Same escaper the other
/// verb drivers keep; duplicated rather than exported to avoid making the
/// verbs module a util shelf.
fn jsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) void {
    buf.append(a, '"') catch oom();
    for (s) |c| switch (c) {
        '"' => buf.appendSlice(a, "\\\"") catch oom(),
        '\\' => buf.appendSlice(a, "\\\\") catch oom(),
        '\n' => buf.appendSlice(a, "\\n") catch oom(),
        '\r' => buf.appendSlice(a, "\\r") catch oom(),
        '\t' => buf.appendSlice(a, "\\t") catch oom(),
        else => if (c < 0x20)
            buf.print(a, "\\u{x:0>4}", .{c}) catch oom()
        else
            buf.append(a, c) catch oom(),
    };
    buf.append(a, '"') catch oom();
}

pub fn runSearch(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var query_text: ?[]const u8 = null;
    var top: usize = 10;
    var json = false;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) die("--top needs a number\n", .{});
            top = std.fmt.parseInt(usize, argv[i], 10) catch die("--top: bad number: {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (query_text == null) {
            query_text = arg;
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    const query = query_text orelse die("usage: hydra search <text> [--top N] [--json] [ROOT...]\n", .{});
    if (query.len == 0) die("hydra search: empty query\n", .{});

    const t0 = nowNs(io);
    var corpus = try corpus_mod.load(gpa, io, if (roots.items.len == 0) &corpus_mod.default_roots else roots.items);
    defer corpus.deinit();

    var lex = try lexicon.Lexicon.build(gpa, corpus.docs);
    defer lex.deinit();
    const built_ns = nowNs(io);

    const hits = try lex.retrieve(gpa, query, top);
    defer gpa.free(hits);

    const cold = zipper.coldBits(query);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (hits) |h| {
        const gain = if (cold > 0.0) 1.0 - h.cost.bits / cold else 0.0;
        if (json) {
            buf.appendSlice(gpa, "{\"path\":") catch oom();
            jsonStr(&buf, gpa, corpus.paths[h.doc]);
            buf.print(gpa, ",\"gain\":{d:.4},\"cost_bits\":{d:.1},\"bits_saved\":{d:.1},\"factors\":{d},\"literals\":{d}}}\n", .{ gain, h.cost.bits, h.bits_saved, h.cost.factors, h.cost.literals }) catch oom();
        } else {
            buf.print(gpa, "{d:.4}  {s}\n", .{ gain, corpus.paths[h.doc] }) catch oom();
        }
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("search: {d} files indexed · {d} hit(s) · index {d:.0} ms · query {d:.0} ms\n", .{
        corpus.docs.len, hits.len, ms(built_ns - t0), ms(nowNs(io) - built_ns),
    });
}
