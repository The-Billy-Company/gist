//! The ripgrep flag surface, declared once.
//!
//! `flag_catalog` is a table, not code: one row per flag, naming its spellings,
//! its parse effect, and its compatibility claim. Two consumers read it and
//! neither may disagree with the other — `grammar.zig` builds the short/long
//! dispatch maps from it, and `face/gist/schema/` renders `gist --schema` from
//! it. A flag cannot therefore be accepted by the parser while the machine-
//! readable manifest calls it unsupported, or vice versa; that drift used to be
//! a prose-versus-behavior bug waiting to happen.
//!
//! Most rows are purely declarative: `.set`/`.unset`/`.set_num`/`.set_str` name
//! the `Opts` field they drive, and the `comptime` block below *proves* each
//! named field has the type its action assumes, so a typo'd or retyped field is
//! a compile error rather than an unreachable branch at runtime. Only the rows
//! that genuinely need behavior (precedence, multi-value accumulation, optional
//! inline values) carry a named action for `grammar.apply` to interpret.

const std = @import("std");
const answer = @import("shape.zig");
const intent = @import("intent.zig");

const Opts = intent.Opts;
const Buffering = intent.Buffering;
const Filename = intent.Filename;
const Engine = intent.Engine;

/// The `Opts` field a declarative catalog row drives, by name.
pub const OptField = std.meta.FieldEnum(Opts);

/// A flag's parse effect. Most flags declaratively set or clear one `Opts`
/// bool — `.set`/`.unset` carry the exact field the catalog row drives (the
/// comptime block below proves each names a bool). Everything value-taking or
/// compound keeps a named action handled in `apply`.
pub const Act = union(enum) {
    set: OptField, // set the named Opts bool
    unset: OptField, // clear it (the --no-X / undo spellings)
    set_many: []const OptField, // set several Opts bools at once
    filename: Filename, // -H/--with-filename, -I/--no-filename
    case: enum { icase, scase, smart }, // -i / -s / -S
    // `-n`/`-N`/`--column`/`--no-column`/`--heading`/`--no-heading` record an
    // EXPLICIT answer; the `--vimgrep`/`--column` implications and the terminal
    // default are applied afterwards, so neither can overwrite one. See
    // `answer.Locus`.
    locate: enum { line_on, line_off, column_on, column_off, heading_on, heading_off },
    boundary: answer.Boundary, // -w / -x — one choice, last spelling wins
    // Every flag that competes for the one answer shape (`answer.Mode`): the
    // enumeration modes, `--json`, and the two non-search walk modes. They
    // resolve through `Mode.update`, so precedence is the enum's law rather
    // than the order these rows happen to appear in.
    mode: answer.Mode,
    // `--no-json` and friends: return to `.standard`, but ONLY if the named
    // mode is the one currently in force. Undoing `--json` must not also undo
    // an `-l` that came after it, and a mode enum cannot express "json off"
    // any other way.
    mode_off: answer.Mode,
    unrestrict,
    passthru,
    sort_files: bool, // --sort-files (true) / --no-sort-files (false = fastest order)
    sort: bool, // --sort (false) / --sortr (true = descending)
    glob_ci: bool, // --glob-case-insensitive (true) / --no- (false)
    ctx_at: enum { after, before, ctx },
    regexp,
    typ: bool, // -t/--type (false) / -T/--type-not (true = negate)
    // `--docs`/`--no-docs`/`--code`/…: the fixed-name spellings of `-t <genus>`,
    // routed through the same `addType` so the corpus partition has exactly one
    // implementation and the two spellings cannot drift apart.
    genus_pick: struct { name: []const u8, negate: bool },
    glob: bool, // -g/--glob (false) / --iglob (true = case-insensitive)
    num_set: [2]OptField, // set the named usize field from a decimal value + its was-set marker
    set_num: OptField, // set the named usize field from a decimal value
    set_str: OptField, // set the named string field from the raw value
    sep: OptField, // as .set_str, but through the C-escape decoder
    maxfsize,
    no_ctxsep,
    replace,
    file,
    ignore_file,
    type_add,
    color,
    // The one hyperlink axis, in the three spellings a caller reaches for:
    // `--hyperlink[=auto|always|never|<alias>|<format>]` (bare = always),
    // `--no-hyperlink`, and rg's value-taking `--hyperlink-format <spec>`.
    hyperlink: enum { flag, off, format },
    encoding,
    // `--no-encoding`: the fixed-choice spelling of the value-taking axis above,
    // exactly as `.engine_is` is to `.engine`.
    encoding_is: intent.Encoding,
    pre_glob,
    pre_off, // --no-pre: forget the preprocessor AND its glob scope
    type_clear, // --type-clear NAME: the name stops being a type at all
    rank,
    // -P/--pcre2: select the PCRE2 backend
    // --auto-hybrid-regex: rg's deprecated spelling of --engine auto
    engine_is: Engine, // the fixed-backend spellings above, by target backend
    engine, // --engine=<default|pcre2|auto>: select the match backend by name
    // --line-buffered / --block-buffered: one choice, last spelling wins (rg
    // documents each as overriding the other). --buffer-size sizes the block.
    buffered: Buffering,
    bufsize,
    // The two presentation poles: -p/--pretty is rg's terminal alias, --plain
    // its gist-native inverse. Each lands three effects, so neither is a
    // declarative row — and both must reach `locus` rather than `line_num` so a
    // later -n/-N still wins, exactly as it does over --vimgrep.
    pretty,
    plain,
    noop,
    noop_val,
    no_config, // --no-config: honored before argv parsing; inert by the time we get here
    colors, // --colors: validate the spec's syntax (fail loud), then discard it
    unsupported,
};

// Every declarative `.set`/`.unset` row must name a bool field — proven here
// at comptime so `setBool`'s non-bool arm is genuinely unreachable.
// (setBool has since been generalized into `setVal`; the same proof now also
// covers the `.set_num`/`.set_str`/`.sep` rows and their field types.)
comptime {
    for (flag_catalog) |spec| switch (spec.action) {
        .set, .unset => |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == bool),
        .set_many => |fs| for (fs) |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == bool),
        .set_num => |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == usize),
        .num_set => |p| std.debug.assert(@FieldType(Opts, @tagName(p[0])) == usize and @FieldType(Opts, @tagName(p[1])) == bool),
        .set_str, .sep => |f| std.debug.assert(@FieldType(Opts, @tagName(f)) == []const u8 or
            @FieldType(Opts, @tagName(f)) == ?[]const u8),
        else => {},
    };
    // A multi-field row lands one flag's worth of effect, so `reachOf` reads
    // the first field and every other field in the row must agree with it —
    // proven here rather than assumed, since a future row could pair a
    // presentation toggle with a corpus one and silently under-report itself.
    for (flag_catalog) |spec| switch (spec.action) {
        .set_many => |fs| for (fs) |f| std.debug.assert(fieldReach(f) == fieldReach(fs[0])),
        .num_set => |p| std.debug.assert(fieldReach(p[0]) == fieldReach(p[1])),
        else => {},
    };
    // A flag with no `doc` is a flag the manual and all four completions would
    // render as a blank column, so the table refuses to hold one — and a doc
    // ending in a period is a sentence where a menu column belongs.
    for (flag_catalog) |spec| {
        std.debug.assert(spec.doc.len > 0);
        std.debug.assert(spec.doc[spec.doc.len - 1] != '.');
    }
}

/// Assign the named `Opts` bool — the back end of `.set`/`.unset`.
/// Generalized over the value's type: the same inline dispatch also lands the
/// `.set_num` (usize) and `.set_str`/`.sep` (plain or optional string) rows.
pub fn setVal(o: *Opts, f: OptField, v: anytype) void {
    switch (f) {
        // zlinter-disable-next-line no_swallow_error - comptime type guard, not an error union: `inline else` expands every field, and the non-matching expansions are the ones this branch discards
        inline else => |ff| if (@FieldType(Opts, @tagName(ff)) == @TypeOf(v) or
            @FieldType(Opts, @tagName(ff)) == ?@TypeOf(v))
        {
            @field(o, @tagName(ff)) = v;
        } else unreachable, // comptime-verified: catalog rows only name bools
    }
}

/// Public compatibility buckets emitted by `gist --schema`. `.native` rows are
/// gist additions, emitted separately from the four-bucket ripgrep matrix.
/// `.improvement` is a flag whose result is identical-or-superset to ripgrep's
/// yet strictly better in behavior, performance, or robustness — never a
/// regression. Where gist differs from rg it is an improvement or it is a bug.
pub const Compatibility = enum {
    supported,
    improvement,
    accepted_but_ignored,
    unsupported_fail_loud,
    native,
};

/// How far a flag's effect travels — the axis that decides what a PERSISTED
/// setting is allowed to do. A file that outlives one invocation is read by
/// people and agents who did not write it, so "may this be persisted, and by
/// whom" has to be a property of the flag rather than a promise in prose.
///
///   corpus        which files, and what bytes of them, the engine sees
///   semantics     given that input, which lines match
///   presentation  how the answer is rendered — the match set is untouched
///   execution     nothing about the answer; only how it is computed
///
/// The committed tree declaration (`.irregex.toml`) is ceilinged at `corpus`:
/// a shared file may say what the repository IS, and may never quietly change
/// what matches for everyone who clones it. Personal preferences carry no
/// ceiling because they are confined to an interactive terminal, but the two
/// answer-changing reaches are what a zero-match run names back to the reader.
pub const Reach = enum { corpus, semantics, presentation, execution };

/// One declarative parser row. Both argv dispatch maps and `--schema` derive
/// from this catalog, so accepting, ignoring, or rejecting a flag cannot drift
/// from the machine-readable contract.
pub const FlagSpec = struct {
    short: ?u8 = null,
    longs: []const []const u8 = &.{},
    action: Act,
    compatibility: Compatibility,
    /// One lowercase line, no trailing period. It is the menu column in every
    /// generated completion and the entry line in the manual, so it is written
    /// to be read at width in a list — `note` is where the prose goes.
    ///
    /// Required, because the alternative is a second table of descriptions
    /// somewhere else, and a second table is a table that can disagree with
    /// this one. ripgrep's hand-written zsh completion is exactly that second
    /// table, and it ships a CI script whose job is to catch the disagreement.
    doc: []const u8,
    note: ?[]const u8 = null,
};

/// The `Reach` of one `Opts` field. Exhaustive on purpose: `OptField` is
/// `FieldEnum(Opts)`, so a new option is a compile error here until someone
/// says how far it travels. That is the same fail-closed discipline the
/// comptime type proof above applies to field TYPES, one axis over.
fn fieldReach(f: OptField) Reach {
    return switch (f) {
        // What the engine is given to read.
        .hidden, .text, .binary, .search_zip, .pre, .pre_globs, .pre_excludes, .encoding, .follow, .one_file_system, .max_depth, .max_filesize, .no_ignore, .no_ignore_vcs, .no_ignore_dot, .no_ignore_parent, .no_ignore_exclude, .no_ignore_global, .no_ignore_files, .no_require_git, .ignore_case_insensitive, .ignore_files, .filter => .corpus,
        // What counts as a match in it.
        .caseless, .smart_case, .unicode, .word, .fixed, .invert, .line_regexp, .crlf, .null_data, .multiline, .multiline_dotall, .re_line_anchors, .engine, .pcre_unicode, .max_per_file, .max_per_file_set, .stop_on_nonmatch, .in_comments, .in_code => .semantics,
        // How the matches are written out.
        // `.hyperlink_bare` is derived parse state, not a settable option: no
        // catalog row targets it, so `reachOf` can never ask about it. It is
        // classified with the flag it observes rather than excluded, because
        // this switch is exhaustive over the STRUCT, and a field with nowhere
        // to go would be an invitation to make the switch non-exhaustive.
        .only_matching, .line_num, .filename, .before, .after, .mode, .include_zero, .max_cols, .max_cols_set, .max_cols_preview, .passthru, .field_match_sep, .field_ctx_sep, .path_sep, .column, .byte_offset, .vimgrep, .heading, .trim, .null_sep, .quiet, .stats, .replace, .sorted, .sort_key, .sort_reverse, .ctx_sep, .color, .hyperlink, .hyperlink_bare, .hyperlink_format, .hostname_bin, .palette, .rank, .rank_k, .uncap, .messages, .ignore_messages, .plain => .presentation,
        // Tier and topology: the answer is identical either way. Buffering is
        // the purest member of the class — it changes only how many syscalls
        // the same bytes take to reach the same reader.
        .threads, .no_index, .buffering, .buffer_size => .execution,
    };
}

/// How far this row's effect travels, or `null` for a row that never takes
/// effect at all (`.unsupported` fails loud before applying). Null is not
/// "harmless" — a caller validating a persisted setting must reject it.
pub fn reachOf(spec: FlagSpec) ?Reach {
    return switch (spec.action) {
        .set, .unset, .set_num, .set_str, .sep => |f| fieldReach(f),
        .set_many => |fs| fieldReach(fs[0]),
        .num_set => |p| fieldReach(p[0]),
        .glob_ci, .typ, .genus_pick, .glob, .maxfsize, .ignore_file, .type_add, .type_clear, .encoding, .encoding_is, .pre_glob, .pre_off, .unrestrict => .corpus,
        .case, .boundary, .regexp, .file, .engine, .engine_is => .semantics,
        .filename, .locate, .mode, .mode_off, .passthru, .sort_files, .sort, .ctx_at, .no_ctxsep, .replace, .color, .colors, .rank, .hyperlink, .pretty, .plain => .presentation,
        .noop, .noop_val, .buffered, .bufsize => .execution,
        // `.unsupported` dies before applying; `.no_config` has already been
        // applied by the pre-argv scan. Null is not "harmless" — it is what
        // makes a persisted layer reject the row, which is exactly right for a
        // flag whose whole job is to disable the persisted layers.
        .unsupported, .no_config => null,
    };
}

pub const flag_catalog = [_]FlagSpec{
    .{ .short = 'i', .longs = &.{"ignore-case"}, .action = .{ .case = .icase }, .doc = "match case-insensitively", .compatibility = .supported, .note = "Unicode case folding by default (full simple case-fold orbits); (?-u)/--no-unicode selects ASCII folding" },
    .{ .short = 's', .longs = &.{"case-sensitive"}, .action = .{ .case = .scase }, .doc = "match case-sensitively", .compatibility = .supported },
    .{ .short = 'S', .longs = &.{"smart-case"}, .action = .{ .case = .smart }, .doc = "match case-insensitively unless the pattern has uppercase", .compatibility = .supported, .note = "codepoint-aware uppercase detection and Unicode folding by default; (?-u)/--no-unicode selects ASCII" },
    .{ .short = 'w', .longs = &.{"word-regexp"}, .action = .{ .boundary = .word }, .doc = "require a word boundary on both sides of a match", .compatibility = .supported, .note = "-w and regex \\b/\\w use Unicode word characters by default (rg parity); (?-u)/--no-unicode selects ASCII byte word chars" },
    .{ .short = 'F', .longs = &.{"fixed-strings"}, .action = .{ .set = .fixed }, .doc = "read the pattern as literal bytes, not a regex", .compatibility = .supported },
    .{ .short = 'v', .longs = &.{"invert-match"}, .action = .{ .set = .invert }, .doc = "print the lines that do not match", .compatibility = .supported },
    .{ .short = 'o', .longs = &.{"only-matching"}, .action = .{ .set = .only_matching }, .doc = "print only the matched part of each line", .compatibility = .supported },
    .{ .short = 'n', .longs = &.{"line-number"}, .action = .{ .locate = .line_on }, .doc = "prefix each line with its line number", .compatibility = .supported },
    .{ .short = 'N', .longs = &.{"no-line-number"}, .action = .{ .locate = .line_off }, .doc = "omit line numbers", .compatibility = .supported },
    .{ .short = 'H', .longs = &.{"with-filename"}, .action = .{ .filename = .always }, .doc = "prefix each line with its file path", .compatibility = .supported },
    .{ .short = 'I', .longs = &.{"no-filename"}, .action = .{ .filename = .never }, .doc = "omit file paths", .compatibility = .supported },
    .{ .short = 'l', .longs = &.{"files-with-matches"}, .action = .{ .mode = .files_with_matches }, .doc = "print only the paths that contain a match", .compatibility = .supported },
    .{ .longs = &.{"files-without-match"}, .action = .{ .mode = .files_without_match }, .doc = "print only the paths that contain no match", .compatibility = .supported },
    .{ .short = 'c', .longs = &.{"count"}, .action = .{ .mode = .count }, .doc = "print how many lines matched, per file", .compatibility = .supported },
    .{ .longs = &.{"count-matches"}, .action = .{ .mode = .count_matches }, .doc = "print how many matches there were, per file", .compatibility = .supported },
    .{ .longs = &.{"include-zero"}, .action = .{ .set = .include_zero }, .doc = "in a count mode, also print the files with no match", .compatibility = .supported, .note = "in a count mode, print a path:0 line for every searched file with no match (exit code unchanged)" },
    .{ .longs = &.{"no-include-zero"}, .action = .{ .unset = .include_zero }, .doc = "omit zero-count files, the default", .compatibility = .supported },
    .{ .longs = &.{"hidden"}, .action = .{ .set = .hidden }, .doc = "search hidden files and directories", .compatibility = .supported },
    .{ .short = 'a', .longs = &.{"text"}, .action = .{ .set = .text }, .doc = "search binary files as if they were text", .compatibility = .supported },
    .{ .longs = &.{"binary"}, .action = .{ .set = .binary }, .doc = "search binary files and print every matching line", .compatibility = .improvement, .note = "improvement: a code locator searches a NUL-bearing file in full and prints every matching line, rather than rg's opaque 'binary file matches' summary that suppresses the lines and stops" },
    .{ .short = 'u', .longs = &.{"unrestricted"}, .action = .unrestrict, .doc = "filter less: -u ignore rules, -uu also hidden, -uuu also binary", .compatibility = .supported, .note = "-u=--no-ignore, -uu adds hidden, -uuu adds --binary; the ignore/hidden ladder is rg-identical, -uuu inherits the --binary improvement" },
    .{ .longs = &.{"column"}, .action = .{ .locate = .column_on }, .doc = "print the column of the first match on each line", .compatibility = .supported },
    .{ .longs = &.{"no-column"}, .action = .{ .locate = .column_off }, .doc = "omit columns", .compatibility = .supported },
    .{ .short = 'b', .longs = &.{"byte-offset"}, .action = .{ .set = .byte_offset }, .doc = "print the byte offset of each matching line", .compatibility = .supported },
    .{ .longs = &.{"vimgrep"}, .action = .{ .set = .vimgrep }, .doc = "one line per match, in vim's quickfix shape", .compatibility = .supported },
    .{ .longs = &.{"heading"}, .action = .{ .locate = .heading_on }, .doc = "group matches under their filename", .compatibility = .supported, .note = "on by default when stdout is a terminal, like ripgrep; piped output stays prefixed" },
    .{ .longs = &.{"no-heading"}, .action = .{ .locate = .heading_off }, .doc = "prefix every line with its path instead of grouping", .compatibility = .supported },
    .{ .longs = &.{"trim"}, .action = .{ .set = .trim }, .doc = "strip leading whitespace from every printed line", .compatibility = .supported },
    .{ .short = '0', .longs = &.{"null"}, .action = .{ .set = .null_sep }, .doc = "terminate each printed path with NUL", .compatibility = .supported },
    .{ .longs = &.{"null-data"}, .action = .{ .set = .null_data }, .doc = "treat NUL, not newline, as the line terminator", .compatibility = .supported },
    .{ .short = 'x', .longs = &.{"line-regexp"}, .action = .{ .boundary = .line }, .doc = "require the pattern to match a whole line", .compatibility = .supported },
    .{ .short = 'q', .longs = &.{"quiet"}, .action = .{ .set = .quiet }, .doc = "print nothing and stop at the first match", .compatibility = .supported },
    .{ .longs = &.{"stats"}, .action = .{ .set = .stats }, .doc = "print search statistics after the results", .compatibility = .supported },
    .{ .longs = &.{"stop-on-nonmatch"}, .action = .{ .set = .stop_on_nonmatch }, .doc = "stop a file at its first non-matching line", .compatibility = .supported },
    .{ .longs = &.{ "passthru", "passthrough" }, .action = .passthru, .doc = "print every line, matching or not", .compatibility = .supported },
    .{ .longs = &.{"max-columns-preview"}, .action = .{ .set = .max_cols_preview }, .doc = "show a truncated preview of an elided long line", .compatibility = .supported },
    .{ .longs = &.{"field-match-separator"}, .action = .{ .sep = .field_match_sep }, .doc = "the separator between a match line's fields", .compatibility = .supported },
    .{ .longs = &.{"field-context-separator"}, .action = .{ .sep = .field_ctx_sep }, .doc = "the separator between a context line's fields", .compatibility = .supported },
    .{ .longs = &.{"crlf"}, .action = .{ .set = .crlf }, .doc = "treat CRLF as the line terminator", .compatibility = .supported },
    .{ .short = 'U', .longs = &.{"multiline"}, .action = .{ .set = .multiline }, .doc = "let one match span line boundaries", .compatibility = .supported },
    .{ .longs = &.{"multiline-dotall"}, .action = .{ .set_many = &.{ .multiline, .multiline_dotall } }, .doc = "multiline, and let . match a newline too", .compatibility = .supported },
    .{ .longs = &.{"json"}, .action = .{ .mode = .json }, .doc = "emit results as JSON Lines", .compatibility = .supported },
    .{ .longs = &.{"files"}, .action = .{ .mode = .files }, .doc = "list every file that would be searched", .compatibility = .supported },
    .{ .longs = &.{"type-list"}, .action = .{ .mode = .types }, .doc = "list every file type and the globs it covers", .compatibility = .improvement, .note = "improvement: rg-sorted, rg-framed output over a strict SUPERSET of rg's type registry (rg's rows byte-identical; the rest richer, plus gist-only types)" },
    .{ .short = 'L', .longs = &.{"follow"}, .action = .{ .set = .follow }, .doc = "follow symbolic links", .compatibility = .supported },
    .{ .longs = &.{"no-follow"}, .action = .{ .unset = .follow }, .doc = "do not follow symbolic links", .compatibility = .supported },
    .{ .longs = &.{"sort-files"}, .action = .{ .sort_files = true }, .doc = "sort by path (rg's deprecated spelling of --sort=path)", .compatibility = .supported, .note = "deprecated rg spelling of --sort=path" },
    .{ .longs = &.{"sort"}, .action = .{ .sort = false }, .doc = "sort the results ascending by this key", .compatibility = .improvement, .note = "improvement: path/modified/accessed/created, ascending; final ordering is rg-identical but produced over a parallel read (rg single-threads sort), and created falls back to ctime where the platform lacks birth time (rg cannot sort at all)" },
    .{ .longs = &.{"sortr"}, .action = .{ .sort = true }, .doc = "sort the results descending by this key", .compatibility = .improvement, .note = "improvement: as --sort but descending; same rg-identical ordering over a parallel read and the same created→ctime robustness fallback" },
    .{ .longs = &.{"glob-case-insensitive"}, .action = .{ .glob_ci = true }, .doc = "match every --glob case-insensitively", .compatibility = .supported },
    .{ .short = 'A', .longs = &.{"after-context"}, .action = .{ .ctx_at = .after }, .doc = "print this many lines after each match", .compatibility = .supported },
    .{ .short = 'B', .longs = &.{"before-context"}, .action = .{ .ctx_at = .before }, .doc = "print this many lines before each match", .compatibility = .supported },
    .{ .short = 'C', .longs = &.{"context"}, .action = .{ .ctx_at = .ctx }, .doc = "print this many lines on both sides of each match", .compatibility = .supported },
    .{ .short = 'm', .longs = &.{"max-count"}, .action = .{ .num_set = .{ .max_per_file, .max_per_file_set } }, .doc = "stop after this many matches in each file", .compatibility = .supported },
    .{ .short = 'e', .longs = &.{"regexp"}, .action = .regexp, .doc = "add a pattern; repeatable, and safe for one starting with a dash", .compatibility = .supported },
    .{ .short = 't', .longs = &.{"type"}, .action = .{ .typ = false }, .doc = "search only files of this type", .compatibility = .supported },
    .{ .short = 'T', .longs = &.{"type-not"}, .action = .{ .typ = true }, .doc = "skip files of this type", .compatibility = .supported },
    // The corpus partition (`corpus/scope/genus.zig`) — every path is exactly
    // one of code/docs/data, so each pair below is an exact complement. `-t` can
    // spell all three too; these exist because the question is asked constantly
    // and `--docs` is what a caller reaches for before reading any manual.
    .{ .longs = &.{"docs"}, .action = .{ .genus_pick = .{ .name = "docs", .negate = false } }, .doc = "search only documentation and prose", .compatibility = .native, .note = "the docs genus: prose and markup you read to understand (markdown, rst, asciidoc, org, man, tex, LICENSE, CHANGELOG, and files under docs//man/), plus anything a documentation directory promotes that no language type claimed. Equivalent to -t docs; no rg counterpart (rg has 13 prose-adjacent types and no aggregate over them)" },
    .{ .longs = &.{"no-docs"}, .action = .{ .genus_pick = .{ .name = "docs", .negate = true } }, .doc = "skip documentation and prose", .compatibility = .native, .note = "the exact complement of --docs: equivalent to -T docs, and the fastest way to stop a symbol search from surfacing every ADR that merely mentions it" },
    .{ .longs = &.{"code"}, .action = .{ .genus_pick = .{ .name = "code", .negate = false } }, .doc = "search only source code", .compatibility = .native, .note = "the code genus, which is the DEFAULT side of the partition: source, build recipes, IDLs, schemas, and anything unrecognized — so an unknown extension is searched rather than silently dropped. Equivalent to -t code" },
    .{ .longs = &.{"no-code"}, .action = .{ .genus_pick = .{ .name = "code", .negate = true } }, .doc = "skip source code", .compatibility = .native, .note = "the exact complement of --code (≡ -T code): what is left is docs and data, the paper trail plus the configuration" },
    .{ .longs = &.{"data"}, .action = .{ .genus_pick = .{ .name = "data", .negate = false } }, .doc = "search only data and configuration", .compatibility = .native, .note = "the data genus: serialization and configuration payload (json, yaml, toml, csv, plist, lockfiles, logs, patches, compressed bytes). Equivalent to -t data" },
    .{ .longs = &.{"no-data"}, .action = .{ .genus_pick = .{ .name = "data", .negate = true } }, .doc = "skip data and configuration", .compatibility = .native, .note = "the exact complement of --data (≡ -T data), which is how you keep a lockfile or a generated fixture from burying the four real call sites" },
    .{ .short = 'g', .longs = &.{"glob"}, .action = .{ .glob = false }, .doc = "include paths matching this glob, or exclude with a leading !", .compatibility = .supported },
    .{ .longs = &.{"iglob"}, .action = .{ .glob = true }, .doc = "as --glob, matched case-insensitively", .compatibility = .supported },
    .{ .short = 'M', .longs = &.{"max-columns"}, .action = .{ .num_set = .{ .max_cols, .max_cols_set } }, .doc = "elide any line longer than this many columns", .compatibility = .supported },
    .{ .longs = &.{"path-separator"}, .action = .{ .set_str = .path_sep }, .doc = "the separator printed between path components", .compatibility = .supported },
    .{ .longs = &.{ "max-depth", "maxdepth" }, .action = .{ .set_num = .max_depth }, .doc = "descend at most this many directories", .compatibility = .supported },
    .{ .longs = &.{"max-filesize"}, .action = .maxfsize, .doc = "skip files larger than this size", .compatibility = .supported },
    .{ .longs = &.{"context-separator"}, .action = .{ .sep = .ctx_sep }, .doc = "the line printed between non-adjacent context blocks", .compatibility = .supported },
    .{ .longs = &.{"no-context-separator"}, .action = .no_ctxsep, .doc = "print nothing between context blocks", .compatibility = .supported },
    .{ .short = 'r', .longs = &.{"replace"}, .action = .replace, .doc = "print this text in place of each match", .compatibility = .supported },
    .{ .short = 'f', .longs = &.{"file"}, .action = .file, .doc = "read patterns from a file, one per line", .compatibility = .supported },
    .{ .longs = &.{"type-add"}, .action = .type_add, .doc = "define or extend a file type, as name:glob", .compatibility = .supported },
    .{ .longs = &.{"color"}, .action = .color, .doc = "when to colorize the output", .compatibility = .supported },
    // OSC-8 hyperlinks. One flag spans the whole axis (posture, alias, or a
    // literal format), and it is ON by default wherever the terminal is known
    // to render it — rg requires learning --hyperlink-format AND an alias, and
    // then routes the result through its color path so NO_COLOR kills it.
    .{ .longs = &.{ "hyperlink", "link" }, .action = .{ .hyperlink = .flag }, .doc = "make paths clickable: a posture, an editor alias, or a format", .compatibility = .improvement, .note = "improvement: bare --hyperlink forces links on; --hyperlink=auto|always|never sets the posture; --hyperlink=<alias|format> picks the destination AND turns links on. Default is auto (on for a human-shaped run in a terminal known to render OSC-8, off otherwise) where rg defaults to none, and gist never ties links to --color/NO_COLOR. GIST_HYPERLINK=<alias> is the standing-preference spelling: it names the destination but leaves the auto probe to decide whether" },
    .{ .longs = &.{ "no-hyperlink", "no-link" }, .action = .{ .hyperlink = .off }, .doc = "never emit hyperlinks", .compatibility = .native },
    .{ .longs = &.{"hyperlink-format"}, .action = .{ .hyperlink = .format }, .doc = "the hyperlink template, or an editor alias", .compatibility = .improvement, .note = "improvement: rg's spelling and grammar exactly ({path}/{line}/{column}/{host}/{wslprefix}, {{ }} escapes, same validation), plus the aliases rg lacks (zed, windsurf, vscode-remote, cursor-remote) and lexical path folding instead of a realpath(2) per matched file" },
    .{ .longs = &.{"hostname-bin"}, .action = .{ .set_str = .hostname_bin }, .doc = "a command whose output supplies {host} in a hyperlink", .compatibility = .supported, .note = "unset uses gethostname(2). Exists because inside WSL or a container the kernel's own name is not the one a link has to reach" },
    // Ignore-rule controls honored by the in-tree .gitignore/.ignore engine.
    .{ .longs = &.{"no-ignore"}, .action = .{ .set = .no_ignore }, .doc = "obey no ignore file at all", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-vcs"}, .action = .{ .set = .no_ignore_vcs }, .doc = "obey no .gitignore rules", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-dot"}, .action = .{ .set = .no_ignore_dot }, .doc = "obey no .ignore rules", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-parent"}, .action = .{ .set = .no_ignore_parent }, .doc = "obey no ignore rules from parent directories", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-exclude"}, .action = .{ .set = .no_ignore_exclude }, .doc = "obey no .git/info/exclude rules", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-files"}, .action = .{ .set = .no_ignore_files }, .doc = "obey no --ignore-file source", .compatibility = .supported },
    // --ignore-files re-enables --ignore-file sources after --no-ignore-files.
    .{ .longs = &.{"ignore-files"}, .action = .{ .unset = .no_ignore_files }, .doc = "obey --ignore-file sources again", .compatibility = .supported },
    .{ .longs = &.{"no-require-git"}, .action = .{ .set = .no_require_git }, .doc = "apply git ignore rules outside a repository too", .compatibility = .supported },
    // --require-git undoes an earlier --no-require-git.
    .{ .longs = &.{"require-git"}, .action = .{ .unset = .no_require_git }, .doc = "apply git ignore rules only inside a repository", .compatibility = .supported },
    .{ .longs = &.{"ignore-file-case-insensitive"}, .action = .{ .set = .ignore_case_insensitive }, .doc = "match ignore-file globs case-insensitively", .compatibility = .supported },
    .{ .longs = &.{"ignore-file"}, .action = .ignore_file, .doc = "read more ignore rules from this file", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-global"}, .action = .{ .set = .no_ignore_global }, .doc = "obey no global git excludesFile", .compatibility = .supported, .note = "git core.excludesFile ($HOME/.gitconfig or $XDG_CONFIG_HOME/git/config → default $XDG_CONFIG_HOME/git/ignore) is read by default in a repo; this disables that global tier only" },
    // The two stderr lanes. Suppression is cosmetic on purpose: rg keeps the
    // failure in the exit code and only withholds the prose, so a script that
    // silences the noise still learns something went wrong.
    .{ .longs = &.{"no-messages"}, .action = .{ .unset = .messages }, .doc = "suppress per-file errors, but not the exit code they set", .compatibility = .supported, .note = "suppress the per-file stderr lane (unreadable path, symlink loop, --pre failure, 'no files were searched'); as in rg the exit code is unchanged, so a silenced error still exits 2" },
    .{ .longs = &.{"messages"}, .action = .{ .set = .messages }, .doc = "print per-file errors", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-messages"}, .action = .{ .unset = .ignore_messages }, .doc = "suppress errors from unreadable ignore sources", .compatibility = .supported, .note = "suppress the narrower ignore-source lane (an --ignore-file that will not open); --no-messages subsumes it. gist's ignore parser accepts every line rg's glob compiler would reject, so this lane carries unreadable sources rather than rg's parse errors" },
    .{ .longs = &.{"ignore-messages"}, .action = .{ .set = .ignore_messages }, .doc = "print errors from unreadable ignore sources", .compatibility = .supported },
    // Gist-native index controls are not ripgrep compatibility claims.
    .{ .longs = &.{"no-index"}, .action = .{ .set = .no_index }, .doc = "scan live, ignoring any persisted index", .compatibility = .native },
    .{ .longs = &.{"index"}, .action = .{ .unset = .no_index }, .doc = "use the persisted index when one is current", .compatibility = .native },
    .{ .longs = &.{"rank"}, .action = .rank, .doc = "ranked view: definitions first, generated files demoted", .compatibility = .native },
    // --uncap: lift the soft output budget (hard OOM ceiling still applies).
    .{ .longs = &.{"uncap"}, .action = .{ .set = .uncap }, .doc = "lift the soft output budget for this query", .compatibility = .native, .note = "lift the ~25k-token soft output cap for this query; the hard OOM ceiling still applies (GIST_UNCAP=1 is the env form)" },
    // --in-comments / --in-code: native comment/code match scoping (lexspan.zig).
    .{ .longs = &.{"in-comments"}, .action = .{ .set = .in_comments }, .doc = "keep only the matches that fall inside a comment", .compatibility = .native, .note = "keep only matches whose span begins inside a //, #, or /* */ comment (native span-lexed view; mutually exclusive with --in-code)" },
    .{ .longs = &.{"in-code"}, .action = .{ .set = .in_code }, .doc = "keep only the matches that fall outside every comment", .compatibility = .native, .note = "keep only matches OUTSIDE any comment (native span-lexed view; mutually exclusive with --in-comments)" },
    // Accepted spellings whose requested behavior is intentionally not applied.
    .{ .longs = &.{ "mmap", "no-mmap" }, .action = .noop, .doc = "accepted for rg parity; gist picks its own read strategy", .compatibility = .accepted_but_ignored },
    // --no-config: read from raw argv before either persisted layer is opened,
    // so it can suppress the file that would otherwise have supplied flags.
    .{ .longs = &.{"no-config"}, .action = .no_config, .compatibility = .supported, .doc = "ignore the committed charter and the personal preferences file", .note = "suppresses .irregex.toml and $XDG_CONFIG_HOME/gist/preferences for this run; GIST_NO_CONFIG=1 is the environment spelling. Read from raw argv before either file is opened" },
    .{ .longs = &.{"one-file-system"}, .action = .{ .set = .one_file_system }, .doc = "do not descend across a filesystem boundary", .compatibility = .supported },
    // --unicode / --no-unicode: linear-engine Unicode mode on (rg default) / off (byte/ASCII).
    .{ .longs = &.{"unicode"}, .action = .{ .set = .unicode }, .doc = "Unicode mode: codepoint classes and full case folding", .compatibility = .supported, .note = "linear-engine Unicode mode (rg default): full case-fold orbits, codepoint \\w/\\d/\\s/./\\p{…}, and Unicode \\b/\\B/\\<\\>/-w" },
    .{ .longs = &.{"no-unicode"}, .action = .{ .unset = .unicode }, .doc = "byte mode: single-byte classes and ASCII word boundaries", .compatibility = .supported, .note = "byte/ASCII mode: single-byte classes and ASCII \\w/\\b (equivalent to a leading (?-u))" },
    .{ .longs = &.{"no-stats"}, .action = .{ .unset = .stats }, .doc = "print no search statistics", .compatibility = .supported },
    .{ .longs = &.{"no-trim"}, .action = .{ .unset = .trim }, .doc = "keep leading whitespace", .compatibility = .supported },
    // ------------------------------------------------------------------
    // The undo half of the surface.
    //
    // Every ripgrep toggle ships an inverse, and the inverse is not a
    // convenience — it is the ONLY way to countermand a flag that arrived from
    // somewhere the caller did not type: an alias, a `RIPGREP_CONFIG_PATH`
    // file, or (here) `.irregex.toml` and the personal preferences file. A
    // surface that can turn a behavior on and not off is a surface whose
    // persisted layer is a one-way door, so these rows are load-bearing for
    // gist's own config layers and not merely for rg parity.
    //
    // They were missing until a conformance sweep over `rg --generate
    // complete-bash` counted them (bench/rgsuite/surface.py): 35 flags that
    // ripgrep documents and gist rejected. The mined suite could not see the
    // hole, because ripgrep's own integration tests do not exercise most of
    // its negations either — which is exactly why the denominator has to come
    // from the flag table rather than from the tests.
    //
    // Each row below is the inverse of a row above it, and last-spelling-wins
    // falls out of the parser's single pass with no precedence rule needed.
    .{ .longs = &.{"no-hidden"}, .action = .{ .unset = .hidden }, .doc = "skip hidden files and directories, the default", .compatibility = .supported },
    .{ .longs = &.{"no-text"}, .action = .{ .unset = .text }, .doc = "apply binary detection again, the default", .compatibility = .supported },
    .{ .longs = &.{"no-binary"}, .action = .{ .unset = .binary }, .doc = "stop at a binary file's first NUL, the default", .compatibility = .supported },
    .{ .longs = &.{"no-crlf"}, .action = .{ .unset = .crlf }, .doc = "treat only LF as the line terminator, the default", .compatibility = .supported },
    .{ .longs = &.{"no-byte-offset"}, .action = .{ .unset = .byte_offset }, .doc = "print no byte offsets, the default", .compatibility = .supported },
    .{ .longs = &.{"no-invert-match"}, .action = .{ .unset = .invert }, .doc = "print the matching lines, the default", .compatibility = .supported },
    .{ .longs = &.{"no-fixed-strings"}, .action = .{ .unset = .fixed }, .doc = "read the pattern as a regex, the default", .compatibility = .supported },
    .{ .longs = &.{"no-multiline"}, .action = .{ .unset = .multiline }, .doc = "confine each match to one line, the default", .compatibility = .supported },
    .{ .longs = &.{"no-multiline-dotall"}, .action = .{ .unset = .multiline_dotall }, .doc = "keep . from matching a newline, the default", .compatibility = .supported },
    .{ .longs = &.{"no-one-file-system"}, .action = .{ .unset = .one_file_system }, .doc = "descend across filesystem boundaries, the default", .compatibility = .supported },
    .{ .longs = &.{"no-search-zip"}, .action = .{ .unset = .search_zip }, .doc = "do not decompress before searching, the default", .compatibility = .supported },
    .{ .longs = &.{"no-max-columns-preview"}, .action = .{ .unset = .max_cols_preview }, .doc = "elide a long line without a preview, the default", .compatibility = .supported },
    .{ .longs = &.{"no-ignore-file-case-insensitive"}, .action = .{ .unset = .ignore_case_insensitive }, .doc = "match ignore-file globs case-sensitively, the default", .compatibility = .supported },
    // The six positive partners of the --no-ignore-* family: each CLEARS the
    // suppression its --no- sibling sets, restoring that one ignore tier.
    .{ .longs = &.{"ignore"}, .action = .{ .unset = .no_ignore }, .doc = "obey ignore files again", .compatibility = .supported },
    .{ .longs = &.{"ignore-vcs"}, .action = .{ .unset = .no_ignore_vcs }, .doc = "obey .gitignore rules again", .compatibility = .supported },
    .{ .longs = &.{"ignore-dot"}, .action = .{ .unset = .no_ignore_dot }, .doc = "obey .ignore rules again", .compatibility = .supported },
    .{ .longs = &.{"ignore-parent"}, .action = .{ .unset = .no_ignore_parent }, .doc = "obey parent-directory ignore rules again", .compatibility = .supported },
    .{ .longs = &.{"ignore-exclude"}, .action = .{ .unset = .no_ignore_exclude }, .doc = "obey .git/info/exclude rules again", .compatibility = .supported },
    .{ .longs = &.{"ignore-global"}, .action = .{ .unset = .no_ignore_global }, .doc = "obey the global git excludesFile again", .compatibility = .supported },
    // Inverses that land on an existing axis rather than a bool: each of these
    // reuses the very action its positive spelling uses, aimed at the default.
    .{ .longs = &.{"no-pcre2"}, .action = .{ .engine_is = .default }, .doc = "use the linear engine again, the default", .compatibility = .supported },
    .{ .longs = &.{"no-auto-hybrid-regex"}, .action = .{ .engine_is = .default }, .doc = "do not escalate to PCRE2, the default", .compatibility = .supported },
    .{ .longs = &.{"no-line-buffered"}, .action = .{ .buffered = .auto }, .doc = "let the destination pick the cadence, the default", .compatibility = .supported },
    .{ .longs = &.{"no-block-buffered"}, .action = .{ .buffered = .auto }, .doc = "let the destination pick the cadence, the default", .compatibility = .supported },
    .{ .longs = &.{"no-encoding"}, .action = .{ .encoding_is = .auto }, .doc = "auto-detect the encoding again, the default", .compatibility = .supported },
    .{ .longs = &.{"no-glob-case-insensitive"}, .action = .{ .glob_ci = false }, .doc = "match every --glob case-sensitively, the default", .compatibility = .supported },
    .{ .longs = &.{"no-sort-files"}, .action = .{ .sort_files = false }, .doc = "return to the fastest discovery order, the default", .compatibility = .supported },
    .{ .longs = &.{"no-json"}, .action = .{ .mode_off = .json }, .doc = "emit text again, the default", .compatibility = .supported },
    .{ .longs = &.{"no-pre"}, .action = .pre_off, .doc = "run no preprocessor, the default", .compatibility = .supported, .note = "clears --pre AND every --pre-glob, as in rg — a preprocessor scope with no preprocessor is not a state a caller can act on" },
    .{ .longs = &.{"type-clear"}, .action = .type_clear, .doc = "forget a file type's definition entirely", .compatibility = .supported, .note = "as in rg, a cleared name is no longer a type at all: a later -t/-T naming it fails loud with 'unrecognized type', and --type-add may define it afresh" },
    // rg's own diagnostic channel. rg writes these to STDERR and leaves stdout
    // and the exit code untouched, so accepting them changes nothing a caller
    // reads — gist's equivalent lane is GIST_TRACE=<lens>, whose vocabulary is
    // its own and deliberately not pretended to be rg's.
    .{ .longs = &.{ "debug", "trace" }, .action = .noop, .doc = "accepted for rg parity; gist's own lane is GIST_TRACE", .compatibility = .accepted_but_ignored, .note = "rg emits its debug/trace prose on stderr and leaves stdout and the exit code alone, so this is accepted and ignored rather than mapped: GIST_TRACE=amend,warm,query,… selects gist's own phase lenses, which are not rg's vocabulary" },
    .{ .longs = &.{"colors"}, .action = .colors, .doc = "restyle one element: {type}:none or {type}:{fg|bg|style}:{value}", .compatibility = .supported, .note = "rg's spec grammar exactly (path/line/column/match × fg/bg/style, named colors, 0-255, r,g,b), merged into gist's palette the way rg's merge into its own — so naming a hue keeps the default's bold. gist renders one SGR sequence per element where rg emits a separate escape per attribute, and paints column numbers only when a spec asks for them" },
    .{ .short = 'j', .longs = &.{"threads"}, .action = .{ .set_num = .threads }, .doc = "cap the worker pool at this many, or 0 for gist's own topology", .compatibility = .supported, .note = "caps the work-stealing worker pool at N (0 = gist's own topology), the same bound rg's -j sets; results are identical" },
    // Match-backend selection. `--engine default` is the linear engine; `--engine
    // auto` compiles linear and escalates to the PCRE2 backend only for a pattern
    // the linear engine declines; `--engine pcre2` / `-P` select PCRE2 outright.
    .{ .longs = &.{"engine"}, .action = .engine, .doc = "which match backend to compile the pattern with", .compatibility = .supported, .note = "default/auto/pcre2 select the engine exactly as rg: default = linear RE2/Pike, auto escalates to PCRE2 only for lookaround/backreferences the linear engine declines, pcre2 selects PCRE2 outright (the gist-native --rank is linear-only)" },
    // PCRE2 Unicode (UTF+UCP) mode — effective under -P / escalated auto; inert
    // under the linear default, which is always ASCII-byte based.
    .{ .longs = &.{"pcre2-unicode"}, .action = .{ .set = .pcre_unicode }, .doc = "PCRE2 Unicode mode, under -P or an escalated --engine auto", .compatibility = .supported, .note = "PCRE2 UTF+UCP mode (rg's -P default); as in rg it governs the PCRE2 backend, effective under -P/auto and inert under gist's extra linear default" },
    .{ .longs = &.{"no-pcre2-unicode"}, .action = .{ .unset = .pcre_unicode }, .doc = "PCRE2 raw-byte mode, under the same two backends", .compatibility = .supported, .note = "PCRE2 raw-byte/ASCII mode; as in rg it governs the PCRE2 backend, effective under -P/auto and inert under gist's extra linear default" },
    .{ .longs = &.{ "dfa-size-limit", "regex-size-limit" }, .action = .noop_val, .doc = "accepted for rg parity; gist's engines have no such ceiling", .compatibility = .accepted_but_ignored },
    // The opt-in PCRE2 JIT backend (vendored 10.47) and rg's deprecated hybrid alias.
    .{ .short = 'P', .longs = &.{"pcre2"}, .action = .{ .engine_is = .pcre2 }, .doc = "use PCRE2: lookaround, backreferences, Unicode properties", .compatibility = .improvement, .note = "improvement: the vendored PCRE2 JIT backend (lookaround, backreferences, Unicode properties) yields rg's exact -P match set, but trigram-prefiltered like the linear engine — the only INDEXED PCRE search in the field (the gist-native --rank is linear-only)" },
    .{ .longs = &.{"auto-hybrid-regex"}, .action = .{ .engine_is = .auto }, .doc = "escalate to PCRE2 only when needed (rg's spelling of --engine auto)", .compatibility = .supported, .note = "rg's own deprecated spelling of --engine auto; escalates to PCRE2 only for a pattern the linear engine declines" },
    // Content-transform flags: decompression + preprocessing + transcoding. The
    // common compressed formats decode in-process (no fork) — see `ingest.zig`.
    .{ .short = 'z', .longs = &.{"search-zip"}, .action = .{ .set = .search_zip }, .doc = "search inside compressed files", .compatibility = .improvement, .note = "improvement: identical results to rg across every codec, but gzip/zlib/zstd/xz decode IN-PROCESS (no per-file `gzip -dc` fork); bzip2/lz4/brotli/lzma/.Z shell the standard tool exactly as rg does" },
    .{ .longs = &.{"pre"}, .action = .{ .set_str = .pre }, .doc = "filter every file through this command before searching it", .compatibility = .supported, .note = "rg parity: the command receives the file path as argv[1] AND the file's bytes on stdin; a non-zero exit is an error (exit 2)" },
    .{ .longs = &.{"pre-glob"}, .action = .pre_glob, .doc = "run --pre only on the paths matching this glob", .compatibility = .supported },
    .{ .short = 'E', .longs = &.{"encoding"}, .action = .encoding, .doc = "decode input with this character encoding", .compatibility = .supported, .note = "auto/none + the full WHATWG label table (rg's encoding_rs set): UTF-8/16, the single-byte pages, and CJK gb18030/GBK, Big5, EUC-JP, Shift_JIS, EUC-KR, ISO-2022-JP; an unrecognized label fails loud" },
    // Delivery cadence — the same bytes, in a different number of syscalls.
    .{ .longs = &.{"line-buffered"}, .action = .{ .buffered = .line }, .compatibility = .improvement, .doc = "flush every finished line as it is found", .note = "improvement: no finished line is ever held, but every finished line already in hand leaves in ONE write — rg's LineWriter pays one syscall per line for the same interactivity. The boundary is the run's real terminator, so --null-data records flush on NUL (rg's line writer only knows \\n)" },
    .{ .longs = &.{"block-buffered"}, .action = .{ .buffered = .block }, .compatibility = .improvement, .doc = "coalesce output into ramped blocks", .note = "improvement: a RAMPED block — the first fragment is never held and the threshold then doubles to the ceiling, so `| head -1` answers immediately and a closed pipe is discovered within a kilobyte; rg's BufWriter holds the first byte as long as the last. Size it with --buffer-size (rg's 8 KiB is a constant)" },
    .{ .longs = &.{"buffer-size"}, .action = .bufsize, .compatibility = .native, .doc = "size the coalescing buffer (default 64K; 0 = unbuffered)", .note = "ceiling for the held bytes, in bytes with an optional K/M suffix (default 64K, a Linux pipe's capacity). Implies --block-buffered when no cadence was named; 0 holds nothing at all, so every fragment becomes its own write" },
    // The two presentation poles.
    .{ .short = 'p', .longs = &.{"pretty"}, .action = .pretty, .compatibility = .supported, .doc = "color, heading, and line numbers at once", .note = "rg's alias for --color always --heading --line-number; a later -N/--no-heading/--color still wins" },
    .{ .longs = &.{"plain"}, .action = .plain, .compatibility = .native, .doc = "print what a pipe would receive, on a terminal", .note = "the inverse pole: pin the answer to what a PIPE would receive even on a terminal — --color never, no long-line elision, block-buffered — so a terminal run and a redirected one differ in nothing the destination decides. Walk ORDER is not a destination decision: pin it with --sort path, exactly as a piped run must" },
};

pub const long_map = std.StaticStringMap(usize).initComptime(blk: {
    var pairs: []const struct { []const u8, usize } = &.{};
    for (flag_catalog, 0..) |spec, spec_i| for (spec.longs) |name| {
        pairs = pairs ++ .{.{ name, spec_i }};
    };
    break :blk pairs;
});
pub const short_map: [256]?usize = blk: {
    var map: [256]?usize = @splat(null);
    for (flag_catalog, 0..) |spec, spec_i| if (spec.short) |short| {
        if (map[short] != null) @compileError("duplicate short flag in flag_catalog");
        map[short] = spec_i;
    };
    break :blk map;
};

test "flag catalog is the parser compatibility source of truth" {
    const t = std.testing;
    var bucket_counts: [4]usize = @splat(0);
    // Post-Unicode-flip: -i/-S/-w are `supported` (rg-parity, Unicode by default),
    // and --unicode/--no-unicode are real `supported` flags (no longer ignored).
    var i_supported = false;
    var word_supported = false;
    var smart_supported = false;
    var unicode_supported = false;
    var no_unicode_supported = false;

    for (flag_catalog, 0..) |spec, spec_i| {
        try t.expect(spec.short != null or spec.longs.len > 0);
        if (spec.short) |short| try t.expectEqual(spec_i, short_map[short].?);
        for (spec.longs) |name| try t.expectEqual(spec_i, long_map.get(name).?);
        switch (spec.compatibility) {
            .supported => bucket_counts[0] += 1,
            .improvement => bucket_counts[1] += 1,
            .accepted_but_ignored => bucket_counts[2] += 1,
            .unsupported_fail_loud => bucket_counts[3] += 1,
            .native => {},
        }
        if (spec.short == 'i') i_supported = spec.compatibility == .supported;
        if (spec.short == 'w') word_supported = spec.compatibility == .supported;
        if (spec.short == 'S') smart_supported = spec.compatibility == .supported;
        for (spec.longs) |name| {
            if (std.mem.eql(u8, name, "unicode")) unicode_supported = spec.compatibility == .supported;
            if (std.mem.eql(u8, name, "no-unicode")) no_unicode_supported = spec.compatibility == .supported;
        }
    }
    // The three live buckets are populated; the fail-loud bucket is now empty —
    // the content-transform flags (-z/--pre/--binary/-E) that used to fail loud
    // are implemented, so gist accepts or honors the entire rg flag surface.
    // Bucket 1 is now `improvement` (proven-better wins): every flag that once
    // diverged is either a documented improvement or was reconciled to parity.
    try t.expect(bucket_counts[0] > 0 and bucket_counts[1] > 0 and bucket_counts[2] > 0);
    try t.expectEqual(@as(usize, 0), bucket_counts[3]);
    // -i/-S/-w reached rg parity (Unicode by default), and --unicode/--no-unicode
    // are genuine toggles rather than accepted-but-ignored no-ops.
    try t.expect(i_supported and word_supported and smart_supported);
    try t.expect(unicode_supported and no_unicode_supported);
}
