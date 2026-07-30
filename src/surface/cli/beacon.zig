//! Where a printed path POINTS: the OSC-8 hyperlink layer.
//!
//! `src/main.zig:42:7` is already the address of a match; a *beacon* makes it a
//! click. The bytes are the frame every modern emulator understands — `ESC ] 8
//! ; ; URL ESC \` before the anchor text, `ESC ] 8 ; ; ESC \` after — and
//! everything hard is deciding **whether** to emit them and **which URL**.
//!
//! It lives in the shared `cli` vocabulary rather than inside gist's emitter
//! because all three faces print paths: a `relate echoes` family and an
//! `irregex blast` ripple are lists of files whose whole purpose is to be
//! opened next. Nothing here knows what a match is, which face is asking, or
//! what that face's flags are called — `resolve` takes a `Request`, and each
//! CLI fills it from its own argv.
//!
//! Byte-compatible with ripgrep's `--hyperlink-format` where it overlaps: same
//! `{path}/{line}/{column}/{host}/{wslprefix}` grammar, same `{{`/`}}` escapes,
//! same validation taxonomy, same RFC 3986 percent-encoding set, every alias it
//! ships. Four things are deliberately different:
//!
//!   * **On by default, fail-closed.** rg links nothing until you learn a flag
//!     *and* an alias. gist probes the emulator (`speaks`) and the editor
//!     family (`destination`) and links when both answer. An emulator we can't
//!     name gets plain bytes, so the failure mode is "no link", never "escape
//!     soup in your pager".
//!   * **Off the color axis, and not parasitic on the path field.** rg's help
//!     states the coupling outright: it writes a link only "when a path is
//!     also in the output and colors are enabled". So `NO_COLOR` silently
//!     kills rg's links, a link into a pipe costs `--color=always` (which
//!     forces color into that pipe as well), and a single explicit file
//!     argument — which prints no filename — has nothing to click at all.
//!     Here a link is navigation, not decoration: it resolves independently of
//!     color, and when no path is printed the locator digits are the anchor.
//!   * **It knows about the far side of an SSH hop.** In a Remote-SSH terminal
//!     a `file://` link is not merely useless, it names a path on the wrong
//!     machine; `destination` answers `vscode://vscode-remote/ssh-remote+…`
//!     instead. rg cannot express this at all.
//!   * **No `realpath` per file.** rg canonicalizes every hit, which costs a
//!     syscall and rewrites the path through symlinks into something the reader
//!     never typed. This folds one cwd lexically. After that a `Waypoint`
//!     splits the URL at its `{line}`/`{column}` holes **once per file**, so the
//!     per-line cost is a memcpy of a prebuilt prefix plus the locator digits
//!     the row was already going to print.

const std = @import("std");
const assay = @import("../../assay/assay.zig");
const portal = @import("../../portal.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ.Map;
const oom = @import("outcome.zig").oom;

/// The frame. `open ++ url ++ st` precedes the anchor text; `close` ends it.
pub const open = "\x1b]8;;";
pub const st = "\x1b\\";
pub const close = open ++ st;

/// When to emit. `auto` is "on iff this terminal will render it" (see `speaks`).
pub const When = enum { auto, always, never };

/// How much text the click covers. `prefix` is ripgrep's anchor and the default:
/// the whole `path:42:7` locator, big enough to hit, small enough that selecting
/// the matched line still yields clean text. `path` links the filename only;
/// `row` extends the anchor over the line body for wide click targets.
pub const Scope = enum { path, prefix, row };

/// A hole in the per-file URL that only the row being printed can fill.
pub const Slot = enum { line, column };

// ───────────────────────────── the alias table ─────────────────────────────

pub const Alias = struct { name: []const u8, blurb: []const u8, format: []const u8 };

/// Every ripgrep alias verbatim, plus the five it lacks. `zed` and `windsurf`
/// are the schemes those editors actually register; the two `-remote` forms are
/// what a VS Code-family editor needs when the terminal is on the far side of
/// an SSH hop.
pub const aliases = [_]Alias{
    .{ .name = "cursor", .blurb = "Cursor (cursor://)", .format = "cursor://file{path}:{line}:{column}" },
    .{ .name = "cursor-remote", .blurb = "Cursor over Remote-SSH", .format = "cursor://vscode-remote/ssh-remote+{host}{path}:{line}:{column}" },
    .{ .name = "default", .blurb = "RFC 8089 (file://) with host", .format = "file://{host}{path}" },
    .{ .name = "file", .blurb = "RFC 8089 (file://) with host", .format = "file://{host}{path}" },
    .{ .name = "grep+", .blurb = "grep+ (grep+://)", .format = "grep+://{path}:{line}" },
    .{ .name = "kitty", .blurb = "kitty-style file:// with #line", .format = "file://{host}{path}#{line}" },
    .{ .name = "macvim", .blurb = "MacVim (mvim://)", .format = "mvim://open?url=file://{path}&line={line}&column={column}" },
    .{ .name = "none", .blurb = "disable hyperlinks", .format = "" },
    .{ .name = "textmate", .blurb = "TextMate (txmt://)", .format = "txmt://open?url=file://{path}&line={line}&column={column}" },
    .{ .name = "vscode", .blurb = "VS Code (vscode://)", .format = "vscode://file{path}:{line}:{column}" },
    .{ .name = "vscode-insiders", .blurb = "VS Code Insiders", .format = "vscode-insiders://file{path}:{line}:{column}" },
    .{ .name = "vscode-remote", .blurb = "VS Code over Remote-SSH", .format = "vscode://vscode-remote/ssh-remote+{host}{path}:{line}:{column}" },
    .{ .name = "vscodium", .blurb = "VSCodium (vscodium://)", .format = "vscodium://file{path}:{line}:{column}" },
    .{ .name = "windsurf", .blurb = "Windsurf (windsurf://)", .format = "windsurf://file{path}:{line}:{column}" },
    .{ .name = "zed", .blurb = "Zed (zed://)", .format = "zed://file{path}:{line}:{column}" },
};

pub fn alias(name: []const u8) ?[]const u8 {
    for (aliases) |x| if (std.mem.eql(u8, x.name, name)) return x.format;
    return null;
}

/// Did a bare `--hyperlink` eat the destination as its pattern?
///
/// `--hyperlink` takes its value inline, because a bare one must not swallow
/// the next token — that token is the pattern. But rg spells this flag
/// `--hyperlink-format vscode`, with a space, so anyone arriving with that
/// muscle memory writes `gist --hyperlink vscode needle .` and searches their
/// tree for the word "vscode" while linking somewhere else entirely. Every
/// other way of getting this wrong already says so; this one used to succeed
/// quietly, which is the exact failure the whole layer exists to prevent.
///
/// Only consulted when the flag was written bare, and only true when the
/// pattern spells a destination — so `gist vscode .`, a perfectly ordinary
/// search, never sees it.
pub fn misspaced(pattern: []const u8) bool {
    return alias(pattern) != null or std.mem.indexOfScalar(u8, pattern, '{') != null;
}

// ──────────────────────────── the format grammar ────────────────────────────

const Part = union(enum) { text: []const u8, host, wsl, path, line, column };

/// What one `--hyperlink` value means. `bad` carries the rendered diagnostic so
/// the flag parser can die loud and `resolve` can warn and carry on.
pub const Choice = union(enum) { when: When, format: []const u8, bad: []const u8 };

/// Read a `--hyperlink` / `GIST_HYPERLINK` value. One flag covers the whole
/// axis: the three postures, any alias, or a literal format string (anything
/// holding a `{`). rg needs two flags and cannot say "auto".
pub fn choose(a: Allocator, value: []const u8) Choice {
    inline for (@typeInfo(When).@"enum".fields) |f|
        if (std.mem.eql(u8, value, f.name)) return .{ .when = @enumFromInt(f.value) };
    if (std.mem.indexOfScalar(u8, value, '{') != null)
        return if (fault(a, value)) |msg| .{ .bad = msg } else .{ .format = value };
    if (alias(value)) |f| return .{ .format = f };
    return .{ .bad = std.fmt.allocPrint(a, "unknown hyperlink alias '{s}' (known: {s}; or write a format like 'vscode://file{{path}}:{{line}}:{{column}}')", .{ value, names }) catch oom() };
}

/// A whole `--hyperlink` / `GIST_HYPERLINK` value: a posture, a destination, or
/// the `WHEN,WHERE` pair that names both.
pub const Wish = struct { when: ?When = null, format: ?[]const u8 = null, bad: ?[]const u8 = null };

/// Read one value into at most one posture and one destination. An empty value
/// is an empty preference — `GIST_HYPERLINK=` in a profile stands the variable
/// down rather than earning a diagnostic on every run.
///
/// The pair form is what lets a single variable hold a complete standing
/// preference: `GIST_HYPERLINK=auto,vscode` says *where* while leaving the
/// probe to say *whether*, and `always,vscode` overrides the probe too. rg
/// spends two flags on this axis and still cannot express either sentence.
///
/// Only a leading posture splits, and only once — everything after that comma
/// is the destination verbatim, because a literal format may itself contain a
/// comma (`…?line={line},col={column}`) and must survive intact.
pub fn wish(a: Allocator, value: []const u8) Wish {
    if (value.len == 0) return .{};
    if (std.mem.indexOfScalar(u8, value, ',')) |c| {
        inline for (@typeInfo(When).@"enum".fields) |f|
            if (std.mem.eql(u8, value[0..c], f.name)) return switch (choose(a, value[c + 1 ..])) {
                .when => .{ .bad = "a hyperlink value names a posture once, as 'WHEN' or 'WHEN,WHERE'" },
                .format => |x| .{ .when = @enumFromInt(f.value), .format = x },
                .bad => |msg| .{ .bad = msg },
            };
    }
    return switch (choose(a, value)) {
        .when => |x| .{ .when = x },
        .format => |x| .{ .format = x },
        .bad => |msg| .{ .bad = msg },
    };
}

/// The alias roster, rendered once at comptime for the diagnostic and `--help`.
pub const names = blk: {
    var s: []const u8 = "";
    for (aliases, 0..) |x, i| s = s ++ (if (i == 0) "" else ", ") ++ x.name;
    break :blk s;
};

/// Validate a literal format, returning a human diagnostic or null. Mirrors
/// ripgrep's failure taxonomy exactly, so a format rg rejects gist rejects.
pub fn fault(a: Allocator, spec: []const u8) ?[]const u8 {
    var parts: std.ArrayList(Part) = .empty;
    defer parts.deinit(a);
    return lower(a, spec, &parts);
}

/// Tokenize `spec` into `parts`, returning a diagnostic instead when malformed.
/// `{{`/`}}` are literal braces; a lone `}` and an unclosed `{` are both errors.
fn lower(a: Allocator, spec: []const u8, parts: *std.ArrayList(Part)) ?[]const u8 {
    const State = enum { text, close_brace, open_brace, in_var };
    var state: State = .text;
    var from: usize = 0; // start of the pending literal run
    var name: usize = 0; // start of the pending variable name
    var i: usize = 0;
    while (i < spec.len) : (i += 1) {
        const c = spec[i];
        switch (state) {
            .text => switch (c) {
                '{' => {
                    text(a, parts, spec[from..i]);
                    state = .open_brace;
                },
                '}' => {
                    text(a, parts, spec[from..i]);
                    state = .close_brace;
                },
                else => {},
            },
            .close_brace => {
                if (c != '}') return "unopened variable: found '}' with no '{' before it";
                from = i; // the second '}' opens the next literal run
                state = .text;
            },
            .open_brace => {
                if (c == '{') {
                    from = i;
                    state = .text;
                } else if (c == '}') {
                    return "unknown variable '{}' (known: path, line, column, host, wslprefix)";
                } else {
                    name = i;
                    state = .in_var;
                }
            },
            .in_var => if (c == '}') {
                const v = spec[name..i];
                const part: Part = if (std.mem.eql(u8, v, "path")) .path //
                    else if (std.mem.eql(u8, v, "line")) .line //
                    else if (std.mem.eql(u8, v, "column")) .column //
                    else if (std.mem.eql(u8, v, "host")) .host //
                    else if (std.mem.eql(u8, v, "wslprefix")) .wsl //
                    else return std.fmt.allocPrint(a, "unknown variable '{{{s}}}' (known: path, line, column, host, wslprefix)", .{v}) catch oom();
                parts.append(a, part) catch oom();
                from = i + 1;
                state = .text;
            },
        }
    }
    switch (state) {
        .text => text(a, parts, spec[from..]),
        .close_brace => return "unopened variable: found '}' with no '{' before it",
        .open_brace, .in_var => return "unclosed variable: found '{' with no '}' after it",
    }
    return verify(parts.items);
}

/// Append a literal run, coalescing with the previous one so `{{`-escaped
/// braces never split the scheme across two parts (which would fail `verify`).
fn text(a: Allocator, parts: *std.ArrayList(Part), run: []const u8) void {
    if (run.len == 0) return;
    if (parts.items.len > 0) if (parts.items[parts.items.len - 1] == .text) {
        const prev = parts.items[parts.items.len - 1].text;
        parts.items[parts.items.len - 1] = .{ .text = std.mem.concat(a, u8, &.{ prev, run }) catch oom() };
        return;
    };
    parts.append(a, .{ .text = run }) catch oom();
}

/// The four semantic rules a well-formed destination must satisfy.
fn verify(parts: []const Part) ?[]const u8 {
    if (parts.len == 0) return null; // the empty format = links off
    if (!has(parts, .path)) return "a hyperlink format needs a {path} variable";
    if (has(parts, .column) and !has(parts, .line)) return "{column} is meaningless without {line}";
    // RFC 1738 §2.1: the URL must open with `scheme:`, scheme = alnum/+/-/.
    const head = if (parts[0] == .text) parts[0].text else return "a hyperlink format must start with a URL scheme (e.g. 'file://')";
    const colon = std.mem.indexOfScalar(u8, head, ':') orelse return "a hyperlink format must start with a URL scheme (e.g. 'file://')";
    if (colon == 0) return "empty URL scheme";
    for (head[0..colon]) |c| switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z', '+', '-', '.' => {},
        else => return "invalid character in the URL scheme",
    };
    return null;
}

fn has(parts: []const Part, comptime want: std.meta.Tag(Part)) bool {
    for (parts) |p| if (p == want) return true;
    return false;
}

// ───────────────────────── reading the environment ─────────────────────────

fn eq(v: ?[]const u8, want: []const u8) bool {
    return if (v) |x| std.mem.eql(u8, x, want) else false;
}

fn eqAny(v: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, v, x)) return true;
    return false;
}

fn holds(hay: ?[]const u8, needle: []const u8) bool {
    const h = hay orelse return false;
    return std.ascii.indexOfIgnoreCase(h, needle) != null;
}

/// `x.y…` ≥ `major.minor`, read as `major*100 + minor` — the shape both
/// `TERM_PROGRAM_VERSION` (tmux) and the raw integer knobs below compare on.
fn atLeast(v: ?[]const u8, floor: u32) bool {
    const s = v orelse return false;
    var it = std.mem.splitScalar(u8, s, '.');
    const major = std.fmt.parseInt(u32, it.first(), 10) catch return false;
    if (it.next()) |m| {
        const minor = std.fmt.parseInt(u32, m, 10) catch 0;
        return major * 100 + minor >= floor;
    }
    return major >= floor;
}

/// Will this terminal render an OSC-8 frame rather than show its bytes?
///
/// Fail-closed by construction: the answer is a roster of emulators known to
/// implement it, not a guess, because the cost of a false positive (`]8;;file
/// ://…` smeared through every result line) is far worse than the cost of a
/// false negative (plain output, exactly what you have today). A multiplexer
/// gates everything — tmux only forwards OSC 8 from 3.4 on, and reports its own
/// version through `TERM_PROGRAM` since 3.2, so an older or unidentifiable tmux
/// answers no.
pub fn speaks(env: *const Environ) bool {
    const term = env.get("TERM") orelse return false;
    if (std.mem.eql(u8, term, "dumb")) return false;
    const prog = env.get("TERM_PROGRAM");
    if (env.get("TMUX") != null and !(eq(prog, "tmux") and atLeast(env.get("TERM_PROGRAM_VERSION"), 304))) return false;
    if (prog) |p| {
        // Apple Terminal advertises nothing and renders the escape literally.
        if (std.mem.eql(u8, p, "Apple_Terminal")) return false;
        if (eqAny(p, &.{ "iTerm.app", "WezTerm", "ghostty", "vscode", "Hyper", "rio", "tabby", "WarpTerminal", "mintty", "tmux" })) return true;
    }
    if (env.get("KITTY_WINDOW_ID") != null or std.mem.eql(u8, term, "xterm-kitty")) return true;
    if (env.get("WT_SESSION") != null) return true; // Windows Terminal
    if (env.get("ALACRITTY_WINDOW_ID") != null) return true; // ≥ 0.12; OSC 8 since 0.11
    if (env.get("DOMTERM") != null) return true;
    if (atLeast(env.get("KONSOLE_VERSION"), 200400)) return true; // Konsole 20.04
    return atLeast(env.get("VTE_VERSION"), 5000); // VTE 0.50 → GNOME Terminal et al.
}

/// Which URL will actually open something here. A VS Code-family terminal is
/// the one case where the answer is unambiguous and enormously better than
/// `file://` — the click lands in the window you are already looking at, on the
/// right line — so it is worth identifying the fork (Cursor, Windsurf,
/// VSCodium, Insiders) and whether the session is remote. Everything else gets
/// ripgrep's `file://` default, which the OS hands to whatever owns the type.
pub fn destination(env: *const Environ) []const u8 {
    if (fork(env)) |f| return f;
    if (env.get("KITTY_WINDOW_ID") != null or eq(env.get("TERM"), "xterm-kitty")) return alias("kitty").?;
    return alias("default").?;
}

fn fork(env: *const Environ) ?[]const u8 {
    // The askpass helper path names the .app/install dir on every platform;
    // Cursor also stamps its own marker even when the git integration is off.
    const app = env.get("VSCODE_GIT_ASKPASS_NODE") orelse env.get("VSCODE_GIT_ASKPASS_MAIN");
    const name: []const u8 = if (holds(app, "cursor") or env.get("CURSOR_TRACE_ID") != null)
        "cursor"
    else if (holds(app, "windsurf"))
        "windsurf"
    else if (holds(app, "vscodium"))
        "vscodium"
    else if (holds(app, "insiders"))
        "vscode-insiders"
    else if (app != null or eq(env.get("TERM_PROGRAM"), "vscode"))
        "vscode"
    else
        return null;
    // Remote-SSH: the paths this run prints live on the far host, so a local
    // `vscode://file/…` opens the wrong machine (or nothing). Only the two
    // forks that ship the remote extension have a remote spelling.
    if (env.get("SSH_CONNECTION") == null and env.get("SSH_TTY") == null) return alias(name);
    return alias(if (std.mem.eql(u8, name, "cursor")) "cursor-remote" else "vscode-remote") orelse alias(name);
}

/// `{host}`: `--hostname-bin` when given (ripgrep parity — a WSL/container user
/// needs the outer host, which the kernel inside cannot name), else the kernel's
/// own. Every failure is the empty string rather than fatal: a `file://` URL
/// with no authority still resolves locally, so a missing hostname degrades the
/// link instead of killing the search that produced it.
fn hostname(a: Allocator, io: std.Io, bin: ?[]const u8) []const u8 {
    const cmd = bin orelse {
        var buf: [portal.host_name_max]u8 = undefined;
        return a.dupe(u8, portal.hostName(&buf) orelse return "") catch oom();
    };
    var child = std.process.spawn(io, .{ .argv = &.{cmd}, .stdout = .pipe, .stderr = .ignore }) catch return "";
    defer child.kill(io);
    var buf: [portal.host_name_max]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &buf);
    const said = out.interface.allocRemaining(a, .limited(buf.len)) catch return "";
    return std.mem.trim(u8, said, " \t\r\n");
}

/// `{wslprefix}`: the UNC prefix that makes a Linux path reachable from Windows.
fn wslPrefix(a: Allocator, env: *const Environ) []const u8 {
    const distro = env.get("WSL_DISTRO_NAME") orelse return "";
    return std.fmt.allocPrint(a, "wsl$/{s}", .{distro}) catch oom();
}

// ────────────────────────── the run-scoped decision ──────────────────────────

/// What the calling face knows that the probe cannot. The three CLIs share no
/// flag struct, so the hyperlink layer takes the four facts it needs and stays
/// ignorant of which one is asking.
pub const Request = struct {
    when: When = .auto,
    /// A validated format or resolved alias, when the user named one.
    format: ?[]const u8 = null,
    /// `--hostname-bin`: the command whose stdout answers `{host}`.
    hostname_bin: ?[]const u8 = null,
    reader: Reader = .human,
};

/// Who consumes this run's bytes — the one property the link decision turns on
/// besides the terminal itself.
pub const Reader = enum {
    /// Rows a person reads. Link them if the terminal renders links.
    human,
    /// Rows a program *tends* to parse but a person still reads (`--vimgrep`).
    /// `auto` stands down because an escape would corrupt the parse; an
    /// explicit `always` is still honored — it is the user's foot.
    parser,
    /// A byte protocol: structured records (`--json`) or NUL-framed paths
    /// (`-0`), where a filename's bytes ARE the payload. A hyperlink is a
    /// property of rendered text, which neither of these is, so nothing
    /// overrides this — not the flag, not the environment.
    records,
};

/// One run's resolved destination: the parsed format with every run-constant
/// variable already substituted, plus the roots a per-file `Waypoint` needs.
pub const Beacon = struct {
    parts: []const Part,
    scope: Scope,
    /// Absolute cwd with no trailing slash (empty at `/`), raw: percent-encoding
    /// happens once over the joined path, so encoding it here would double it.
    cwd: []const u8,
    host: []const u8,
    wsl: []const u8,
    /// Does the URL vary per row? False for `file://{host}{path}`, which lets
    /// the emitter reuse one frame for every line of a file.
    per_line: bool,

    /// Build the destination for one file. Called once per file, never per line.
    pub fn waypoint(self: *const Beacon, a: Allocator, path: []const u8) Waypoint {
        var chunks: std.ArrayList([]const u8) = .empty;
        var slots: std.ArrayList(Slot) = .empty;
        var cur: std.ArrayList(u8) = .empty;
        cur.appendSlice(a, open) catch oom();
        for (self.parts) |p| switch (p) {
            .text => |t| cur.appendSlice(a, t) catch oom(),
            .host => cur.appendSlice(a, self.host) catch oom(),
            .wsl => cur.appendSlice(a, self.wsl) catch oom(),
            .path => encode(a, &cur, self.absolute(a, path)),
            .line, .column => {
                chunks.append(a, cur.items) catch oom();
                slots.append(a, if (p == .line) .line else .column) catch oom();
                cur = .empty;
            },
        };
        cur.appendSlice(a, st) catch oom();
        chunks.append(a, cur.items) catch oom();
        return .{ .path = path, .chunks = chunks.items, .slots = slots.items, .torn = tears(path) };
    }

    /// The path as `{path}`: absolute and lexically folded, never canonicalized.
    /// Resolving symlinks (rg's `realpath`) costs a syscall per file and hands
    /// the reader a path they never typed — `/private/var/…` for `/tmp/…`, the
    /// physical mount for a worktree. Folding `.`/`..` textually keeps the answer
    /// inside the tree the query named. Borrows `path` when already clean and
    /// absolute, which is the case every rooted search argument produces.
    fn absolute(self: *const Beacon, a: Allocator, path: []const u8) []const u8 {
        const rooted = path.len > 0 and path[0] == '/';
        if (!dotted(path)) return if (rooted) path else std.fmt.allocPrint(a, "{s}/{s}", .{ self.cwd, path }) catch oom();
        var out: std.ArrayList(u8) = .empty;
        if (!rooted) out.appendSlice(a, self.cwd) catch oom();
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (std.mem.lastIndexOfScalar(u8, out.items, '/')) |k| out.shrinkRetainingCapacity(k);
                continue;
            }
            out.append(a, '/') catch oom();
            out.appendSlice(a, seg) catch oom();
        }
        if (out.items.len == 0) out.append(a, '/') catch oom();
        return out.items;
    }
};

var live: ?Beacon = null;

/// Install the run's beacon before any worker thread spawns; read-only after,
/// exactly like the diagnostic policy next door in `assay`.
pub fn install(b: ?Beacon) void {
    live = b;
}

pub fn current() ?*const Beacon {
    return if (live) |*b| b else null;
}

/// Decide this run's hyperlink posture, or null for "emit no links".
///
/// Precedence: the flag, then `GIST_HYPERLINK`, then the probe. `never` and a
/// record stream are absolute. `auto` additionally requires a real terminal
/// that `speaks` OSC-8 and bytes meant for a human. `always` overrides all of
/// that except a record stream.
pub fn resolve(a: Allocator, r: Request, io: std.Io, env: *const Environ) ?Beacon {
    var when = r.when;
    var spec = r.format;
    if (spec == null and when == .auto) if (assay.envSpan("GIST_HYPERLINK")) |raw| {
        const w = wish(a, raw);
        if (w.bad) |msg| assay.diag("gist: note: ignoring GIST_HYPERLINK={s} — {s}\n", .{ raw, msg });
        if (w.when) |x| when = x;
        if (w.format) |f| spec = f;
    };
    // Answered before anything is probed, but still answered: a lit lens that
    // says nothing reads as "nothing to report", which is the one thing it must
    // never mean. Every run that lights it gets exactly one line.
    if (r.reader == .records) return trace("output is a byte protocol", null);
    if (when == .never) return trace("turned off", null);
    if (when == .auto) {
        if (r.reader == .parser) return trace("machine-shaped output", null);
        if (!(std.Io.File.stdout().isTty(io) catch false)) return trace("stdout is not a terminal", null);
        if (!speaks(env)) return trace("terminal does not advertise OSC-8", null);
    }
    const format = spec orelse destination(env);
    const b = forFormat(a, format, .{
        .cwd = std.mem.trimEnd(u8, here(a, io, env), "/"),
        // Naming a variable is the only reason to pay for its value: `{host}`
        // can cost a subprocess, `{wslprefix}` an env read.
        .host = if (std.mem.indexOf(u8, format, "{host}") != null) hostname(a, io, r.hostname_bin) else "",
        .wsl = if (std.mem.indexOf(u8, format, "{wslprefix}") != null) wslPrefix(a, env) else "",
        .scope = scopeOf(),
    }) orelse return trace("no usable destination", null);
    return trace(format, b);
}

/// Would this run link even with no terminal on the other end?
///
/// The resident session renders its own frames and holds no beacon, so any run
/// that owes the reader links has to stay cold. Every other route there is
/// already refused — `auto` needs a TTY, and a `--hyperlink` flag makes the
/// request ineligible outright — which leaves exactly one question for the
/// warm client to ask, and it is cheaper than resolving a beacon to find out.
/// A malformed value counts: it earns a note from `resolve`, and only the cold
/// path has one to give. Staying silent about a misspelled alias *and* printing
/// no links is the exact confusion this layer exists to remove.
///
/// So does a lit `link` lens, for the same reason one step further out. Asking
/// `GIST_TRACE=link` why a run didn't link is a debugging act, and the answer
/// lives in `resolve` — which a warm answer never calls. Without this the lens
/// is silent in its single most common case (no flag, no env, output piped),
/// which is worse than having no lens: it reads as "nothing to report."
pub fn forcesLinks(a: Allocator) bool {
    if (assay.lit(.link)) return true;
    const raw = assay.envSpan("GIST_HYPERLINK") orelse return false;
    const w = wish(a, raw);
    return w.bad != null or w.when == .always;
}

/// Where a beacon comes from once the destination is known. Split from `resolve`
/// because *whether* to link (terminal probe, output shape, env precedence) and
/// *what the URL is* are independent questions — the Vim plugin and the tests
/// want the second without the first.
pub const Roots = struct {
    /// Absolute, no trailing slash. Relative match paths are joined onto it.
    cwd: []const u8 = "",
    host: []const u8 = "",
    wsl: []const u8 = "",
    scope: Scope = .prefix,
};

/// Null when the format cannot be a URL — the empty one (`none`, which means
/// "off") or one the grammar rejects. Deliberately NOT an error: nothing failed
/// here, a destination was declined, and the run simply prints plain text.
pub fn forFormat(a: Allocator, format: []const u8, r: Roots) ?Beacon {
    if (format.len == 0) return null;
    var parts: std.ArrayList(Part) = .empty;
    if (lower(a, format, &parts) != null) return null;
    return .{
        .parts = parts.items,
        .scope = r.scope,
        .cwd = r.cwd,
        .host = r.host,
        .wsl = r.wsl,
        .per_line = has(parts.items, .line),
    };
}

/// This run's directory, preferring the shell's LOGICAL `$PWD` to the physical
/// path. A shell keeps `$PWD` unresolved through symlinks, so a click from
/// inside `/tmp/x` opens `/tmp/x` rather than macOS's `/private/tmp/x` — the
/// directory the reader is standing in, not the one the kernel prefers. A
/// non-shell parent can hand down a stale `$PWD`, so it is confirmed by inode
/// against `.` and the physical answer wins any disagreement.
fn here(a: Allocator, io: std.Io, env: *const Environ) []const u8 {
    const dir = std.Io.Dir.cwd();
    const physical = dir.realPathFileAlloc(io, ".", a) catch return "";
    const logical = env.get("PWD") orelse return physical;
    if (logical.len == 0 or logical[0] != '/' or std.mem.eql(u8, logical, physical)) return physical;
    const mine = dir.statFile(io, ".", .{}) catch return physical;
    const named = dir.statFile(io, logical, .{}) catch return physical;
    return if (mine.inode == named.inode) logical else physical;
}

/// Report the decision under `GIST_TRACE=link` and pass it through, so every
/// exit from `resolve` says why on one line and none of them can go silent.
fn trace(why: []const u8, b: ?Beacon) ?Beacon {
    assay.trace(.link, "link: {s} · {s}\n", .{ if (b == null) "off" else "on", why });
    return b;
}

fn scopeOf() Scope {
    const raw = assay.envSpan("GIST_HYPERLINK_SCOPE") orelse return .prefix;
    inline for (@typeInfo(Scope).@"enum".fields) |f|
        if (std.mem.eql(u8, raw, f.name)) return @enumFromInt(f.value);
    return .prefix;
}

// ───────────────────────────── the per-file URL ─────────────────────────────

/// One file's destination, pre-split at the holes only a row can fill:
/// `chunks[i]` is the literal text before `slots[i]`, and `chunks[slots.len]`
/// closes it. The OSC-8 open frame is folded into `chunks[0]` and the string
/// terminator into the last chunk, so a line-blind format (`file://{host}{path}`)
/// emits as exactly one `memcpy` and the usual `…{path}:{line}:{column}` costs
/// three tiny copies plus the two integers the locator was printing anyway.
pub const Waypoint = struct {
    /// Identity of the file this was built for — the emitter's per-file memo key.
    path: []const u8,
    chunks: []const []const u8,
    slots: []const Slot,
    /// Would printing this name inside the frame tear it? Decided here, once per
    /// file, so the per-row question is a bool. See `tears`.
    torn: bool,
};

/// Would framing this text split one hyperlink across two terminal lines?
///
/// OSC-8 wraps *rendered text*, and the only way a control byte reaches an
/// anchor is a filename containing one — a literal newline or tab in a name.
/// The URL survives it (percent-encoding is exact), but the anchor does not:
/// the emulator is left guessing where the click target ended, which is the
/// same escape-soup failure the `auto` roster exists to refuse. ripgrep frames
/// it anyway and emits a two-line link. Declining costs one scan of a path we
/// were already about to encode, happens once per file, and forfeits nothing
/// real — no editor opens a file by a name it cannot put on one line. The row
/// still prints; it just isn't clickable.
pub fn tears(shown: []const u8) bool {
    for (shown) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

// ─────────────────────── the row-shaped faces' one call ───────────────────────
//
// gist's emitter builds a `Waypoint` per file and reuses it across thousands of
// matching lines. relate and irregex print tens of rows, each naming a
// different file, so they take the direct route below: one frame per row, no
// memo, and a plain borrow of the caller's bytes when the run emits no links.

/// Wrap `text` in a click frame pointing at `path`:`line`. The primitive under
/// `anchor` and `locator`, exposed because a face occasionally has the locator
/// and the text it wants underlined as two separate things.
pub fn link(a: Allocator, path: []const u8, line: u64, anchored: []const u8) []const u8 {
    const b = current() orelse return anchored;
    if (tears(anchored)) return anchored;
    const w = b.waypoint(a, path);
    var out: std.ArrayList(u8) = .empty;
    for (w.slots, 0..) |slot, i| {
        out.appendSlice(a, w.chunks[i]) catch oom();
        // A row-shaped face knows a line but never a column; `{column}` in the
        // chosen format resolves to the start of that line.
        out.print(a, "{d}", .{if (slot == .line) line else 1}) catch oom();
    }
    out.appendSlice(a, w.chunks[w.slots.len]) catch oom();
    out.appendSlice(a, anchored) catch oom();
    out.appendSlice(a, close) catch oom();
    return out.items;
}

/// A printed unit label, made clickable in place. relate names a unit either by
/// path (`src/root.zig`) or by fragment (`src/probe.zig#L340`), and the `#Lnnn`
/// suffix is exactly the `{line}` a format wants — so the row that says which
/// *function* it found also opens on that function.
pub fn anchor(a: Allocator, label: []const u8) []const u8 {
    if (current() == null) return label; // before the split, to allocate nothing
    const cut = std.mem.lastIndexOf(u8, label, "#L");
    const path = if (cut) |i| label[0..i] else label;
    const line = if (cut) |i| std.fmt.parseInt(u64, label[i + 2 ..], 10) catch 1 else 1;
    return link(a, path, line, label);
}

/// `path:line` rendered as one clickable locator, into a buffer the caller
/// already owns — the row shape `irregex blast`, `provenance`, `relate
/// patterns`, and the `--rank` view all print. Under `GIST_HYPERLINK_SCOPE=path`
/// the click target narrows to the filename and the `:line` trails outside the
/// frame, so selecting a row still yields text a shell can take.
///
/// This is the primitive rather than `locator` because one caller renders
/// inside the resident daemon, where a per-row allocation would accumulate for
/// the life of the process. A run with no beacon costs exactly the `print` the
/// row was doing anyway.
pub fn writeLocator(a: Allocator, out: *std.ArrayList(u8), path: []const u8, line: u64) void {
    const b = current() orelse return out.print(a, "{s}:{d}", .{ path, line }) catch oom();
    if (b.scope == .path) {
        out.appendSlice(a, link(a, path, line, path)) catch oom();
        out.print(a, ":{d}", .{line}) catch oom();
        return;
    }
    out.appendSlice(a, link(a, path, line, std.fmt.allocPrint(a, "{s}:{d}", .{ path, line }) catch oom())) catch oom();
}

/// `writeLocator` as a value, for a row assembled inside one `print` call.
pub fn locator(a: Allocator, path: []const u8, line: u64) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    writeLocator(a, &out, path, line);
    return out.items;
}

/// Does the path carry a `.`/`..` segment (or an empty one) needing the fold?
/// Deliberately not a bare `.` scan: `/.git/objects` is clean and common.
fn dotted(p: []const u8) bool {
    return std.mem.startsWith(u8, p, "./") or std.mem.startsWith(u8, p, "../") or
        std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..") or
        std.mem.endsWith(u8, p, "/.") or std.mem.endsWith(u8, p, "/..") or
        std.mem.indexOf(u8, p, "/./") != null or std.mem.indexOf(u8, p, "/../") != null or
        std.mem.indexOf(u8, p, "//") != null;
}

/// Percent-encode into `buf` per RFC 3986 §2.3, matching ripgrep byte for byte:
/// unreserved ASCII plus `/` and `:` pass through, and so does everything ≥ 0x80
/// (RFC 8089 §4 does not mandate an encoding for non-ASCII, and encoding it
/// breaks `file://` on Windows). A clean path — nearly every path — costs
/// exactly one `appendSlice`, because the loop only breaks the run at a byte
/// that actually needs three characters.
fn encode(a: Allocator, buf: *std.ArrayList(u8), s: []const u8) void {
    const hex = "0123456789ABCDEF";
    var from: usize = 0;
    for (s, 0..) |c, i| {
        switch (c) {
            '0'...'9', 'A'...'Z', 'a'...'z', '/', ':', '-', '.', '_', '~', 0x80...0xff => continue,
            else => {},
        }
        buf.appendSlice(a, s[from..i]) catch oom();
        buf.appendSlice(a, &[_]u8{ '%', hex[c >> 4], hex[c & 0xF] }) catch oom();
        from = i + 1;
    }
    buf.appendSlice(a, s[from..]) catch oom();
}
