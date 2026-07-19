//! hydra — the compression-search CLI (the `hydra` binary).
//!
//! What if compression was a text search algorithm? hydra is that question as
//! a product: five verbs over the hydra engine + irregex primitives (relate ∪
//! match ∪ weave), riding the same corpus policy as the `gist` binary:
//!
//!   hydra search <text> [--top N] [--json] [ROOT...]
//!       which files would describe this text most cheaply? — the two-stage
//!       compression retrieval (fingerprint lexicon → suffix-automaton
//!       cross-parse; engine/lexicon.zig + engine/zipper.zig)
//!   hydra quote <text> [--json]
//!       rewrite <text> as quotations from the WHOLE corpus, priced in bits —
//!       the Ziv–Merhav cross-parse on the persisted codex shelf
//!       (engine/quote.zig + src/codex/cento.zig; needs `gist codex build`)
//!   hydra similar <path> [--top N] [--json] [ROOT...]
//!       nearest files by compression kinship (LZ dictionary distance) —
//!       "what else in this tree is LIKE this file?"
//!   hydra dups [--max-distance T] [--top N] [--json] [ROOT...]
//!       near-duplicate pairs across the corpus, closest first
//!   hydra patterns -e P [-e P…] [--by pattern|file] [--under GLOB] [ROOT...]
//!       one walk, N patterns, exact per-pattern attribution, loom-shaped
//!
//! Plus the introspection conventions: `--help`, `--version`, `--schema`
//! (a JSON capability manifest for agents/codegen).
//!
//! This is the thin dispatch shell only: the verbs' real work lives in
//! `src/hydra/engine/`, reached through the `irregex` module.

const std = @import("std");
const irregex = @import("irregex");

const verbs = irregex.commands.irregex; // similar / dups / patterns drivers
const search = irregex.commands.hydra_search; // the compression-retrieval verb
const quote = irregex.commands.hydra_quote; // the corpus-global cross-parse verb
const schema = irregex.commands.hydra_schema; // `--schema` JSON manifest

fn usage() void {
    std.debug.print(
        \\hydra — compression-as-search over the irregex primitives
        \\
        \\usage:
        \\  hydra search <text> [--top N] [--json] [ROOT...]
        \\      which files would describe this text most cheaply?
        \\      (two-stage compression retrieval; score = coding gain in [0,1])
        \\  hydra quote <text> [--json]
        \\      rewrite <text> as quotations from the WHOLE corpus, priced in
        \\      bits (Ziv-Merhav cross-parse on the codex shelf; O(|text|) —
        \\      needs `gist codex build`)
        \\  hydra similar <path> [--top N] [--json] [ROOT...]
        \\      nearest files by compression kinship (LZ dictionary distance)
        \\  hydra dups [--max-distance T] [--top N] [--json] [ROOT...]
        \\      near-duplicate file pairs, closest first
        \\  hydra patterns -e P [-e P...] [-f FILE] [-F] [-i]
        \\                 [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]
        \\      one walk, N patterns, per-pattern attribution
        \\
        \\  hydra --schema     a JSON capability manifest for agents
        \\  hydra --version
        \\
        \\Corpus policy: the index corpus (same roots and policy as `gist index`);
        \\results on stdout (--json = NDJSON), diagnostics on stderr.
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // argv[0]
    const mode = it.next() orelse {
        usage();
        return;
    };

    if (std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
        usage();
        return;
    }
    if (std.mem.eql(u8, mode, "--version") or std.mem.eql(u8, mode, "-V")) {
        std.debug.print("hydra {s}\n", .{irregex.version_string});
        return;
    }
    if (std.mem.eql(u8, mode, "--schema")) {
        schema.emit();
        return;
    }

    // Same output-budget resolution as the gist CLI (GIST_UNCAP / GIST_MAX_OUTPUT_*)
    // so a grouped `patterns --by` answer is never silently clipped differently.
    irregex.corpus.initOutputBudget(false);

    const known = [_][]const u8{ "search", "quote", "similar", "dups", "patterns" };
    for (known) |k| {
        if (!std.mem.eql(u8, mode, k)) continue;
        var rest: std.ArrayList([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (it.next()) |arg| try rest.append(gpa, arg);
        if (std.mem.eql(u8, mode, "search")) {
            try search.runSearch(gpa, io, rest.items);
        } else if (std.mem.eql(u8, mode, "quote")) {
            try quote.runQuote(gpa, io, rest.items);
        } else if (std.mem.eql(u8, mode, "similar")) {
            try verbs.runSimilar(gpa, io, rest.items);
        } else if (std.mem.eql(u8, mode, "dups")) {
            try verbs.runDups(gpa, io, rest.items);
        } else {
            try verbs.runPatterns(gpa, io, rest.items);
        }
        return;
    }

    std.debug.print("hydra: unknown verb '{s}' (search | quote | similar | dups | patterns; --help)\n", .{mode});
    std.process.exit(2);
}
