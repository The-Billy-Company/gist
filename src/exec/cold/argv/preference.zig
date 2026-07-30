//! Personal preferences — the reader's half of what outlives an invocation.
//!
//! The charter (`corpus/scope/charter.zig`) says what the TREE is, and it is
//! committed because that fact is everyone's. This file is the opposite kind of
//! thing: what one person likes to look at. `--heading`, `-n`, `--max-columns`,
//! `--smart-case`. It is machine-local, it is never committed, and nobody else
//! is affected by it.
//!
//! Which is exactly why ripgrep's version of this is dangerous and gist's is
//! not. A `.ripgreprc` applies to every invocation, so a `--smart-case` in it
//! silently changes what a colleague's script matches on your machine and not on
//! theirs — the reason `--no-config` had to be invented, and the reason an agent
//! is expected to pass it. Here, preferences apply **only when stdout is an
//! interactive terminal**. That is not a new rule bolted on: it is the envelope
//! boundary gist already draws everywhere else. The answer keep declines on a
//! TTY (`surface/cli/reprise.zig`), the resident daemon declines on a TTY, color
//! resolves on a TTY. Riding the same line means a pipe, a redirect, `--json`, a
//! script, CI, the daemon, and an agent are all structurally outside this file's
//! reach, and none of them ever needs `--no-config` to be sure of it.
//!
//! Two smaller repairs of the same feature:
//!
//!   * Lines are TOKENIZED, with shell quoting. ripgrep's are verbatim argv
//!     elements, so `--glob '!.git/*'` puts literal quote characters into the
//!     glob and silently matches nothing — the single most-reported confusion
//!     about that file (#927, #932, #2646, #3428). Here a quote is a quote.
//!   * Every flag is checked against the catalog as the file is read, naming
//!     the file and line. A typo is a loud error at the top of the run rather
//!     than a mystery in the middle of it.

const std = @import("std");
const builtin = @import("builtin");
const assay = @import("../../../assay/assay.zig");
const catalog = @import("catalog.zig");
const charter = @import("../../../corpus/scope/charter.zig");
const misread = @import("../../../kernel/math/misread.zig");

const Reach = catalog.Reach;

/// A personal file, but still a file the process must survive. The byte ceiling
/// is `charter.slurp`'s; this one bounds what a single line-storm can prepend.
const max_tokens: usize = 512;

/// A loaded preferences file: the argv it lowers to, plus how far the flags in
/// it travel. The reaches are not enforcement (a terminal-only file needs no
/// ceiling); they are what lets a zero-match run tell the reader whether their
/// own preferences could be the reason.
pub const Preferences = struct {
    path: []const u8,
    tokens: []const []const u8,
    /// True if any flag in the file reaches `corpus` or `semantics` — i.e. the
    /// file can change the ANSWER, not just its rendering.
    changes_answer: bool = false,

    pub fn deinit(self: *const Preferences, gpa: std.mem.Allocator) void {
        for (self.tokens) |tok| gpa.free(tok);
        gpa.free(self.tokens);
        gpa.free(self.path);
    }
};

// File-private parse vocabulary (ADR-373): these names never leave this module
// as a public error set — the run exits, tests assert via global `error.X`.
const Fault = error{
    UnknownFlag,
    NotPersistable,
    ExpectedFlag,
    UnterminatedQuote,
    TooManyTokens,
    Oversized,
};

// ── the run's answer ─────────────────────────────────────────────────────────

/// The tokens to prepend to this run's argv — empty unless stdout is an
/// interactive terminal. Prepended, not appended, so anything typed explicitly
/// still wins: last spelling of a flag takes effect, which is ripgrep's rule and
/// the reason overriding a preference needs no special syntax.
///
/// The gate is checked BEFORE the file is opened, which is a correctness
/// property and not an optimization. A malformed personal file is a loud exit
/// for the person who wrote it — and must be *nothing at all* for a pipe, a
/// script, or an agent, none of which would have honored the file anyway. Read
/// first and fault second would mean one human's typo failing every agent in
/// the tree with an exit 2 naming a path they cannot see: precisely the
/// action-at-a-distance this layer exists to rule out. (It also means the
/// overwhelmingly common non-interactive run costs zero syscalls here.)
pub fn forThisRun(io: std.Io) []const []const u8 {
    if (!(std.Io.File.stdout().isTty(io) catch false)) return &.{};
    if (charter.suppressedNow()) return &.{};
    const p = loaded() orelse {
        // Now it matters: this run WOULD have used the file.
        if (state.fault) |e| {
            report(e);
            std.process.exit(2);
        }
        return &.{};
    };
    if (p.changes_answer and p.tokens.len > 0) steered = p.path;
    return p.tokens;
}

/// Say why the preferences file could not be used. Split from the exit so a
/// provenance report can print the same sentence without ending the process.
pub fn report(e: anyerror) void {
    var loc: [24]u8 = undefined;
    assay.diag("gist: {s}{s}: {s}\n", .{
        state.path orelse "preferences",
        misread.at(&loc, state.diag),
        faultNote(e),
    });
    if (didYouMean(e, state.diag.token)) |better| {
        assay.diag("gist: try --{s} — `{s}` is not a flag gist knows\n", .{ better, state.diag.token });
    }
    assay.diag("gist: note: --no-config ignores it for this run\n", .{});
}

/// The flag worth suggesting for a fault, or null when there is none — the
/// charter's `didYouMean` in this layer's vocabulary. Only `UnknownFlag` is a
/// fault about a name; an unterminated quote is not improved by guessing at
/// the last flag it saw.
pub fn didYouMean(e: anyerror, token: []const u8) ?[]const u8 {
    if (e != Fault.UnknownFlag) return null;
    return nearestFlag(token);
}

/// The catalog's long spelling nearest a typo. Only long flags are guessed: a
/// mistyped short flag is one character, where every candidate is equidistant
/// and a suggestion would be a coin flip dressed up as help.
pub fn nearestFlag(token: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, "--")) return null;
    const body = token[2..];
    const typo = body[0 .. std.mem.indexOfScalar(u8, body, '=') orelse body.len];
    var names: [catalog.flag_catalog.len * 2][]const u8 = undefined;
    var n: usize = 0;
    for (catalog.flag_catalog) |spec| for (spec.longs) |long| {
        names[n] = long;
        n += 1;
    };
    return misread.nearest(typo, names[0..n]);
}

/// The preferences file that steered THIS run's answer, if one did — recorded
/// at the moment the tokens were handed to argv rather than re-derived, so a
/// zero-match hint reports what actually happened and cannot disagree with it.
pub fn steering() ?[]const u8 {
    return steered;
}

var steered: ?[]const u8 = null;

/// What the file SAYS — regardless of the TTY gate or `--no-config`, both of
/// which are facts about this run rather than about the file. That is what lets
/// `gist config` explain a preferences file from inside a pipe, and explain it
/// even in a shell that exports `GIST_NO_CONFIG`.
///
/// Never exits. A malformed file is recorded (`faulted`) rather than fatal,
/// because whether it *should* be fatal depends on the caller: the run that
/// would have used it says so and dies, while a run merely reporting on the
/// configuration must be able to say "present, but malformed" — which is the
/// single most useful thing it could say to whoever has to fix it.
pub fn loaded() ?*const Preferences {
    if (state.done) return state.prefs;
    state.done = true;

    const gpa = std.heap.page_allocator; // process-lifetime; never freed
    const path = locate() orelse return null;
    state.path = path;
    const src = charter.slurp(gpa, path) catch |e| {
        // Absent is the common case and not a fault; unreadable or oversized is.
        if (e != error.FileNotFound) state.fault = e;
        return null;
    };
    defer gpa.free(src);

    const owned = gpa.create(Preferences) catch return null;
    owned.* = parse(gpa, path, src, &state.diag) catch |e| {
        // The token slices `src`, which this scope is about to free — and the
        // diagnostic outlives the read (`gist config check` prints it, and the
        // suggestion is computed from it).
        state.diag.token = misread.keepToken(&state.token_bytes, state.diag.token);
        state.fault = e;
        return null;
    };
    state.prefs = owned;
    return owned;
}

/// The fault that kept this file from loading, if there was one, with the path
/// it applies to. `null` for the ordinary case of no preferences file at all.
pub fn faulted() ?struct { path: []const u8, err: anyerror, at: misread.Diagnostic } {
    _ = loaded();
    const e = state.fault orelse return null;
    return .{ .path = state.path orelse "preferences", .err = e, .at = state.diag };
}

var state: struct {
    done: bool = false,
    prefs: ?*const Preferences = null,
    fault: ?anyerror = null,
    path: ?[]const u8 = null,
    diag: misread.Diagnostic = .{},
    token_bytes: [128]u8 = undefined,
} = .{};

pub fn faultNote(e: anyerror) []const u8 {
    return switch (e) {
        Fault.UnknownFlag => "unknown flag (see `gist --help`)",
        Fault.NotPersistable => "that flag only means something typed on the command line",
        Fault.ExpectedFlag => "every line must begin with a flag — a bare word here would become a search pattern for every run",
        Fault.UnterminatedQuote => "unterminated quote",
        Fault.TooManyTokens => "too many entries",
        Fault.Oversized => "file is too large to be a preferences file",
        else => "unreadable",
    };
}

/// `$GIST_PREFERENCES`, else the platform's machine-local config home. Unset
/// and absent are the same answer — no preferences — because having none is the
/// overwhelmingly common case and must cost nothing.
///
/// `XDG_CONFIG_HOME` is consulted first on every platform (a Windows user who
/// ports a dotfile setup means it), then each platform's own spelling of the
/// same idea: `~/.config` on POSIX, `%LOCALAPPDATA%` on Windows. `LOCALAPPDATA`
/// rather than `APPDATA` is the whole point of this file — `APPDATA` roams
/// between machines, and a preferences file that follows you onto another
/// machine is the `.ripgreprc` hazard this design exists to avoid.
fn locate() ?[]const u8 {
    if (assay.envSpan("GIST_PREFERENCES")) |p| return if (p.len > 0) p else null;
    const Buf = struct {
        var bytes: [1024]u8 = undefined;
    };
    const sep = std.fs.path.sep_str;
    if (assay.envSpan("XDG_CONFIG_HOME")) |base| {
        return std.fmt.bufPrint(&Buf.bytes, "{s}" ++ sep ++ "gist" ++ sep ++ "preferences", .{base}) catch null;
    }
    if (comptime builtin.os.tag == .windows) {
        if (assay.envSpan("LOCALAPPDATA")) |base| {
            return std.fmt.bufPrint(&Buf.bytes, "{s}\\gist\\preferences", .{base}) catch null;
        }
    }
    // `HOME` before `USERPROFILE`: a Windows shell that sets `HOME` (Git for
    // Windows, MSYS2) is one where the user's dotfiles genuinely live there.
    if (assay.envSpan("HOME") orelse home()) |h| {
        return std.fmt.bufPrint(&Buf.bytes, "{s}" ++ sep ++ ".config" ++ sep ++ "gist" ++ sep ++ "preferences", .{h}) catch null;
    }
    return null;
}

/// The platform's home directory when it isn't spelled `HOME` — Windows only.
fn home() ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    return assay.envSpan("USERPROFILE");
}

// ── parsing ──────────────────────────────────────────────────────────────────

/// Lower a preferences file to argv tokens, validating every flag against the
/// catalog. Errors rather than exits, so the format is testable.
///
/// One line is one flag and its value(s). That scoping is what lets a bare word
/// be REFUSED without this module having to know which flags take values — a
/// question only `grammar.apply` can answer, and a second copy of that answer
/// here would be a drift hazard for no gain.
pub fn parse(gpa: std.mem.Allocator, path: []const u8, src: []const u8, diag: ?*misread.Diagnostic) !Preferences {
    var out: std.ArrayList([]const u8) = .empty;
    var changes = false;
    errdefer {
        for (out.items) |tok| gpa.free(tok);
        out.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, src, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        var line: Line = .{ .src = std.mem.trim(u8, raw, " \t\r") };
        var first = true;
        // The token is owned by `out` once appended, so the diagnostic borrows
        // from the raw source line instead — it outlives the failed parse's
        // cleanup, which frees everything this loop built.
        errdefer if (diag) |d| {
            d.* = .{ .line = lineno, .token = firstWord(line.src) };
        };
        while (try line.next(gpa)) |tok| {
            errdefer gpa.free(tok);
            if (out.items.len >= max_tokens) return Fault.TooManyTokens;
            if (first and !isFlag(tok)) return Fault.ExpectedFlag;
            first = false;
            if (isFlag(tok) and try admit(tok)) changes = true;
            try out.append(gpa, tok);
        }
    }

    return .{
        .path = try gpa.dupe(u8, path),
        .tokens = try out.toOwnedSlice(gpa),
        .changes_answer = changes,
    };
}

fn isFlag(tok: []const u8) bool {
    return tok.len > 1 and tok[0] == '-';
}

/// The line's leading word, unquoted and untokenized — what to quote back in a
/// fault. Deliberately not the parsed token: the parse is what failed.
fn firstWord(line: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return line[0..end];
}

/// Check one flag against the catalog and report whether it changes the answer.
///
/// A row with no reach is refused outright. That is the catalog's way of saying
/// "this spelling never survives to affect a search" — either it dies on sight
/// (`.unsupported`) or it was consumed before argv parsing (`--no-config`).
/// Persisting one is at best a no-op and at worst a lie about what the file
/// does, and the reach axis already knows which rows those are.
fn admit(tok: []const u8) !bool {
    var answerish = false;
    if (std.mem.startsWith(u8, tok, "--")) {
        const body = tok[2..];
        const name = body[0 .. std.mem.indexOfScalar(u8, body, '=') orelse body.len];
        if (name.len == 0) return Fault.ExpectedFlag; // a bare `--` ends flags; meaningless persisted
        answerish = try answerChanging(catalog.long_map.get(name) orelse return Fault.UnknownFlag);
    } else for (tok[1..]) |c| {
        // A short bundle's tail can be an attached value (`-j4`, `-M0`); the
        // digit is the value, not another flag, so validation stops there.
        if (std.ascii.isDigit(c)) break;
        if (try answerChanging(catalog.short_map[c] orelse return Fault.UnknownFlag)) answerish = true;
    }
    return answerish;
}

fn answerChanging(spec_i: usize) !bool {
    return switch (catalog.reachOf(catalog.flag_catalog[spec_i]) orelse return Fault.NotPersistable) {
        .corpus, .semantics => true,
        .presentation, .execution => false,
    };
}

/// One line's tokens, with shell quoting — the repair of ripgrep's verbatim
/// lines. `'…'` is literal, `"…"` honors `\"`/`\\`, a bare `\` escapes the next
/// byte, and an unquoted `#` begins a comment.
const Line = struct {
    src: []const u8,
    i: usize = 0,

    fn next(self: *Line, gpa: std.mem.Allocator) !?[]const u8 {
        while (self.i < self.src.len and (self.src[self.i] == ' ' or self.src[self.i] == '\t')) self.i += 1;
        if (self.i >= self.src.len or self.src[self.i] == '#') return null;

        var tok: std.ArrayList(u8) = .empty;
        errdefer tok.deinit(gpa);
        while (self.i < self.src.len) : (self.i += 1) switch (self.src[self.i]) {
            ' ', '\t' => break,
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, self.src, self.i + 1, '\'') orelse return Fault.UnterminatedQuote;
                try tok.appendSlice(gpa, self.src[self.i + 1 .. end]);
                self.i = end;
            },
            '"' => {
                self.i += 1;
                while (true) : (self.i += 1) {
                    if (self.i >= self.src.len) return Fault.UnterminatedQuote;
                    if (self.src[self.i] == '"') break;
                    if (self.src[self.i] == '\\' and self.i + 1 < self.src.len) self.i += 1;
                    try tok.append(gpa, self.src[self.i]);
                }
            },
            '\\' => {
                self.i += 1;
                if (self.i >= self.src.len) return Fault.UnterminatedQuote;
                try tok.append(gpa, self.src[self.i]);
            },
            else => |c| try tok.append(gpa, c),
        };
        return try tok.toOwnedSlice(gpa);
    }
};
