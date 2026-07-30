//! `beacon.zig`'s proof: the format grammar, the destination probe, and the
//! bytes a `Waypoint` actually frames.
//!
//! The grammar cases are ripgrep's own — its `hyperlink/mod.rs` test module
//! plus the rules its `validate`/`validate_scheme` enforce — so "gist accepts
//! exactly what rg accepts" is checked rather than claimed. The probe cases are
//! gist-only (rg has no probe), and each one pins a REFUSAL as hard as an
//! acceptance: an emulator we cannot name must produce plain bytes, because the
//! failure mode of a false positive is escape soup in every result line.

const std = @import("std");
const beacon = @import("beacon.zig");

const t = std.testing;

/// One arena per case: `resolve`/`waypoint` allocate the way the run allocator
/// does (fire and forget), so the test frees the same way the process does.
fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

// ───────────────────────────── the value grammar ─────────────────────────────

test "choose reads the three postures, every alias, and a literal format" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    try t.expectEqual(beacon.When.always, beacon.choose(a, "always").when);
    try t.expectEqual(beacon.When.never, beacon.choose(a, "never").when);
    try t.expectEqual(beacon.When.auto, beacon.choose(a, "auto").when);
    try t.expectEqualStrings("vscode://file{path}:{line}:{column}", beacon.choose(a, "vscode").format);
    try t.expectEqualStrings("", beacon.choose(a, "none").format);
    try t.expectEqualStrings("x://{path}", beacon.choose(a, "x://{path}").format);
}

test "a value carries a posture, a destination, or the pair of them" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // One term stays one term, whichever axis it names.
    try t.expectEqual(beacon.When.always, beacon.wish(a, "always").when.?);
    try t.expectEqual(@as(?[]const u8, null), beacon.wish(a, "always").format);
    try t.expectEqualStrings("vscode://file{path}:{line}:{column}", beacon.wish(a, "vscode").format.?);
    try t.expectEqual(@as(?beacon.When, null), beacon.wish(a, "vscode").when);

    // The pair names both — this is the sentence rg cannot write at all.
    const pair = beacon.wish(a, "auto,vscode");
    try t.expectEqual(beacon.When.auto, pair.when.?);
    try t.expectEqualStrings("vscode://file{path}:{line}:{column}", pair.format.?);

    // Only a LEADING posture splits, and only once, so a comma inside a literal
    // format survives to the URL instead of truncating it.
    const commas = "x://open?p={path}&at={line},{column}";
    try t.expectEqualStrings(commas, beacon.wish(a, commas).format.?);
    try t.expectEqualStrings(commas, beacon.wish(a, "always," ++ commas).format.?);
    try t.expectEqual(beacon.When.always, beacon.wish(a, "always," ++ commas).when.?);

    // A bad half poisons the whole value rather than half-applying.
    try t.expect(beacon.wish(a, "always,sublime").bad != null);
    try t.expect(beacon.wish(a, "always,auto").bad != null);
    try t.expectEqual(@as(?beacon.When, null), beacon.wish(a, "always,sublime").when);
}

test "an unknown alias names the whole roster instead of failing bare" {
    var ar = arena();
    defer ar.deinit();
    const msg = beacon.choose(ar.allocator(), "sublime").bad;
    try t.expect(std.mem.indexOf(u8, msg, "sublime") != null);
    try t.expect(std.mem.indexOf(u8, msg, "vscode") != null);
    try t.expect(std.mem.indexOf(u8, msg, "zed") != null);
}

test "every shipped alias is itself a valid format" {
    var ar = arena();
    defer ar.deinit();
    for (beacon.aliases) |x| {
        if (x.format.len == 0) continue; // `none` is the deliberate empty one
        if (beacon.fault(ar.allocator(), x.format)) |msg|
            std.debug.panic("alias {s} is malformed: {s}", .{ x.name, msg });
    }
}

test "format validation rejects exactly what ripgrep rejects" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Well-formed.
    try t.expectEqual(@as(?[]const u8, null), beacon.fault(a, "file://{host}{path}"));
    try t.expectEqual(@as(?[]const u8, null), beacon.fault(a, "grep+://{path}:{line}"));
    try t.expectEqual(@as(?[]const u8, null), beacon.fault(a, "f://{path}#{line}"));
    try t.expectEqual(@as(?[]const u8, null), beacon.fault(a, "")); // empty = links off
    // `{{`/`}}` are literal braces, and the escape must not split the scheme.
    try t.expectEqual(@as(?[]const u8, null), beacon.fault(a, "file://{{{path}}}"));

    // Malformed, one rule each.
    try t.expect(beacon.fault(a, "file://{path") != null); // unclosed
    try t.expect(beacon.fault(a, "file://path}") != null); // unopened
    try t.expect(beacon.fault(a, "file://{bogus}") != null); // unknown variable
    try t.expect(beacon.fault(a, "file://host") != null); // no {path}
    try t.expect(beacon.fault(a, "file://{path}:{column}") != null); // {column} without {line}
    try t.expect(beacon.fault(a, "{path}") != null); // no scheme
    try t.expect(beacon.fault(a, "f oo://{path}") != null); // space in the scheme
    try t.expect(beacon.fault(a, "://{path}") != null); // empty scheme
}

// ────────────────────────── the terminal / target probe ──────────────────────

const Env = std.process.Environ.Map;

fn env(pairs: []const [2][]const u8) !Env {
    var m = Env.init(t.allocator);
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

test "speaks answers yes only for emulators we can name" {
    const yes = [_][]const [2][]const u8{
        &.{ .{ "TERM", "xterm-256color" }, .{ "TERM_PROGRAM", "iTerm.app" } },
        &.{ .{ "TERM", "xterm-256color" }, .{ "TERM_PROGRAM", "WezTerm" } },
        &.{ .{ "TERM", "xterm-256color" }, .{ "TERM_PROGRAM", "vscode" } },
        &.{ .{ "TERM", "xterm-ghostty" }, .{ "TERM_PROGRAM", "ghostty" } },
        &.{.{ "TERM", "xterm-kitty" }},
        &.{ .{ "TERM", "xterm-256color" }, .{ "KITTY_WINDOW_ID", "1" } },
        &.{ .{ "TERM", "xterm-256color" }, .{ "ALACRITTY_WINDOW_ID", "9" } },
        &.{ .{ "TERM", "xterm-256color" }, .{ "VTE_VERSION", "6003" } },
        &.{ .{ "TERM", "xterm-256color" }, .{ "KONSOLE_VERSION", "220401" } },
    };
    for (yes) |pairs| {
        var m = try env(pairs);
        defer m.deinit();
        try t.expect(beacon.speaks(&m));
    }

    const no = [_][]const [2][]const u8{
        &.{}, // no TERM at all — a cron job, a CI runner
        &.{.{ "TERM", "dumb" }},
        &.{ .{ "TERM", "xterm-256color" }, .{ "TERM_PROGRAM", "Apple_Terminal" } }, // renders it literally
        &.{.{ "TERM", "xterm-256color" }}, // an emulator we cannot name: fail closed
        &.{ .{ "TERM", "xterm-256color" }, .{ "VTE_VERSION", "4205" } }, // VTE too old
        &.{ .{ "TERM", "xterm-256color" }, .{ "KONSOLE_VERSION", "180801" } }, // Konsole too old
    };
    for (no) |pairs| {
        var m = try env(pairs);
        defer m.deinit();
        try t.expect(!beacon.speaks(&m));
    }
}

test "tmux gates on its own version, not on the emulator underneath it" {
    // tmux < 3.4 swallows OSC 8, so a capable emulator behind it still gets
    // plain bytes — the case a naive TERM_PROGRAM probe gets wrong.
    var old = try env(&.{ .{ "TERM", "tmux-256color" }, .{ "TMUX", "/tmp/s,1,0" }, .{ "TERM_PROGRAM", "tmux" }, .{ "TERM_PROGRAM_VERSION", "3.2a" } });
    defer old.deinit();
    try t.expect(!beacon.speaks(&old));

    var new = try env(&.{ .{ "TERM", "tmux-256color" }, .{ "TMUX", "/tmp/s,1,0" }, .{ "TERM_PROGRAM", "tmux" }, .{ "TERM_PROGRAM_VERSION", "3.5" } });
    defer new.deinit();
    try t.expect(beacon.speaks(&new));

    // Inside tmux with no version to read: unidentifiable, so no.
    var mute = try env(&.{ .{ "TERM", "screen-256color" }, .{ "TMUX", "/tmp/s,1,0" }, .{ "TERM_PROGRAM", "iTerm.app" } });
    defer mute.deinit();
    try t.expect(!beacon.speaks(&mute));
}

test "destination identifies the editor fork and the remote hop" {
    const cases = [_]struct { pairs: []const [2][]const u8, want: []const u8 }{
        .{ .pairs = &.{.{ "TERM_PROGRAM", "vscode" }}, .want = "vscode://file{path}:{line}:{column}" },
        .{ .pairs = &.{.{ "VSCODE_GIT_ASKPASS_NODE", "/Applications/Cursor.app/Contents/x" }}, .want = "cursor://file{path}:{line}:{column}" },
        .{ .pairs = &.{.{ "CURSOR_TRACE_ID", "abc" }}, .want = "cursor://file{path}:{line}:{column}" },
        .{ .pairs = &.{.{ "VSCODE_GIT_ASKPASS_NODE", "/opt/windsurf/x" }}, .want = "windsurf://file{path}:{line}:{column}" },
        .{ .pairs = &.{.{ "VSCODE_GIT_ASKPASS_NODE", "/usr/share/vscodium/x" }}, .want = "vscodium://file{path}:{line}:{column}" },
        // Remote-SSH: a local file:// URL would point at the wrong machine.
        .{ .pairs = &.{ .{ "TERM_PROGRAM", "vscode" }, .{ "SSH_CONNECTION", "10.0.0.1 22 10.0.0.2 22" } }, .want = "vscode://vscode-remote/ssh-remote+{host}{path}:{line}:{column}" },
        .{ .pairs = &.{ .{ "CURSOR_TRACE_ID", "abc" }, .{ "SSH_TTY", "/dev/pts/3" } }, .want = "cursor://vscode-remote/ssh-remote+{host}{path}:{line}:{column}" },
        // Not an editor terminal: RFC 8089, exactly ripgrep's default.
        .{ .pairs = &.{.{ "TERM_PROGRAM", "iTerm.app" }}, .want = "file://{host}{path}" },
        .{ .pairs = &.{.{ "TERM", "xterm-kitty" }}, .want = "file://{host}{path}#{line}" },
    };
    for (cases) |c| {
        var m = try env(c.pairs);
        defer m.deinit();
        try t.expectEqualStrings(c.want, beacon.destination(&m));
    }
}

// ───────────────────────────── the emitted bytes ─────────────────────────────

/// A beacon built straight from a format, bypassing the terminal probe — the
/// unit under test here is the URL, not the decision to print one.
fn at(a: std.mem.Allocator, spec: []const u8, cwd: []const u8) !beacon.Beacon {
    return beacon.forFormat(a, spec, .{ .cwd = cwd, .host = "box" }) orelse error.NoDestination;
}

/// Render a waypoint the way `Emitter.linkOpen` does, for byte comparison.
fn frame(a: std.mem.Allocator, w: beacon.Waypoint, line: usize, col: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (w.slots, 0..) |slot, i| {
        try out.appendSlice(a, w.chunks[i]);
        try out.print(a, "{d}", .{if (slot == .line) line else col});
    }
    try out.appendSlice(a, w.chunks[w.slots.len]);
    return out.items;
}

test "a waypoint frames the OSC-8 open sequence with the row's locator spliced in" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    const b = try at(a, "vscode://file{path}:{line}:{column}", "/home/g/proj");
    const w = b.waypoint(a, "src/main.zig");
    try t.expectEqualStrings(
        "\x1b]8;;vscode://file/home/g/proj/src/main.zig:42:7\x1b\\",
        try frame(a, w, 42, 7),
    );
    // Two slots ⇒ three chunks, so the per-line cost is three copies and two
    // integers — the path is interpolated once, when the file was entered.
    try t.expectEqual(@as(usize, 2), w.slots.len);
    try t.expectEqual(@as(usize, 3), w.chunks.len);
}

test "a line-blind format collapses to a single chunk" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    const w = (try at(a, "file://{host}{path}", "/home/g")).waypoint(a, "x.txt");
    try t.expectEqual(@as(usize, 0), w.slots.len);
    try t.expectEqual(@as(usize, 1), w.chunks.len);
    try t.expectEqualStrings("\x1b]8;;file://box/home/g/x.txt\x1b\\", try frame(a, w, 1, 1));
}

test "the path is absolute, dot-folded, and percent-encoded like ripgrep" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try at(a, "file://{path}", "/home/g/proj");

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // Relative paths join the cwd; absolute ones are left where they are.
        .{ .in = "src/main.zig", .want = "file:///home/g/proj/src/main.zig" },
        .{ .in = "/etc/hosts", .want = "file:///etc/hosts" },
        // `.`/`..` fold lexically — no realpath(2), no symlink rewriting.
        .{ .in = "./src/./main.zig", .want = "file:///home/g/proj/src/main.zig" },
        .{ .in = "../other/x.zig", .want = "file:///home/g/other/x.zig" },
        .{ .in = "/a/b/../c//d", .want = "file:///a/c/d" },
        // A dot in a SEGMENT is not a dot segment: `.git` must survive intact.
        .{ .in = ".git/config", .want = "file:///home/g/proj/.git/config" },
        // RFC 3986 §2.3: `/` `:` `-` `.` `_` `~` and alnum pass; the rest encode.
        .{ .in = "a b/c%d?e#f.zig", .want = "file:///home/g/proj/a%20b/c%25d%3Fe%23f.zig" },
        // Non-ASCII stays raw (RFC 8089 §4 leaves it open; rg leaves it raw).
        .{ .in = "café/über.zig", .want = "file:///home/g/proj/café/über.zig" },
    };
    for (cases) |c| try t.expectEqualStrings(
        try std.fmt.allocPrint(a, "\x1b]8;;{s}\x1b\\", .{c.want}),
        try frame(a, b.waypoint(a, c.in), 1, 1),
    );
}

test "waypoint substitutes the run-constant host once, not per row" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const w = (try at(a, "file://{host}{path}#{line}", "/w")).waypoint(a, "f");
    try t.expectEqualStrings("\x1b]8;;file://box/w/f#", w.chunks[0]);
    try t.expectEqualStrings("\x1b\\", w.chunks[1]);
}

// ─────────────────── the anchor a control byte would tear ───────────────────

test "a name with a control byte declines the frame but keeps its URL exact" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Only what an emulator would render as a break counts: C0, DEL. Everything
    // a filename normally contains — spaces, quotes, UTF-8 — frames fine.
    try t.expect(beacon.tears("a\nb.txt"));
    try t.expect(beacon.tears("a\tb.txt"));
    try t.expect(beacon.tears("a\x1b]8;;evil\x1b\\b.txt"));
    try t.expect(beacon.tears("a\x7fb.txt"));
    try t.expect(!beacon.tears("with space.txt"));
    try t.expect(!beacon.tears("café/über.zig"));
    try t.expect(!beacon.tears("quo'te\"d;&.txt"));

    // The refusal is carried on the waypoint, decided once per file…
    const b = try at(a, "file://{path}", "/w");
    try t.expect(b.waypoint(a, "two\nlines.txt").torn);
    try t.expect(!b.waypoint(a, "one line.txt").torn);

    // …and the URL is still exact, because a digits-only anchor (no path in the
    // frame) is untearable and remains clickable. Declining is about the text
    // between the escapes, never about the address.
    try t.expectEqualStrings(
        "\x1b]8;;file:///w/two%0Alines.txt\x1b\\",
        try frame(a, b.waypoint(a, "two\nlines.txt"), 1, 1),
    );
}

test "link declines an anchor that would span two terminal lines" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    beacon.install(try at(a, "file://{path}#{line}", "/w"));
    defer beacon.install(null);

    // A clean label frames; a torn one comes back as the caller's own bytes,
    // borrowed, so the row prints exactly as it would with links off.
    const ok = beacon.anchor(a, "src/root.zig#L12");
    try t.expectEqualStrings("\x1b]8;;file:///w/src/root.zig#12\x1b\\src/root.zig#L12\x1b]8;;\x1b\\", ok);

    const torn = "src/two\nlines.zig";
    try t.expectEqualStrings(torn, beacon.anchor(a, torn));
    try t.expectEqual(torn.ptr, beacon.anchor(a, torn).ptr);
}

// ──────────────────────── who the bytes are actually for ────────────────────────

test "a byte protocol refuses every posture, including always" {
    // The one refusal with no override. `--json` and `-0` hand a filename to a
    // program as data; a frame around it is not decoration there, it is a
    // corrupt field. So `records` outranks the flag AND the environment, while
    // `parser` (--vimgrep) only makes `auto` stand down — a person still reads
    // those rows, so an explicit `always` remains their call.
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var speaking = try env(&.{.{ "TERM", "xterm-kitty" }});
    defer speaking.deinit();

    for ([_]beacon.When{ .always, .auto, .never }) |when| {
        const r: beacon.Request = .{ .when = when, .format = "file://{path}", .reader = .records };
        try t.expectEqual(@as(?beacon.Beacon, null), beacon.resolve(a, r, io, &speaking));
    }

    // Same terminal, same explicit posture, a reader who can see: linked.
    try t.expect(beacon.resolve(a, .{
        .when = .always,
        .format = "file://{path}",
        .reader = .human,
    }, io, &speaking) != null);

    // …and the middle case, which is the whole reason `parser` is not `records`.
    try t.expect(beacon.resolve(a, .{ .when = .auto, .format = "file://{path}", .reader = .parser }, io, &speaking) == null);
    try t.expect(beacon.resolve(a, .{ .when = .always, .format = "file://{path}", .reader = .parser }, io, &speaking) != null);
}
