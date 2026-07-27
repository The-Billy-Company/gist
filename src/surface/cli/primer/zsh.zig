//! The zsh completion — the one worth looking at.
//!
//! ripgrep's zsh completion is the best in the field and it is **hand-written**:
//! 743 lines carrying a comment asking you to re-run a CI script "to ensure
//! that the options supported by this function stay in synch with the `rg`
//! binary". A drift gate is an admission that there is drift to gate. This one
//! is minted from the table the parser dispatches on, so the class of bug does
//! not exist, and the effort that would have gone into keeping it in sync went
//! into three things ripgrep's does not do:
//!
//! **1. The option menu is grouped and captioned.** `_arguments` files every
//! option under one flat `options` tag, which is why `rg -<TAB>` is a wall of
//! ~90 undifferentiated flags. zsh's own answer is documented — split one tag
//! into labeled groups with `tag-order` and give each label an
//! `ignored-patterns` — and it is generated here from the same functional-reach
//! groups the man page is organized by, so `gist -<TAB>` arrives as captioned
//! sections: which bytes are searched, what counts as a match, how it is shown.
//! `_arguments` stays authoritative over the grammar; only the presentation is
//! ours, so nothing about the parse is re-implemented here to drift.
//!
//! **2. Every candidate set is baked, with its gloss.** `_rg_types` shells out
//! to `rg --type-list` and re-parses it *on every keystroke*; the same tab under
//! gist filters an array that was written into this file at generation time.
//! Same for engines, sort keys, and encodings. A completion costs zero forks.
//!
//! **3. Mutual exclusion is derived.** ripgrep hand-maintains its exclusion
//! lists (`'(-i --ignore-case -s --case-sensitive)'`); here they fall out of the
//! parser's own action table, so a flag pair that becomes rivals in the search
//! becomes rivals in the menu in the same commit.
//!
//! The visual defaults are set only where the caller has set nothing, and only
//! inside this tool's completion context. A personal `zstyle` always wins.

const std = @import("std");
const primer = @import("primer.zig");
const shell = @import("shell.zig");
const oom = @import("../outcome.zig").oom;

const Choice = primer.Choice;
const Opt = primer.Opt;
const Surface = primer.Surface;

/// A zstyle tag or `_describe` tag: `[a-z0-9-]`, since anything else would
/// need quoting at every lookup site.
fn tag(gpa: std.mem.Allocator, word: []const u8) []const u8 {
    const out = gpa.alloc(u8, word.len) catch oom();
    for (word, out) |c, *o| o.* = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-';
    return out;
}

/// A `tag-order` description is one shell word, so its spaces are escaped
/// rather than quoted — the style value already sits inside quotes.
///
/// A colon may not survive. `_next_label` cuts `label:description` apart with
/// `${curtag%:*}`, which takes the LAST colon, so a description carrying one
/// silently becomes part of the tag name and every `ignored-patterns` lookup
/// for that label misses — the group still renders, captioned and correct
/// looking, holding every option in the table. Escaping doesn't help; the
/// parameter expansion doesn't care about backslashes. So the character is
/// spent here rather than left to break a caption three layers away.
fn wordy(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) void {
    for (text) |c| {
        if (c == ':') {
            buf.appendSlice(gpa, "-") catch oom();
            continue;
        }
        if (c == ' ') buf.append(gpa, '\\') catch oom();
        if (c == '\'') {
            buf.appendSlice(gpa, "'\\''") catch oom();
        } else buf.append(gpa, c) catch oom();
    }
}

/// `_describe` splits a candidate on its first unescaped colon.
fn described(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, word: []const u8) void {
    for (word) |c| {
        if (c == ':' or c == '\\') buf.append(gpa, '\\') catch oom();
        if (c == '\'') {
            buf.appendSlice(gpa, "'\\''") catch oom();
        } else buf.append(gpa, c) catch oom();
    }
}

/// An `_arguments` explanation lives inside `[...]`, where a literal bracket
/// would close it early.
fn explain(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) void {
    for (text) |c| {
        switch (c) {
            '[', ']', '\\' => buf.append(gpa, '\\') catch oom(),
            '\'' => {
                buf.appendSlice(gpa, "'\\''") catch oom();
                continue;
            },
            else => {},
        }
        buf.append(gpa, c) catch oom();
    }
}

// ── the visual defaults ──────────────────────────────────────────────────

fn styles(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface) void {
    const ctx = std.fmt.allocPrint(gpa, ":completion:*:*:{s}:*", .{s.tool}) catch oom();

    buf.print(gpa,
        \\# Visual defaults. `_{s}_style` writes a style only where the lookup
        \\# finds nothing, so anything you set in .zshrc — globally or for
        \\# {s} alone — wins over everything below.
        \\_{s}_style() {{
        \\  local -a probe
        \\  zstyle -a "$1" "$2" probe || zstyle "$1" "$2" "${{@:3}}"
        \\}}
        \\
        \\_{s}_style '{s}' group-name ''
        \\_{s}_style '{s}' verbose yes
        \\_{s}_style '{s}' list-separator '·'
        \\_{s}_style '{s}' menu 'select'
        \\_{s}_style '{s}:descriptions' format '%F{{cyan}}%B%d%b%f'
        \\_{s}_style '{s}:messages' format '%F{{magenta}}%d%f'
        \\_{s}_style '{s}:warnings' format '%F{{red}}no {s} candidate matches %d%f'
        \\
    , .{ s.tool, s.tool, s.tool, s.tool, ctx, s.tool, ctx, s.tool, ctx, s.tool, ctx, s.tool, ctx, s.tool, ctx, s.tool, ctx, s.tool }) catch oom();

    if (s.groups.len == 0) return;

    // The documented way to split one tag into captioned sections: relabel
    // `options` once per group, then let each label ignore everything that is
    // not its own. Every spelling appears exactly once across the patterns, so
    // this costs one pass over the option table, not one per group.
    //
    // The value tags come FIRST, and that ordering is load-bearing. At `-t<TAB>`
    // zsh can either finish the glued value or keep completing option names, and
    // it offers the earliest tag-order entry that produces anything. With the
    // option groups first, `gist -t<TAB>` answered with the flag list while
    // `gist -t <TAB>` answered with file types — the same keystroke count, two
    // different menus. Naming the value tags ahead of the groups puts the answer
    // the caller is mid-way through typing before the list they have left.
    buf.print(gpa,
        \\
        \\# Split the flat `options` tag into the same functional groups the man
        \\# page is organized by, so `{s} -<TAB>` arrives captioned instead of as
        \\# one undifferentiated wall of flags. Value tags lead, so a half-typed
        \\# `-t<TAB>` completes the type rather than re-offering every flag.
        \\_{s}_style '{s}' tag-order '
    , .{ s.tool, s.tool, ctx }) catch oom();
    buf.appendSlice(gpa, "\n ") catch oom();
    for (primer.distinctSets(gpa, s, "").items) |e| buf.print(gpa, " {s}", .{tag(gpa, e.name)}) catch oom();
    // The tags zsh's own actions file their candidates under, for the values no
    // closed set can express.
    buf.appendSlice(gpa, " files directories commands") catch oom();
    for (s.groups) |g| {
        buf.print(gpa, "\n  options:-{s}:", .{tag(gpa, g.key)}) catch oom();
        wordy(buf, gpa, g.title);
    }
    buf.appendSlice(gpa, "\n' '*'\n") catch oom();

    buf.print(gpa, "_{s}_style '{s}' group-order", .{ s.tool, ctx }) catch oom();
    for (s.groups) |g| buf.print(gpa, " 'options-{s}'", .{tag(gpa, g.key)}) catch oom();
    buf.append(gpa, '\n') catch oom();

    var rows: std.ArrayList(Opt) = .empty;
    for (s.groups) |g| {
        s.inGroup(g.key, &rows, gpa);
        if (rows.items.len == 0) continue;
        buf.print(gpa, "_{s}_style '{s}:options-{s}' ignored-patterns '^(", .{ s.tool, ctx, tag(gpa, g.key) }) catch oom();
        var first = true;
        for (rows.items) |o| {
            if (o.short) |c| {
                if (!first) buf.append(gpa, '|') catch oom();
                buf.print(gpa, "-{c}", .{c}) catch oom();
                first = false;
            }
            for (o.longs) |long| {
                if (!first) buf.append(gpa, '|') catch oom();
                buf.print(gpa, "--{s}", .{long}) catch oom();
                first = false;
            }
        }
        buf.appendSlice(gpa, ")'\n") catch oom();
    }
}

// ── baked candidate sets ─────────────────────────────────────────────────

fn setFns(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface, sets: primer.Sets) void {
    for (sets.items) |e| {
        buf.print(gpa,
            \\
            \\# {d} candidates, written here at generation time. ripgrep's
            \\# equivalent forks the binary and re-parses its output per keystroke.
            \\_{s}_{s}() {{
            \\  local -a c=(
            \\
        , .{ e.choices.len, s.tool, e.name }) catch oom();
        for (e.choices) |c| {
            buf.appendSlice(gpa, "    '") catch oom();
            described(buf, gpa, c.word);
            buf.append(gpa, ':') catch oom();
            shell.sq(buf, gpa, c.doc);
            buf.appendSlice(gpa, "'\n") catch oom();
        }
        buf.print(gpa,
            \\  )
            \\  _describe -t '{s}' '{s}' c
            \\}}
            \\
        , .{ e.name, e.name }) catch oom();
    }
}

// ── the option specs ─────────────────────────────────────────────────────

/// The exclusion list: every spelling that picking this option rules out.
/// Aliases of one flag always rule each other out; rivals rule out the whole
/// rivalry. A repeatable option rules out nothing — that is what repeatable
/// means, and it is the one case ripgrep's hand-kept lists get wrong by
/// omission rather than by drift.
fn exclusions(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface, o: Opt, self: usize) void {
    if (o.value) |v| if (v.many) return;
    const paired = s.rivals(o.rival) > 1;
    // `_arguments` already refuses to offer an option twice, so a lone
    // single-spelling flag needs no list; aliases do, or zsh treats `-i` and
    // `--ignore-case` as two unrelated options and offers both.
    if (!paired and names(o) < 2) return;

    buf.appendSlice(gpa, "'(") catch oom();
    var first = true;
    for (s.opts, 0..) |other, i| {
        if (i != self and !(paired and std.mem.eql(u8, other.rival, o.rival))) continue;
        if (other.short) |c| {
            if (!first) buf.append(gpa, ' ') catch oom();
            buf.print(gpa, "-{c}", .{c}) catch oom();
            first = false;
        }
        for (other.longs) |long| {
            if (!first) buf.append(gpa, ' ') catch oom();
            buf.print(gpa, "--{s}", .{long}) catch oom();
            first = false;
        }
    }
    buf.appendSlice(gpa, ")'") catch oom();
}

fn names(o: Opt) usize {
    return (if (o.short) |_| @as(usize, 1) else 0) + o.longs.len;
}

/// `{-f+,--file=}` — every spelling, marked with how it carries its value.
///
/// The mark is the load-bearing part: `+` lets the value ride in the same word
/// or the next, `=` is its long form, and `=-` refuses the next word entirely.
fn spellings(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, o: Opt) void {
    const mark: []const u8 = if (o.value == null) "" else if (o.glued()) "-" else "+";
    const long_mark: []const u8 = if (o.value == null) "" else if (o.glued()) "=-" else "=";
    const braced = names(o) > 1;

    if (braced) buf.append(gpa, '{') catch oom();
    var first = true;
    if (o.short) |c| {
        buf.print(gpa, "-{c}{s}", .{ c, mark }) catch oom();
        first = false;
    }
    for (o.longs) |long| {
        if (!first) buf.append(gpa, ',') catch oom();
        buf.print(gpa, "--{s}{s}", .{ long, long_mark }) catch oom();
        first = false;
    }
    if (braced) buf.append(gpa, '}') catch oom();
}

fn action(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface, o: Opt, sets: primer.Sets) void {
    const v = o.value orelse return;
    // A glued value is optional by construction: the bare spelling is legal,
    // and `::` is how zsh spells "may be absent".
    buf.appendSlice(gpa, if (v.glued) "::" else ":") catch oom();
    buf.appendSlice(gpa, v.name) catch oom();
    buf.append(gpa, ':') catch oom();
    if (sets.find(o)) |name| {
        buf.print(gpa, "_{s}_{s}", .{ s.tool, name }) catch oom();
    } else switch (v.of) {
        .file, .glob => buf.appendSlice(gpa, "_files") catch oom(),
        .dir => buf.appendSlice(gpa, "_files -/") catch oom(),
        .command => buf.appendSlice(gpa, "_cmdstring") catch oom(),
        // A count, free text, or the degenerate empty set: name the value and
        // offer nothing, rather than the directory listing a value-blind
        // generator falls back to.
        .number, .open, .listed => {},
    }
}

fn spec(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface, o: Opt, self: usize, sets: primer.Sets) void {
    buf.appendSlice(gpa, "    ") catch oom();
    // `!` tells _arguments to understand the spelling without offering it.
    if (o.negation()) buf.appendSlice(gpa, "$no") catch oom();
    exclusions(buf, gpa, s, o, self);
    if (o.value) |v| if (v.many) buf.appendSlice(gpa, "'*'") catch oom();
    // A brace list has to stay unquoted to expand into one spec per spelling,
    // so the quote opens after it; a lone spelling sits inside the same quotes
    // as its explanation, where no metacharacter can be read as one.
    const braced = names(o) > 1;
    if (!braced) buf.append(gpa, '\'') catch oom();
    spellings(buf, gpa, o);
    if (braced) buf.append(gpa, '\'') catch oom();
    buf.append(gpa, '[') catch oom();
    explain(buf, gpa, o.doc);
    buf.append(gpa, ']') catch oom();
    action(buf, gpa, s, o, sets);
    buf.appendSlice(gpa, "'\n") catch oom();
}

// ── the whole file ───────────────────────────────────────────────────────

pub fn write(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface) void {
    const sets = primer.distinctSets(gpa, s, "");

    buf.print(gpa,
        \\#compdef {s}
        \\
        \\# zsh completion for {s}, generated by `{s} --generate complete-zsh`.
        \\#
        \\# Every candidate below is baked in: a tab costs no subprocess. Do not
        \\# edit — this file is a rendering of {s}'s own flag table, so the fix
        \\# for anything wrong here is upstream, and regeneration carries it.
        \\
    , .{ s.tool, s.tool, s.tool, s.tool }) catch oom();

    styles(buf, gpa, s);
    setFns(buf, gpa, s, sets);

    if (s.verbs.len > 0) {
        buf.print(gpa,
            \\
            \\_{s}_verbs() {{
            \\  local -a c=(
            \\
        , .{s.tool}) catch oom();
        for (s.verbs) |v| {
            buf.appendSlice(gpa, "    '") catch oom();
            described(buf, gpa, v.name);
            buf.append(gpa, ':') catch oom();
            shell.sq(buf, gpa, v.doc);
            buf.appendSlice(gpa, "'\n") catch oom();
        }
        buf.print(gpa,
            \\  )
            \\  _describe -t commands 'command' c
            \\}}
            \\
        , .{}) catch oom();
    }

    buf.print(gpa,
        \\
        \\_{s}() {{
        \\  local curcontext="$curcontext" ret=1
        \\  # Undo spellings are noise until they are asked for — `!` keeps them
        \\  # understood but unoffered. Typing `--no` brings them back.
        \\  local no='!'
        \\  [[ $PREFIX == --no* ]] && no=''
        \\  local -a args
        \\  args=(
        \\
    , .{s.tool}) catch oom();
    for (s.opts, 0..) |o, i| spec(buf, gpa, s, o, i, sets);
    if (s.verbs.len > 0)
        buf.print(gpa, "    '1: :_{s}_verbs'\n    '*:path:_files'\n", .{s.tool}) catch oom()
    else
        buf.appendSlice(gpa, "    '*:path:_files'\n") catch oom();
    buf.print(gpa,
        \\  )
        \\  _arguments -s -S -C : "$args[@]" && ret=0
        \\  return ret
        \\}}
        \\
        \\_{s} "$@"
        \\
    , .{s.tool}) catch oom();
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn rendered(gpa: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    write(&buf, gpa, primer.sample);
    return buf.items;
}

test "the option menu is split into captioned groups" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = rendered(arena.allocator());
    // The documented tag-relabelling, one label per functional group…
    try t.expect(std.mem.indexOf(u8, out, "options:-match:Pattern\\ and\\ matching") != null);
    try t.expect(std.mem.indexOf(u8, out, "options:-out:Output") != null);
    // …each ignoring everything outside its own group.
    try t.expect(std.mem.indexOf(u8, out, ":options-match' ignored-patterns '^(-i|--ignore-case|-s|--case-sensitive|-f|--file)'") != null);
    // Grouping is inert without this.
    try t.expect(std.mem.indexOf(u8, out, "group-name ''") != null);
}

test "value tags outrank the option groups, so a half-typed -t completes a type" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const out = rendered(gpa);
    const order = out[std.mem.indexOf(u8, out, "tag-order '").? + "tag-order '".len ..];
    const body = order[0..std.mem.indexOfScalar(u8, order, '\'').?];

    // zsh offers the first tag-order entry that yields anything. At `-t<TAB>`
    // both "finish the glued value" and "keep naming options" are live, so
    // whichever is named first decides the menu — and the caller is mid-value.
    const first_group = std.mem.indexOf(u8, body, "options:-").?;
    for (primer.distinctSets(gpa, primer.sample, "").items) |e| {
        const at = std.mem.indexOf(u8, body, tag(gpa, e.name)) orelse {
            std.debug.print("value tag '{s}' is missing from tag-order\n", .{e.name});
            return error.TagMissing;
        };
        try t.expect(at < first_group);
    }
    // The open-ended values zsh's own actions file elsewhere.
    for ([_][]const u8{ "files", "directories", "commands" }) |name|
        try t.expect(std.mem.indexOf(u8, body, name).? < first_group);
}

test "no caption smuggles a colon into the tag name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // The failure this guards is silent and convincing: `_next_label` splits
    // `label:description` at the LAST colon, so one colon in a caption moves
    // the tag from `options-match` to `options-match:Pattern`, every
    // `ignored-patterns` lookup misses, and each group renders beautifully
    // captioned around a copy of the entire option table.
    var buf: std.ArrayList(u8) = .empty;
    var surf = primer.sample;
    surf.groups = &.{
        .{ .key = "match", .title = "Match: what counts", .blurb = "" },
        .{ .key = "out", .title = "Output", .blurb = "" },
    };
    write(&buf, gpa, surf);
    const order = buf.items[std.mem.indexOf(u8, buf.items, "tag-order '").?..];
    const body = order["tag-order '".len..][0..std.mem.indexOfScalar(u8, order["tag-order '".len..], '\'').?];
    try t.expect(std.mem.indexOf(u8, body, "options:-match:Match-\\ what\\ counts") != null);
    // Two colons per relabel line and no more: the tag/label cut and the
    // label/caption cut. A third is the bug. The leading value-tag line is a
    // bare tag list and carries none, which is why this looks for the relabels
    // rather than asserting over every line.
    var lines = std.mem.tokenizeScalar(u8, body, '\n');
    var relabels: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, "options:-")) {
            try t.expectEqual(@as(usize, 0), std.mem.count(u8, trimmed, ":"));
            continue;
        }
        relabels += 1;
        try t.expectEqual(@as(usize, 2), std.mem.count(u8, trimmed, ":"));
    }
    try t.expectEqual(surf.groups.len, relabels);
}

test "rivals exclude each other; a lone flag only excludes its own aliases" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = rendered(arena.allocator());
    try t.expect(std.mem.indexOf(u8, out, "'(-i --ignore-case -s --case-sensitive)'{-i,--ignore-case}") != null);
    // A rivalry of one, spelled one way, needs no list: _arguments already
    // refuses to offer an option that is on the line.
    try t.expect(std.mem.indexOf(u8, out, "\n    '--heading[group under a filename]'\n") != null);
    // Repeatable options exclude nothing and take the `*` prefix instead.
    try t.expect(std.mem.indexOf(u8, out, "'*'{-f+,--file=}'[read patterns from a file]:FILE:_files'") != null);
}

test "a glued value may not be eaten from the next word" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = rendered(arena.allocator());
    // `--rank=-` refuses the next word, and `::` makes the value optional —
    // together they are why `gist --rank <TAB>` still completes a path rather
    // than swallowing the pattern.
    try t.expect(std.mem.indexOf(u8, out, "'--rank=-[ranked view]::N:'") != null);
}

test "closed sets are baked as literals, never fetched" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = rendered(arena.allocator());
    try t.expect(std.mem.indexOf(u8, out, "'auto:when stdout is a terminal'") != null);
    try t.expect(std.mem.indexOf(u8, out, "_describe -t 'when' 'when' c") != null);
    // Nothing in a completion may shell out — that is the whole performance
    // claim, and it is the line ripgrep's `_rg_types` crosses per keystroke.
    try t.expect(std.mem.indexOf(u8, out, "$(") == null);
}

test "user styles win over the generated defaults" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = rendered(arena.allocator());
    try t.expect(std.mem.indexOf(u8, out, "zstyle -a \"$1\" \"$2\" probe || zstyle") != null);
    // …and every style written is scoped to this tool's own context, so
    // sourcing the file cannot change how anything else completes.
    var it = std.mem.splitSequence(u8, out, "_demo_style '");
    _ = it.next();
    var seen: usize = 0;
    while (it.next()) |rest| : (seen += 1)
        try t.expect(std.mem.startsWith(u8, rest, ":completion:*:*:demo:*"));
    try t.expect(seen >= 7);
}

test "undo spellings are understood but withheld until --no is typed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = rendered(arena.allocator());
    try t.expect(std.mem.indexOf(u8, out, "[[ $PREFIX == --no* ]] && no=''") != null);
}
