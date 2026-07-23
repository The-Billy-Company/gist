//! relate — the compression-search CLI (the `relate` binary).
//!
//! What if compression was a text search algorithm? relate is that question as
//! a product: eight query verbs + its own index lifecycle over the relate
//! engine + irregex primitives (relate ∪ match ∪ weave), riding the same
//! corpus policy as the `gist` binary:
//!
//!   relate search <text> [--top N] [--json] [ROOT...]
//!       which files would describe this text most cheaply? — the two-stage
//!       compression retrieval (persisted codebook nomination → bounded
//!       suffix-automaton cross-parse; surface/exec/cold/engine/retrieval.zig)
//!   relate pack <text> [--top N] [--json] [ROOT...]
//!       the SET of files that jointly describes <text> cheapest — greedy
//!       submodular coverage, each pick priced by what it ADDS (surface/face/relate/pack.zig)
//!   relate quote <text> [--json]
//!       rewrite <text> as quotations from the WHOLE corpus, priced in bits —
//!       the Ziv–Merhav cross-parse on the persisted codex shelf
//!       (surface/face/relate/quote.zig + src/corpus/index/codex/cento.zig; `relate index --shelf`)
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
//!       in structure, ranked by that gap (surface/face/relate/echoes.zig)
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
//! under `src/surface/face/relate/`; the compression engines live under
//! `src/kernel/kinship/` and the persisted tiers under `src/corpus/index/`,
//! reached through the `irregex` module.

const std = @import("std");
const irregex = @import("irregex");

const verbs = irregex.commands.irregex; // similar / dups / patterns drivers
const search = irregex.commands.relate_search; // the compression-retrieval verb
const quote = irregex.commands.relate_quote; // the corpus-global cross-parse verb
const pack = irregex.commands.relate_pack; // the anti-redundant context packer
const family = irregex.commands.relate_family; // the fork-family clusters verb
const echoes = irregex.commands.relate_echoes; // the structure-vs-bytes DRY verb
const conceptsv = irregex.commands.relate_concepts; // function-level concept discovery
const lifecycle = irregex.commands.relate_lifecycle; // index / status
const schema = irregex.commands.relate_schema; // `--schema` JSON manifest

fn usage() void {
    irregex.corpus.emitStdout(
        \\relate — compression-as-search over the irregex primitives
        \\
        \\ergonomics — ask the question, then choose the verb:
        \\  vague text -> ranked files       search
        \\  compact non-redundant context    pack
        \\  pasted text -> provenance        quote
        \\  one file -> nearest neighbors    similar
        \\  duplicate pairs                  dups
        \\  complete duplicate families      clusters
        \\  same shape, renamed vocabulary   echoes
        \\  same FUNCTION across files       concepts
        \\  N exact patterns, one walk       patterns
        \\
        \\query verbs:
        \\  relate search <text> [--top N] [--json] [ROOT...]
        \\      independent file rank by coding gain; higher is better, and a
        \\      worse-than-cold candidate may score below zero
        \\  relate pack <text> [--top N] [--json] [ROOT...]
        \\      set-valued context; each pick pays only for bits not covered earlier
        \\  relate quote <text> [--json]
        \\      whole-corpus verbatim attribution priced against the codex shelf
        \\  relate similar <path> [--lens bytes|structure|fused] [--top N] [--json]
        \\                 [--no-index] [ROOT...]
        \\      nearest files; lower distance is closer
        \\  relate dups [--max-distance T] [--top N] [--json] [--no-index] [ROOT...]
        \\      verified near-duplicate pairs at distance <= T
        \\  relate clusters [--max-distance T] [--min-size N] [--top N] [--json]
        \\                  [--no-index] [ROOT...]
        \\      connected components of the same verified duplicate graph
        \\  relate echoes [--min-echo E] [--top N] [--json] [--no-index] [ROOT...]
        \\      byte_distance - structure_distance >= E; higher exposes stronger
        \\      renamed-twin / shared-skeleton candidates
        \\  relate concepts [TEXT] [--lens structure|bytes|echo] [--max-distance T]
        \\                  [--min-lines N] [--min-size N] [--top N] [--brief]
        \\                  [--json] [--no-index] [ROOT...]
        \\      function-level families of the same idea (no TEXT), or the nearest
        \\      function fragments to TEXT; --brief trims to exemplar + count
        \\  relate patterns -e P [-e P...] [-f FILE] [-F] [-i]
        \\                 [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]
        \\      one walk with exact per-pattern attribution; --by groups counts
        \\
        \\niche choices:
        \\  similar --lens bytes      vocabulary/copy-paste kinship (default)
        \\  similar --lens structure  normalized renamed-twin kinship
        \\  similar --lens fused      whichever channel sees the stronger relation
        \\  dups vs clusters          raw pairs vs complete transitive families
        \\  echoes                    use when byte similarity misses renamed structure
        \\  search vs pack            independent ranking vs jointly useful context
        \\  --no-index                live differential oracle for atlas-backed verbs
        \\  ROOT...                   scope the index corpus; quote always uses the whole shelf
        \\  --json                    deterministic NDJSON on stdout; diagnostics stay on stderr
        \\
        \\lifecycle:
        \\  relate index [--shelf]    build the kinship atlas; --shelf also builds
        \\                            the codex required by quote
        \\  relate status [--json]    atlas + shelf readiness and freshness
        \\  missing/corrupt atlas     answer live; acceleration never changes results
        \\  search / pack             reuse Gist's mmap-backed trigram codebook
        \\  narrow kinship scope      sketches live when cheaper than atlas load
        \\
        \\introspection:
        \\  relate --help / -h         this ergonomics guide
        \\  relate --schema            versioned JSON verb contract for agents
        \\  relate --version / -V
        \\
        \\channels & corpus:
        \\  results -> stdout · diagnostics -> stderr
        \\  GIST_UNCAP=1 / GIST_MAX_OUTPUT_*   shared agent-output budget controls
        \\  analytics read the wider index corpus, not gist's rg-parity gitignore walk
        \\
    );
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
        .{ "concepts", conceptsv.runConcepts },
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

    std.debug.print("relate: unknown verb '{s}' (search | pack | quote | similar | dups | clusters | echoes | concepts | patterns | index | status; --help)\n", .{mode});
    std.process.exit(2);
}
