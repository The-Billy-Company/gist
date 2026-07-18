//! hydra --schema — the deterministic, machine-readable capability manifest.
//!
//! hydra's verb surface is closed and static (three verbs over the irregex
//! primitives), so unlike gist's manifest — which renders its rg-flag buckets
//! from the parser catalog — this one is a single comptime document. The JSON
//! validity test keeps it honest.

const std = @import("std");
const corpus_mod = @import("../../kernel/corpus/corpus.zig");

const manifest =
    \\{
    \\  "tool": "hydra",
    \\  "version": "0.1.0",
    \\  "summary": "compression-as-search over the irregex primitives: kinship (relate), multi-pattern attribution (match), and engine-side shaping (weave)",
    \\  "verbs": {
    \\    "similar": {
    \\      "summary": "nearest files to <path> by compression kinship (LZ dictionary distance, closest first)",
    \\      "args": [{"name": "path", "type": "string", "required": true, "description": "the probe file"}, {"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--top", "type": "int", "default": 20, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {path, distance} rows"}]
    \\    },
    \\    "dups": {
    \\      "summary": "near-duplicate file pairs across the corpus, closest first (copy-paste drift, forked fixtures)",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "--max-distance", "type": "float", "default": 0.25, "description": "pair admission threshold in [0,1]"}, {"name": "--top", "type": "int", "default": 100, "description": "rows surfaced"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON {a, b, distance} rows"}]
    \\    },
    \\    "patterns": {
    \\      "summary": "N patterns, one pass, exact per-pattern attribution; index-elides reads when every pattern has a sound trigram prefilter",
    \\      "args": [{"name": "ROOT...", "type": "string[]", "required": false, "description": "corpus roots (default: the index roots)"}],
    \\      "flags": [{"name": "-e/--regexp", "type": "string[]", "default": null, "description": "a pattern (repeatable)"}, {"name": "-f/--file", "type": "string", "default": null, "description": "newline-separated pattern file"}, {"name": "-F/--fixed-strings", "type": "bool", "default": false, "description": "patterns are literals"}, {"name": "-i/--ignore-case", "type": "bool", "default": false, "description": "case-insensitive (disables index elision)"}, {"name": "--by", "type": "string", "default": null, "description": "group rows into counts: pattern | file"}, {"name": "--under", "type": "string", "default": null, "description": "keep rows whose path matches this glob"}, {"name": "--top", "type": "int", "default": 0, "description": "cap rows/groups (0 = all)"}, {"name": "--json", "type": "bool", "default": false, "description": "NDJSON rows ({path, line, pattern_id, pattern}) or groups ({label, count})"}]
    \\    }
    \\  },
    \\  "corpus_policy": "the index corpus — every non-binary file under the roots minus VCS/build subtrees (corpus.load), the same policy `gist index` uses; corpus analytics, not a gitignore-precedence walk",
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "exit_codes": {"0": "verb ran (rows may be empty)", "2": "usage, parse, path, or pattern error"}
    \\}
    \\
;

/// Emit the JSON capability manifest to stdout.
pub fn emit() void {
    corpus_mod.emitStdout(manifest);
}

test "hydra --schema is valid JSON naming all three verbs" {
    const t = std.testing;
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, manifest, .{});
    defer parsed.deinit();
    const verbs = parsed.value.object.get("verbs").?.object;
    try t.expect(verbs.contains("similar"));
    try t.expect(verbs.contains("dups"));
    try t.expect(verbs.contains("patterns"));
    try t.expectEqualStrings("hydra", parsed.value.object.get("tool").?.string);
}
