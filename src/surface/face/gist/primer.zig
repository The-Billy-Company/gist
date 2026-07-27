//! gist, described once — the surface the manual and all four completions are
//! rendered from.
//!
//! Nothing here is a second description of the CLI. Every option comes out of
//! `flag_catalog`, the table `grammar.zig` dispatches argv on; every candidate
//! set comes out of the table the parser validates against — the type registry
//! `-t` resolves, the WHATWG label table `-E` resolves, the alias roster
//! `--hyperlink` resolves. Three derivations turn that parse table into a
//! surface a human reads:
//!
//!   * [`valueOf`] — what a flag takes, keyed off the ACTION rather than a
//!     hand-kept list, so a shell never offers a filename after a switch;
//!   * [`rivalOf`] — what a flag rules out, derived from the `Opts` field the
//!     action writes, so two flags that fight in the parser fight in the menu;
//!   * [`groupOf`] — where it belongs, from the `Reach` the parser already
//!     records to decide what a persisted setting may do.
//!
//! All three are exhaustive switches over `Act`, so a new action is a compile
//! error here until someone says what it takes, what it displaces, and how far
//! it travels. That is the difference between this and ripgrep's completions:
//! rg's zsh function is hand-written and ships a CI script whose job is to
//! catch the drift; here the drift has nowhere to live.

const std = @import("std");
const beacon = @import("../../cli/beacon.zig");
const catalog = @import("../../exec/cold/argv/catalog.zig");
const encoding = @import("../../exec/cold/read/encoding.zig");
const intent = @import("../../exec/cold/argv/intent.zig");
const oom = @import("../../cli/outcome.zig").oom;
const primer = @import("../../cli/primer/primer.zig");
const types = @import("../../../corpus/scope/types.zig");

const Act = catalog.Act;
const Choice = primer.Choice;
const Opt = primer.Opt;
const Value = primer.Value;

// ── closed candidate sets ────────────────────────────────────────────────

/// Every variant of `E`, glossed. `gloss` is a switch at the call site, so an
/// enum that grows a variant fails to compile until the menu explains it — the
/// same fail-closed shape `fieldReach` uses one axis over.
fn variants(comptime E: type, comptime gloss: fn (E) []const u8) []const Choice {
    comptime {
        var out: [@typeInfo(E).@"enum".fields.len]Choice = undefined;
        for (@typeInfo(E).@"enum".fields, &out) |f, *slot|
            slot.* = .{ .word = f.name, .doc = gloss(@field(E, f.name)) };
        const frozen = out;
        return &frozen;
    }
}

const when = variants(intent.ColorChoice, struct {
    fn g(c: intent.ColorChoice) []const u8 {
        return switch (c) {
            .auto => "colorize only a terminal that has not opted out",
            .always => "colorize regardless of destination",
            .never => "never colorize",
            .ansi => "always, and with ANSI escapes even on Windows",
        };
    }
}.g);

const engines = variants(intent.Engine, struct {
    fn g(e: intent.Engine) []const u8 {
        return switch (e) {
            .default => "the linear engine — no backtracking, no catastrophic case",
            .pcre2 => "the vendored PCRE2 JIT — lookaround and backreferences",
            .auto => "linear, escalating to PCRE2 only when the pattern needs it",
        };
    }
}.g);

const sort_keys = variants(intent.SortKey, struct {
    fn g(k: intent.SortKey) []const u8 {
        return switch (k) {
            .none => "no ordering — the fastest discovery order",
            .path => "by display path",
            .modified => "by mtime",
            .accessed => "by atime",
            .created => "by birth time, falling back to ctime",
        };
    }
}.g);

const postures = variants(beacon.When, struct {
    fn g(w: beacon.When) []const u8 {
        return switch (w) {
            .auto => "link only where the terminal is known to render OSC-8",
            .always => "link regardless of terminal",
            .never => "never link",
        };
    }
}.g);

/// What `--generate` can mint, glossed — the menu for the flag that writes the
/// menus. Derived from `primer.Target`, the same enum `--generate` parses its
/// argument with, so the offer and the acceptance cannot disagree and a sixth
/// target is a compile error here until it is explained. ripgrep's zsh
/// completion spells these five out by hand and its fish completion repeats the
/// flag's own sentence five times.
const generate_targets = variants(primer.Target, struct {
    fn g(target: primer.Target) []const u8 {
        return switch (target) {
            .man => "the gist(1) manual, in roff",
            .@"complete-bash" => "bash completion (bash-completion 2.x autoloads it)",
            .@"complete-zsh" => "zsh completion, grouped by what a flag changes",
            .@"complete-fish" => "fish completion",
            .@"complete-powershell" => "PowerShell completion, to dot-source from $PROFILE",
        };
    }
}.g);

/// `--hyperlink` spans one axis in three spellings, so its menu is the posture
/// vocabulary and the editor roster in one list — which is the whole reason it
/// is one flag here and two flags plus a memorized alias in ripgrep.
fn linkChoices(gpa: std.mem.Allocator) []const Choice {
    var out: std.ArrayList(Choice) = .empty;
    out.appendSlice(gpa, postures) catch oom();
    for (beacon.aliases) |a| out.append(gpa, .{ .word = a.name, .doc = a.blurb }) catch oom();
    return out.items;
}

/// How many of a type's globs a menu column shows before it stops being a
/// column. `gist --type-list` prints them in full.
const glob_preview = 4;

/// The file-type registry, one candidate per accepted name — aliases included,
/// since `-t rs` and `-t rust` are both things a caller types.
///
/// ripgrep's zsh completion answers this tab by forking `rg --type-list` and
/// re-parsing it, *per keystroke*. The registry is a comptime table on both
/// sides; the only reason to fetch it at tab time is not having read it at
/// generation time.
fn typeChoices(gpa: std.mem.Allocator) []const Choice {
    var out: std.ArrayList(Choice) = .empty;
    out.append(gpa, .{ .word = "all", .doc = "every type in the registry" }) catch oom();
    for (types.type_table) |row| {
        var gloss: std.ArrayList(u8) = .empty;
        for (row.globs, 0..) |g, i| {
            if (i == glob_preview) {
                gloss.print(gpa, " +{d} more", .{row.globs.len - i}) catch oom();
                break;
            }
            if (i > 0) gloss.append(gpa, ' ') catch oom();
            gloss.appendSlice(gpa, g) catch oom();
        }
        // Aliases share one row and therefore one gloss slice — the same
        // comptime deduplication the registry itself relies on.
        for (row.names) |name| out.append(gpa, .{ .word = name, .doc = gloss.items }) catch oom();
    }
    return out.items;
}

/// Every WHATWG label `-E` resolves, glossed with the encoding it lands on —
/// so picking `sjis` out of 221 labels is a menu rather than a memory test.
fn encodingChoices(gpa: std.mem.Allocator) []const Choice {
    var out: std.ArrayList(Choice) = .empty;
    out.append(gpa, .{ .word = "auto", .doc = "sniff a BOM, else treat the bytes as UTF-8" }) catch oom();
    out.append(gpa, .{ .word = "none", .doc = "no transcoding at all, not even a BOM sniff" }) catch oom();
    for (encoding.labels) |e| {
        const canonical = std.mem.replaceOwned(u8, gpa, e.tag, "_", "-") catch oom();
        out.append(gpa, .{ .word = e.label, .doc = canonical }) catch oom();
    }
    return out.items;
}

/// The three sets that cannot be comptime literals — each built once and shared
/// by every flag that offers it, so `-t` and `-T` bake one table between them.
const Baked = struct { types: []const Choice, encodings: []const Choice, links: []const Choice };

// ── what a flag takes ────────────────────────────────────────────────────

/// The value `spec` consumes, or null for a switch.
///
/// Exhaustive over `Act` on purpose. ripgrep's *generated* bash completion
/// offers `compgen -f` after `--word-regexp`, because its generator cannot tell
/// a switch from a value-taking option; the parser's own action union can, and
/// this is the one place that knowledge is read.
fn valueOf(spec: catalog.FlagSpec, baked: Baked) ?Value {
    return switch (spec.action) {
        .set, .unset, .set_many, .filename, .case, .locate, .boundary, .mode, .mode_off, .passthru, .sort_files, .glob_ci, .no_ctxsep, .pretty, .plain, .engine_is, .encoding_is, .pre_off, .buffered, .noop, .no_config, .unsupported => null,
        // `-u`/`-uu`/`-uuu` is a tier counted by repetition, not a value.
        .unrestrict => null,
        .set_num, .num_set, .ctx_at => .{ .name = "NUM", .of = .number },
        .set_str => |f| switch (f) {
            .pre, .hostname_bin => .{ .name = "COMMAND", .of = .command },
            else => .{ .name = "SEPARATOR" },
        },
        .sep => .{ .name = "SEPARATOR" },
        .maxfsize, .bufsize => .{ .name = "SIZE" },
        .sort => .{ .name = "SORTKEY", .of = .{ .listed = sort_keys } },
        .regexp => .{ .name = "PATTERN", .many = true },
        .typ => .{ .name = "TYPE", .of = .{ .listed = baked.types }, .many = true },
        .glob, .pre_glob => .{ .name = "GLOB", .of = .glob, .many = true },
        .replace => .{ .name = "TEXT" },
        .file, .ignore_file => .{ .name = "FILE", .of = .file, .many = true },
        .type_add => .{ .name = "TYPESPEC", .many = true },
        .type_clear => .{ .name = "TYPE", .of = .{ .listed = baked.types }, .many = true },
        .color => .{ .name = "WHEN", .of = .{ .listed = when } },
        // A bare `--hyperlink` is legal and must not eat the next word — that
        // word is the pattern. `--hyperlink-format` is rg's spelling and takes
        // its value the ordinary way.
        .hyperlink => |how| switch (how) {
            .off => null,
            .flag => .{ .name = "TARGET", .of = .{ .listed = baked.links }, .glued = true },
            .format => .{ .name = "TARGET", .of = .{ .listed = baked.links } },
        },
        .encoding => .{ .name = "ENCODING", .of = .{ .listed = baked.encodings } },
        .rank => .{ .name = "N", .of = .number, .glued = true },
        .engine => .{ .name = "ENGINE", .of = .{ .listed = engines } },
        .colors => .{ .name = "SPEC" },
        .noop_val => .{ .name = "VALUE" },
    };
}

// ── what a flag rules out ────────────────────────────────────────────────

/// The rivalry `spec` belongs to: options that write the same piece of parse
/// state, so choosing one is choosing against the others.
///
/// Keyed on the `Opts` field the action lands, which makes the derivation exact
/// rather than editorial — `--heading`/`--no-heading` are rivals because they
/// assign the same bool, and `--context-separator`/`--no-context-separator`
/// because they assign the same string. ripgrep hand-maintains these lists.
///
/// Three deliberate abstentions, each because the parser genuinely allows the
/// combination: a repeatable option (ruled out by `many` instead), a
/// multi-field alias like `--multiline-dotall` (which implies `-U` rather than
/// fighting it), and `-A`/`-B`, which coexist and only jointly outrank `-C`.
fn rivalOf(spec: catalog.FlagSpec) []const u8 {
    return switch (spec.action) {
        .set, .unset, .set_num, .set_str, .sep => |f| @tagName(f),
        .num_set => |p| @tagName(p[0]),
        .case => "case",
        .boundary => "boundary",
        .filename => "filename",
        .locate => |l| switch (l) {
            .line_on, .line_off => "line_num",
            .column_on, .column_off => "column",
            .heading_on, .heading_off => "heading",
        },
        .mode, .mode_off => "mode",
        .sort, .sort_files => "sort_key",
        .maxfsize => "max_filesize",
        .no_ctxsep => "ctx_sep",
        .replace => "replace",
        .color => "color",
        // The two presentation poles are each other's opposite — but neither is
        // a rival of `--color`, which is documented to win when spelled after.
        .pretty, .plain => "posture",
        .hyperlink => "hyperlink",
        .encoding, .encoding_is => "encoding",
        .engine, .engine_is => "engine",
        .buffered => "buffering",
        .rank => "rank",
        // `--no-pre` is `--pre`'s rival even though `--pre` is a `.set_str` row:
        // both write `pre`, and the tag name is how that rivalry is spelled.
        .pre_off => "pre",
        .set_many, .unrestrict, .passthru, .ctx_at, .glob_ci, .regexp, .typ, .glob, .file, .ignore_file, .type_add, .type_clear, .pre_glob, .bufsize, .colors, .noop, .noop_val, .no_config, .unsupported => "",
    };
}

// ── where a flag belongs ─────────────────────────────────────────────────

const groups = [_]primer.Group{
    .{ .key = "corpus", .title = "Corpus — which bytes are searched", .blurb = "Which files, and which of their bytes, the engine is given to read." },
    .{ .key = "semantics", .title = "Semantics — what counts as a match", .blurb = "Given those bytes, which lines match. These are the flags that can change your answer." },
    .{ .key = "presentation", .title = "Presentation — how the answer is shown", .blurb = "How the matches are written out. The match set itself is untouched." },
    .{ .key = "execution", .title = "Execution — how it is computed", .blurb = "Nothing about the answer — only how many cores, syscalls, or elided reads it takes to produce it." },
    .{ .key = "config", .title = "Configuration — read before the run", .blurb = "Honored before argv parsing begins, so they can suppress what would otherwise have supplied flags." },
    .{ .key = "about", .title = "About — ask the binary instead of searching", .blurb = "These replace the search rather than shaping it: each one answers a question about gist itself and exits." },
};

/// The section `spec` is filed under: the `Reach` the parser already records.
/// A flag that never takes effect at all (it is read before argv parsing, or it
/// fails loud) has no reach and is filed as configuration.
fn groupOf(spec: catalog.FlagSpec) []const u8 {
    return if (catalog.reachOf(spec)) |r| @tagName(r) else "config";
}

// ── prose the flag table cannot hold ─────────────────────────────────────

/// Two subjects an option list is the wrong shape for.
///
/// Configuration earns a section because `--no-config` is otherwise the only
/// mention of two files it suppresses, which a reader finds only by already
/// knowing to look. Completion earns one because a manual that was itself minted
/// by `--generate` should say how to install its siblings.
///
/// Automatic filtering deliberately gets no section, though ripgrep devotes one
/// to it: those flags are already collected under "Corpus" with a blurb saying
/// what the section is for. rg needs the prose because its options are
/// alphabetical, so the filtering story is scattered across the page.
const sections = [_]primer.Section{
    .{ .title = "CONFIGURATION FILES", .paragraphs = &.{
        "Two files, split along a line ripgrep's .ripgreprc does not draw: what the tree IS, versus what one reader likes to look at. Neither is required, and --no-config (or GIST_NO_CONFIG=1) ignores both.",
        ".irregex.toml, committed at the tree root, holds facts about the repository every clone should agree on. It carries no argv, only typed keys — roots, skip, and types — and all three faces honor it. Discovery climbs from the working directory and stops at the repository boundary, so a tree without its own declaration never inherits a parent directory's. It is ceilinged at corpus reach: a shared file may say what the repository is, and may never quietly change what matches for the people who clone it.",
        "$XDG_CONFIG_HOME/gist/preferences is machine-local and never committed ($GIST_PREFERENCES overrides the path). It is flag lines, one per line, prepended to argv, so anything typed still wins. Lines are tokenized with shell quoting — ripgrep's are verbatim argv elements, which is why a quoted glob there arrives with its quotes and matches nothing — every flag is checked against the catalog as the file is read, and a line not starting with a flag is refused, because a stray bare word in a persisted argv file is the search pattern for every invocation forever.",
        "Preferences apply only when stdout is an interactive terminal. That is the same envelope gist already draws for the answer keep, the resident session, and color resolution, which puts a pipe, a redirect, --json, a script, CI, and every agent structurally outside their reach — so none of them ever needs --no-config to be sure what it will get.",
    } },
    .{ .title = "SHELL COMPLETION", .paragraphs = &.{
        "This page and the completions for bash, zsh, fish, and PowerShell are all minted by gist --generate, each a rendering of the same table the parser dispatches argv on. A flag therefore cannot exist in the binary and be missing from a menu.",
        "Every closed value set — the file-type registry behind -t, the WHATWG labels behind -E, the sort keys, the engines, the hyperlink aliases — is written into the completion when it is generated. A tab costs no subprocess, where ripgrep's zsh function answers -t by running rg --type-list and re-parsing it on every keystroke. The zsh completion additionally groups its candidates by what a flag changes and withholds the flags a chosen flag rules out, both derived rather than hand-kept.",
        "Regenerate after upgrading gist, since the menus are a snapshot of the binary that wrote them: make install-gist does this and installs all five artifacts under the XDG directories.",
    } },
};

// ── the surface ──────────────────────────────────────────────────────────

/// The four that never reach the parse table.
///
/// `main.zig` answers these before `flag_catalog` is consulted, because each one
/// replaces the search instead of configuring it. That makes this the one place
/// in the surface not derived from the catalog — so it is written out rather
/// than inferred, and `lifecycleIsExhaustive` holds it to what `main` accepts.
/// The alternative, filing them in the catalog as actions the grammar never
/// dispatches, would put a lie in the table every other derivation reads.
const lifecycle = [_]Opt{
    .{ .short = 'h', .longs = &.{"help"}, .group = "about", .doc = "print the usage summary and exit" },
    .{ .short = 'V', .longs = &.{"version"}, .group = "about", .doc = "print the version and exit" },
    .{ .longs = &.{"schema"}, .group = "about", .native = true, .doc = "the exhaustive JSON surface manifest, for an agent or a codegen step", .note = "Machine-readable sibling of this manual: every flag, its value kind, and its ripgrep compatibility, rendered from the same table." },
    .{ .longs = &.{"generate"}, .group = "about", .native = true, .doc = "mint the manual or a shell completion, and exit", .value = .{ .name = "TARGET", .of = .{ .listed = generate_targets } }, .note = "Every artifact is a rendering of this same surface, so a flag cannot exist in the parser and be missing from a menu. Each closed value set is baked in at generation, so a tab costs no subprocess." },
};

fn options(gpa: std.mem.Allocator) []const Opt {
    const baked = Baked{
        .types = typeChoices(gpa),
        .encodings = encodingChoices(gpa),
        .links = linkChoices(gpa),
    };
    var out: std.ArrayList(Opt) = .empty;
    for (catalog.flag_catalog) |spec| out.append(gpa, .{
        .short = spec.short,
        .longs = spec.longs,
        .doc = spec.doc,
        .group = groupOf(spec),
        .value = valueOf(spec, baked),
        .note = spec.note,
        .rival = rivalOf(spec),
        .native = spec.compatibility == .native,
    }) catch oom();
    out.appendSlice(gpa, &lifecycle) catch oom();
    return out.items;
}

/// gist's surface, allocated in `gpa` (an arena at every call site — the whole
/// value is written once and rendered once).
pub fn surface(gpa: std.mem.Allocator) primer.Surface {
    return .{
        .tool = "gist",
        .tagline = "indexed regex code search with ripgrep's grammar",
        .synopsis = &.{
            "[OPTIONS] PATTERN [PATH...]",
            "index [ROOT...]",
            "status [--json]",
            "serve [ROOT...]",
            "codex build|count|tally|status [TEXT]",
        },
        .description = &.{
            "gist searches the tree for PATTERN and prints the matching lines. It is a byte-for-byte drop-in for ripgrep's default behavior — the same flags, the same gitignore and hidden-file precedence, the same 0/1/2 exit codes — riding a persisted trigram index that lets it skip reading files no match can be in.",
            "No setup is required. With no index, gist live-scans and answers exactly what a walk would; with a current index, it answers the same bytes faster by eliding provably non-candidate reads. Acceleration is never allowed to change output, and --no-index forces the pure walk if you want to see that for yourself.",
            "Beyond parity, gist adds the shapes ripgrep cannot express: --rank puts a symbol's definition above its call sites and sinks generated files, -P rides a trigram-prefiltered PCRE2 so lookaround and backreferences stay indexed, and a resident session answers repeat queries without paying process startup.",
            "The options below are grouped by what a flag CHANGES, not by spelling, because that is the question a reader arrives with. The four sections are the same reach classification the parser uses to decide what a persisted configuration file is allowed to say.",
        },
        .groups = &groups,
        .opts = options(gpa),
        .verbs = &.{
            .{ .name = "index", .doc = "build and persist the trigram index over ROOT (default: this tree)" },
            .{ .name = "status", .doc = "is an index ready, how fresh, how big" },
            .{ .name = "serve", .doc = "run the resident warm session (auto-spawned; run it to scope the roots)" },
            .{ .name = "codex", .doc = "exact corpus-wide literal counts off the compressed self-index", .sub = &.{
                .{ .word = "build", .doc = "persist the codex shelf" },
                .{ .word = "count", .doc = "corpus-wide occurrences of a literal, with no corpus I/O" },
                .{ .word = "tally", .doc = "per-file counts, heaviest first" },
                .{ .word = "status", .doc = "shelf size and freshness" },
            } },
            .{ .name = "search", .doc = "the ordinary search, addressed with a verb" },
            .{ .name = "rg", .doc = "the same engine under the name an alias would give it" },
        },
        .sections = &sections,
        .env = &.{
            .{ .word = "GIST_DIR", .doc = "artifact home for the index and the atlas (default .local/gist-verify)" },
            .{ .word = "GIST_ROOTS", .doc = "the roots to index when none are given" },
            .{ .word = "GIST_SKIP", .doc = "extra directories to prune from the index and freshness walks" },
            .{ .word = "GIST_HINTS", .doc = "0 mutes the stderr guidance channel; results are untouched either way" },
            .{ .word = "GIST_UNCAP", .doc = "1 lifts the soft output budget, as --uncap does per-query" },
            .{ .word = "GIST_MAX_OUTPUT_TOKENS", .doc = "resize the soft output budget, in tokens" },
            .{ .word = "GIST_MAX_OUTPUT_BYTES", .doc = "resize the soft output budget, in bytes" },
            .{ .word = "GIST_TRACE", .doc = "comma-separated phase lenses (amend, journal, reconcile, warm, rank, index, query, session, fault, link) or all" },
            .{ .word = "GIST_TRACE_FORMAT", .doc = "text or json; defaults to the run's own --json setting" },
            .{ .word = "GIST_NO_AUTOSERVE", .doc = "1 declines the automatic resident session" },
            .{ .word = "GIST_NO_CONFIG", .doc = "1 ignores the committed charter and the personal preferences file" },
            .{ .word = "NO_COLOR", .doc = "any value turns colorization off, as --color never does" },
        },
        .examples = &.{
            .{ .cmd = "gist WalletService", .doc = "every occurrence in this tree, ripgrep's default shape" },
            .{ .cmd = "gist 'pgxpool\\.\\w+' --rank", .doc = "definitions first, call sites after, generated files demoted" },
            .{ .cmd = "gist -P '(?<=func )\\w+' services", .doc = "a lookbehind, still trigram-prefiltered" },
            .{ .cmd = "gist -t zig -l 'fn write'", .doc = "just the Zig files that contain it" },
            .{ .cmd = "gist index && gist status", .doc = "persist the index, then check what it covers" },
        },
        .exits = &.{
            .{ .code = 0, .means = "the search matched, or the verb succeeded" },
            .{ .code = 1, .means = "the search ran and matched nothing" },
            .{ .code = 2, .means = "a usage, parse, path, or unsupported-flag error" },
        },
        .see_also = &.{ "relate(1)", "irregex(1)", "rg(1)", "grep(1)" },
    };
}

/// Answer `gist --generate <target>` on stdout.
pub fn emit(version: []const u8, target: ?[]const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    primer.emit(surface(arena.allocator()), version, target);
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "every flag in the parser's table reaches the surface, exactly once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = surface(arena.allocator());
    // The catalog, plus the four `main` answers before the catalog is read.
    try t.expectEqual(catalog.flag_catalog.len + lifecycle.len, s.opts.len);
    // Every option is filed under a group that exists, so none is silently
    // dropped by a renderer iterating the declared sections.
    var filed: usize = 0;
    var rows: std.ArrayList(Opt) = .empty;
    for (s.groups) |g| {
        s.inGroup(g.key, &rows, arena.allocator());
        filed += rows.items.len;
    }
    try t.expectEqual(s.opts.len, filed);
}

test "the parser decides what takes a value — never a guess" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = surface(arena.allocator());
    const shape = struct {
        fn of(surf: primer.Surface, long: []const u8) Opt {
            for (surf.opts) |o| for (o.longs) |l| if (std.mem.eql(u8, l, long)) return o;
            unreachable;
        }
    }.of;
    // The exact pair ripgrep's generated bash gets wrong: a switch must take
    // nothing, so a shell has no excuse to offer a directory listing after it.
    try t.expect(shape(s, "word-regexp").value == null);
    try t.expect(shape(s, "heading").value == null);
    try t.expect(shape(s, "file").value.?.of == .file);
    try t.expect(shape(s, "type").value.?.many);
    // A bare `--rank` and a bare `--hyperlink` are legal, so neither may eat
    // the next word — that word is the pattern.
    try t.expect(shape(s, "rank").glued());
    try t.expect(shape(s, "hyperlink").glued());
    try t.expect(!shape(s, "hyperlink-format").glued());
}

test "closed sets are baked whole, and shared between the flags that offer them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const s = surface(gpa);
    const sets = primer.distinctSets(gpa, s, "");
    var by_name: usize = 0;
    for (sets.items) |e| {
        if (std.mem.eql(u8, e.name, "type")) {
            by_name += 1;
            // The whole registry, aliases and the `all` wildcard included.
            try t.expect(e.choices.len > types.type_table.len);
        }
        if (std.mem.eql(u8, e.name, "encoding")) {
            by_name += 1;
            try t.expectEqual(encoding.labels.len + 2, e.choices.len);
        }
    }
    try t.expectEqual(@as(usize, 2), by_name);
    // More than one flag takes a TYPE — `-t`, `-T`, and `--type-clear` — and the
    // 221-row registry is written down ONCE for all of them. That sharing is the
    // invariant, so assert it directly rather than counting the flags: a count
    // fails every time a fourth flag legitimately joins, while saying nothing
    // about the thing that would actually be broken.
    const typed = for (sets.items) |e| {
        if (std.mem.eql(u8, e.name, "type")) break e.choices;
    } else return error.TypeSetNotBaked;
    var offering: usize = 0;
    for (s.opts) |o| if (o.set()) |set| if (set.ptr == typed.ptr) {
        offering += 1;
        try t.expectEqual(typed.len, set.len);
    };
    try t.expect(offering > 1);
    // …and nobody kept a private copy beside it. `distinctSets` keys on the
    // slice POINTER, so a flag that grew its own copy of the rows would surface
    // as a second entry (`type2`) holding the same table — the regression this
    // test exists to catch.
    for (sets.items) |e| if (e.choices.ptr != typed.ptr)
        try t.expect(e.choices.len != typed.len or
            !std.mem.eql(u8, e.choices[0].word, typed[0].word));
}

test "rivalries fall out of the state a flag writes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = surface(arena.allocator());
    // -i / -s / -S resolve to one case mode in the parser…
    try t.expectEqual(@as(usize, 3), s.rivals("case"));
    // …--heading and --no-heading assign one bool…
    try t.expectEqual(@as(usize, 2), s.rivals("heading"));
    // …and --context-separator fights --no-context-separator over one string,
    // which no hand-kept exclusion list would have thought to pair.
    try t.expectEqual(@as(usize, 2), s.rivals("ctx_sep"));
    // A repeatable option is nobody's rival: `-e A -e B` is the point of it.
    for (s.opts) |o| if (o.value) |v| if (v.many) try t.expectEqualStrings("", o.rival);
}

test "a flag's section is the reach the parser already recorded" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = surface(arena.allocator());
    for (s.opts) |o| {
        for (o.longs) |l| {
            if (std.mem.eql(u8, l, "hidden")) try t.expectEqualStrings("corpus", o.group);
            if (std.mem.eql(u8, l, "fixed-strings")) try t.expectEqualStrings("semantics", o.group);
            if (std.mem.eql(u8, l, "heading")) try t.expectEqualStrings("presentation", o.group);
            if (std.mem.eql(u8, l, "threads")) try t.expectEqualStrings("execution", o.group);
            if (std.mem.eql(u8, l, "no-config")) try t.expectEqualStrings("config", o.group);
        }
    }
}

test "every artifact renders, and no completion shells out to build a menu" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const s = surface(gpa);
    inline for (@typeInfo(primer.Target).@"enum".fields) |f| {
        var buf: std.ArrayList(u8) = .empty;
        primer.render(&buf, gpa, s, .{ .version = "9.9.9", .date = "2001-02-03" }, @field(primer.Target, f.name));
        try t.expect(buf.items.len > 4096);
        // The performance claim, checked rather than asserted. ripgrep's zsh
        // completion answers `-t<TAB>` by running `rg --type-list` and
        // re-parsing it, per keystroke; no generated artifact here may run
        // gist at all, because every menu it could ask for is already in the
        // file. (The zsh renderer additionally forbids ANY command
        // substitution — see its own test.)
        try t.expect(std.mem.indexOf(u8, buf.items, "$(gist") == null);
        try t.expect(std.mem.indexOf(u8, buf.items, "(gist ") == null);
    }
}

test "the four flags handled before the catalog are the four main dispatches on" {
    // `lifecycle` is the surface's only hand-written row, so it is the only one
    // that can drift. Read `main.zig`'s bytes and require each advertised
    // spelling to appear there: a menu may not offer a flag the binary would
    // reject. (The reverse direction — a new lifecycle flag in `main` that
    // nobody advertised — is what `--generate`'s own menu, derived from
    // `primer.Target`, makes impossible for the one flag that takes a value.)
    const src = @embedFile("main.zig");
    for (lifecycle) |o| {
        for (o.longs) |long| {
            var quoted: [64]u8 = undefined;
            const needle = try std.fmt.bufPrint(&quoted, "\"--{s}\"", .{long});
            t.expect(std.mem.indexOf(u8, src, needle) != null) catch |e| {
                std.debug.print("primer advertises --{s}, which main.zig never tests for\n", .{long});
                return e;
            };
        }
    }
    // And the one that takes a value offers exactly what it parses.
    const gen = lifecycle[lifecycle.len - 1];
    try t.expectEqualStrings("generate", gen.longs[0]);
    try t.expectEqual(@typeInfo(primer.Target).@"enum".fields.len, gen.set().?.len);
    inline for (@typeInfo(primer.Target).@"enum".fields, gen.set().?) |f, choice| {
        try t.expectEqualStrings(f.name, choice.word);
        try t.expect(choice.doc.len > 0);
        try t.expect(primer.Target.parse(choice.word) != null);
    }
}
