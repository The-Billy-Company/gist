//! relate — what the face can do, declared once.
//!
//! The single source for `relate --help`, `relate --schema`, verb dispatch,
//! and the unknown-verb line. Each row owns its handler, so the four can't
//! disagree: a verb that isn't here isn't runnable, and a verb that's here is
//! documented in both registers (`blurb` for a person, `summary` for an agent
//! reading `--schema` with no other documentation).
//!
//! Rendering lives in `surface/cli/manifest.zig`; this file is only the
//! content. Adding a verb is adding a row.

const std = @import("std");
const manifest = @import("../../cli/manifest.zig");

const search = @import("search.zig");
const pack = @import("pack.zig");
const quote = @import("quote.zig");
const similar = @import("similar.zig");
const verbs = @import("verbs.zig");
const family = @import("family.zig");
const echoes = @import("echoes.zig");
const concepts = @import("concepts.zig");
const lifecycle = @import("lifecycle.zig");

const Verb = manifest.Verb;

/// The two args nearly every kinship verb takes, so a scope means the same
/// thing on all of them.
const roots_arg = manifest.Arg{
    .name = "ROOT...",
    .kind = "string[]",
    .doc = "corpus roots (default: the index roots)",
};

/// The flags shared across the kinship verbs — declared once so `--top` and
/// `--json` cannot describe themselves differently on two verbs.
fn top(n: i64) manifest.Flag {
    return .{ .name = "--top", .kind = "int", .default = .{ .int = n }, .doc = "rows surfaced" };
}

fn json(shape: []const u8) manifest.Flag {
    return .{ .name = "--json", .kind = "bool", .default = .{ .boolean = false }, .doc = shape };
}

const no_index = manifest.Flag{
    .name = "--no-index",
    .kind = "bool",
    .default = .{ .boolean = false },
    .doc = "force the live corpus build (skip the atlas); identical answers, more bytes read",
};

const channel_flag = manifest.Flag{
    .name = "--as",
    .kind = "string",
    .default = .{ .text = "copies" },
    .doc = "kinship channel: copies (LZJD over raw bytes) | twins (bytes−structure gap: same skeleton, renamed vocabulary) | shapes (normalized-structure silhouette) | any (closest of either). the metric names bytes|echo|structure|fused are accepted as --lens aliases",
};

const min_grade = manifest.Flag{
    .name = "--min-grade",
    .kind = "string",
    .doc = "withhold rows weaker than this calibrated grade: identical | strong | moderate | weak | none",
};

pub const face = manifest.Face{
    .tool = "relate",
    .tagline = "relate — compression-as-search over the irregex primitives",
    .summary = "compression-as-search: retrieval by conditional description length (search), anti-redundant context packing (pack), corpus-global quotation (quote), file kinship over one channel vocabulary (similar/dups/clusters/echoes), FUNCTION-level concept discovery (concepts), multi-pattern attribution (patterns), and an owned warm tier (index/status). every kinship score carries a calibrated grade, so background never reads as a hit",
    .verbs = &.{
        .{
            .name = "search",
            .asks = "vague text -> ranked files",
            .form = "<text> [--top N] [--json] [ROOT...]",
            .blurb = "independent file rank by coding gain; higher is better, and a\nworse-than-cold candidate may score below zero",
            .summary = "which files would describe this text most cheaply? the persisted trigram codebook nominates with corpus-priced query evidence, then a suffix-automaton cross-parse over bounded query-bearing windows decides; higher coding gain is closer",
            .args = &.{ .{ .name = "text", .required = true, .doc = "the query text" }, roots_arg },
            .flags = &.{ top(10), json("NDJSON {path, gain, cost_bits, bits_saved, factors, literals} rows") },
            .run = search.runSearch,
        },
        .{
            .name = "pack",
            .asks = "compact non-redundant context",
            .form = "<text> [--top N] [--json] [ROOT...]",
            .blurb = "set-valued context; each pick pays only for bits not covered earlier",
            .summary = "the SET of files that jointly describes <text> cheapest — greedy max-coverage over corpus-priced query chunks from the persisted codebook; each pick's marginal_bits is exactly what it adds beyond earlier picks",
            .args = &.{ .{ .name = "text", .required = true, .doc = "the query text" }, roots_arg },
            .flags = &.{
                .{ .name = "--top", .kind = "int", .default = .{ .int = 8 }, .doc = "maximum files picked (stops early when nothing adds bits)" },
                json("NDJSON {rank, path, marginal_bits, coverage} rows in pick order"),
            },
            .run = pack.runPack,
        },
        .{
            .name = "quote",
            .asks = "pasted text -> provenance",
            .form = "<text> [--json]",
            .blurb = "whole-corpus verbatim attribution priced against the codex shelf",
            .summary = "rewrite <text> as maximal verbatim quotations from the WHOLE corpus, priced in bits (Ziv-Merhav cross-parse on the persisted codex shelf); bits/byte = corpus-conditional compression rate, low = the corpus already knows it; each phrase attributed to one exemplar file; requires `relate index --shelf` (or `gist codex build`)",
            .args = &.{.{ .name = "text", .required = true, .doc = "the query text" }},
            .flags = &.{json("summary object then NDJSON {text, occurrences, bits, source} phrase rows")},
            .run = quote.runQuote,
        },
        .{
            .name = "similar",
            .asks = "one file -> nearest neighbors",
            .form = "<path> [--as copies|twins|shapes|any] [--top N]\n[--min-grade G] [--json] [--no-index] [ROOT...]",
            .blurb = "nearest files on the chosen channel. every row carries a calibrated\ngrade, and an answer made only of background says so on stderr",
            .summary = "nearest files to <path> by compression kinship, strongest first. ranking always returns rows, so every row carries a calibrated grade and --min-grade withholds the ones that are only background; when the whole answer is background the verb says so on stderr rather than looking like a hit. answers from the kinship atlas when one is fresh-foldable, live otherwise — identical answers",
            .args = &.{ .{ .name = "path", .required = true, .doc = "the probe file" }, roots_arg },
            .flags = &.{ channel_flag, min_grade, top(20), json("NDJSON {path, distance, grade, channel} rows"), no_index },
            .run = similar.runSimilar,
        },
        .{
            .name = "dups",
            .asks = "duplicate pairs",
            .form = "[--max-distance T] [--top N] [--min-grade G]\n[--json] [--no-index] [ROOT...]",
            .blurb = "verified near-duplicate pairs at distance <= T",
            .summary = "near-duplicate file pairs across the corpus, closest first (copy-paste drift, forked fixtures); candidates nominate from bottom-16 seed buckets and every emitted pair is exactly verified; atlas-accelerated like similar",
            .args = &.{roots_arg},
            .flags = &.{
                .{ .name = "--max-distance", .kind = "float", .default = .{ .float = 0.25 }, .doc = "pair admission threshold in [0,1]" },
                min_grade,
                top(100),
                json("NDJSON {a, b, distance, grade} rows"),
                no_index,
            },
            .run = verbs.runDups,
        },
        .{
            .name = "clusters",
            .asks = "complete duplicate families",
            .form = "[--max-distance T] [--min-size N] [--top N]\n[--min-grade G] [--json] [--no-index] [ROOT...]",
            .blurb = "connected components of the same verified duplicate graph",
            .summary = "fork families — connected components of the verified dup graph, largest first: the whole fixture farm or mirrored module tree in one answer instead of a pair list the caller re-joins; exactly the transitive closure of dups at the same threshold. a family is graded by its LOOSEST verified edge, so a grade describes the whole family, not its tightest pair",
            .args = &.{roots_arg},
            .flags = &.{
                .{ .name = "--max-distance", .kind = "float", .default = .{ .float = 0.25 }, .doc = "edge admission threshold in [0,1]" },
                .{ .name = "--min-size", .kind = "int", .default = .{ .int = 2 }, .doc = "smallest family surfaced" },
                .{ .name = "--top", .kind = "int", .default = .{ .int = 50 }, .doc = "families surfaced" },
                min_grade,
                json("NDJSON {size, max_distance, grade, paths[]} rows"),
                no_index,
            },
            .run = family.runClusters,
        },
        .{
            .name = "echoes",
            .asks = "same shape, renamed vocabulary",
            .form = "[--min-echo E] [--top N] [--min-grade G]\n[--json] [--no-index] [ROOT...]",
            .blurb = "bytes − structure >= E; a wider gap is a stronger renamed-twin\ncandidate — the DRY finding byte kinship structurally cannot see",
            .summary = "DRY candidates dups cannot see: file pairs far apart in bytes but close in structure (echo = byte_distance − structure_distance), widest gap first — same skeleton under different vocabulary (Type-2 clones), the abstraction-candidate report; candidates nominate via silhouette seed buckets, every emitted pair exactly verified against both channels. this is a GAP channel: higher is stronger, and byte-identical files score zero",
            .args = &.{roots_arg},
            .flags = &.{
                .{ .name = "--min-echo", .kind = "float", .default = .{ .float = 0.15 }, .doc = "smallest bytes−structure gap surfaced, in [0,1]" },
                min_grade,
                .{ .name = "--top", .kind = "int", .default = .{ .int = 50 }, .doc = "rows surfaced" },
                json("NDJSON {a, b, echo, bytes, structure, grade} rows"),
                no_index,
            },
            .run = echoes.runEchoes,
        },
        .{
            .name = "concepts",
            .asks = "same FUNCTION across files",
            .form = "[TEXT] [--lens structure|bytes|echo] [--max-distance T]\n[--min-lines N] [--min-size N] [--top N] [--brief]\n[--json] [--no-index] [ROOT...]",
            .blurb = "function-level families of the same idea (no TEXT), or the nearest\nfunction fragments to TEXT; --brief trims to exemplar + count",
            .summary = "the FUNCTION-level sibling of clusters/echoes: with no text, package-wide families of theoretically-similar functions (the repeated engine, the duplicated JSON dump), ranked by consolidation opportunity (conservative repeated lines, then channel confidence — never a fused score); with text, the nearest function fragments to that concept. comparison unit is the function fragment, not the file; --lens picks the channel (structure default/warm, bytes for near-verbatim clones, echo for renamed twins); byte sketches computed only for nominated fragments; atlas-class warm tier via concepts.frag",
            .args = &.{
                .{ .name = "text", .doc = "a concept to retrieve nearest fragments for; omit for package-wide family discovery. a bare arg naming an existing path is a ROOT, not text" },
                roots_arg,
            },
            .flags = &.{
                .{ .name = "--lens", .kind = "string", .default = .{ .text = "structure" }, .doc = "kinship channel: structure | bytes | echo" },
                .{ .name = "--max-distance", .kind = "float", .default = .{ .float = 0.25 }, .doc = "structure/bytes edge admission threshold in [0,1]" },
                .{ .name = "--min-echo", .kind = "float", .default = .{ .float = 0.15 }, .doc = "smallest bytes−structure gap for the echo lens, in [0,1]" },
                .{ .name = "--min-lines", .kind = "int", .default = .{ .int = 5 }, .doc = "shortest fragment that can anchor a family" },
                .{ .name = "--min-size", .kind = "int", .default = .{ .int = 2 }, .doc = "smallest family surfaced" },
                top(20),
                .{ .name = "--brief", .kind = "bool", .default = .{ .boolean = false }, .doc = "one line per family: shape + exemplar + (+k more)" },
                json("NDJSON family rows {members[], count, repeated_lines, confidence, structure, bytes?, echo?} or hit rows {path, line_start, line_end, distance}"),
                .{ .name = "--no-index", .kind = "bool", .default = .{ .boolean = false }, .doc = "force the live extract + build (skip concepts.frag)" },
            },
            .run = concepts.runConcepts,
        },
        .{
            .name = "patterns",
            .asks = "N exact patterns, one walk",
            .form = "-e P [-e P...] [-f FILE] [-F] [-i]\n[--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]",
            .blurb = "one walk with exact per-pattern attribution; --by groups counts",
            .summary = "N patterns, one pass, exact per-pattern attribution; index-elides reads when every pattern has a sound trigram prefilter",
            .args = &.{roots_arg},
            .flags = &.{
                .{ .name = "-e/--regexp", .kind = "string[]", .doc = "a pattern (repeatable)" },
                .{ .name = "-f/--file", .kind = "string", .doc = "newline-separated pattern file" },
                .{ .name = "-F/--fixed-strings", .kind = "bool", .default = .{ .boolean = false }, .doc = "patterns are literals" },
                .{ .name = "-i/--ignore-case", .kind = "bool", .default = .{ .boolean = false }, .doc = "case-insensitive (disables index elision)" },
                .{ .name = "--by", .kind = "string", .doc = "group rows into counts: pattern | file" },
                .{ .name = "--under", .kind = "string", .doc = "keep rows whose path matches this glob" },
                .{ .name = "--top", .kind = "int", .default = .{ .int = 0 }, .doc = "cap rows/groups (0 = all)" },
                json("NDJSON rows ({path, line, pattern_id, pattern}) or groups ({label, count})"),
            },
            .run = verbs.runPatterns,
        },
        .{
            .name = "index",
            .form = "[--shelf]",
            .blurb = "build the kinship atlas; --shelf also builds the codex quote reads",
            .summary = "build + persist the kinship atlas (one LZJD sketch + one structure silhouette per corpus file; broad kinship queries answer warm while narrow explicit scopes may sketch live); --shelf also rebuilds the codex shelf quote reads",
            .flags = &.{.{ .name = "--shelf", .kind = "bool", .default = .{ .boolean = false }, .doc = "also build the codex shelf (the same artifact `gist codex build` writes)" }},
            .section = .lifecycle,
            .run = lifecycle.runIndex,
        },
        .{
            .name = "status",
            .form = "[--json]",
            .blurb = "atlas + shelf readiness and freshness",
            .summary = "atlas + shelf readiness and freshness; exit 0 when the atlas is ready, 1 otherwise (verbs still answer, live)",
            .flags = &.{json("one {schema_version, atlas{state, files, bytes, stale_files, built_unix_ns}, shelf{state, bytes}} object")},
            .section = .lifecycle,
            .run = lifecycle.runStatus,
        },
    },
    .notes = &.{
        .{ .key = "channels", .text = "one vocabulary across every kinship verb: copies (LZJD over raw bytes) | twins (byte−structure gap: same skeleton, renamed vocabulary) | shapes (normalized-structure silhouette) | any (min of copies and shapes). copies/shapes/any score a DISTANCE (lower is closer, admitted by --max-distance); twins scores a GAP (higher is stronger, admitted by --min-echo)" },
        .{ .key = "grades", .text = "every kinship score is banded so a caller can tell a finding from background: distances grade identical <=0.05, strong <=0.25, moderate <=0.50, weak <=0.75, none above; gaps grade strong >=0.45, moderate >=0.30, weak >=0.15, none below. --min-grade withholds weaker rows, and an answer that is entirely background explains itself on stderr (silenced by GIST_HINTS=0)" },
        .{ .key = "corpus_policy", .text = "the shared corpus — every non-binary, non-gitignored file under the roots, with the same gitignore precedence as gist plus corpus-only VCS/build pruning" },
        .{ .key = "warm_tier", .text = "search/pack nominate from Gist's mmap-backed trigram codebook and fold changed files; broad kinship queries use the atlas while narrow explicit scopes automatically sketch live when cheaper; quote uses the codex shelf" },
    },
    .exits = &.{
        .{ .code = 0, .means = "verb ran (rows may be empty)" },
        .{ .code = 1, .means = "status: atlas unavailable" },
        .{ .code = 2, .means = "usage, parse, path, or pattern error" },
    },
    .epilogue =
    \\channels — one vocabulary, every verb (`--as`, or `--lens` by metric name):
    \\  copies    (bytes)      verbatim duplication and its drift (default)
    \\  twins     (echo)       same skeleton, renamed vocabulary — the DRY signal
    \\  shapes    (structure)  shared skeleton, vocabulary irrelevant
    \\  any       (fused)      whichever channel sees the stronger relation
    \\
    \\grades — how much a score is worth, so background never reads as a hit:
    \\  distances   identical <=0.05 · strong <=0.25 · moderate <=0.50 · weak <=0.75
    \\  gaps        strong >=0.45 · moderate >=0.30 · weak >=0.15
    \\  --min-grade G   withhold rows weaker than G (empty beats noise)
    \\  GIST_HINTS=0    mute the stderr verdict for byte-counting captures
    \\
    \\niche choices:
    \\  dups vs clusters          raw pairs vs complete transitive families
    \\  echoes                    use when byte similarity misses renamed structure
    \\  search vs pack            independent ranking vs jointly useful context
    \\  --no-index                live differential oracle for atlas-backed verbs
    \\  ROOT...                   scope the index corpus; quote always uses the whole shelf
    \\  --json                    deterministic NDJSON on stdout; diagnostics stay on stderr
    \\
    \\lifecycle notes:
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
    ,
};

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "relate --schema is valid JSON naming all eleven verbs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    manifest.schema(&buf, a, face, "0.2.0");

    const parsed = try std.json.parseFromSlice(std.json.Value, a, buf.items, .{});
    const rendered = parsed.value.object.get("verbs").?.object;
    try t.expectEqualStrings("relate", parsed.value.object.get("tool").?.string);
    for ([_][]const u8{ "search", "pack", "quote", "similar", "dups", "clusters", "echoes", "concepts", "patterns", "index", "status" }) |v| {
        try t.expect(rendered.contains(v));
    }
    try t.expectEqual(@as(usize, 11), rendered.count());
}

test "every verb documents itself in both registers and can run" {
    for (face.verbs) |v| {
        try t.expect(v.name.len > 0);
        try t.expect(v.blurb.len > 0); // the human register
        try t.expect(v.summary.len > v.blurb.len); // the agent register, always richer
        for (v.flags) |f| try t.expect(f.doc.len > 0);
        for (v.args) |arg| try t.expect(arg.doc.len > 0);
    }
}

test "the shared flag rows keep one description across every verb that takes them" {
    // The drift this table exists to prevent: --no-index meaning one thing on
    // `similar` and another on `dups` because they were written separately.
    const on_similar = face.find("similar").?;
    const on_dups = face.find("dups").?;
    try t.expectEqualStrings(on_similar.flags[4].doc, on_dups.flags[4].doc);
    try t.expectEqualStrings("--no-index", on_dups.flags[4].name);
}
