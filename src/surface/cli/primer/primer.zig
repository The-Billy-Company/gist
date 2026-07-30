//! `--generate` — the man page and the shell completions, minted from the
//! same table the parser dispatches on.
//!
//! `--schema` already answers the machine that reads JSON. A human standing at
//! a prompt with a half-typed flag is a different reader with the same problem,
//! and until this package they got nothing: ripgrep ships completions, gist
//! shipped none.
//!
//! Copying ripgrep's answer would have copied its weakness. ripgrep's zsh
//! completion is the best one in the field and it is **hand-written** — 743
//! lines carrying a comment that asks you to re-run a CI script "to ensure that
//! the options supported by this function stay in synch with the `rg` binary",
//! which is a drift gate admitting there is drift to gate. Its bash completion
//! *is* generated, and offers file paths after `--word-regexp`, because the
//! generator does not know which flags take values. Both failures are the same
//! failure: the completion is a second description of the surface.
//!
//! Here there is one description. A `Surface` is the neutral shape a face
//! declares itself in — options with their groups, their rivalries, and what
//! each one takes — and every artifact is a rendering of it:
//!
//!   * [`page`](page.zig)  — roff, grouped by what a flag CHANGES rather than
//!                           alphabetically, because "which flags alter the
//!                           match set" is the question a reader arrives with;
//!   * [`shell`](shell.zig) — bash, fish, and PowerShell;
//!   * [`zsh`](zsh.zig)     — zsh, the one worth looking at (tag-split, not a
//!                           flat flag dump).
//!
//! Nothing a completion offers is fetched at tab time. Every closed candidate
//! set — file types with their globs, encoding labels, engines, sort keys — is
//! baked into the script when it is generated, so a tab costs zero processes
//! where ripgrep's `_rg_types` costs a `rg --type-list` fork per keystroke.
//! The set cannot go stale in a way regeneration does not fix, because the
//! generator reads the same tables the search does.

const std = @import("std");
const corpus_mod = @import("irregex").corpus;
const assay = @import("irregex").assay;
const oom = @import("irregex").inner.cli.outcome.oom;

const page = @import("page.zig");
const shell = @import("shell.zig");
const zsh = @import("zsh.zig");
const portal = @import("irregex").portal;

// ── the vocabulary a face describes itself in ────────────────────────────

/// One candidate a shell may offer, with the gloss shown beside it.
///
/// The gloss is not decoration: in zsh and fish it is the second column of the
/// menu, which is the difference between picking `sjis` confidently and
/// guessing at 220 encoding labels.
pub const Choice = struct { word: []const u8, doc: []const u8 = "" };

/// Where a value's candidates come from. Everything closed is `listed` and
/// therefore baked; the open cases say what KIND of thing is wanted so a shell
/// can delegate to its own file/directory completion instead of guessing.
pub const Candidates = union(enum) {
    /// Free text no shell can guess — a regex, a separator, a template.
    open,
    /// A count. No candidates, but a man page renders the placeholder and a
    /// shell knows not to offer files.
    number,
    /// A path on disk.
    file,
    /// A directory.
    dir,
    /// A glob, completed as a path fragment (rg's `_files` habit for `-g`).
    glob,
    /// A shell command line.
    command,
    /// A closed set, in full.
    listed: []const Choice,
};

/// What a flag takes after its name.
pub const Value = struct {
    /// The placeholder a man page prints and a completion menu labels with.
    name: []const u8,
    of: Candidates = .open,
    /// Only the glued form carries the value (`--rank=N`), so a shell must not
    /// eat the following word — that word is the pattern.
    glued: bool = false,
    /// Repeatable: each occurrence accumulates rather than replacing.
    many: bool = false,
};

/// A section of the surface. Groups are declared in display order.
pub const Group = struct { key: []const u8, title: []const u8, blurb: []const u8 = "" };

/// One option, in the only place it is written down.
pub const Opt = struct {
    short: ?u8 = null,
    longs: []const []const u8 = &.{},
    /// One line, lowercase, no trailing period — it is read in a menu column.
    doc: []const u8,
    /// The `Group.key` this option is filed under.
    group: []const u8,
    value: ?Value = null,
    /// Extra prose only the man page prints.
    note: ?[]const u8 = null,
    /// Options sharing a non-empty rivalry key are mutually exclusive: pick
    /// one and a shell stops offering the others. Derived, never hand-kept.
    rival: []const u8 = "",
    /// A spelling ripgrep has no answer for, marked so a reader can see which
    /// half of the surface is parity and which half is ours.
    native: bool = false,

    /// Does this option take a value at all?
    pub fn valued(self: Opt) bool {
        return self.value != null;
    }

    /// Is the value inline-only (`--rank=N`)? A shell that consumes the next
    /// word after the bare spelling would eat the pattern.
    pub fn glued(self: Opt) bool {
        return if (self.value) |v| v.glued else false;
    }

    /// The closed candidate set, or null when the value is open-ended.
    pub fn set(self: Opt) ?[]const Choice {
        const v = self.value orelse return null;
        return switch (v.of) {
            .listed => |c| c,
            else => null,
        };
    }

    /// A `--no-…` spelling that undoes another flag. Completion menus hold
    /// these back until the caller types `--no`, the way ripgrep's zsh function
    /// does by hand — otherwise a third of the list is undo.
    pub fn negation(self: Opt) bool {
        for (self.longs) |long| if (std.mem.startsWith(u8, long, "no-")) return true;
        return false;
    }
};

/// A verb: a word in the first position that is not a flag and not a pattern.
pub const Verb = struct { name: []const u8, doc: []const u8, sub: []const Choice = &.{} };

pub const Exit = struct { code: u8, means: []const u8 };
pub const Example = struct { cmd: []const u8, doc: []const u8 };

/// A prose section of the manual, printed after OPTIONS.
///
/// One field instead of one field per heading. A manual's remaining sections —
/// CONFIGURATION FILES, AUTOMATIC FILTERING, CAVEATS, REGEX SYNTAX — are all
/// the same shape (a title and paragraphs), differ per face, and are read by no
/// renderer but this one. Giving each its own `Surface` field would grow the
/// vocabulary once per thing a face wants to say, which is how a description
/// language turns into a template.
///
/// Prose only. Anything a completion could act on — a flag, a value set, a verb
/// — belongs in `opts` or `verbs`, where all five renderers can see it.
pub const Section = struct { title: []const u8, paragraphs: []const []const u8 };

/// Everything a face is, in the shape the renderers read. One value per binary.
pub const Surface = struct {
    tool: []const u8,
    /// The one-line NAME entry, tool excluded.
    tagline: []const u8,
    /// Invocation forms, tool excluded, in roff-free plain text.
    synopsis: []const []const u8,
    /// DESCRIPTION, one string per paragraph.
    description: []const []const u8,
    groups: []const Group,
    opts: []const Opt,
    verbs: []const Verb = &.{},
    /// Prose sections printed after OPTIONS, in declaration order.
    sections: []const Section = &.{},
    env: []const Choice = &.{},
    examples: []const Example = &.{},
    exits: []const Exit,
    see_also: []const []const u8 = &.{},

    /// The options filed under `key`, in declaration order.
    pub fn inGroup(self: Surface, key: []const u8, out: *std.ArrayList(Opt), gpa: std.mem.Allocator) void {
        out.clearRetainingCapacity();
        for (self.opts) |o| if (std.mem.eql(u8, o.group, key)) out.append(gpa, o) catch oom();
    }

    /// How many options share `key` as a rivalry. Zero and one mean "no rivalry
    /// worth rendering" — a mutual-exclusion group of one excludes nothing, and
    /// emitting it anyway is how ripgrep's hand-written zsh grew fifty groups.
    pub fn rivals(self: Surface, key: []const u8) usize {
        if (key.len == 0) return 0;
        var n: usize = 0;
        for (self.opts) |o| if (std.mem.eql(u8, o.rival, key)) {
            n += 1;
        };
        return n;
    }

    /// Does any option take a value? (A face of pure switches skips the value
    /// machinery entirely in every generated script.)
    pub fn anyValued(self: Surface) bool {
        for (self.opts) |o| if (o.value != null) return true;
        return false;
    }
};

// ── baked candidate sets ─────────────────────────────────────────────────

/// The distinct closed candidate sets a surface declares, each under one shell
/// identifier.
///
/// Two options offering the same set (`-t` and `-T` over the file-type
/// registry) share one baked table instead of carrying a copy each. That is
/// what makes baking affordable at all: gist's registry is 221 rows, and a
/// per-flag copy would put it in the script three times.
pub const Sets = struct {
    pub const Entry = struct { name: []const u8, choices: []const Choice };

    items: []const Entry,
    /// Set identity, parallel to `items` — the slices are comptime tables, so
    /// the pointer IS the identity and no deep compare is needed.
    keys: []const [*]const Choice,

    /// The identifier holding `o`'s candidates, or null if it has none.
    pub fn find(self: Sets, o: Opt) ?[]const u8 {
        const set = o.set() orelse return null;
        if (set.len == 0) return null;
        for (self.keys, 0..) |k, i| if (k == set.ptr) return self.items[i].name;
        return null;
    }
};

/// Collect every distinct closed set, naming each `<prefix><placeholder>`.
pub fn distinctSets(gpa: std.mem.Allocator, s: Surface, prefix: []const u8) Sets {
    var items: std.ArrayList(Sets.Entry) = .empty;
    var keys: std.ArrayList([*]const Choice) = .empty;
    for (s.opts) |o| {
        const set = o.set() orelse continue;
        if (set.len == 0) continue;
        if (already(keys.items, set.ptr)) continue;
        const label = std.ascii.allocLowerString(gpa, o.value.?.name) catch oom();
        var name = std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, label }) catch oom();
        for (items.items) |e| if (std.mem.eql(u8, e.name, name)) {
            name = std.fmt.allocPrint(gpa, "{s}{d}", .{ name, items.items.len }) catch oom();
            break;
        };
        items.append(gpa, .{ .name = name, .choices = set }) catch oom();
        keys.append(gpa, set.ptr) catch oom();
    }
    return .{ .items = items.items, .keys = keys.items };
}

fn already(keys: []const [*]const Choice, ptr: [*]const Choice) bool {
    for (keys) |k| if (k == ptr) return true;
    return false;
}

// ── the targets ──────────────────────────────────────────────────────────

/// What `--generate` can mint. The spellings are ripgrep's, so an agent or a
/// packaging script that already knows `rg --generate complete-zsh` needs to
/// learn nothing.
pub const Target = enum {
    man,
    @"complete-bash",
    @"complete-zsh",
    @"complete-fish",
    @"complete-powershell",

    pub fn parse(word: []const u8) ?Target {
        return std.meta.stringToEnum(Target, word);
    }
};

/// Which build of the tool a rendering came from. Only the manual prints it,
/// but it travels with every render so no renderer has to reach for a clock.
///
/// `.TH` wants a real date, and mandoc warns about anything it cannot parse as
/// one — yet a page carrying today's date is a diff on every rebuild, which
/// makes a byte-for-byte drift gate worthless. `SOURCE_DATE_EPOCH` is the
/// reproducible-builds answer to exactly this, so `of` honors it: a gate or a
/// distro build exports it and gets identical bytes, and a human running
/// `gist --generate man` gets a page dated the day it was minted. Resolved
/// once, here, rather than at each call site.
pub const Stamp = struct {
    version: []const u8,
    /// ISO 8601 `YYYY-MM-DD`.
    date: []const u8,

    /// Resolve the stamp for this process: `SOURCE_DATE_EPOCH` when it holds a
    /// number, otherwise the wall clock. The only impure step, kept to one line
    /// so `at` below can be tested without touching the environment.
    pub fn of(version: []const u8, buf: *[10]u8) Stamp {
        const pinned: ?u64 = if (assay.envSpan("SOURCE_DATE_EPOCH")) |raw|
            std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null
        else
            null;
        return at(pinned orelse now(), version, buf);
    }

    /// Wall-clock seconds off the platform clock, floored at the epoch. A
    /// machine whose clock refuses to answer still mints a page — dated
    /// 1970-01-01, which reads as "this build had no clock" rather than
    /// aborting a packaging run over a date field.
    fn now() u64 {
        return portal.wallSeconds();
    }

    /// The stamp for a given Unix second. Pure.
    pub fn at(secs: u64, version: []const u8, buf: *[10]u8) Stamp {
        const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        return .{
            .version = version,
            // YYYY-MM-DD always fills exactly 10 bytes — the only error
            // bufPrint can raise here is NoSpaceLeft, which the size proves away.
            .date = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                yd.year, md.month.numeric(), md.day_index + 1,
            }) catch |err| switch (err) {
                error.NoSpaceLeft => unreachable,
            },
        };
    }
};

/// Render one target into `buf`. Pure — the tests read the bytes rather than
/// the process's stdout, which is why every renderer takes a buffer.
pub fn render(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Surface, stamp: Stamp, target: Target) void {
    switch (target) {
        .man => page.write(buf, gpa, s, stamp),
        .@"complete-bash" => shell.bash(buf, gpa, s),
        .@"complete-zsh" => zsh.write(buf, gpa, s),
        .@"complete-fish" => shell.fish(buf, gpa, s),
        .@"complete-powershell" => shell.powershell(buf, gpa, s),
    }
}

/// Answer `--generate <target>`: write the artifact to stdout, or name every
/// target on stderr and exit 2. An unknown target is a usage error, not an
/// empty file — a packaging script that typos `complete-zshell` must fail its
/// build rather than install nothing.
pub fn emit(s: Surface, version: []const u8, word: ?[]const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const target = if (word) |w| Target.parse(w) orelse unknown(s.tool, w) else unknown(s.tool, null);
    var date: [10]u8 = undefined;
    var buf: std.ArrayList(u8) = .empty;
    render(&buf, gpa, s, Stamp.of(version, &date), target);
    corpus_mod.emitStdout(buf.items);
}

fn unknown(tool: []const u8, word: ?[]const u8) noreturn {
    if (word) |w|
        assay.diag("{s}: unknown --generate target '{s}'\n", .{ tool, w })
    else
        assay.diag("{s}: --generate needs a target\n", .{tool});
    inline for (@typeInfo(Target).@"enum".fields) |f|
        assay.diag("{s}: try: {s} --generate {s}\n", .{ tool, tool, f.name });
    std.process.exit(2);
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

/// A miniature face carrying one of every shape the renderers branch on: a
/// short+long switch, a rivalry pair, a listed value, a repeatable path value,
/// a glued optional value, a native flag, a verb with sub-words.
pub const sample = Surface{
    .tool = "demo",
    .tagline = "a face for the tests",
    .synopsis = &.{"[OPTIONS] PATTERN [PATH...]"},
    .description = &.{"Demo searches things."},
    .groups = &.{
        .{ .key = "match", .title = "Pattern and matching" },
        .{ .key = "out", .title = "Output" },
    },
    .opts = &.{
        .{ .short = 'i', .longs = &.{"ignore-case"}, .doc = "match case-insensitively", .group = "match", .rival = "case" },
        .{ .short = 's', .longs = &.{"case-sensitive"}, .doc = "match case-sensitively", .group = "match", .rival = "case" },
        .{
            .longs = &.{"color"},
            .doc = "when to colorize",
            .group = "out",
            .value = .{ .name = "WHEN", .of = .{ .listed = &.{ .{ .word = "auto", .doc = "when stdout is a terminal" }, .{ .word = "never" } } } },
        },
        .{ .short = 'f', .longs = &.{"file"}, .doc = "read patterns from a file", .group = "match", .value = .{ .name = "FILE", .of = .file, .many = true } },
        .{ .longs = &.{"rank"}, .doc = "ranked view", .group = "out", .native = true, .value = .{ .name = "N", .of = .number, .glued = true } },
        .{ .longs = &.{"heading"}, .doc = "group under a filename", .group = "out", .rival = "heading", .note = "off when piped" },
    },
    .verbs = &.{.{ .name = "index", .doc = "build the index", .sub = &.{.{ .word = "all", .doc = "everything" }} }},
    .env = &.{.{ .word = "DEMO_DIR", .doc = "artifact home" }},
    .examples = &.{.{ .cmd = "demo -i needle src", .doc = "case-insensitive search under src" }},
    .exits = &.{ .{ .code = 0, .means = "matched" }, .{ .code = 2, .means = "usage error" } },
    .see_also = &.{"rg(1)"},
};

test "a rivalry of one is not a rivalry" {
    // `heading` is declared but unpaired: rendering it as a mutual-exclusion
    // group would exclude nothing and cost a line in every script.
    try t.expectEqual(@as(usize, 2), sample.rivals("case"));
    try t.expectEqual(@as(usize, 1), sample.rivals("heading"));
    try t.expectEqual(@as(usize, 0), sample.rivals(""));
}

test "every target renders every flag — the whole point of one table" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    inline for (@typeInfo(Target).@"enum".fields) |f| {
        var buf: std.ArrayList(u8) = .empty;
        render(&buf, gpa, sample, .{ .version = "9.9.9", .date = "2001-02-03" }, @field(Target, f.name));
        try t.expect(buf.items.len > 200);
        try t.expect(std.mem.indexOf(u8, buf.items, "demo") != null);
        // roff escapes every hyphen (`\-`) so a flag survives a copy-paste out
        // of a terminal; undo that before looking for the spelling.
        const plain = std.mem.replaceOwned(u8, gpa, buf.items, "\\-", "-") catch oom();
        for (sample.opts) |o| {
            for (o.longs) |long| try t.expect(std.mem.indexOf(u8, plain, long) != null);
            if (o.short) |c| {
                const short = std.fmt.allocPrint(gpa, "-{c}", .{c}) catch oom();
                try t.expect(std.mem.indexOf(u8, plain, short) != null);
            }
        }
    }
}

test "target spellings are ripgrep's, so muscle memory carries" {
    try t.expectEqual(Target.man, Target.parse("man").?);
    try t.expectEqual(Target.@"complete-zsh", Target.parse("complete-zsh").?);
    try t.expect(Target.parse("complete-zshell") == null);
    try t.expect(Target.parse("") == null);
}

test "inGroup partitions the option list exactly once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var seen: usize = 0;
    var rows: std.ArrayList(Opt) = .empty;
    for (sample.groups) |g| {
        sample.inGroup(g.key, &rows, gpa);
        seen += rows.items.len;
    }
    // No option is orphaned into a group nobody declared, and none is filed twice.
    try t.expectEqual(sample.opts.len, seen);
}
