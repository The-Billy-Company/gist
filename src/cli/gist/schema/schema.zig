//! gist --schema — the deterministic, machine-readable capability manifest.
//!
//! Search compatibility is not prose copied from the parser. The four ripgrep
//! buckets are rendered directly from `runtime/cold/argv/args.zig`'s declarative catalog,
//! the same rows that build the short- and long-flag dispatch tables.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const args = @import("../../../runtime/cold/argv/args.zig");

const manifest_prefix =
    \\{
    \\  "tool": "gist",
    \\  "version": "0.1.0",
    \\  "summary": "persistent trigram-indexed code locator for an agent's repeated exact-search loop",
    \\  "verbs": {
    \\    "index": {
    \\      "summary": "build and persist the trigram index and freshness anchor",
    \\      "args": [],
    \\      "flags": []
    \\    },
    \\    "status": {
    \\      "summary": "read-only index presence, size, age, counts, and roots",
    \\      "args": [],
    \\      "flags": [{"name": "--json", "type": "bool", "default": false, "description": "emit the versioned status snapshot instead of human prose"}],
    \\      "json_schema": {
    \\        "schema_version": "integer; currently 1",
    \\        "state": "\"ready\" | \"unavailable\"",
    \\        "index": "null | {path:string, paths_file:string, files_indexed:integer, distinct_trigrams:integer, postings:integer, index_bytes:integer, paths_bytes:integer}",
    \\        "freshness": "{anchor_unix_ns:null|integer, age_seconds:null|number}",
    \\        "roots": "string[]"
    \\      }
    \\    },
    \\    "codex": {
    \\      "summary": "the exact existence/count tier over the compressed self-index shelf: `build` persists it (codex.shelf); `count <text>` answers the corpus-wide occurrence count in O(|text|) with zero corpus I/O and zero false positives (exit 0 = present, 1 = absent); `tally <text> [--top N]` gives per-file counts heaviest-first; `status` reports size and freshness. Query verbs report how many files changed since the shelf was built.",
    \\      "args": [{"name": "verb", "type": "string", "required": true, "description": "build | count | tally | status"}, {"name": "text", "type": "string", "required": false, "description": "the literal text to count (count/tally)"}],
    \\      "flags": [{"name": "--json", "type": "bool", "default": false, "description": "versioned machine output"}, {"name": "--top", "type": "int", "default": 20, "description": "tally rows surfaced"}]
    \\    },
    \\    "similar": {"moved": "the relate binary owns this verb — see `relate --schema`"},
    \\    "dups": {"moved": "the relate binary owns this verb — see `relate --schema`"},
    \\    "patterns": {"moved": "the relate binary owns this verb — see `relate --schema`"}
    \\  },
    \\  "search": {
    \\    "summary": "gist <pattern> [PATH...] [flags] live-scans with ripgrep-like defaults and automatically uses a covering index only to elide provable non-candidate reads",
    \\    "args": [
    \\      {"name": "pattern", "type": "string", "required": true, "description": "literal or RE2-style regex"},
    \\      {"name": "PATH...", "type": "string[]", "required": false, "description": "positional search roots"}
    \\    ],
    \\    "flag_surface": "broad, tested ripgrep-compatible subset; not full ripgrep compatibility. Unsupported and unknown flags fail loud with exit 2.",
    \\    "ripgrep_compatibility": {
    \\      "source_of_truth": "src/runtime/cold/argv/args.zig:flag_catalog",
    \\      "unknown_flags": "unsupported-fail-loud",
    \\      "buckets": {
;

const manifest_suffix =
    \\      }
    \\    },
    \\    "native_additions": [
    \\      {"native": "--rank", "type": "int?", "default": 20, "description": "definition-first ranked view over the same regex + PATH scope as the line engine; optional =N caps top-K and requires an index"},
    \\      {"native": "--no-index", "type": "bool", "default": false, "description": "force the pure live walk"},
    \\      {"native": "--index", "type": "bool", "default": false, "description": "re-enable automatic index acceleration after --no-index"},
    \\      {"native": "--uncap", "type": "bool", "default": false, "description": "lift the ~25k-token (100 KiB) soft output cap for this query; the hard 256 MiB OOM ceiling still applies. Env: GIST_UNCAP=1, GIST_MAX_OUTPUT_TOKENS, GIST_MAX_OUTPUT_BYTES"}
    \\    ],
    \\    "alias": "gist rg [flags] <pattern> [PATH...] and gist search <pattern> [PATH...] address the same engine"
    \\  },
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "hints": {
    \\    "summary": "structured stderr guidance on notable outcomes: a no-match run gets a 'gist: no matches for ...' summary plus up to three ranked suggestion lines derived from the query's own shape (-i / -U / -F / -uu / scope); a truncated run gets the output-budget notice. Results on stdout are never touched.",
    \\    "channel": "stderr",
    \\    "grammar": ["gist: <outcome>", "gist: try <flag or move> — <why it applies>", "gist: note: <fact worth knowing>"],
    \\    "fires_on": ["no matches (exit 1)", "output truncated by the soft/hard budget"],
    \\    "suppressed_by": ["GIST_HINTS=0 (or false/no)", "--quiet", "--json", "--files"],
    \\    "env": {"GIST_HINTS": "0/false/no mutes the channel; unset or any other value keeps it on"}
    \\  },
    \\  "exit_codes": {"0": "search ran and matched, or an introspection action succeeded", "1": "search ran with no match", "2": "usage, parse, path, or unsupported-flag error"}
    \\}
    \\
;

const Bucket = struct {
    name: []const u8,
    compatibility: args.Compatibility,
};

const buckets = [_]Bucket{
    .{ .name = "supported", .compatibility = .supported },
    .{ .name = "supported-with-differences", .compatibility = .supported_with_differences },
    .{ .name = "accepted-but-ignored", .compatibility = .accepted_but_ignored },
    .{ .name = "unsupported-fail-loud", .compatibility = .unsupported_fail_loud },
};

fn appendJsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(a, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

fn appendSpec(a: std.mem.Allocator, out: *std.ArrayList(u8), spec: args.FlagSpec) !void {
    try out.appendSlice(a, "{\"spellings\":[");
    var first = true;
    if (spec.short) |short| {
        try appendJsonString(a, out, &.{ '-', short });
        first = false;
    }
    for (spec.longs) |long| {
        if (!first) try out.append(a, ',');
        try out.print(a, "\"--{s}\"", .{long});
        first = false;
    }
    try out.append(a, ']');
    if (spec.note) |note| {
        try out.appendSlice(a, ",\"note\":");
        try appendJsonString(a, out, note);
    }
    try out.append(a, '}');
}

fn render(a: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, manifest_prefix);
    for (buckets, 0..) |bucket, bucket_i| {
        if (bucket_i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "        ");
        try appendJsonString(a, &out, bucket.name);
        try out.appendSlice(a, ": [");
        var first = true;
        for (args.flag_catalog) |spec| {
            if (spec.compatibility != bucket.compatibility) continue;
            if (!first) try out.append(a, ',');
            try appendSpec(a, &out, spec);
            first = false;
        }
        try out.append(a, ']');
    }
    try out.append(a, '\n');
    try out.appendSlice(a, manifest_suffix);
    return out.toOwnedSlice(a);
}

/// Emit the JSON capability manifest to stdout.
pub fn emit() void {
    const a = std.heap.page_allocator;
    const manifest = render(a) catch {
        std.debug.print("gist: could not render --schema\n", .{});
        std.process.exit(2);
    };
    defer a.free(manifest);
    corpus_mod.emitStdout(manifest);
}

test "--schema is valid JSON derived from the parser catalog" {
    const t = std.testing;
    const manifest = try render(t.allocator);
    defer t.allocator.free(manifest);

    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, manifest, .{});
    defer parsed.deinit();
    for (buckets) |bucket| {
        try t.expect(std.mem.indexOf(u8, manifest, bucket.name) != null);
    }
    // Post-Unicode-flip: -i/-S/-w are `supported` (rg-parity) with Unicode by
    // default, no longer `supported_with_differences` for ASCII-only folding.
    try t.expect(std.mem.indexOf(u8, manifest, "Unicode case folding by default") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "ASCII-only case folding") == null);
    try t.expect(std.mem.indexOf(u8, manifest, "\\\\b/\\\\w") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "98" ++ ".6") == null);
    try t.expect(std.mem.indexOf(u8, manifest, "known " ++ "FAIL") == null);
}
