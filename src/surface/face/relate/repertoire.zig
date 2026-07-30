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

const pack = @import("pack.zig");
const quote = @import("quote.zig");
const probe = @import("similar.zig");
const repeat = @import("echoes.zig");
const attribute = @import("patterns.zig");
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

/// One channel flag, one default per verb — the vocabulary is shared, the
/// default is the verb's own question (`similar` compares bytes, `echoes` looks
/// for the gap byte comparison cannot see).
fn channel_flag(default: []const u8) manifest.Flag {
    return .{
        .name = "--as",
        .kind = "string",
        .default = .{ .text = default },
        .doc = "kinship channel: copies (LZJD over raw bytes) | twins (bytes−structure gap: same skeleton, renamed vocabulary) | shapes (normalized-structure silhouette) | any (closest of either). the metric names bytes|echo|structure|fused are accepted as --lens aliases",
    };
}

const min_grade = manifest.Flag{
    .name = "--min-grade",
    .kind = "string",
    .doc = "withhold rows weaker than this calibrated grade: identical | strong | moderate | weak | none",
};

const unit_flag = manifest.Flag{
    .name = "--unit",
    .kind = "string",
    .default = .{ .text = "file" },
    .doc = "what a row IS: file | function (one fragment, so a cloned 12-line helper is visible where its containing files share 3% of their bytes) | match (a window around an exact hit; needs --matching)",
};

const min_lines = manifest.Flag{
    .name = "--min-lines",
    .kind = "int",
    .doc = "shortest fragment admitted to the population (default 5 for --unit function, 0 for files)",
};

const min_mass = manifest.Flag{
    .name = "--min-mass",
    .kind = "int",
    .doc = "smallest fingerprint sample admitted; below it two units land at distance ~0 by arithmetic, so the row would be a false identical (default scales with --unit)",
};

/// The exact filter, shared by every verb that can compose (ADR-367). The
/// patterns select; compression then reasons only inside what matched.
const matching = [_]manifest.Flag{
    .{ .name = "--matching/-e", .kind = "string[]", .doc = "run the exact engine first and ask this question only inside what matched (repeatable)" },
    .{ .name = "--match", .kind = "string", .default = .{ .text = "any" }, .doc = "candidate rule for --matching: any (>=1 pattern) | all (every pattern)" },
    .{ .name = "-F/--fixed-strings", .kind = "bool", .default = .{ .boolean = false }, .doc = "--matching patterns are literals" },
    .{ .name = "-i/--ignore-case", .kind = "bool", .default = .{ .boolean = false }, .doc = "case-insensitive --matching" },
};

pub const face = manifest.Face{
    .tool = "relate",
    .tagline = "relate — compression-as-search over the irregex primitives",
    .summary = "compression-as-search: one neighbor verb (similar — a path, a fragment, or text as the probe; kinship or coding-gain recall, chosen by the probe's shape), one repetition verb (echoes — unit x channel x shape, so pairs, fork families, function-level clones, and the distinct complement are one query), anti-redundant context packing (pack), corpus-global quotation (quote), multi-pattern attribution (patterns), and an owned warm tier (index/status). every query verb takes --matching to run the exact engine first and reason only inside what matched (ADR-367), and every kinship score carries a calibrated grade, so background never reads as a hit",
    .verbs = &.{
        .{
            .name = "similar",
            .asks = "one thing -> its neighbors",
            .form = "<path | path#Lnnn | text> [--as copies|twins|shapes|any]\n[--unit file|function] [--matching PAT]... [--min-grade G]\n[--top N] [--json] [--no-index] [ROOT...]",
            .blurb = "one probe, one ranked answer. a path scores kinship, `path#Lnnn`\nscores the function containing that line, bare text scores coding\ngain (recall) unless --as names a kinship channel",
            .summary = "what else is like this ONE thing, where the probe's SHAPE decides how it is priced: a path -> kinship over files; `path#Lnnn` -> the enclosing function compared against function fragments (so the answer is 'where else is this implementation', not 'which file resembles a function'); bare text -> the recall channel, coding gain against the corpus (higher is closer, the inverse of a distance, which is why it is its own channel with its own bands rather than a number in the distance column); text + --as -> kinship against the snippet, for 'what is shaped like this'. ranking always returns rows, so every row carries a calibrated grade, --min-grade withholds background, and an answer made only of background says so on stderr. sub-mass units stay out of the population entirely (two units too small to fingerprint land at distance ~0 by arithmetic, and a false identical is worse than no row); generated files stay IN, because a probe's generated twin is a legitimate answer. answers from the kinship atlas when one is fresh-foldable, live otherwise — identical answers",
            .args = &.{
                .{ .name = "probe", .required = true, .doc = "a file path, `path#Lnnn` for the function containing that line, or text" },
                roots_arg,
            },
            .flags = &.{
                channel_flag("copies (a record probe) | recall (bare text)"),
                unit_flag,
                matching[0],
                matching[1],
                matching[2],
                matching[3],
                min_grade,
                min_lines,
                min_mass,
                top(20),
                json("NDJSON {unit, distance|echo|gain, grade, channel} rows; a recall row adds cost_bits, bits_saved, factors, literals"),
                no_index,
            },
            .run = probe.runSimilar,
            .keeps = true,
        },
        .{
            .name = "echoes",
            .asks = "what repeats here",
            .form = "[--unit file|function|match] [--as copies|twins|shapes|any]\n[--shape pairs|families|distinct] [--max-distance T]\n[--min-echo E] [--min-size N] [--min-lines N] [--min-mass N]\n[--include-generated] [--matching PAT]... [--min-grade G]\n[--top N] [--brief] [--json] [--no-index] [ROOT...]",
            .blurb = "repetition along three axes: what a row IS (unit), which repetition\n(channel), and what the answer is FOR (pairs to inspect, families to\nact on, distinct for the complement). the default channel is the\nbytes−structure gap — the DRY signal byte kinship cannot see",
            .summary = "what repeats in this corpus, asked along three axes instead of through four verbs. UNIT: file | function (a fragment, so a 12-line helper cloned into six files is visible where the files share 3% of their bytes) | match (a window around an exact hit). CHANNEL: copies = copy-paste and its drift; shapes = shared skeleton regardless of vocabulary; twins = the DIFFERENCE bytes−structure, the Type-2-clone signal no other tool reports (same shape under renamed identifiers), self-calibrating per pair where structure distance alone has no clean absolute threshold. SHAPE: pairs = two things to inspect; families = the transitive closure, so a caller never re-runs union-find over a pair list; distinct = the complement, turning 'which of these 14 implementations is genuinely unique' into a measurement with each unit's nearest miss priced. the retired verbs are single flag combinations: dups = --as copies, clusters = --as copies --shape families, concepts = --as shapes --shape families --unit function. codegen and sub-mass units are withheld from the population uniformly (a generated pair is never a refactor candidate — the fix lives in the template — and an 86-member family of one-line re-exports at distance 0.0000 is arithmetic); --include-generated turns the sweep into a drift audit",
            .args = &.{roots_arg},
            .flags = &.{
                unit_flag,
                channel_flag("twins"),
                .{ .name = "--shape", .kind = "string", .default = .{ .text = "pairs" }, .doc = "what the answer is for: pairs | families (transitive closure) | distinct (the complement: units with no relative, each with its nearest miss)" },
                .{ .name = "--max-distance", .kind = "float", .default = .{ .float = 0.25 }, .doc = "edge admission for the distance channels (copies/shapes/any), in [0,1]" },
                .{ .name = "--min-echo", .kind = "float", .default = .{ .float = 0.15 }, .doc = "edge admission for the gap channel (twins): smallest bytes−structure gap, in [0,1]" },
                .{ .name = "--min-size", .kind = "int", .default = .{ .int = 2 }, .doc = "smallest family surfaced" },
                min_lines,
                min_mass,
                .{ .name = "--include-generated", .kind = "bool", .default = .{ .boolean = false }, .doc = "keep generated files in the population — a codegen drift audit rather than a refactor sweep" },
                matching[0],
                matching[1],
                matching[2],
                matching[3],
                .{ .name = "-C", .kind = "int", .default = .{ .int = 3 }, .doc = "lines of context around each hit for --unit match" },
                min_grade,
                .{ .name = "--top", .kind = "int", .default = .{ .int = 50 }, .doc = "rows surfaced" },
                .{ .name = "--brief", .kind = "bool", .default = .{ .boolean = false }, .doc = "one line per family: shape + exemplar + (+k more)" },
                json("NDJSON pair rows {a, b, distance|echo, bytes, structure, grade}, family rows {size, repeated_lines, distance|echo, bytes, structure, grade, members[]}, or distinct rows {unit, nearest, bytes, structure}"),
                no_index,
            },
            .run = repeat.runEchoes,
            .keeps = true,
        },
        .{
            .name = "pack",
            .asks = "compact non-redundant context",
            .form = "<text> [--matching PAT]... [--match any|all] [-F] [-i]\n[--top N] [--json] [ROOT...]",
            .blurb = "set-valued context; each pick pays only for bits not covered earlier.\n--matching prices novelty inside the exact filter, and every pick\nnames the patterns that admitted it",
            .summary = "the SET of files that jointly describes <text> cheapest — greedy max-coverage over corpus-priced query chunks from the persisted codebook; each pick's marginal_bits is exactly what it adds beyond earlier picks. with --matching the lexicon is built from ONLY the files the patterns admitted, so novelty is priced inside the matching set and a file that never matched can never be picked (this is what `irregex context` was); the admitting patterns and the marginal bits stay in separate columns, never fused",
            .args = &.{ .{ .name = "text", .required = true, .doc = "the query text" }, roots_arg },
            .flags = &.{
                matching[0],
                matching[1],
                matching[2],
                matching[3],
                .{ .name = "--top", .kind = "int", .default = .{ .int = 8 }, .doc = "maximum files picked (stops early when nothing adds bits)" },
                json("NDJSON {rank, path, marginal_bits, coverage} rows in pick order; narrowed rows add patterns[]"),
            },
            .run = pack.runPack,
            .keeps = true,
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
            .keeps = true,
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
            .run = attribute.runPatterns,
            .keeps = true,
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
    .retired = &.{
        .{
            .name = "search",
            .now = "similar <text>",
            .because = "one probe verb: bare text scores the recall channel, a path scores kinship — the split forced you to know which one your question was before asking it",
        },
        .{
            .name = "dups",
            .now = "echoes --as copies",
            .because = "a channel is a flag, not a verb",
        },
        .{
            .name = "clusters",
            .now = "echoes --as copies --shape families",
            .because = "a shape is a flag, not a verb",
        },
        .{
            .name = "concepts",
            .now = "echoes --as shapes --shape families --unit function",
            .because = "the comparison unit is a flag; every axis of a repetition question now composes with every other",
        },
    },
    .notes = &.{
        .{ .key = "channels", .text = "one vocabulary across every kinship verb: copies (LZJD over raw bytes) | twins (byte−structure gap: same skeleton, renamed vocabulary) | shapes (normalized-structure silhouette) | any (min of copies and shapes). copies/shapes/any score a DISTANCE (lower is closer, admitted by --max-distance); twins scores a GAP (higher is stronger, admitted by --min-echo)" },
        .{ .key = "grades", .text = "every score is banded so a caller can tell a finding from background: distances grade identical <=0.05, strong <=0.25, moderate <=0.50, weak <=0.75, none above; gaps (twins) grade strong >=0.45, moderate >=0.30, weak >=0.15, none below, and never reach identical because byte-identical files have a zero gap; recall gains grade identical >=0.90, strong >=0.60, moderate >=0.45, weak >=0.30. --min-grade withholds weaker rows, and an answer that is entirely background explains itself on stderr (silenced by GIST_HINTS=0)" },
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
    \\  copies    (bytes)      verbatim duplication and its drift
    \\  twins     (echo)       same skeleton, renamed vocabulary — the DRY signal
    \\  shapes    (structure)  shared skeleton, vocabulary irrelevant
    \\  any       (fused)      whichever channel sees the stronger relation
    \\  recall                 coding gain of text against the corpus (bare-text probe)
    \\
    \\grades — how much a score is worth, so background never reads as a hit:
    \\  distances   identical <=0.05 · strong <=0.25 · moderate <=0.50 · weak <=0.75
    \\  gaps        strong >=0.45 · moderate >=0.30 · weak >=0.15
    \\  gains       identical >=0.90 · strong >=0.60 · moderate >=0.45 · weak >=0.30
    \\  --min-grade G   withhold rows weaker than G (empty beats noise)
    \\  GIST_HINTS=0    mute the stderr verdict for byte-counting captures
    \\
    \\the three axes of `echoes` — one query per question, not one verb per corner:
    \\  --unit file|function|match     what a row IS
    \\  --as copies|twins|shapes|any   which repetition
    \\  --shape pairs|families|distinct  what the answer is FOR
    \\  e.g.  --unit function --as copies --shape families   cloned implementations
    \\        --unit file --as twins                          abstraction candidates
    \\        --shape distinct                                the genuinely unique ones
    \\
    \\niche choices:
    \\  similar <path> vs <text>  kinship against a record vs recall against the corpus
    \\  similar path#Lnnn         compare THIS function, not its containing file
    \\  similar vs pack           independent ranking vs jointly useful context
    \\  --matching PAT            exact first, compression inside the matches (ADR-367)
    \\  --include-generated       codegen drift audit instead of a refactor sweep
    \\  --no-index                live differential oracle for atlas-backed verbs
    \\  ROOT...                   scope the index corpus; quote always uses the whole shelf
    \\  --json                    deterministic NDJSON on stdout; diagnostics stay on stderr
    \\
    \\lifecycle notes:
    \\  missing/corrupt atlas     answer live; acceleration never changes results
    \\  recall / pack             reuse Gist's mmap-backed trigram codebook
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

test "relate --schema is valid JSON naming all seven verbs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    manifest.schema(&buf, a, face, "0.2.0");

    const parsed = try std.json.parseFromSlice(std.json.Value, a, buf.items, .{});
    const rendered = parsed.value.object.get("verbs").?.object;
    try t.expectEqualStrings("relate", parsed.value.object.get("tool").?.string);
    for ([_][]const u8{ "similar", "echoes", "pack", "quote", "patterns", "index", "status" }) |v| {
        try t.expect(rendered.contains(v));
    }
    try t.expectEqual(@as(usize, 7), rendered.count());
}

test "each absorbed verb is retired with a runnable replacement, not just deleted" {
    // The fold's contract: the name is not a verb any more (so nothing dispatches
    // it on stale semantics), and the manifest still says what to run instead.
    const folds = [_]struct { name: []const u8, has: []const u8 }{
        .{ .name = "search", .has = "similar" },
        .{ .name = "dups", .has = "echoes --as copies" },
        .{ .name = "clusters", .has = "--shape families" },
        .{ .name = "concepts", .has = "--unit function" },
    };
    for (folds) |f| {
        try t.expect(face.find(f.name) == null);
        const r = face.folded(f.name).?;
        try t.expect(std.mem.indexOf(u8, r.now, f.has) != null);
        try t.expect(r.because.len > 0);
        // The replacement must name a verb this face actually has, or the
        // coaching line sends the caller into another unknown-verb wall.
        var it = std.mem.splitScalar(u8, r.now, ' ');
        try t.expect(face.find(it.first()) != null);
    }
}

test "every composing verb offers the same exact-filter surface" {
    // ADR-367 as a modifier: --matching means one thing across the face, so a
    // caller who learned it on `pack` can use it on `similar` and `echoes`.
    for ([_][]const u8{ "similar", "echoes", "pack" }) |name| {
        const v = face.find(name).?;
        var found = false;
        for (v.flags) |f| found = found or std.mem.eql(u8, f.name, "--matching/-e");
        try t.expect(found);
    }
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
    // `similar` and another on `echoes` because they were written separately.
    const shared = [_][]const u8{ "--no-index", "--min-grade", "--unit", "--min-mass", "--matching/-e", "--match" };
    for (shared) |name| {
        var doc: ?[]const u8 = null;
        var seen: usize = 0;
        for (face.verbs) |v| for (v.flags) |f| {
            if (!std.mem.eql(u8, f.name, name)) continue;
            seen += 1;
            if (doc) |d| try t.expectEqualStrings(d, f.doc) else doc = f.doc;
        };
        try t.expect(seen >= 2); // otherwise this row proves nothing
    }
}
