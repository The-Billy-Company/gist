//! `gist config` — what is steering this run, and where it came from.
//!
//! ripgrep has a configuration file and no way to ask it anything. To find out
//! what a `.ripgreprc` is doing you open it and reason about it yourself, which
//! is why the standing advice for confusing results is "try `--no-config`" —
//! bisection as a diagnostic, because introspection does not exist.
//!
//! Persisted configuration earns that introspection or it should not be
//! persisted. Three questions, one verb:
//!
//!   * `gist config`         what is in force right now, and from which file
//!   * `gist config check`   is what I wrote valid — without running a search
//!   * `gist config init`    write the file, prefilled from what this machine
//!                           is already carrying
//!
//! `init` is the one with no ripgrep analogue at all. The two facts the charter
//! exists to hold were previously stranded in per-machine state — `GIST_ROOTS`
//! in one shell's environment, `skips.list` inside a gitignored artifact
//! directory — so the migration is not "read the docs and hand-write TOML", it
//! is "gist already knows; let it write down what you told it". Nobody has to
//! learn the format to get a correct charter.

const std = @import("std");
const assay = @import("../../../../assay/assay.zig");
const charter = @import("../../../../corpus/scope/charter.zig");
const corpus = @import("../../../../corpus/tree/corpus.zig");
const misread = @import("../../../../corpus/scope/misread.zig");
const preference = @import("../../../exec/cold/argv/preference.zig");
const jsonstr = @import("../../../exec/cold/emit/jsonstr.zig");

const Dir = std.Io.Dir;

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var verb: []const u8 = "";
    var json = false;
    var write = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true //
        else if (std.mem.eql(u8, a, "--write")) write = true //
        else if (a.len > 0 and a[0] == '-') return usage(a) //
        else if (verb.len == 0) verb = a //
        else return usage(a);
    }

    if (verb.len == 0) return show(gpa, io, json);
    if (std.mem.eql(u8, verb, "check")) return check(gpa);
    if (std.mem.eql(u8, verb, "init")) return init(gpa, io, write);
    return usage(verb);
}

fn usage(bad: []const u8) noreturn {
    assay.diag("gist: config: unexpected `{s}`\n", .{bad});
    assay.diag(
        \\usage: gist config [--json]     what is in force, and from which file
        \\       gist config check        validate both layers; exit 2 if either is malformed
        \\       gist config init [--write]   write a charter prefilled from this machine
        \\
    , .{});
    std.process.exit(2);
}

// ── show ─────────────────────────────────────────────────────────────────────

/// Report the resolved stack. Every line answers "which file said this", since
/// the only reason to ask is that something is behaving in a way the typed
/// command does not explain.
fn show(gpa: std.mem.Allocator, io: std.Io, json: bool) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    if (json) {
        try renderJson(gpa, &out, io);
    } else {
        try renderHuman(gpa, &out, io);
    }
    corpus.emitStdout(out.items);
}

fn renderHuman(gpa: std.mem.Allocator, out: *std.ArrayList(u8), io: std.Io) !void {
    // Suppression is a banner, not a refusal. `GIST_NO_CONFIG` exported into a
    // shell is exactly when someone needs to see what is on disk, and the one
    // command whose job is introspection declining to introspect would be the
    // ripgrep defect this verb exists to repair.
    const off = charter.suppressedNow();
    if (off) try out.appendSlice(gpa, "suppressed — --no-config / GIST_NO_CONFIG; no search this run reads either file\n\n");

    try out.appendSlice(gpa, "corpus — what this tree is (committed, applies to everyone)\n");
    if (charter.faulted()) |f| {
        var loc: [24]u8 = undefined;
        try out.print(gpa, "  {s}{s}  MALFORMED — {s}\n", .{ f.path, misread.at(&loc, f.at), charter.faultNote(f.err) });
        try out.appendSlice(gpa, "  nothing from it is in force; every search falls back to the defaults below\n");
    } else if (charter.inspect()) |c| {
        try out.print(gpa, "  {s}\n", .{c.path});
        try list(gpa, out, "roots", c.roots);
        try list(gpa, out, "skip", c.skip);
        try list(gpa, out, "types", c.types);
        if (c.roots.len == 0 and c.skip.len == 0 and c.types.len == 0) {
            try out.appendSlice(gpa, "    (declares nothing)\n");
        }
    } else {
        try out.print(gpa, "  no {s} in this tree — `gist config init` writes one\n", .{charter.filename});
    }

    // The environment still outranks the file, so a reader whose charter looks
    // ignored is usually looking at a shell variable they set months ago. That
    // is exactly the invisible state the charter exists to retire, so name it.
    try overrides(gpa, out);

    try out.appendSlice(gpa, "\ntaste — what you like to look at (machine-local, terminal only)\n");
    if (preference.faulted()) |f| {
        var loc: [24]u8 = undefined;
        try out.print(gpa, "  {s}{s}  MALFORMED — {s}\n", .{ f.path, misread.at(&loc, f.at), preference.faultNote(f.err) });
    } else if (preference.loaded()) |p| {
        try out.print(gpa, "  {s}\n", .{p.path});
        try out.appendSlice(gpa, "    ");
        for (p.tokens, 0..) |tok, i| {
            if (i > 0) try out.append(gpa, ' ');
            try out.appendSlice(gpa, tok);
        }
        try out.append(gpa, '\n');
        try out.print(gpa, "    {s}\n", .{if (preference.forThisRun(io).len > 0)
            "in force — stdout is a terminal"
        else if (off)
            "NOT in force — suppressed"
        else
            "NOT in force — stdout is not a terminal, so this file is invisible to this run"});
        if (p.changes_answer) {
            try out.appendSlice(gpa, "    contains flags that change WHICH LINES MATCH, not just how they render\n");
        }
    } else {
        try out.appendSlice(gpa, "  none\n");
    }
}

fn list(gpa: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try out.print(gpa, "    {s: <6}", .{label});
    for (items, 0..) |x, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, x);
    }
    try out.append(gpa, '\n');
}

/// Environment variables that outrank the committed file. Reported whether or
/// not a charter exists: "my charter is being ignored" and "I have no charter
/// but roots are set anyway" are the same confusion from opposite directions.
fn overrides(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    inline for (.{
        .{ "GIST_ROOTS", "roots" },
        .{ "GIST_SKIP", "skip" },
    }) |pair| if (assay.envSpan(pair[0])) |v| if (v.len > 0) {
        try out.print(gpa, "  {s}={s} in this shell — overrides the charter's `{s}`\n", .{ pair[0], v, pair[1] });
    };
}

fn renderJson(gpa: std.mem.Allocator, out: *std.ArrayList(u8), io: std.Io) !void {
    try out.appendSlice(gpa, "{\"suppressed\":");
    try out.appendSlice(gpa, if (charter.suppressedNow()) "true" else "false");

    try out.appendSlice(gpa, ",\"charter\":");
    if (charter.faulted()) |f| {
        try out.appendSlice(gpa, "{\"path\":");
        jsonstr.write(out, gpa, f.path);
        try out.print(gpa, ",\"valid\":false,\"line\":{d},\"error\":", .{f.at.line});
        jsonstr.write(out, gpa, charter.faultNote(f.err));
        try out.append(gpa, '}');
    } else if (charter.inspect()) |c| {
        try out.appendSlice(gpa, "{\"path\":");
        jsonstr.write(out, gpa, c.path);
        try out.appendSlice(gpa, ",\"valid\":true,\"roots\":");
        try strings(gpa, out, c.roots);
        try out.appendSlice(gpa, ",\"skip\":");
        try strings(gpa, out, c.skip);
        try out.appendSlice(gpa, ",\"types\":");
        try strings(gpa, out, c.types);
        try out.append(gpa, '}');
    } else try out.appendSlice(gpa, "null");

    try out.appendSlice(gpa, ",\"preferences\":");
    if (preference.faulted()) |f| {
        try out.appendSlice(gpa, "{\"path\":");
        jsonstr.write(out, gpa, f.path);
        try out.print(gpa, ",\"valid\":false,\"line\":{d},\"error\":", .{f.at.line});
        jsonstr.write(out, gpa, preference.faultNote(f.err));
        try out.append(gpa, '}');
    } else if (preference.loaded()) |p| {
        try out.appendSlice(gpa, "{\"path\":");
        jsonstr.write(out, gpa, p.path);
        try out.appendSlice(gpa, ",\"valid\":true,\"tokens\":");
        try strings(gpa, out, p.tokens);
        try out.print(gpa, ",\"in_force\":{s},\"changes_answer\":{s}}}", .{
            if (preference.forThisRun(io).len > 0) "true" else "false",
            if (p.changes_answer) "true" else "false",
        });
    } else try out.appendSlice(gpa, "null");

    try out.appendSlice(gpa, "}\n");
}

fn strings(gpa: std.mem.Allocator, out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.append(gpa, '[');
    for (items, 0..) |x, i| {
        if (i > 0) try out.append(gpa, ',');
        jsonstr.write(out, gpa, x);
    }
    try out.append(gpa, ']');
}

// ── check ────────────────────────────────────────────────────────────────────

/// Validate both layers without running a search — the pre-commit and CI shape,
/// and the answer to "did I write that correctly?" that does not require
/// inventing a query and squinting at the results.
///
/// Reports BOTH layers before exiting, rather than dying on the first: someone
/// fixing their configuration wants the whole list, not one item per run.
fn check(gpa: std.mem.Allocator) !void {
    var bad = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var loc: [24]u8 = undefined;

    if (charter.faulted()) |f| {
        bad = true;
        try out.print(gpa, "{s}{s}: {s}\n", .{ f.path, misread.at(&loc, f.at), charter.faultNote(f.err) });
        if (charter.didYouMean(f.err, f.at.token)) |k| {
            try out.print(gpa, "  try `{s}` — `{s}` is not a charter key\n", .{ k, f.at.token });
        }
    } else if (charter.inspect()) |c| {
        try out.print(gpa, "{s}: ok\n", .{c.path});
    }

    if (preference.faulted()) |f| {
        bad = true;
        try out.print(gpa, "{s}{s}: {s}\n", .{ f.path, misread.at(&loc, f.at), preference.faultNote(f.err) });
        if (preference.didYouMean(f.err, f.at.token)) |better| {
            try out.print(gpa, "  try `--{s}` — `{s}` is not a flag gist knows\n", .{ better, f.at.token });
        }
    } else if (preference.loaded()) |p| {
        try out.print(gpa, "{s}: ok\n", .{p.path});
    }

    if (out.items.len == 0) try out.appendSlice(gpa, "no persisted configuration\n");
    corpus.emitStdout(out.items);
    if (bad) std.process.exit(2);
}

// ── init ─────────────────────────────────────────────────────────────────────

/// Write the charter this machine has been carrying in unshareable places.
///
/// Only facts the user already asserted are lifted — `GIST_ROOTS` from the
/// environment, `skips.list` from the artifact directory. Nothing is inferred
/// from the shape of the tree: a guessed `skip` silently hides files, which is
/// the exact failure this whole layer is built to prevent, and being wrong
/// about it would be far worse than making someone type one line.
fn init(gpa: std.mem.Allocator, io: std.Io, write: bool) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const roots = try env_list(gpa, "GIST_ROOTS");
    defer freeAll(gpa, roots);
    const skip = try seededSkips(gpa, io);
    defer freeAll(gpa, skip);

    try out.appendSlice(gpa,
        \\# What this tree is. Committed, so every clone and every agent agrees.
        \\# Only corpus facts belong here — which files exist, never what counts
        \\# as a match in them. Personal taste goes in your preferences file.
        \\
    );
    try emitKey(gpa, &out, "roots", roots, "the subtrees that mean \"the corpus\" here");
    try emitKey(gpa, &out, "skip", skip, "directory basenames no corpus walk enters");
    try emitKey(gpa, &out, "types", &.{}, "extra --type names, as name:glob");

    if (!write) {
        corpus.emitStdout(out.items);
        assay.diag("gist: nothing written — `gist config init --write` creates {s}\n", .{charter.filename});
        if (roots.len > 0 or skip.len > 0) {
            assay.diag("gist: note: prefilled from this machine's GIST_ROOTS / skips.list, which no clone of this tree can see\n", .{});
        }
        return;
    }

    if (Dir.cwd().statFile(io, charter.filename, .{})) |_| {
        assay.diag("gist: {s} already exists — edit it, or delete it first\n", .{charter.filename});
        std.process.exit(2);
    } else |_| {}

    try Dir.cwd().writeFile(io, .{ .sub_path = charter.filename, .data = out.items });
    assay.diag("gist: wrote {s} — commit it so the tree travels with its corpus\n", .{charter.filename});
}

fn emitKey(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, items: []const []const u8, why: []const u8) !void {
    try out.print(gpa, "\n# {s}\n", .{why});
    // A key with nothing to say is commented out rather than written empty:
    // `roots = []` is a declaration ("no roots"), and an example is worth more
    // to the next reader than an assertion nobody meant to make.
    if (items.len == 0) {
        try out.print(gpa, "# {s} = []\n", .{key});
        return;
    }
    try out.print(gpa, "{s} = [", .{key});
    for (items, 0..) |x, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.print(gpa, "\"{s}\"", .{x});
    }
    try out.appendSlice(gpa, "]\n");
}

fn env_list(gpa: std.mem.Allocator, comptime name: [:0]const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer freeAll(gpa, found.items);
    if (assay.envSpan(name)) |v| {
        var it = std.mem.tokenizeAny(u8, v, ": ,");
        while (it.next()) |tok| try found.append(gpa, try gpa.dupe(u8, tok));
    }
    return found.toOwnedSlice(gpa);
}

/// `<GIST_DIR>/skips.list` — the same file `haystack` reads, so what `init`
/// lifts is exactly what this machine has been silently applying.
fn seededSkips(gpa: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer freeAll(gpa, found.items);

    const env = try env_list(gpa, "GIST_SKIP");
    defer freeAll(gpa, env);
    for (env) |tok| try found.append(gpa, try gpa.dupe(u8, tok));

    const path = try std.fmt.allocPrint(gpa, "{s}/skips.list", .{corpus.outDir()});
    defer gpa.free(path);
    const src = Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10)) catch return found.toOwnedSlice(gpa);
    defer gpa.free(src);

    var lines = std.mem.tokenizeAny(u8, src, "\r\n");
    while (lines.next()) |line| {
        const tok = std.mem.trim(u8, line, " \t");
        if (tok.len == 0 or tok[0] == '#') continue;
        try found.append(gpa, try gpa.dupe(u8, tok));
    }
    return found.toOwnedSlice(gpa);
}

fn freeAll(gpa: std.mem.Allocator, items: []const []const u8) void {
    for (items) |x| gpa.free(x);
    gpa.free(items);
}
