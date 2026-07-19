//! relate --schema — the deterministic, machine-readable capability manifest.
//!
//! relate's verb surface is closed and static (seven query verbs + the two
//! lifecycle verbs over the relate engine + irregex primitives), so unlike
//! gist's manifest — which renders its rg-flag buckets from the parser
//! catalog — this one is a single comptime document. The JSON validity test
//! keeps it honest.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");

const manifest =
    \\{
    \\  "tool": "relate",
    \\  "version": "0.1.0",
    \\  "summary": "compression-as-search: retrieval by conditional description length (search), anti-redundant context packing (pack), corpus-global quotation (quote), kinship (similar/dups/clusters), multi-pattern attribution (patterns), and an owned warm tier (index/status)",
    \\  "verbs": {
    \\    "search": {
    \\      "summary": "which files would describe this text most cheaply? two-stage compression retrieval: a corpus-priced fingerprint lexicon nominates, an exact suffix-automaton cross-parse decides; score = coding gain in [0,1], higher = closer",
    \\      "args": [{"name": "text", "type": "string", "required": true, "description": "the query text"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--top", "type": "int", "default": 10, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {path, gain, cost_bits, bits_saved, factors, literals} rows"}]
    \\    },
    \\    "pack": {
    \\      "summary": "the SET of files that jointly describes <text> cheapest — greedy submodular max-coverage over corpus-priced fingerprints; each pick's marginal_bits is exactly what it adds beyond the picks before it (anti-redundant context assembly, the shape independent top-K retrievers cannot express)",
    \\      "args": [{"name": "text", "type": "string", "required": true, "description": "the query text"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--top", "type": "int", "default": 8, "description": "maximum files picked (stops early when nothing adds bits)"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {rank, path, marginal_bits, coverage} rows in pick order"}]
    \\    },
    \\    "quote": {
    \\      "summary": "rewrite <text> as maximal verbatim quotations from the WHOLE corpus, priced in bits (Ziv-Merhav cross-parse on the persisted codex shelf); bits/byte = corpus-conditional compression rate, low = the corpus already knows it; each phrase attributed to one exemplar file; requires `relate index --shelf` (or `gist codex build`)",
    \\      "args": [{"name": "text", "type": "string", "required": true, "description": "the query text"}],
    \\      "flags": [{"name": "--json", "type": "bool", "default": false, "description": "summary object then NDJSON {text, occurrences, bits, source} phrase rows"}]
    \\    },
    \\    "similar": {
    \\      "summary": "nearest files to <path> by compression kinship (LZ dictionary distance, closest first); answers from the kinship atlas when one is fresh-foldable, live otherwise — identical answers",
    \\      "args": [{"name": "path", "type": "string", "required": true, "description": "the probe file"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--top", "type": "int", "default": 20, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {path, distance} rows"}, {"name": "--no-index", "type": "bool", "default": false, "description": "force the live corpus build (skip the atlas)"}]
    \\    },
    \\    "dups": {
    \\      "summary": "near-duplicate file pairs across the corpus, closest first (copy-paste drift, forked fixtures); atlas-accelerated like similar",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--max-distance", "type": "float", "default": 0.25, "description": "pair admission threshold in [0,1]"}, {"name": "--top", "type": "int", "default": 100, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {a, b, distance} rows"}, {"name": "--no-index", "type": "bool", "default": false, "description": "force the live corpus build (skip the atlas)"}]
    \\    },
    \\    "clusters": {
    \\      "summary": "fork families — connected components of the verified dup graph, largest first: the whole fixture farm or mirrored module tree in one answer instead of a pair list the caller re-joins; exactly the transitive closure of dups at the same threshold",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--max-distance", "type": "float", "default": 0.25, "description": "edge admission threshold in [0,1]"}, {"name": "--min-size", "type": "int", "default": 2, "description": "smallest family surfaced"}, {"name": "--top", "type": "int", "default": 50, "description": "families surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {size, max_distance, paths[]} rows"}, {"name": "--no-index", "type": "bool", "default": false, "description": "force the live corpus build (skip the atlas)"}]
    \\    },
    \\    "patterns": {
    \\      "summary": "N patterns, one pass, exact per-pattern attribution; index-elides reads when every pattern has a sound trigram prefilter",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "-e/--regexp", "type": "string[]", "default": null, "description": "a pattern (repeatable)"}, {"name": "-f/--file", "type": "string", "default": null, "description": "newline-separated pattern file"}, {"name": "-F/--fixed-strings", "type": "bool", "default": false, "description": "patterns are literals"}, {"name": "-i/--ignore-case", "type": "bool", "default": false, "description": "case-insensitive (disables index elision)"}, {"name": "--by", "type": "string", "default": null, "description": "group rows into counts: pattern | file"}, {"name": "--under", "type": "string", "default": null, "description": "keep rows whose path matches this glob"}, {"name": "--top", "type": "int", "default": 0, "description": "cap rows/groups (0 = all)"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON rows ({path, line, pattern_id, pattern}) or groups ({label, count})"}]
    \\    },
    \\    "index": {
    \\      "summary": "build + persist the kinship atlas (one LZJD sketch per corpus file; the sketch verbs then answer warm, folding fresh changes in at query time); --shelf also rebuilds the codex shelf quote reads",
    \\      "args": [],
    \\      "flags": [{"name": "--shelf", "type": "bool", "default": false, "description": "also build the codex shelf (the same artifact `gist codex build` writes)"}]
    \\    },
    \\    "status": {
    \\      "summary": "atlas + shelf readiness and freshness; exit 0 when the atlas is ready, 1 otherwise (verbs still answer, live)",
    \\      "args": [],
    \\      "flags": [{"name": "--json", "type": "bool", "default": false, "description": "one {schema_version, atlas{state, files, bytes, stale_files, built_unix_ns}, shelf{state, bytes}} object"}]
    \\    }
    \\  },
    \\  "corpus_policy": "the index corpus — every non-binary file under the roots minus VCS/build subtrees (corpus.load), the same policy `gist index` uses; corpus analytics, not a gitignore-precedence walk",
    \\  "warm_tier": "the kinship atlas (kinship.atlas) persists per-file LZJD sketches; queries fold in every file changed since the build anchor and gate emitted rows against deletion — an accelerator, never an authority (--no-index forces the live build, identical answers)",
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "exit_codes": {"0": "verb ran (rows may be empty)", "1": "status: atlas unavailable", "2": "usage, parse, path, or pattern error"}
    \\}
    \\
;

/// Emit the JSON capability manifest to stdout.
pub fn emit() void {
    corpus_mod.emitStdout(manifest);
}

test "relate --schema is valid JSON naming all nine verbs" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, manifest, .{});
    defer parsed.deinit();
    const verbs = parsed.value.object.get("verbs").?.object;
    for ([_][]const u8{ "search", "pack", "quote", "similar", "dups", "clusters", "patterns", "index", "status" }) |v| {
        try t.expect(verbs.contains(v));
    }
    try t.expectEqualStrings("relate", parsed.value.object.get("tool").?.string);
}
