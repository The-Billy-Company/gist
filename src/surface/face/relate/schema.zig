//! relate --schema — the deterministic, machine-readable capability manifest.
//!
//! relate's verb surface is closed and static (nine query verbs + the two
//! lifecycle verbs over the relate engine + irregex primitives), so unlike
//! gist's manifest — which renders its rg-flag buckets from the parser
//! catalog — this one is a single comptime document. The JSON validity test
//! keeps it honest.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");

const manifest =
    \\{
    \\  "tool": "relate",
    \\  "version": "0.1.0",
    \\  "summary": "compression-as-search: retrieval by conditional description length (search), anti-redundant context packing (pack), corpus-global quotation (quote), file kinship (similar/dups/clusters), structural DRY candidates (echoes), FUNCTION-level concept discovery + retrieval (concepts), multi-pattern attribution (patterns), and an owned warm tier (index/status)",
    \\  "verbs": {
    \\    "search": {
    \\      "summary": "which files would describe this text most cheaply? the persisted trigram codebook nominates with corpus-priced query evidence, then a suffix-automaton cross-parse over bounded query-bearing windows decides; higher coding gain is closer",
    \\      "args": [{"name": "text", "type": "string", "required": true, "description": "the query text"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--top", "type": "int", "default": 10, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {path, gain, cost_bits, bits_saved, factors, literals} rows"}]
    \\    },
    \\    "pack": {
    \\      "summary": "the SET of files that jointly describes <text> cheapest — greedy max-coverage over corpus-priced query chunks from the persisted codebook; each pick's marginal_bits is exactly what it adds beyond earlier picks",
    \\      "args": [{"name": "text", "type": "string", "required": true, "description": "the query text"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--top", "type": "int", "default": 8, "description": "maximum files picked (stops early when nothing adds bits)"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {rank, path, marginal_bits, coverage} rows in pick order"}]
    \\    },
    \\    "quote": {
    \\      "summary": "rewrite <text> as maximal verbatim quotations from the WHOLE corpus, priced in bits (Ziv-Merhav cross-parse on the persisted codex shelf); bits/byte = corpus-conditional compression rate, low = the corpus already knows it; each phrase attributed to one exemplar file; requires `relate index --shelf` (or `gist codex build`)",
    \\      "args": [{"name": "text", "type": "string", "required": true, "description": "the query text"}],
    \\      "flags": [{"name": "--json", "type": "bool", "default": false, "description": "summary object then NDJSON {text, occurrences, bits, source} phrase rows"}]
    \\    },
    \\    "similar": {
    \\      "summary": "nearest files to <path> by compression kinship, closest first; --lens picks the distance channel — bytes (LZJD over raw bytes, default), structure (winnowed normalized-token silhouette: renamed Type-2 twins surface), or fused (min of both); answers from the kinship atlas when one is fresh-foldable, live otherwise — identical answers",
    \\      "args": [{"name": "path", "type": "string", "required": true, "description": "the probe file"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--lens", "type": "string", "default": "bytes", "description": "distance channel: bytes | structure | fused"}, {"name": "--top", "type": "int", "default": 20, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {path, distance} rows"}, {"name": "--no-index", "type": "bool", "default": false, "description": "force the live corpus build (skip the atlas)"}]
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
    \\    "echoes": {
    \\      "summary": "DRY candidates dups cannot see: file pairs far apart in bytes but close in structure (echo = byte_distance − structure_distance), widest gap first — same skeleton under different vocabulary (Type-2 clones), the abstraction-candidate report; candidates nominate via silhouette seed buckets, every emitted pair exactly verified against both channels",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--min-echo", "type": "float", "default": 0.15, "description": "smallest bytes−structure gap surfaced, in [0,1]"}, {"name": "--top", "type": "int", "default": 50, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {a, b, echo, bytes, structure} rows"}, {"name": "--no-index", "type": "bool", "default": false, "description": "force the live corpus build (skip the atlas)"}]
    \\    },
    \\    "concepts": {
    \\      "summary": "the FUNCTION-level sibling of clusters/echoes: with no text, package-wide families of theoretically-similar functions (the repeated engine, the duplicated JSON dump), ranked by consolidation opportunity (conservative repeated lines, then channel confidence — never a fused score); with text, the nearest function fragments to that concept. comparison unit is the function fragment, not the file; --lens picks the channel (structure default/warm, bytes for near-verbatim clones, echo for renamed twins); byte sketches computed only for nominated fragments; atlas-class warm tier via concepts.frag",
    \\      "args": [{"name": "text", "type": "string", "required": false, "description": "a concept to retrieve nearest fragments for; omit for package-wide family discovery. a bare arg naming an existing path is a ROOT, not text"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--lens", "type": "string", "default": "structure", "description": "kinship channel: structure | bytes | echo"}, {"name": "--max-distance", "type": "float", "default": 0.25, "description": "structure/bytes edge admission threshold in [0,1]"}, {"name": "--min-echo", "type": "float", "default": 0.15, "description": "smallest bytes−structure gap for the echo lens, in [0,1]"}, {"name": "--min-lines", "type": "int", "default": 5, "description": "shortest fragment that can anchor a family"}, {"name": "--min-size", "type": "int", "default": 2, "description": "smallest family surfaced"}, {"name": "--top", "type": "int", "default": 20, "description": "families (or fragments) surfaced"}, {"name": "--brief", "type": "bool", "default": false, "description": "one line per family: shape + exemplar + (+k more)"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON family rows {members[], count, repeated_lines, confidence, structure, bytes?, echo?} or hit rows {path, line_start, line_end, distance}"}, {"name": "--no-index", "type": "bool", "default": false, "description": "force the live extract + build (skip concepts.frag)"}]
    \\    },
    \\    "patterns": {
    \\      "summary": "N patterns, one pass, exact per-pattern attribution; index-elides reads when every pattern has a sound trigram prefilter",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "-e/--regexp", "type": "string[]", "default": null, "description": "a pattern (repeatable)"}, {"name": "-f/--file", "type": "string", "default": null, "description": "newline-separated pattern file"}, {"name": "-F/--fixed-strings", "type": "bool", "default": false, "description": "patterns are literals"}, {"name": "-i/--ignore-case", "type": "bool", "default": false, "description": "case-insensitive (disables index elision)"}, {"name": "--by", "type": "string", "default": null, "description": "group rows into counts: pattern | file"}, {"name": "--under", "type": "string", "default": null, "description": "keep rows whose path matches this glob"}, {"name": "--top", "type": "int", "default": 0, "description": "cap rows/groups (0 = all)"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON rows ({path, line, pattern_id, pattern}) or groups ({label, count})"}]
    \\    },
    \\    "index": {
    \\      "summary": "build + persist the kinship atlas (one LZJD sketch + one structure silhouette per corpus file; broad kinship queries answer warm while narrow explicit scopes may sketch live); --shelf also rebuilds the codex shelf quote reads",
    \\      "args": [],
    \\      "flags": [{"name": "--shelf", "type": "bool", "default": false, "description": "also build the codex shelf (the same artifact `gist codex build` writes)"}]
    \\    },
    \\    "status": {
    \\      "summary": "atlas + shelf readiness and freshness; exit 0 when the atlas is ready, 1 otherwise (verbs still answer, live)",
    \\      "args": [],
    \\      "flags": [{"name": "--json", "type": "bool", "default": false, "description": "one {schema_version, atlas{state, files, bytes, stale_files, built_unix_ns}, shelf{state, bytes}} object"}]
    \\    }
    \\  },
    \\  "corpus_policy": "the shared corpus — every non-binary, non-gitignored file under the roots, with the same gitignore precedence as gist plus corpus-only VCS/build pruning",
    \\  "warm_tier": "search/pack nominate from Gist's mmap-backed trigram codebook and fold changed files; broad kinship queries use the atlas while narrow explicit scopes automatically sketch live when cheaper; quote uses the codex shelf",
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "exit_codes": {"0": "verb ran (rows may be empty)", "1": "status: atlas unavailable", "2": "usage, parse, path, or pattern error"}
    \\}
    \\
;

/// Emit the JSON capability manifest to stdout.
pub fn emit() void {
    corpus_mod.emitStdout(manifest);
}

test "relate --schema is valid JSON naming all eleven verbs" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, manifest, .{});
    defer parsed.deinit();
    const verbs = parsed.value.object.get("verbs").?.object;
    for ([_][]const u8{ "search", "pack", "quote", "similar", "dups", "clusters", "echoes", "concepts", "patterns", "index", "status" }) |v| {
        try t.expect(verbs.contains(v));
    }
    try t.expectEqualStrings("relate", parsed.value.object.get("tool").?.string);
}
