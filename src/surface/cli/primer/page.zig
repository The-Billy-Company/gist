//! The man page, in roff.
//!
//! One deliberate departure from every grep manual ever written: the options
//! are **not alphabetical**. They are grouped by what a flag changes — the
//! corpus, the match set, the rendering, or only the way the answer is
//! computed — because that is the axis a reader arrives on. Nobody opens
//! `man rg` wondering what comes after `--max-filesize`; they open it asking
//! "which of these changes what I get back". Alphabetical order answers a
//! question no reader has, and it is the reason a 2229-line manual is a
//! scrolling exercise.
//!
//! The grouping is not editorial. It is the `Reach` the parser already records
//! for every flag so it can decide what a persisted setting is allowed to do,
//! projected into section headings — so the manual's organization and the
//! configuration system's safety rule are the same fact, and a new flag lands
//! in the right section by being classified at all.

const std = @import("std");
const primer = @import("primer.zig");
const oom = @import("irregex").inner.cli.outcome.oom;

const Opt = primer.Opt;
const Surface = primer.Surface;

/// Write `text` as roff body copy: hyphens become the ASCII hyphen-minus that
/// a reader can copy back into a shell, backslashes survive, a line that would
/// otherwise begin with a control character is protected, and anything above
/// ASCII becomes a `\[uXXXX]` escape.
///
/// That last one keeps the page pure ASCII. A raw UTF-8 em dash renders on a
/// modern mandoc and turns to mojibake on a groff in a C locale, which is the
/// kind of thing a manual is read on. It is also what mandoc measures a line's
/// length in, so escaping here is what lets the fold below be accurate.
fn body(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) void {
    if (text.len > 0 and (text[0] == '.' or text[0] == '\'')) buf.appendSlice(gpa, "\\&") catch oom();
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c < 0x80) {
            switch (c) {
                '\\' => buf.appendSlice(gpa, "\\e") catch oom(),
                '-' => buf.appendSlice(gpa, "\\-") catch oom(),
                else => buf.append(gpa, c) catch oom(),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + n > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            i += 1;
            continue;
        };
        buf.print(gpa, "\\[u{X:0>4}]", .{cp}) catch oom();
        i += n;
    }
}

/// Where a body line is folded. roff refills paragraphs itself, so this
/// changes nothing a reader sees — it exists so `mandoc -Tlint` has nothing to
/// say about the source, and so a `git diff` of a regenerated page is a few
/// words wide instead of one 300-column line per paragraph.
const fold = 78;

fn line(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) void {
    // Escape first, fold second: an escape is two characters with no space in
    // it, so a break at a space can never land inside one.
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(gpa);
    body(&esc, gpa, text);

    // Some callers open the line before handing the rest here (`gist \- `),
    // so the fold starts from what is already on it.
    var col = if (std.mem.lastIndexOfScalar(u8, buf.items, '\n')) |nl|
        buf.items.len - nl - 1
    else
        buf.items.len;
    var words = std.mem.splitScalar(u8, esc.items, ' ');
    var first = true;
    while (words.next()) |w| {
        if (!first and col + 1 + w.len > fold) {
            buf.append(gpa, '\n') catch oom();
            col = 0;
            // A folded line starting with a control character would be read as
            // a request rather than as the word it is.
            if (w.len > 0 and (w[0] == '.' or w[0] == '\'')) {
                buf.appendSlice(gpa, "\\&") catch oom();
                col = 2;
            }
        } else if (!first) {
            buf.append(gpa, ' ') catch oom();
            col += 1;
        }
        buf.appendSlice(gpa, w) catch oom();
        col += w.len;
        first = false;
    }
    buf.append(gpa, '\n') catch oom();
}

/// `\fB\-i\fR, \fB\-\-ignore\-case\fR=\fITYPE\fR` — the term line of an entry.
fn term(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, o: Opt) void {
    var first = true;
    if (o.short) |s| {
        buf.print(gpa, "\\fB\\-{c}\\fR", .{s}) catch oom();
        first = false;
    }
    for (o.longs) |long| {
        if (!first) buf.appendSlice(gpa, ", ") catch oom();
        buf.appendSlice(gpa, "\\fB\\-\\-") catch oom();
        body(buf, gpa, long);
        buf.appendSlice(gpa, "\\fR") catch oom();
        first = false;
    }
    if (o.value) |v| {
        // A glued-only value is written the only way it may be given, so the
        // manual cannot teach an invocation the parser rejects.
        buf.appendSlice(gpa, if (o.glued()) "[=" else if (o.short != null and o.longs.len == 0) " " else "=") catch oom();
        buf.appendSlice(gpa, "\\fI") catch oom();
        body(buf, gpa, v.name);
        buf.appendSlice(gpa, "\\fR") catch oom();
        if (o.glued()) buf.append(gpa, ']') catch oom();
    }
    buf.append(gpa, '\n') catch oom();
}

/// The accepted values of a closed set, as an indented sub-list. Capped: a
/// registry of 221 file types is a reference table, not a paragraph, and the
/// entry's `note` points at the verb that prints it in full.
const inline_choices = 10;

fn choices(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, o: Opt) void {
    const set = o.set() orelse return;
    if (set.len == 0) return;
    if (set.len > inline_choices) {
        buf.print(gpa, ".sp\n{d} accepted values.\n", .{set.len}) catch oom();
        return;
    }
    buf.appendSlice(gpa, ".RS\n") catch oom();
    for (set) |c| {
        buf.appendSlice(gpa, ".TP\n\\fB") catch oom();
        body(buf, gpa, c.word);
        buf.appendSlice(gpa, "\\fR\n") catch oom();
        line(buf, gpa, if (c.doc.len > 0) c.doc else " ");
    }
    buf.appendSlice(gpa, ".RE\n") catch oom();
}

fn entry(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, o: Opt) void {
    buf.appendSlice(gpa, ".TP\n") catch oom();
    term(buf, gpa, o);
    line(buf, gpa, o.doc);
    choices(buf, gpa, o);
    if (o.note) |n| {
        buf.appendSlice(gpa, ".sp\n") catch oom();
        line(buf, gpa, n);
    }
}

fn heading(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, macro: []const u8, title: []const u8) void {
    buf.print(gpa, "{s} \"{s}\"\n", .{ macro, title }) catch oom();
}

/// Render the whole manual for `s`, carrying `stamp` into the `.TH` line.
pub fn write(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface, stamp: primer.Stamp) void {
    var upper: [32]u8 = undefined;
    const name = std.ascii.upperString(upper[0..@min(upper.len, s.tool.len)], s.tool);
    // Date, then tool and version as the source, then the manual — ripgrep's
    // layout and the one mandoc parses without complaint. `Stamp` decides what
    // the date IS (see its doc comment); this stays a pure function of what it
    // is handed, so a drift gate that pins `SOURCE_DATE_EPOCH` gets identical
    // bytes from identical inputs.
    buf.print(gpa, ".TH {s} 1 {s} \"{s} {s}\" \"User Commands\"\n", .{ name, stamp.date, s.tool, stamp.version }) catch oom();
    // Left-align and never hyphenate: a manual whose flags break across a line
    // is a manual you cannot copy a flag out of.
    buf.appendSlice(gpa, ".nh\n.ad l\n") catch oom();

    heading(buf, gpa, ".SH", "NAME");
    buf.print(gpa, "{s} \\- ", .{s.tool}) catch oom();
    line(buf, gpa, s.tagline);

    heading(buf, gpa, ".SH", "SYNOPSIS");
    for (s.synopsis, 0..) |form, i| {
        if (i > 0) buf.appendSlice(gpa, ".br\n") catch oom();
        buf.print(gpa, "\\fB{s}\\fR ", .{s.tool}) catch oom();
        line(buf, gpa, form);
    }

    heading(buf, gpa, ".SH", "DESCRIPTION");
    for (s.description, 0..) |para, i| {
        if (i > 0) buf.appendSlice(gpa, ".sp\n") catch oom();
        line(buf, gpa, para);
    }

    if (s.verbs.len > 0) {
        heading(buf, gpa, ".SH", "COMMANDS");
        for (s.verbs) |v| {
            buf.appendSlice(gpa, ".TP\n\\fB") catch oom();
            body(buf, gpa, v.name);
            buf.appendSlice(gpa, "\\fR\n") catch oom();
            line(buf, gpa, v.doc);
            if (v.sub.len > 0) {
                buf.appendSlice(gpa, ".sp\nSub-commands: ") catch oom();
                for (v.sub, 0..) |c, i| {
                    if (i > 0) buf.appendSlice(gpa, ", ") catch oom();
                    body(buf, gpa, c.word);
                }
                buf.append(gpa, '\n') catch oom();
            }
        }
    }

    heading(buf, gpa, ".SH", "OPTIONS");
    var rows: std.ArrayList(Opt) = .empty;
    for (s.groups) |g| {
        s.inGroup(g.key, &rows, gpa);
        if (rows.items.len == 0) continue;
        heading(buf, gpa, ".SS", g.title);
        if (g.blurb.len > 0) line(buf, gpa, g.blurb);
        for (rows.items) |o| entry(buf, gpa, o);
    }

    // The face's own prose, between the flags and the environment they read.
    for (s.sections) |sec| {
        heading(buf, gpa, ".SH", sec.title);
        for (sec.paragraphs, 0..) |p, i| {
            if (i > 0) buf.appendSlice(gpa, ".PP\n") catch oom();
            line(buf, gpa, p);
        }
    }

    if (s.env.len > 0) {
        heading(buf, gpa, ".SH", "ENVIRONMENT");
        for (s.env) |e| {
            buf.appendSlice(gpa, ".TP\n\\fB") catch oom();
            body(buf, gpa, e.word);
            buf.appendSlice(gpa, "\\fR\n") catch oom();
            line(buf, gpa, e.doc);
        }
    }

    if (s.examples.len > 0) {
        heading(buf, gpa, ".SH", "EXAMPLES");
        for (s.examples) |e| {
            buf.appendSlice(gpa, ".TP\n\\fB") catch oom();
            body(buf, gpa, e.cmd);
            buf.appendSlice(gpa, "\\fR\n") catch oom();
            line(buf, gpa, e.doc);
        }
    }

    heading(buf, gpa, ".SH", "EXIT STATUS");
    for (s.exits) |e| {
        buf.print(gpa, ".TP\n\\fB{d}\\fR\n", .{e.code}) catch oom();
        line(buf, gpa, e.means);
    }

    if (s.see_also.len > 0) {
        heading(buf, gpa, ".SH", "SEE ALSO");
        for (s.see_also, 0..) |ref, i| {
            if (i > 0) buf.appendSlice(gpa, ", ") catch oom();
            body(buf, gpa, ref);
        }
        buf.append(gpa, '\n') catch oom();
    }
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

const fixed: primer.Stamp = .{ .version = "9.9.9", .date = "2001-02-03" };

fn renderSample(gpa: std.mem.Allocator) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    write(&buf, gpa, primer.sample, fixed);
    return buf.items;
}

test "the .TH line is one mandoc parses, and is a function of its inputs alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = renderSample(arena.allocator());
    // Date in the date field. mandoc warns on anything it cannot parse as one,
    // and the version in that slot was exactly that warning.
    try t.expect(std.mem.startsWith(u8, out, ".TH DEMO 1 2001-02-03 \"demo 9.9.9\" \"User Commands\""));
    // Rendering twice must produce the same bytes — no clock, no allocator
    // address, nothing a rebuild can move. The date arrives as an argument
    // precisely so this stays true.
    const again = renderSample(arena.allocator());
    try t.expectEqualStrings(out, again);
}

test "a pinned epoch renders the date mandoc expects" {
    var buf: [10]u8 = undefined;
    try t.expectEqualStrings("1970-01-01", primer.Stamp.at(0, "9.9.9", &buf).date);
    // A leading-zero day and a two-digit month, the two shapes bufPrint can
    // silently get wrong: 2026-07-06, and the last second before it.
    try t.expectEqualStrings("2026-07-06", primer.Stamp.at(1783296000, "9.9.9", &buf).date);
    try t.expectEqualStrings("2026-07-05", primer.Stamp.at(1783295999, "9.9.9", &buf).date);
    // A whole rendering with a pinned stamp is byte-identical to itself, which
    // is the property `SOURCE_DATE_EPOCH` exists to buy a packager.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const stamp = primer.Stamp.at(1783296000, "9.9.9", &buf);
    var a: std.ArrayList(u8) = .empty;
    var b: std.ArrayList(u8) = .empty;
    write(&a, gpa, primer.sample, stamp);
    write(&b, gpa, primer.sample, stamp);
    try t.expectEqualStrings(a.items, b.items);
    try t.expect(std.mem.indexOf(u8, a.items, "2026-07-06") != null);
}

test "hyphens are escaped so a reader can copy a flag back into a shell" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = renderSample(arena.allocator());
    try t.expect(std.mem.indexOf(u8, out, "\\fB\\-i\\fR, \\fB\\-\\-ignore\\-case\\fR") != null);
    // A bare `--ignore-case` would render as a roff en-dash; the whole point of
    // `body` is that no unescaped hyphen survives into the output.
    try t.expect(std.mem.indexOf(u8, out, " --ignore-case") == null);
}

test "a glued-only value is written the only way the parser accepts it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = renderSample(arena.allocator());
    // `--rank` takes an inline count or nothing; `--rank N` would be a lie the
    // manual told about the parser.
    try t.expect(std.mem.indexOf(u8, out, "\\fB\\-\\-rank\\fR[=\\fIN\\fR]") != null);
    // A spaced value keeps the `=` form, which both spellings accept.
    try t.expect(std.mem.indexOf(u8, out, "\\fB\\-\\-color\\fR=\\fIWHEN\\fR") != null);
}

test "sections are ordered by what a flag changes, not by spelling" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = renderSample(arena.allocator());
    const match = std.mem.indexOf(u8, out, ".SS \"Pattern and matching\"").?;
    const output = std.mem.indexOf(u8, out, ".SS \"Output\"").?;
    try t.expect(match < output);
    // `-s` is filed with `-i`, above every Output flag, despite sorting after
    // `--color` alphabetically — the axis is reach, not the alphabet.
    const case_sensitive = std.mem.indexOf(u8, out, "case\\-sensitive").?;
    try t.expect(case_sensitive < output);
}

test "the page is pure ASCII roff, folded where mandoc measures it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    var surf = primer.sample;
    surf.description = &.{"An em dash — like this one — is spelled as an escape, because a manual gets read through a groff in a C locale as often as through mandoc, and one raw multi-byte character is the difference between a dash and mojibake."};
    write(&buf, arena.allocator(), surf, fixed);
    try t.expect(std.mem.indexOf(u8, buf.items, "\\[u2014]") != null);
    for (buf.items) |c| try t.expect(c < 0x80);
    // Folded at the width mandoc counts in — escaped bytes, not codepoints.
    var lines = std.mem.splitScalar(u8, buf.items, '\n');
    while (lines.next()) |l| try t.expect(l.len <= fold);
}

test "a small closed set is spelled out; a large one is counted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = renderSample(arena.allocator());
    try t.expect(std.mem.indexOf(u8, out, "when stdout is a terminal") != null);
    try t.expect(std.mem.indexOf(u8, out, "\\fBnever\\fR") != null);
}
