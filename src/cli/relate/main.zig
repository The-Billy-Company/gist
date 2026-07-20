//! relate — the compression-search CLI (the `relate` binary).
//!
//! What if compression was a text search algorithm? relate is that question as
//! a product: eight query verbs + its own index lifecycle over the relate
//! engine + irregex primitives (relate ∪ match ∪ weave), riding the same
//! corpus policy as the `gist` binary:
//!
//!   relate search <text> [--top N] [--json] [ROOT...]
//!       which files would describe this text most cheaply? — the two-stage
//!       compression retrieval (fingerprint lexicon → suffix-automaton
//!       cross-parse; search/similarity/lexicon.zig + search/similarity/zipper.zig)
//!   relate pack <text> [--top N] [--json] [ROOT...]
//!       the SET of files that jointly describes <text> cheapest — greedy
//!       submodular coverage, each pick priced by what it ADDS (cli/relate/pack.zig)
//!   relate quote <text> [--json]
//!       rewrite <text> as quotations from the WHOLE corpus, priced in bits —
//!       the Ziv–Merhav cross-parse on the persisted codex shelf
//!       (cli/relate/quote.zig + src/index/codex/cento.zig; `relate index --shelf`)
//!   relate similar <path> [--lens bytes|structure|fused] [--top N] [--json] [ROOT...]
//!       nearest files by compression kinship — the lens picks the distance
//!       channel: raw bytes (LZJD), normalized structure (silhouette), or
//!       their min ("what else in this tree is LIKE this file?")
//!   relate dups [--max-distance T] [--top N] [--json] [ROOT...]
//!       near-duplicate pairs across the corpus, closest first
//!   relate clusters [--max-distance T] [--min-size N] [--top N] [ROOT...]
//!       fork FAMILIES — connected components of the dup graph, largest first
//!   relate echoes [--min-echo E] [--top N] [--json] [ROOT...]
//!       DRY candidates dups cannot see: pairs far apart in bytes but close
//!       in structure, ranked by that gap (cli/relate/echoes.zig)
//!   relate patterns -e P [-e P…] [--by pattern|file] [--under GLOB] [ROOT...]
//!       one walk, N patterns, exact per-pattern attribution, loom-shaped
//!
//!   relate index [--shelf]     build the kinship atlas (+ the codex shelf)
//!   relate status [--json]     atlas + shelf readiness and freshness
//!
//! Plus the introspection conventions: `--help`, `--version`, `--schema`
//! (a JSON capability manifest for agents/codegen).
//!
//! This is the thin dispatch shell only: verb drivers live beside this file
//! under `src/cli/relate/`; the compression engines live under
//! `src/search/similarity/` and the persisted tiers under `src/index/`,
//! reached through the `irregex` module.

const std = @import("std");
const irregex = @import("irregex");

const verbs = irregex.commands.irregex; // similar / dups / patterns drivers
const search = irregex.commands.relate_search; // the compression-retrieval verb
const quote = irregex.commands.relate_quote; // the corpus-global cross-parse verb
const pack = irregex.commands.relate_pack; // the anti-redundant context packer
const family = irregex.commands.relate_family; // the fork-family clusters verb
const echoes = irregex.commands.relate_echoes; // the structure-vs-bytes DRY verb
const lifecycle = irregex.commands.relate_lifecycle; // index / status
const schema = irregex.commands.relate_schema; // `--schema` JSON manifest

fn usage() void {
    std.debug.print(
        \\relate — compression-as-search over the irregex primitives
        \\
        \\usage:
        \\  relate search <text> [--top N] [--json] [ROOT...]
        \\      which files would describe this text most cheaply?
        \\      (two-stage compression retrieval; score = coding gain in [0,1])
        \\  relate pack <text> [--top N] [--json] [ROOT...]
        \\      the SET of files that jointly describes <text> cheapest —
        \\      each pick scored by the bits it ADDS beyond the picks before it
        \\  relate quote <text> [--json]
        \\      rewrite <text> as quotations from the WHOLE corpus, priced in
        \\      bits (Ziv-Merhav cross-parse on the codex shelf; O(|text|) —
        \\      needs `relate index --shelf` or `gist codex build`)
        \\  relate similar <path> [--lens bytes|structure|fused] [--top N] [--json]
        \\                 [--no-index] [ROOT...]
        \\      nearest files by compression kinship; the lens picks the distance
        \\      channel — raw bytes (LZJD, default), normalized structure
        \\      (renamed twins surface), or their min (fused)
        \\  relate dups [--max-distance T] [--top N] [--json] [--no-index] [ROOT...]
        \\      near-duplicate file pairs, closest first
        \\  relate clusters [--max-distance T] [--min-size N] [--top N] [--json]
        \\                  [--no-index] [ROOT...]
        \\      fork families — connected components of the dup graph, largest first
        \\  relate echoes [--min-echo E] [--top N] [--json] [--no-index] [ROOT...]
        \\      DRY candidates dups cannot see — pairs far apart in bytes but
        \\      close in structure (echo = bytes − structure), widest gap first
        \\  relate patterns -e P [-e P...] [-f FILE] [-F] [-i]
        \\                 [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]
        \\      one walk, N patterns, per-pattern attribution
        \\
        \\  relate index [--shelf]   build + persist the kinship atlas (and the
        \\                           codex shelf with --shelf); the sketch verbs
        \\                           then answer warm, folding in fresh changes
        \\  relate status [--json]   atlas + shelf readiness and freshness
        \\
        \\  relate --schema     a JSON capability manifest for agents
        \\  relate --version
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
        std.debug.print("relate {s}\n", .{irregex.version_string});
        return;
    }
    if (std.mem.eql(u8, mode, "--schema")) {
        schema.emit();
        return;
    }

    // Same output-budget resolution as the gist CLI (GIST_UNCAP / GIST_MAX_OUTPUT_*)
    // so a grouped `patterns --by` answer is never silently clipped differently.
    irregex.corpus.initOutputBudget(false);

    const dispatch = .{
        .{ "search", search.runSearch },
        .{ "pack", pack.runPack },
        .{ "quote", quote.runQuote },
        .{ "similar", verbs.runSimilar },
        .{ "dups", verbs.runDups },
        .{ "clusters", family.runClusters },
        .{ "echoes", echoes.runEchoes },
        .{ "patterns", verbs.runPatterns },
        .{ "index", lifecycle.runIndex },
        .{ "status", lifecycle.runStatus },
    };
    inline for (dispatch) |d| {
        if (std.mem.eql(u8, mode, d[0])) {
            var rest: std.ArrayList([]const u8) = .empty;
            defer rest.deinit(gpa);
            while (it.next()) |arg| try rest.append(gpa, arg);
            try d[1](gpa, io, rest.items);
            return;
        }
    }

    std.debug.print("relate: unknown verb '{s}' (search | pack | quote | similar | dups | clusters | echoes | patterns | index | status; --help)\n", .{mode});
    std.process.exit(2);
}
