//! gist --schema — the deterministic, machine-readable capability manifest.
//!
//! Search compatibility is not prose copied from the parser. The four ripgrep
//! buckets are rendered directly from `surface/exec/cold/argv/args.zig`'s declarative
//! catalog, the same rows that build the short- and long-flag dispatch tables.
//! The hyperlink alias roster is rendered from `cli/beacon.zig`'s table for the
//! same reason: an agent cannot be told about a destination the parser rejects.

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const args = @import("../../../exec/cold/argv/args.zig");
const beacon = @import("../../../cli/beacon.zig");
const jsonstr = @import("../../../exec/cold/emit/jsonstr.zig");
const assay = @import("../../../../assay/assay.zig");

// Split at the version so the one number is interpolated from the engine's
// single source rather than hand-copied here — the drift `relate echoes` caught
// was exactly this literal claiming 0.1.0 against an engine at 0.2.0.
// The trailing separator is concatenated rather than typed so this manifest's
// `"key": value` spacing survives a formatter that eats trailing whitespace.
const manifest_head =
    \\{
    \\  "tool": "gist",
    \\  "version":
++ " ";

const manifest_prefix =
    \\,
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
    \\    "echoes": {"moved": "the relate binary owns this verb — see `relate --schema`"},
    \\    "patterns": {"moved": "the relate binary owns this verb — see `relate --schema`"}
    \\  },
    \\  "search": {
    \\    "summary": "gist <pattern> [PATH...] [flags] live-scans with ripgrep-like defaults and automatically uses a covering index only to elide provable non-candidate reads",
    \\    "args": [
    \\      {"name": "pattern", "type": "string", "required": true, "description": "literal or RE2-style regex"},
    \\      {"name": "PATH...", "type": "string[]", "required": false, "description": "positional search roots"}
    \\    ],
    \\    "flag_surface": "a tested ripgrep-compatible flag surface: every implemented flag matches ripgrep's behavior, except the `improvements` bucket where gist is strictly better (identical-or-superset results, faster, or more robust) — never a regression. Not every ripgrep flag is implemented; an unimplemented or unknown flag fails loud with exit 2.",
    \\    "ripgrep_compatibility": {
    \\      "source_of_truth": "src/surface/exec/cold/argv/args.zig:flag_catalog",
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
    \\      {"native": "--uncap", "type": "bool", "default": false, "description": "lift the ~25k-token (100 KiB) soft output cap for this query; the hard 256 MiB OOM ceiling still applies. Env: GIST_UNCAP=1, GIST_MAX_OUTPUT_TOKENS, GIST_MAX_OUTPUT_BYTES"},
    \\      {"native": "--buffer-size", "type": "size", "default": "64K", "description": "ceiling for the bytes the drain may hold, with an optional K/M/G suffix. Implies --block-buffered when no cadence was named, and sizes the line policy's tail when one was; 0 holds nothing, so every fragment is its own write. rg's block size is a fixed 8 KiB constant with no knob"},
    \\      {"native": "--plain", "type": "bool", "default": false, "description": "pin the answer to what a PIPE would receive even on a terminal: --color never, no long-line elision, block-buffered — so a terminal run and a redirected one differ in nothing the destination decides. Walk order is not one of those things: pin it with --sort path, as a piped run must"}
    \\    ],
    \\    "buffering": {
    \\      "summary": "when result bytes leave the process. Delivery cadence only: the emitted bytes are identical under every setting, and no policy is ever allowed to reorder them.",
    \\      "spellings": ["--line-buffered", "--block-buffered", "--buffer-size <SIZE>"],
    \\      "default": "auto — line on a terminal, block on a pipe or file (rg's rule)",
    \\      "line": "no finished line is held, but every finished line already in hand leaves in ONE write; rg's LineWriter pays one syscall per line. Splits on the run's real terminator, so --null-data records flush on NUL",
    \\      "block": "ramped: the first fragment is never held and the threshold then doubles from 1 KiB to the ceiling, so `| head -1` answers immediately and a closed pipe is discovered within a kilobyte; rg's BufWriter holds the first byte as long as the last"
    \\    },
    \\    "alias": "gist rg [flags] <pattern> [PATH...] and gist search <pattern> [PATH...] address the same engine"
    \\  },
    \\  "hyperlink": {
;

// The alias roster is rendered from `beacon.aliases` (the same table the parser
// resolves against), so an agent reading `--schema` can never be told about a
// destination the binary does not accept — or miss one it does.
const manifest_hyperlink_tail =
    \\    "summary": "OSC-8 click targets on printed locators. Default posture is auto: on when stdout is a terminal known to render OSC-8 and the output is human-shaped, off otherwise — so piped and redirected output is byte-identical to a run with the feature absent. --json and --null are byte protocols and never link under any posture; --vimgrep declines under auto but an explicit always is honored. Independent of --color/NO_COLOR.",
    \\    "spellings": ["--hyperlink[=auto|always|never|<alias>|<format>]", "--no-hyperlink", "--hyperlink-format <alias|format>", "--hostname-bin <cmd>"],
    \\    "format_variables": ["{path}", "{line}", "{column}", "{host}", "{wslprefix}"],
    \\    "format_rules": ["{path} is required", "{column} requires {line}", "the format must begin with a URL scheme", "{{ and }} are literal braces"],
    \\    "path_value": "absolute and lexically folded ('.'/'..' removed), percent-encoded per RFC 3986 with '/' ':' and bytes >= 0x80 left raw. Never canonicalized: no realpath(2) per matched file, and no symlink rewriting of the path you searched.",
    \\    "scope": {"default": "prefix", "values": ["path", "prefix", "row"], "env": "GIST_HYPERLINK_SCOPE"},
    \\    "env": {"GIST_HYPERLINK": "auto|always|never, an alias, a format, or a WHEN,WHERE pair such as 'always,vscode'. A preference rather than an act: naming only a destination here says WHERE and leaves the auto probe to say WHETHER (the flag turns links on). Honored by relate and irregex too.", "GIST_HYPERLINK_SCOPE": "path|prefix|row"},
    \\    "diagnose": "GIST_TRACE=link prints one line saying whether this run links and why"
    \\  },
    \\  "generate": {
    \\    "summary": "render this same surface for a human: `gist --generate <target>` writes the man page or a shell completion to stdout, from the flag catalog this manifest is built from. Every closed candidate set (221 file types, the WHATWG encoding labels, engines, sort keys, hyperlink aliases) is baked into the script at generation time, so a tab completion costs zero subprocesses.",
    \\    "targets": ["man", "complete-bash", "complete-zsh", "complete-fish", "complete-powershell"],
    \\    "spellings": ["--generate <target>", "--generate=<target>"],
    \\    "determinism": "a pure function of the surface plus --version, so a drift gate can diff the bytes"
    \\  },
    \\  "config": {
    \\    "summary": "two optional persisted layers, split by whether the fact belongs to the repository or to one reader. Every flag row above carries a `reach`, and each layer is ceilinged by it, so a persisted setting can be judged instead of trusted.",
    \\    "reach_vocabulary": {
    \\      "corpus": "which files and bytes the engine is allowed to see",
    \\      "semantics": "which lines count as a match",
    \\      "presentation": "how a match is rendered",
    \\      "execution": "only how the answer is computed, never what it is"
    \\    },
    \\    "layers": [
    \\      {
    \\        "name": "charter",
    \\        "path": ".irregex.toml",
    \\        "discovery": "from the working directory upward, stopping at the repository boundary, so a tree never inherits a parent's",
    \\        "committed": true,
    \\        "applies_to_you": true,
    \\        "format": "typed TOML keys, never argv",
    \\        "keys": {"roots": "string[] — what \"the corpus\" means here", "skip": "string[] — directory basenames the corpus walk never enters", "types": "string[] — --type-add specs applied before argv"},
    \\        "reach_ceiling": "corpus",
    \\        "precedence": "below GIST_ROOTS / GIST_SKIP, above the built-in defaults",
    \\        "source_of_truth": "src/corpus/scope/charter.zig"
    \\      },
    \\      {
    \\        "name": "preferences",
    \\        "path": "$GIST_PREFERENCES, else $XDG_CONFIG_HOME/gist/preferences, else ~/.config/gist/preferences",
    \\        "committed": false,
    \\        "applies_to_you": false,
    \\        "gate": "interactive terminal only — the same envelope that gates the answer keep, the resident daemon, and color; a pipe, a redirect, --json, a script, CI, and the daemon are all structurally outside it",
    \\        "format": "one flag per line, shell-tokenized (quotes are quotes), prepended to argv so anything typed still wins; a line that is not a known flag is a fatal error at read time",
    \\        "reach_ceiling": "semantics",
    \\        "source_of_truth": "src/surface/exec/cold/argv/preference.zig"
    \\      }
    \\    ],
    \\    "suppress": {"flag": "--no-config", "env": "GIST_NO_CONFIG=1", "when": "read from raw argv before either file is opened, and accepted anywhere any verb accepts flags", "affects": "what a search honors, not what a report may describe — gist config and gist status still name both files and mark the run suppressed"},
    \\    "inspect": {
    \\      "show": "gist config [--json] — the resolved stack: each layer's path, what it declares, whether it is in force, and the env vars that outrank it",
    \\      "check": "gist config check — validate both layers without running a search; reports both before exiting, 2 if either is malformed",
    \\      "init": "gist config init [--write] — write .irregex.toml prefilled from this machine's GIST_ROOTS and skips.list; lifts only asserted facts, never infers a skip from the tree",
    \\      "also": "gist status names both files and flags a malformed one"
    \\    },
    \\    "faults": "located (path:line) and quoted, with a nearest-name suggestion for an unknown charter key or flag; a malformed charter is fatal to a search, a malformed preferences file is fatal only to a run that would have used it",
    \\    "disclosure": "when a persisted flag could have changed the answer, a zero-match run names the file in the hint channel"
    \\  },
    \\  "output_stream": {"results": "stdout", "diagnostics": "stderr"},
    \\  "trace": {
    \\    "summary": "phase-trace diagnostics on stderr, off by default; on a --json run the stderr diagnostic is one NDJSON record, so timing is machine-parseable alongside stdout results",
    \\    "channel": "stderr",
    \\    "env": {"GIST_TRACE": "comma-separated lenses (amend,journal,reconcile,warm,rank,index,query,session,fault,link) or 'all'; off when unset", "GIST_TRACE_FORMAT": "text|json; defaults to the run's --json format"}
    \\  },
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
    .{ .name = "improvements", .compatibility = .improvement },
    .{ .name = "accepted-but-ignored", .compatibility = .accepted_but_ignored },
    .{ .name = "unsupported-fail-loud", .compatibility = .unsupported_fail_loud },
};

fn appendSpec(a: std.mem.Allocator, out: *std.ArrayList(u8), spec: args.FlagSpec) !void {
    try out.appendSlice(a, "{\"spellings\":[");
    var first = true;
    if (spec.short) |short| {
        jsonstr.write(out, a, &.{ '-', short });
        first = false;
    }
    for (spec.longs) |long| {
        if (!first) try out.append(a, ',');
        try out.print(a, "\"--{s}\"", .{long});
        first = false;
    }
    try out.append(a, ']');
    // How far the flag travels. An agent reading this manifest can tell, without
    // running anything, which flags could change ITS answer versus only how the
    // answer looks — and which ones a persisted config is allowed to carry.
    if (args.reachOf(spec)) |reach| try out.print(a, ",\"reach\":\"{t}\"", .{reach});
    if (spec.note) |note| {
        try out.appendSlice(a, ",\"note\":");
        jsonstr.write(out, a, note);
    }
    try out.append(a, '}');
}

fn render(a: std.mem.Allocator, version: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, manifest_head);
    jsonstr.write(&out, a, version);
    try out.appendSlice(a, manifest_prefix);
    for (buckets, 0..) |bucket, bucket_i| {
        if (bucket_i > 0) try out.appendSlice(a, ",\n");
        try out.appendSlice(a, "        ");
        jsonstr.write(&out, a, bucket.name);
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
    try out.appendSlice(a, "\n    \"aliases\": {");
    for (beacon.aliases, 0..) |x, i| {
        if (i > 0) try out.append(a, ',');
        jsonstr.write(&out, a, x.name);
        try out.append(a, ':');
        jsonstr.write(&out, a, if (x.format.len == 0) x.blurb else x.format);
    }
    try out.appendSlice(a, "},\n");
    try out.appendSlice(a, manifest_hyperlink_tail);
    return out.toOwnedSlice(a);
}

/// Emit the JSON capability manifest to stdout, stamped with `version` — the
/// same string `--version` prints, so the two can never disagree.
pub fn emit(version: []const u8) void {
    const a = std.heap.page_allocator;
    const manifest = render(a, version) catch {
        assay.diag("gist: could not render --schema\n", .{});
        std.process.exit(2);
    };
    defer a.free(manifest);
    corpus_mod.emitStdout(manifest);
}

test "--schema is valid JSON derived from the parser catalog" {
    const t = std.testing;
    const manifest = try render(t.allocator, "9.9.9");
    defer t.allocator.free(manifest);
    // The stamp is the caller's, not a literal in this file.
    try t.expect(std.mem.indexOf(u8, manifest, "\"version\": \"9.9.9\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, manifest, .{});
    defer parsed.deinit();
    for (buckets) |bucket| {
        try t.expect(std.mem.indexOf(u8, manifest, bucket.name) != null);
    }
    // Post-Unicode-flip: -i/-S/-w are `supported` (rg-parity) with Unicode by
    // default, no longer a divergence bucketed for ASCII-only folding.
    try t.expect(std.mem.indexOf(u8, manifest, "Unicode case folding by default") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "ASCII-only case folding") == null);
    try t.expect(std.mem.indexOf(u8, manifest, "\\\\b/\\\\w") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "98" ++ ".6") == null);
    try t.expect(std.mem.indexOf(u8, manifest, "known " ++ "FAIL") == null);

    // The advertised `source_of_truth` must name the LIVE catalog location, not
    // the pre-move `runtime/cold` path. `@embedFile` on the SAME relative path
    // the module imports (`args` above) is a COMPILE-TIME existence proof: if the
    // catalog is relocated again, this fails to build, forcing the public string
    // below to be updated in lockstep — the manifest can never silently outlive
    // its authority.
    comptime {
        _ = @embedFile("../../../exec/cold/argv/args.zig");
    }
    try t.expect(std.mem.indexOf(u8, manifest, "\"source_of_truth\": \"src/surface/exec/cold/argv/args.zig:flag_catalog\"") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "runtime/cold") == null); // no stale pre-move pointer survives

    // Same existence proof for the two config layers the manifest describes: an
    // agent is told which module decides each one, so relocating either fails
    // the build rather than leaving the manifest pointing at nothing.
    comptime {
        _ = @embedFile("../../../../corpus/scope/charter.zig");
        _ = @embedFile("../../../exec/cold/argv/preference.zig");
    }
    try t.expect(std.mem.indexOf(u8, manifest, "\"src/corpus/scope/charter.zig\"") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "\"src/surface/exec/cold/argv/preference.zig\"") != null);

    // The preference layer's whole safety argument is that it cannot reach a
    // non-interactive reader. If that claim is ever softened here, the manifest
    // would be advertising a promise the code no longer makes.
    const cfg = parsed.value.object.get("config").?.object;
    const layers = cfg.get("layers").?.array;
    try t.expectEqual(@as(usize, 2), layers.items.len);
    try t.expect(layers.items[0].object.get("applies_to_you").?.bool);
    try t.expect(!layers.items[1].object.get("applies_to_you").?.bool);
    // Every reach the flag rows can emit must be defined in the vocabulary an
    // agent reads them against.
    const vocab = cfg.get("reach_vocabulary").?.object;
    inline for (@typeInfo(args.Reach).@"enum".fields) |f| try t.expect(vocab.get(f.name) != null);
}
