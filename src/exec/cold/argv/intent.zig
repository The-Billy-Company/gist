//! The request a gist run is about to serve — resolved, and under construction.
//!
//! `Opts` (plus the type/glob `Filter`) is the single precedence-sensitive state
//! the whole cold path reads: ten modules take it, nobody parses argv twice, and
//! the derived predicates (`term`, `outTerm`, `enumeration`, …) live on the
//! record so a walker, a matcher, and a printer cannot disagree about what was
//! asked for.
//!
//! `Builder` is the same request mid-flight: the multi-valued flags (`-e`, `-t`,
//! `-g`, `--type-add`, `--pre-glob`, `--ignore-file`) arrive one token at a time
//! and have nowhere to land until argv ends, so each gets a growable list here
//! and `grammar.zig` freezes the lot into the slices above. The two halves are
//! deliberately one module: every `Filter` set is exactly one `Builder` list,
//! and if they sat in separate files, adding a scope flag to one and forgetting
//! the other would be a silent dropped-filter bug rather than a compile error
//! you trip over three lines away.

const std = @import("std");
const glob = @import("../../../kernel/math/glob.zig");
const types = @import("../../../corpus/scope/types.zig");
const genus = @import("../../../corpus/scope/genus.zig");
const answer = @import("shape.zig");
const encoding = @import("../../../corpus/read/encoding.zig");
const emit_color = @import("../emit/color.zig");
const verdict = @import("verdict.zig");

/// The resolved answer shape — see `answer.zig`. Re-exported so `Opts.mode`
/// and the flag surface stay readable from one import.
pub const Mode = answer.Mode;

const die = @import("../../../surface/cli/outcome.zig").die;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const lowerDup = verdict.lowerDup;
const stripAnchor = verdict.stripAnchor;

pub const Filename = enum { auto, always, never };

/// `--color`: `auto` (the default) colorizes iff stdout is a real terminal and
/// the environment doesn't opt out (`NO_COLOR`, `TERM=dumb`); `always`/`ansi`
/// force it on regardless of destination or environment; `never` forces it
/// off. Resolved against stdout + the environment in `color.zig`.
pub const ColorChoice = enum { auto, always, never, ansi };

/// `--hyperlink`: whether a printed locator carries an OSC-8 click target.
/// `auto` (the default) is "on iff this terminal will render it and this
/// output is for a human"; `always` overrides the probe; `never` is off.
/// Defined by, and resolved against stdout + the environment in,
/// `cli/beacon.zig` — the hyperlink layer is shared with relate and irregex,
/// so gist's argv borrows its vocabulary rather than declaring a parallel one.
pub const Hyperlink = @import("../../../surface/cli/beacon.zig").When;

/// `-E`/`--encoding`: the source encoding to transcode to UTF-8 before matching.
/// `auto` (the default) is BOM sniffing (UTF-8 BOM stripped, UTF-16 BOM
/// transcoded); `none` disables even that; the explicit labels force a transcode
/// regardless of any BOM. The enum and its full WHATWG label resolver live in
/// `encoding.zig` (which also owns the legacy-code-page decoders); `ingest.zig`
/// keeps the `auto`/`none`/UTF fast paths and delegates the rest there. Re-exported
/// here so the flag surface stays the one place argv semantics are read.
pub const Encoding = encoding.Encoding;

/// Resolve an `--encoding` label to the enum, or null for an unrecognized one
/// (the caller fails loud). The full WHATWG label table (`encoding_rs::for_label`,
/// which rg rides) plus gist's `auto`/`none` spellings — see `encoding.fromLabel`.
pub const encodingFromLabel = encoding.fromLabel;

fn globAppliesCI(a: std.mem.Allocator, pat: []const u8, path: []const u8) bool {
    return glob.globApplies(lowerDup(a, pat), lowerDup(a, path));
}

/// The path spelling a `-g`/`-t` glob is matched against: the walked path with
/// any leading `./` peeled. ripgrep's walker matches relative to the search
/// root, so `rg -g 'sub/**' .` — whose rows PRINT as `./sub/c.py` — still sees
/// `sub/c.py`, and conversely `-g './sub/**'` matches nothing there. Matching
/// the display spelling instead silently dropped every rooted glob (one with a
/// `/` in it) whenever a positional `.` was present, which is the common shape.
fn globView(path: []const u8) []const u8 {
    var s = path;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    return s;
}

/// Resolved type/glob scope (`-t/-T/-g/--glob/--iglob`), AND-combined; each set
/// is a no-op when empty. Borrows caller-owned slices (a parse-time arena).
pub const Filter = struct {
    exts: []const []const u8 = &.{}, // -t (union of type globs, see scope/types.zig)
    neg_exts: []const []const u8 = &.{}, // -T
    includes: []const []const u8 = &.{}, // -g/--glob (case-sensitive)
    iglobs: []const []const u8 = &.{}, // --iglob (case-insensitive)
    excludes: []const []const u8 = &.{}, // -g '!…' / --glob '!…'
    type_all: bool = false, // -t all
    ntype_all: bool = false, // -T all
    genera: genus.Set = .empty, // -t docs / --docs (see scope/genus.zig)
    neg_genera: genus.Set = .empty, // -T docs / --no-docs

    pub fn hasInclude(self: Filter) bool {
        return self.exts.len > 0 or self.includes.len > 0 or self.iglobs.len > 0 or
            self.type_all or self.genera.any();
    }
    /// Does this path survive the type/glob scope? A `-g '!…'` exclude always
    /// vetoes. Then a positive `-g`/`--iglob` is ripgrep's Override WHITELIST
    /// and DECIDES on its own: a match forces the path in over any `-t`/`-T`,
    /// and — once one positive glob exists — a non-match forces it out. Type
    /// filters only rule on the paths no override spoke for. Measured against
    /// rg 15.2: `-t py -g '*.rs'` lists the .rs files (not the .py ones), and
    /// `-T md -g '*.md'` lists the .md file the negation would have dropped.
    ///
    /// A genus (`--docs`, `-t code`) sits at the SAME tier as a type, because it
    /// is one: it loses to an explicit `-g` override, negation wins over
    /// selection, and selections union — so `--docs --code` is both, and
    /// `--docs --no-docs` is nothing, exactly as `-t md -T md` is.
    pub fn admits(self: Filter, a: std.mem.Allocator, path: []const u8) bool {
        const p = globView(path);
        for (self.excludes) |g| if (glob.globApplies(g, p)) return false;
        if (self.includes.len > 0 or self.iglobs.len > 0) {
            for (self.includes) |g| if (glob.globApplies(g, p)) return true;
            for (self.iglobs) |g| if (globAppliesCI(a, g, p)) return true;
            return false;
        }
        for (self.neg_exts) |e| if (glob.globApplies(e, p)) return false;
        if (self.neg_genera.any() and self.neg_genera.has(genus.of(p))) return false;
        if (self.ntype_all and types.isKnownType(p)) return false;
        if (self.exts.len == 0 and !self.type_all and !self.genera.any()) return true;
        for (self.exts) |e| if (glob.globApplies(e, p)) return true;
        if (self.genera.any() and self.genera.has(genus.of(p))) return true;
        return self.type_all and types.isKnownType(p);
    }
    /// ripgrep `Override` whitelist: does an explicit `-g`/`--glob`/`--iglob` glob
    /// force this path IN, OVERRIDING the hidden/ignore filters (`Match::Whitelist`
    /// short-circuit)? ONLY `-g`/`--iglob` form the override — `-t`/`-T` type
    /// filters do NOT bypass ignore, they layer on top of it. A `-g '!…'` exclude
    /// vetoes; empty include sets ⇒ no override (normal hidden/ignore stands).
    pub fn whitelists(self: Filter, a: std.mem.Allocator, path: []const u8) bool {
        if (self.includes.len == 0 and self.iglobs.len == 0) return false;
        const p = globView(path);
        for (self.excludes) |g| if (glob.globApplies(g, p)) return false;
        for (self.includes) |g| if (glob.globApplies(g, p)) return true;
        for (self.iglobs) |g| if (globAppliesCI(a, g, p)) return true;
        return false;
    }
    /// Does any include whitelist UN-HIDE this path (bypass the dotfile skip)? A
    /// `-g`/`--iglob` override does (via `whitelists`), and so does a `-t`/`-t all`
    /// TYPE match — ripgrep un-hides a dotfile that a type filter selects, even
    /// though a type filter never bypasses gitignore (that stays `whitelists`).
    ///
    /// A GENUS deliberately does not un-hide, where a named type does. Un-hiding
    /// reads a specific `-t md` as intent to include; `--code` names no
    /// spelling, and since it is the partition's DEFAULT half it would claim
    /// every unrecognized path — measured: it pulled in `.git/logs/HEAD` and
    /// `.git/lost-found/**`, which is not a search anyone asked for. So a genus
    /// narrows what the walk already produced and never widens it.
    pub fn whitelistsHidden(self: Filter, a: std.mem.Allocator, path: []const u8) bool {
        if (self.whitelists(a, path)) return true;
        const p = globView(path);
        for (self.exts) |e| if (glob.globApplies(e, p)) return true;
        return self.type_all and types.isKnownType(p);
    }
    /// True when any set constrains the file list (lets the caller skip the walk
    /// filter entirely on an unscoped query).
    pub fn active(self: Filter) bool {
        return self.hasInclude() or self.neg_exts.len > 0 or self.excludes.len > 0 or
            self.ntype_all or self.neg_genera.any();
    }
};

/// Which match backend realizes the pattern (`-P`/`--pcre2`, `--engine=<name>`).
/// `default` is gist's linear-time RE2/Pike engine — no backtracking, no
/// lookaround/backreferences, safe over an adversarial tree. `pcre2` is the
/// opt-in vendored PCRE2 JIT backend (`kernel/regex/pcre2/backend.zig`) for the constructs
/// the linear engine can't express. `auto` is ripgrep's hybrid: `run.zig` compiles
/// the linear engine first (its speed + trigram AST) and only escalates to PCRE2
/// for a pattern the linear engine declines (lookaround / backreferences). Both
/// backends are live and trigram-prefiltered; the choice is resolved and executed
/// in `run.zig`.
pub const Engine = enum { default, pcre2, auto };

/// `--sort`/`--sortr`/`--sort-files` ordering key. `none` (the default) leaves
/// gist free to stream in the fastest work-stealing discovery order; any other
/// key forces a globally ordered result. `path` sorts by the display path;
/// `modified`/`accessed`/`created` sort by the file's mtime/atime/birth time.
/// ripgrep abandons parallelism entirely when a sort is requested — gist keeps
/// its parallel *reads* and only orders the final emit, so an ordered gist run
/// still beats rg's single-threaded sort walk.
pub const SortKey = enum { none, path, modified, accessed, created };

/// `--line-buffered` / `--block-buffered`: when result bytes leave the process.
/// `auto` (the default) reads the destination the way ripgrep does — a terminal
/// wants each line as it is found, a pipe or a file wants them coalesced.
/// `off` is what `--buffer-size=0` asks for: a buffer that can hold nothing is
/// no buffer, so every fragment the printer produces becomes its own write —
/// the cadence to reach for when something downstream is measuring the shape of
/// the stream rather than reading it.
/// None of them ever changes which bytes are written, only how many trips
/// through the kernel it takes; see `corpus/tree/drain.zig` for what each costs.
pub const Buffering = enum { auto, line, block, off };

pub const Opts = struct {
    caseless: bool = false,
    smart_case: bool = false,
    // --unicode / --no-unicode (rg default ON). Governs the LINEAR engine's
    // Unicode mode: case folding over full case-fold orbits, `\w`/`\d`/`\s`/`.`
    // and `\p{…}` over codepoints, and Unicode `\b`/`\B`/`\<`/`\>`/`-w`. Cleared
    // (`(?-u)`/`--no-unicode`), the engine is a pure byte/ASCII matcher. `(?u)`/
    // `(?-u)` leading directives flip it per run. PCRE2 has its own `pcre_unicode`.
    unicode: bool = true,
    word: bool = false,
    fixed: bool = false,
    invert: bool = false,
    only_matching: bool = false,
    line_num: bool = false,
    filename: Filename = .auto,
    before: usize = 0,
    after: usize = 0,
    max_per_file: usize = 0,
    // Was --max-count/-m given? Distinguishes an explicit `-m0` (ripgrep's
    // "match nothing" — search short-circuits before emitting/counting a single
    // hit, exit 1, no output, in EVERY mode) from the unset default where 0 is
    // the "unlimited" sentinel the per-file emit guards read. Mirrors
    // `max_cols_set` below.
    max_per_file_set: bool = false,
    // Which of the mutually exclusive answer shapes the flags resolved to
    // (`-l`, `--files-without-match`, `-c`, `--count-matches`, `--json`,
    // `--files`, `--type-list`, or the default). Every mode flag resolves
    // through `answer.Mode.update`, so precedence is that enum's law and this
    // is the whole representation — there is no state in which two modes are
    // both chosen, because there is one field. See `answer.zig`.
    mode: Mode = .standard,
    // --include-zero / --no-include-zero (rg default OFF, last-wins): in a count
    // mode, emit a `path:0` line for every searched file with no match instead of
    // suppressing it. The exit code is unchanged (0 matches ⇒ exit 1) — only the
    // per-file zero line is added. Forces the serial engine and disables the
    // whole-file literal gate + index elision so every searched file is counted.
    include_zero: bool = false,
    hidden: bool = false,
    text: bool = false, // -a/--text: disable binary detection, search as text
    // --binary / -uuu: search binary files in full (never quit at the first NUL).
    // gist's flavor searches the whole file and prints every matching line — a
    // superset that never drops a match — rather than rg's binary-summary
    // suppression (documented divergence; both stop treating a NUL as a wall).
    binary: bool = false,
    // -z/--search-zip: transparently decompress by extension before searching
    // (gzip/zlib/zstd/xz in-process, the rest via the standard external tool).
    search_zip: bool = false,
    // --pre <cmd> (+ --pre-glob): run a preprocessor over each selected file and
    // search its stdout; overrides --search-zip. See `ingest.zig`.
    pre: ?[]const u8 = null,
    pre_globs: []const []const u8 = &.{}, // --pre-glob includes (empty ⇒ all)
    pre_excludes: []const []const u8 = &.{}, // --pre-glob '!…'
    encoding: Encoding = .auto, // -E/--encoding source encoding (transcode → UTF-8)
    max_cols: usize = 0,
    // Was --max-columns/-M given on the argv? Distinguishes an explicit `-M0`
    // (opt out of any cap) from the unset default, so the TTY-only long-line
    // guard (`run.zig`) applies only when the user expressed no preference.
    max_cols_set: bool = false,
    max_cols_preview: bool = false, // --max-columns-preview
    passthru: bool = false, // --passthru (print every line)
    field_match_sep: []const u8 = ":", // --field-match-separator
    field_ctx_sep: []const u8 = "-", // --field-context-separator
    path_sep: ?[]const u8 = null,
    // presentation / locator flags
    column: bool = false, // --column
    byte_offset: bool = false, // -b/--byte-offset
    vimgrep: bool = false, // --vimgrep
    heading: bool = false, // --heading
    trim: bool = false, // --trim
    null_sep: bool = false, // --null/-0 (NUL after path)
    line_regexp: bool = false, // -x/--line-regexp
    quiet: bool = false, // -q/--quiet
    stats: bool = false, // --stats
    stop_on_nonmatch: bool = false, // --stop-on-nonmatch
    crlf: bool = false, // --crlf
    null_data: bool = false, // --null-data (NUL line terminator)
    multiline: bool = false, // -U/--multiline
    multiline_dotall: bool = false, // --multiline-dotall
    // The regex `m` flag, resolved after leading `(?m)`/`(?-m)` directives. Base
    // = `multiline` (rg's `-U` default is `m` ON); `(?-m)` clears it so `^`/`$`
    // anchor only at the buffer ends while the whole-buffer search stays live.
    // Threaded into the matcher compile (`line_anchors`); inert in per-line mode.
    re_line_anchors: bool = false,
    // Match-backend selection (-P/--pcre2, --engine, --auto-hybrid-regex).
    // `default` = the linear RE2/Pike engine; `pcre2` routes to the vendored
    // PCRE2 JIT backend; `auto` compiles linear and escalates to PCRE2 only for a
    // pattern the linear engine declines (run.zig resolves + executes the choice).
    engine: Engine = .default,
    pcre_unicode: bool = true, // --pcre2-unicode / --no-pcre2-unicode (PCRE2 Unicode mode)
    replace: ?[]const u8 = null, // -r/--replace
    // walk-scope flags
    follow: bool = false, // -L/--follow symlinks
    sorted: bool = false, // any explicit ordering active (forces the deterministic sorted walk)
    sort_key: SortKey = .none, // --sort/--sortr key; .none = fastest discovery order
    sort_reverse: bool = false, // --sortr: descending instead of ascending
    threads: usize = 0, // -j/--threads: 0 = gist picks its topology; N caps the worker pool
    one_file_system: bool = false, // --one-file-system: never descend into another device
    max_depth: usize = 0, // --max-depth/--maxdepth (0 = unlimited)
    max_filesize: usize = 0, // --max-filesize (bytes, 0 = unlimited)
    // ignore-rule flags (.gitignore/.ignore/.rgignore + --ignore-file); see rgignore.zig
    no_ignore: bool = false, // --no-ignore / -u (disable every ignore source)
    no_ignore_vcs: bool = false, // --no-ignore-vcs (.gitignore + exclude off)
    no_ignore_dot: bool = false, // --no-ignore-dot (.ignore/.rgignore off)
    no_ignore_parent: bool = false, // --no-ignore-parent (ancestors above CWD off)
    no_ignore_exclude: bool = false, // --no-ignore-exclude (.git/info/exclude off)
    no_ignore_global: bool = false, // --no-ignore-global (git core.excludesFile off)
    no_ignore_files: bool = false, // --no-ignore-files (--ignore-file sources off)
    no_require_git: bool = false, // --no-require-git (honor .gitignore w/o a repo)
    ignore_case_insensitive: bool = false, // --ignore-file-case-insensitive
    ignore_files: []const []const u8 = &.{}, // --ignore-file <path> (ordered)
    // --messages / --no-messages (rg default ON): the per-file stderr lane — a
    // path that would not open, descend, or preprocess, plus the "no files were
    // searched" verdict. Cleared, those lines are not printed; the run's EXIT
    // CLASS is untouched, so an unreadable directory still exits 2 silently
    // (rg's own rule). Lowered onto `assay.Chatter` once at `serial.run`.
    messages: bool = true,
    // --ignore-messages / --no-ignore-messages (rg default ON): the narrower
    // lane for an ignore SOURCE that could not be honored (an `--ignore-file`
    // that will not open). `--no-messages` subsumes this one; the nesting is
    // resolved in `assay.muffle`, not here.
    ignore_messages: bool = true,
    // ctx_sep: null = suppressed line (--no-context-separator); else the string.
    ctx_sep: ?[]const u8 = "--",
    color: ColorChoice = .auto, // --color auto|always|never|ansi
    // --hyperlink / --no-hyperlink: whether a result's locator is a click.
    // `auto` (the default) links iff the terminal is known to render OSC-8 and
    // the output shape is meant for a human — resolved in `cli/beacon.zig`,
    // deliberately independent of `color` (a link is navigation, not paint).
    hyperlink: Hyperlink = .auto,
    // The destination template, alias-resolved and syntax-checked at parse
    // time. Null = let the beacon probe the terminal for the right editor URL.
    hyperlink_format: ?[]const u8 = null,
    // Was `--hyperlink` written bare, with no `=value`? Then the token after it
    // is the PATTERN, and someone carrying rg's `--hyperlink-format vscode`
    // spacing just searched for their editor's name. Remembered so the run can
    // say so (`beacon.misspacedNote`) instead of silently linking somewhere else.
    hyperlink_bare: bool = false,
    // --hostname-bin: a command whose stdout supplies `{host}` (rg parity —
    // a WSL or container shell needs the outer host, not the kernel's).
    hostname_bin: ?[]const u8 = null,
    // --colors, resolved once at `seal` into the four SGR prefixes this run
    // paints with. It rides Opts rather than an emitter parameter because Opts
    // already reaches every render path — serial, swarm, and the daemon's
    // facet — so honoring a spec cost no signature a new argument. The default
    // is gist's own palette, byte-for-byte what a run with no spec has always
    // printed.
    palette: emit_color.Palette = .{},
    // --no-index: never consult the persisted trigram index — always live-read
    // every walked file. Default (false) auto-detects an index and uses it purely
    // to SKIP reading files it proves can't match (unchanged since the build and
    // not a trigram candidate); the walk + output stay byte-identical either way.
    // `--index` is the explicit opt-in spelling of that default (undo a prior
    // `--no-index`); neither ever changes results, only how many files are opened.
    no_index: bool = false,
    // --rank[=N]: gist-native ranked view (no rg equivalent) — definition-first
    // RRF over indexed candidates when available, else the live walk. `rank_k`
    // = 0 means the default 20; --no-index explicitly selects live ranking.
    rank: bool = false,
    rank_k: usize = 0,
    // --uncap: lift the soft output budget (the ~25k-token agent-context guard,
    // corpus.zig) for THIS query — the agent deliberately wants the full result.
    // The hard OOM ceiling still applies. `GIST_UNCAP=1` is the env equivalent
    // (what the bench harness sets to keep rg byte-parity exact).
    uncap: bool = false,
    // --in-comments / --in-code: gist-native match SCOPING built on the shared
    // comment/code span lexer (kernel/compose/lexspan.zig). `--in-comments`
    // keeps only matches whose span begins inside a `//`/`#`/`/* */` comment
    // (doc mentions, TODOs, stale-invariant surface); `--in-code` keeps only
    // matches OUTSIDE any comment. Mutually exclusive. They select an early
    // native view (like `--rank`) rather than threading through the certified
    // rg-parity per-line engine, so ripgrep parity is untouched.
    in_comments: bool = false,
    in_code: bool = false,
    // --line-buffered / --block-buffered / --buffer-size: the stdout drain's
    // policy and its ceiling in bytes (0 ⇒ gist's 64 KiB default). Delivery
    // cadence only — the emitted bytes are identical under every setting, which
    // is why both carry `Reach.execution`.
    buffering: Buffering = .auto,
    buffer_size: usize = 0,
    // --plain: pin the answer to the shape a PIPE would receive, even when
    // stdout is a terminal. gist has three destination-conditional behaviors
    // (`--color auto`, the TTY long-line `-M` guard, `--line-buffered`'s auto
    // resolution), and a run that must not differ from a redirected one should
    // not have to remember and re-spell each of them.
    // The inverse pole of `-p`/`--pretty`.
    plain: bool = false,
    filter: Filter = .{},
    pub fn wantsContext(self: Opts) bool {
        return self.before > 0 or self.after > 0;
    }
    /// The line terminator byte: NUL under `--null-data`, else newline. Governs
    /// both how the input is split into lines and how each emitted line ends.
    pub fn term(self: Opts) u8 {
        return if (self.null_data) 0 else '\n';
    }
    /// The terminator the PRINTER appends to every line it emits (match/context
    /// bodies, `-l` paths, `-c` counts, headings, `--` separators). Under
    /// `--crlf` ripgrep's printer writes `\r\n` — its own output adopts the
    /// CRLF convention, not just the input split — while the INPUT terminator
    /// (`term()`, above) stays `\n` with the `\r` folded into the match view.
    /// A line body's own trailing `\r` is stripped before this is appended
    /// (`Emitter.emitBody`), mirroring rg's `trim_line_terminator`.
    pub fn outTerm(self: Opts) []const u8 {
        return if (self.null_data) "\x00" else if (self.crlf) "\r\n" else "\n";
    }
    /// The byte a finished OUTPUT record ends with — the boundary
    /// `--line-buffered` is allowed to hold nothing past. Normally the last
    /// byte the printer appends (`\n`, CRLF's `\n`, NUL under `--null-data`);
    /// `--null` makes the enumeration modes NUL-terminate their paths instead,
    /// and a stream with no `\n` in it at all must not be held to one.
    pub fn recordTerm(self: Opts) u8 {
        if (self.null_sep and self.enumeration()) return 0;
        const out = self.outTerm();
        return out[out.len - 1];
    }
    /// The separator between two adjacent groups, in the two pieces a caller
    /// writes in order — `null` once `--no-context-separator` suppressed it.
    /// A context gap and a FILE boundary are the same event to ripgrep, and
    /// three engines emit it (serial render, parallel sink, resident session);
    /// spelling the rule once is what keeps `--context-separator`, its
    /// suppression, and the `--null-data` terminator from being honored in
    /// some of them and not others. Split rather than joined so the hot
    /// emitter path stays allocation-free.
    pub fn groupSep(self: Opts) ?[2][]const u8 {
        return if (self.ctx_sep) |sep| .{ sep, self.outTerm() } else null;
    }
    /// The single-byte reconstruction terminator for a body line that WAS
    /// terminated in the file: the emitter's line slices keep any `\r` but
    /// drop the split byte, so appending this re-materializes the original
    /// bytes exactly (dos `…\r`+`\n`, unix `…`+`\n`) — rg writes such lines
    /// verbatim and only falls back to `outTerm()` when one is missing.
    pub fn termStr(self: Opts) []const u8 {
        return if (self.null_data) "\x00" else "\n";
    }
    /// True for the two "no pattern needed" modes (`--files`, `--type-list`):
    /// they answer from the walk, so a bare argument after them is a path.
    pub fn noPattern(self: Opts) bool {
        return !self.mode.searching();
    }
    /// The compact per-file ENUMERATION modes: one short line per file — a path
    /// (`-l`, `--files-without-match`, `--files`) or a count (`-c`,
    /// `--count-matches`). A partial answer here is misleading, and on the
    /// unordered parallel engine a soft-cap cut yields a nondeterministic SUBSET
    /// run-to-run; these are exempted from the soft context cap
    /// (`corpus.exemptSoftCap`) so the SET is complete and reproducible. The
    /// full-content modes (default, `-o`, context, `--json`) keep the cap — their
    /// volume is the reason it exists, and their truncation is already ordered.
    pub fn enumeration(self: Opts) bool {
        return self.mode.enumerates();
    }

    /// Does `--heading` GROUP this run — a blank line between file groups, the
    /// path lifted out of the row prefix and onto a title line above it?
    ///
    /// Only the content shape has rows to lift a path out of, so a mode that
    /// already prints one short line per file (`-c`, `-l`, …) keeps its own
    /// `path:N` prefix and is not grouped; `--vimgrep` pins one location per
    /// row by definition and so opts out too.
    ///
    /// Deliberately independent of whether the path is SHOWN: `-I` removes the
    /// title line but not the grouping (`rg --heading -I` over two files still
    /// separates them with a blank line). Both engines used to fold the
    /// filename decision into this one and each folded a different set of
    /// modes into it, which is how `--heading` came to mean four things.
    pub fn groups(self: Opts) bool {
        return self.heading and self.mode.frames() and !self.vimgrep;
    }
};

/// `types` is what this run's `--type-add`/`--type-clear` did to the registry.
/// It survives `seal` because `--type-list` has to render the registry the
/// SEARCH would have used, and the resolved include/exclude globs in `opts`
/// cannot be read back into the names they came from.
///
/// `locus` survives for the same reason, one question later: `opts` already
/// carries the answer a PIPE gets, and argv is the wrong place to learn that
/// stdout is a terminal (parsing stays free of I/O, which is what lets every
/// grammar test run without one). Handing the unspent explicit answers to the
/// destination pass lets it re-resolve them against the real fd without ever
/// being able to overrule a flag. See `answer.Locus`.
pub const Parsed = struct {
    patterns: [][]const u8,
    opts: Opts,
    roots: [][]const u8,
    pattern_files: [][]const u8 = &.{},
    types: types.Overlay = .{},
    locus: answer.Locus = .{},
};

/// A `--type-add name:...` definition, resolved to the globs `-t name` scopes by.
/// The listing row shape, so a definition needs no conversion to be rendered.
const CustomType = types.NameGlobs;

/// Mutable parse state: resolves flags into Opts, collects type/glob sets, and
/// records -A/-B/-C values so -A/-B can take precedence over -C regardless of
/// argv order (ripgrep's rule), plus the `-u` repetition level.
pub const Builder = struct {
    a: std.mem.Allocator,
    o: Opts = .{},
    /// The explicit `-n`/`-N`/`--column`/`--no-column` answers, null until
    /// asked. Lives on the Builder rather than `Opts` because it is spent at
    /// `seal`, which resolves it into `o.line_num` / `o.column`.
    locus: answer.Locus = .{},
    pat: ?[]const u8 = null,
    roots: std.ArrayList([]const u8) = .empty,
    exts: std.ArrayList([]const u8) = .empty,
    neg_exts: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,
    iglobs: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    pat_files: std.ArrayList([]const u8) = .empty, // -f/--file
    pre_globs: std.ArrayList([]const u8) = .empty, // --pre-glob includes
    pre_excludes: std.ArrayList([]const u8) = .empty, // --pre-glob '!…'
    extra_pats: std.ArrayList([]const u8) = .empty, // 2nd+ -e/--regexp
    ignore_files: std.ArrayList([]const u8) = .empty, // --ignore-file
    custom_types: std.ArrayList(CustomType) = .empty, // --type-add
    cleared_types: std.ArrayList([]const u8) = .empty, // --type-clear
    genera: genus.Set = .empty, // -t docs / --docs
    neg_genera: genus.Set = .empty, // -T docs / --no-docs
    // --colors, in argv order: specs merge, so the last one naming an attribute
    // wins and `seal` renders them into `o.palette` exactly once.
    color_specs: std.ArrayList([]const u8) = .empty,
    type_all: bool = false,
    ntype_all: bool = false,
    glob_ci: bool = false, // --glob-case-insensitive
    a_val: ?usize = null,
    b_val: ?usize = null,
    c_val: ?usize = null,
    urestrict: u8 = 0,

    /// Accumulate a pattern from `-e/--regexp` (or a bare pattern arg). The first
    /// becomes `pat`; each subsequent one is OR-combined at finalize (ripgrep ORs
    /// multiple `-e`). A literal (`-F`) alternation is handled downstream.
    pub fn addPat(self: *Builder, p: []const u8) void {
        if (self.pat == null) self.pat = p else self.extra_pats.append(self.a, p) catch oom();
    }
    /// `--type-clear NAME`: the name stops being a file type at all. rg's
    /// reading is total — a cleared name is not an empty type, it is *no* type,
    /// so a later `-t`/`-T` naming it fails loud exactly as a typo would. The
    /// cleared list therefore has to be consulted BEFORE both the custom-type
    /// table and the built-in registry, and clearing also drops any custom defs
    /// the name already carried (otherwise the clear would be partial).
    pub fn clearTypeDef(self: *Builder, name: []const u8) void {
        if (self.isTypeCleared(name)) return;
        var kept: std.ArrayList(CustomType) = .empty;
        for (self.custom_types.items) |ct| {
            if (!std.mem.eql(u8, ct.name, name)) kept.append(self.a, ct) catch oom();
        }
        self.custom_types = kept;
        self.cleared_types.append(self.a, name) catch oom();
    }
    pub fn isTypeCleared(self: *const Builder, name: []const u8) bool {
        for (self.cleared_types.items) |c| if (std.mem.eql(u8, c, name)) return true;
        return false;
    }
    pub fn addType(self: *Builder, name: []const u8, negate: bool) void {
        if (self.isTypeCleared(name)) die("unrecognized type: {s}\n", .{name});
        if (std.mem.eql(u8, name, "all")) {
            (if (negate) &self.ntype_all else &self.type_all).* = true;
        } else if (genus.named(name)) |g| {
            // A genus is a type whose membership is computed rather than
            // matched, so it rides its own field instead of a glob list.
            (if (negate) &self.neg_genera else &self.genera).merge(g);
            // `--type-add docs:notes/**` (or `types` in the charter) WIDENS a
            // genus rather than redefining it, since the positive sets are a
            // union. Its globs join `exts`, not `includes`, so they add to the
            // selection instead of becoming an override that decides alone.
            if (self.customGlobs(name)) |globs|
                (if (negate) &self.neg_exts else &self.exts).appendSlice(self.a, globs) catch oom();
            // A user-defined `--type-add` type resolves to include/exclude globs; a
            // built-in resolves to its own glob set (scope/types.zig).
        } else if (self.customGlobs(name)) |globs| {
            (if (negate) &self.excludes else &self.includes).appendSlice(self.a, globs) catch oom();
        } else {
            const e = types.extsForType(name) orelse die("unrecognized type: {s}\n", .{name});
            (if (negate) &self.neg_exts else &self.exts).appendSlice(self.a, e) catch oom();
        }
    }
    /// Register a `--type-add` spec: `name:glob` appends a glob to `name`; the
    /// `name:include:t1,t2` form aliases `name` to the union of other types.
    pub fn addTypeDef(self: *Builder, spec: []const u8) void {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse die("invalid --type-add: {s}\n", .{spec});
        const name = spec[0..colon];
        const rest = spec[colon + 1 ..];
        // Defining a name un-clears it: `--type-clear rust --type-add rust:*.rs`
        // is rg's documented way to REPLACE a built-in type rather than extend
        // it, and it only works if the clear does not outlive the redefinition.
        if (self.isTypeCleared(name)) {
            var kept: std.ArrayList([]const u8) = .empty;
            for (self.cleared_types.items) |c| {
                if (!std.mem.eql(u8, c, name)) kept.append(self.a, c) catch oom();
            }
            self.cleared_types = kept;
        }
        var globs: std.ArrayList([]const u8) = .empty;
        if (std.mem.startsWith(u8, rest, "include:")) {
            var it = std.mem.splitScalar(u8, rest["include:".len..], ',');
            while (it.next()) |ty| {
                if (self.customGlobs(ty)) |g| {
                    globs.appendSlice(self.a, g) catch oom();
                } else if (types.extsForType(ty)) |exts| {
                    // A built-in type's rows are already valid globs (scope/types.zig),
                    // so they slot straight into the `include:` union with no conversion.
                    globs.appendSlice(self.a, exts) catch oom();
                } else die("unrecognized type: {s}\n", .{ty});
            }
        } else {
            globs.append(self.a, rest) catch oom();
        }
        self.custom_types.append(self.a, .{ .name = name, .globs = globs.toOwnedSlice(self.a) catch oom() }) catch oom();
    }
    /// The accumulated globs for a user-defined type, or null if `name` is not one.
    fn customGlobs(self: *Builder, name: []const u8) ?[]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var found = false;
        for (self.custom_types.items) |ct| if (std.mem.eql(u8, ct.name, name)) {
            out.appendSlice(self.a, ct.globs) catch oom();
            found = true;
        };
        return if (found) out.items else null;
    }
    pub fn addGlob(self: *Builder, g: []const u8, insensitive: bool) void {
        // `{a,b,c}` alternation (ripgrep/git glob): expand into the cartesian
        // product of every brace group up front, then register each variant.
        var variants: std.ArrayList([]const u8) = .empty;
        verdict.braceExpand(self.a, g, &variants);
        for (variants.items) |v| self.addGlobOne(v, insensitive);
    }
    /// `--pre-glob <g>`: which files `--pre` is fed. A leading `!` marks an
    /// exclude (vetoes), else an include; the leading `/` anchor is stripped the
    /// same way `-g` globs are, so both match against the full display path.
    pub fn addPreGlob(self: *Builder, g: []const u8) void {
        if (g.len > 0 and g[0] == '!') {
            self.pre_excludes.append(self.a, stripAnchor(g[1..])) catch oom();
        } else self.pre_globs.append(self.a, stripAnchor(g)) catch oom();
    }
    fn addGlobOne(self: *Builder, g: []const u8, insensitive: bool) void {
        const neg = g.len > 0 and g[0] == '!';
        const core = stripAnchor(if (neg) g[1..] else g);
        // An explicit `-g`/`--glob` compiles strictly (rg's `Glob::new`): an
        // unclosed `[` character class is an error, not the literal `[` a lenient
        // gitignore line would treat it as. Fail loud (exit 2) here, at the seam.
        if (glob.unterminatedClass(core))
            die("gist: error parsing glob '{s}': unclosed character class; missing ']'\n", .{g});
        const list = if (neg) &self.excludes else if (insensitive) &self.iglobs else &self.includes;
        list.append(self.a, core) catch oom();
    }

    /// Freeze the accumulated sets onto `Opts` and hand back the finished
    /// request. Every growable list above lands in exactly one field here, which
    /// is why the two live in one module: a new scope flag that forgets this step
    /// would parse cleanly and then filter nothing.
    pub fn seal(self: *Builder, pats: [][]const u8) Parsed {
        // `-v`/`-o` are not modes, but they rewrite which count a count mode
        // means — so the correction can only run once the whole argv is in.
        self.o.mode = self.o.mode.settle(self.o.invert, self.o.only_matching);
        // Now that every explicit answer is in, let `--vimgrep`/`--column` imply
        // what is still unanswered — never the other way around. Resolved here
        // against `terminal = false`, the posture with a byte contract to keep:
        // every caller that never asks about its destination (the schema, the
        // primer, `--type-list`, every test) gets ripgrep's piped shape, and the
        // one caller that does re-resolves from `Parsed.locus` below.
        self.o.column = self.locus.columns(self.o.vimgrep);
        self.o.line_num = self.locus.lines(self.o.vimgrep, false);
        self.o.heading = self.locus.headings(false);
        // --glob-case-insensitive: fold case-sensitive includes into the iglob set.
        if (self.glob_ci) {
            self.iglobs.appendSlice(self.a, self.includes.items) catch oom();
            self.includes.clearRetainingCapacity();
        }
        inline for (.{ "exts", "neg_exts", "includes", "iglobs", "excludes" }) |f|
            @field(self.o.filter, f) = @field(self, f).toOwnedSlice(self.a) catch oom();
        self.o.filter.type_all, self.o.filter.ntype_all = .{ self.type_all, self.ntype_all };
        self.o.filter.genera, self.o.filter.neg_genera = .{ self.genera, self.neg_genera };
        inline for (.{ "ignore_files", "pre_globs", "pre_excludes" }) |f|
            @field(self.o, f) = @field(self, f).toOwnedSlice(self.a) catch oom();
        // Specs merge in argv order, so the palette can only be rendered once
        // the last one is in. No spec leaves the default constants in place.
        if (self.color_specs.items.len > 0)
            self.o.palette = emit_color.resolve(self.a, self.color_specs.items);
        return .{
            .patterns = pats,
            .opts = self.o,
            .roots = self.roots.toOwnedSlice(self.a) catch oom(),
            .pattern_files = self.pat_files.toOwnedSlice(self.a) catch oom(),
            .types = .{
                .added = self.custom_types.toOwnedSlice(self.a) catch oom(),
                .cleared = self.cleared_types.toOwnedSlice(self.a) catch oom(),
            },
            .locus = self.locus,
        };
    }
};
