//! Shared CLI vocabulary — the verb table a face is described BY, not the
//! four hand-kept lists it used to be described by.
//!
//! `relate`'s surface was written down five times: the module doc comment, the
//! `usage()` text, the `--schema` JSON, the `dispatch` tuple, and the
//! unknown-verb error line. Nothing tied them together, so they drifted — the
//! shipped manifest still advertised `similar --lens bytes|structure|fused`
//! after the flag became `--as`, and both faces' manifests claimed version
//! 0.1.0 against an engine at 0.2.0. `relate echoes` found the two hand-written
//! manifests sitting at structure distance 0.038 while 0.66 apart in bytes:
//! the same document written twice in different words. This module is the
//! answer to its own finding.
//!
//! A face now declares a `Face` — its verbs, each with the handler that runs
//! it — and everything else is rendered:
//!
//!   * `dispatch` routes argv (the row owns its handler, so a verb cannot be
//!     listed without being runnable, or runnable without being listed);
//!   * `usage` renders the help, deriving the question→verb index and every
//!     usage line from the same rows;
//!   * `schema` renders the JSON manifest, including the envelope both faces
//!     were copying verbatim (output stream, trace env, exit codes);
//!   * `names` renders the unknown-verb line;
//!   * `drive` runs the whole process: diagnostic install, argv, the three
//!     introspection conventions, the output budget, dispatch, and the exit
//!     contract. Collapsing the four hand-kept lists left both faces' `main`
//!     byte-identical apart from their own name — `relate echoes` scored the
//!     two at structure distance 0.000, the strongest echo in the corpus, so
//!     the shell moved here and `main` is now the binary's identity only.
//!
//! The rendering is by hand rather than through reflection: the shapes are
//! fixed, the escaping is `emit.jsonStr` (the one escaper every face shares),
//! and the tests parse the rendered bytes back, so an invalid manifest cannot
//! ship.

const std = @import("std");
const emit = @import("irregex").inner.cli.emit;
const outcome = @import("irregex").inner.cli.outcome;
const corpus_mod = @import("irregex").corpus;
const charter = @import("irregex").commands.scope.charter;
const assay = @import("irregex").assay;
const reprise = @import("reprise.zig");
const beacon = @import("irregex").inner.cli.beacon;
const portal = @import("irregex").portal;

const oom = @import("irregex").inner.cli.outcome.oom;

/// A flag's default, typed so the manifest renders `8` / `0.25` / `false` /
/// `"any"` / `null` as JSON rather than as prose about them.
pub const Default = union(enum) {
    /// No default — the flag is absent unless passed, and absence is not a value.
    unset,
    int: i64,
    float: f64,
    boolean: bool,
    text: []const u8,

    fn render(self: Default, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
        switch (self) {
            .unset => buf.appendSlice(gpa, "null") catch oom(),
            .int => |v| buf.print(gpa, "{d}", .{v}) catch oom(),
            .float => |v| buf.print(gpa, "{d}", .{v}) catch oom(),
            .boolean => |v| buf.appendSlice(gpa, if (v) "true" else "false") catch oom(),
            .text => |v| emit.jsonStr(buf, gpa, v),
        }
    }
};

/// A positional argument.
pub const Arg = struct {
    name: []const u8,
    kind: []const u8 = "string",
    required: bool = false,
    doc: []const u8,
};

/// A flag. `kind` is the manifest's type name (`int`/`float`/`bool`/`string`/
/// `string[]`); `required` marks the few flags a verb cannot run without.
pub const Flag = struct {
    name: []const u8,
    kind: []const u8,
    default: Default = .unset,
    required: bool = false,
    doc: []const u8,
};

/// Where a verb sits in the help. Query verbs answer questions; lifecycle
/// verbs own the artifacts those answers ride on.
pub const Section = enum { query, lifecycle };

/// A verb: how to invoke it, how to explain it, and how to run it.
pub const Verb = struct {
    name: []const u8,
    /// The question this verb answers, for the help's question→verb index.
    /// Empty means "no shorthand" — lifecycle verbs mostly.
    asks: []const u8 = "",
    /// The invocation form, tool name excluded. Embedded newlines continue
    /// onto aligned lines.
    form: []const u8,
    /// Human orientation under the form; embedded newlines are separate lines.
    blurb: []const u8,
    /// The long description `--schema` carries — written for a machine reader
    /// that has no other documentation.
    summary: []const u8,
    args: []const Arg = &.{},
    flags: []const Flag = &.{},
    section: Section = .query,
    run: *const fn (std.mem.Allocator, std.Io, []const []const u8) anyerror!void,
    /// Whether this verb's answer is a pure function of the corpus, so the
    /// resident daemon may hold it against a change epoch (`reprise.zig`).
    ///
    /// True for a question ABOUT the corpus. False for anything that reads the
    /// clock, the artifacts' own state, or the world outside the tree — a
    /// lifecycle verb reporting index freshness must never be answered from a
    /// cache of what it said last time, because "what it said last time" is
    /// precisely the thing being asked about.
    keeps: bool = false,
};

/// A name that used to be a verb and is now a shape of another one.
///
/// A fold that only deletes the old name teaches nothing: the next invocation
/// of muscle memory (or of an agent's stale transcript) gets `unknown verb` and
/// a bare list, when the tool knows exactly what the caller meant. A retired
/// row keeps the name reachable as a *diagnostic* — never as a silent alias, so
/// a script pinned to the old spelling fails loudly with the new invocation in
/// hand instead of drifting on semantics that moved underneath it.
pub const Retired = struct {
    name: []const u8,
    /// The invocation that does this job now, verbatim and runnable.
    now: []const u8,
    /// What the fold bought, in one clause — the reason the name is gone.
    because: []const u8,
    /// The binary that owns `now`, when the job moved to a SIBLING face — the
    /// composed verbs folded into `relate`, so `irregex family` has to point out
    /// of its own tool. Null means this face.
    tool: ?[]const u8 = null,

    /// The full replacement invocation as a caller would type it.
    pub fn invocation(self: Retired, face: []const u8) [2][]const u8 {
        return .{ self.tool orelse face, self.now };
    }
};

/// A top-level manifest field beyond the verbs — the tool-specific policy
/// prose (`corpus_policy`, `scoring`, …) each face needs to state once.
pub const Note = struct { key: []const u8, text: []const u8 };

/// An exit code and what it means for this face.
pub const Exit = struct { code: u8, means: []const u8 };

/// Everything a face is. One value per binary.
pub const Face = struct {
    tool: []const u8,
    /// The help's first line.
    tagline: []const u8,
    /// The manifest's `summary` — the whole face in one machine-read sentence.
    summary: []const u8,
    verbs: []const Verb,
    /// Names that were folded into a verb above. Reachable as coaching, not as
    /// aliases (see `Retired`).
    retired: []const Retired = &.{},
    notes: []const Note = &.{},
    exits: []const Exit,
    /// Help prose that is genuinely prose: the channel/grade vocabulary, the
    /// niche choices, the corpus policy. Rendered verbatim after the verbs.
    epilogue: []const u8 = "",

    /// Look up a verb by name.
    pub fn find(self: Face, name: []const u8) ?Verb {
        for (self.verbs) |v| if (std.mem.eql(u8, v.name, name)) return v;
        return null;
    }

    /// Look up a folded name.
    pub fn folded(self: Face, name: []const u8) ?Retired {
        for (self.retired) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }
};

// ── dispatch ─────────────────────────────────────────────────────────────

/// Run the verb named `mode`, or report `false` if this face has no such verb.
/// The handler comes off the same row the help and manifest describe.
pub fn dispatch(
    face: Face,
    mode: []const u8,
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !bool {
    const verb = face.find(mode) orelse return false;
    try verb.run(gpa, io, argv);
    return true;
}

/// `search | pack | quote | …` — the unknown-verb line's verb list.
pub fn names(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, face: Face) void {
    for (face.verbs, 0..) |v, i| {
        if (i > 0) buf.appendSlice(gpa, " | ") catch oom();
        buf.appendSlice(gpa, v.name) catch oom();
    }
}

/// Print the unknown-verb diagnostic and exit 2 — the shape both faces used.
///
/// A name this face used to carry is answered with the invocation that replaced
/// it, in gist's hint grammar (`try:` / `note:`), because the caller's intent is
/// known and only the spelling moved. Exit stays 2: coaching, never an alias.
pub fn unknown(face: Face, mode: []const u8) noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    if (face.folded(mode)) |r| {
        const at = r.invocation(face.tool);
        assay.diag("{s}: '{s}' folded into {s} {s}\n", .{ face.tool, mode, at[0], at[1] });
        assay.diag("{s}: try: {s} {s}\n", .{ face.tool, at[0], at[1] });
        assay.diag("{s}: note: {s}\n", .{ face.tool, r.because });
        std.process.exit(2);
    }
    var buf: std.ArrayList(u8) = .empty;
    names(&buf, gpa, face);
    assay.diag("{s}: unknown verb '{s}' ({s}; --help)\n", .{ face.tool, mode, buf.items });
    std.process.exit(2);
}

// ── the help ─────────────────────────────────────────────────────────────

/// Render the human help: tagline, the question→verb index, every verb's form
/// and blurb by section, then the face's prose epilogue.
pub fn usage(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, face: Face) void {
    buf.print(gpa, "{s}\n", .{face.tagline}) catch oom();

    // The question→verb index: what an agent scans before it knows the names.
    var any_asks = false;
    for (face.verbs) |v| any_asks = any_asks or v.asks.len > 0;
    if (any_asks) {
        buf.appendSlice(gpa, "\nergonomics — ask the question, then choose the verb:\n") catch oom();
        var widest: usize = 0;
        for (face.verbs) |v| widest = @max(widest, v.asks.len);
        for (face.verbs) |v| {
            if (v.asks.len == 0) continue;
            buf.print(gpa, "  {s}", .{v.asks}) catch oom();
            buf.appendNTimes(gpa, ' ', widest - v.asks.len + 4) catch oom();
            buf.print(gpa, "{s}\n", .{v.name}) catch oom();
        }
    }

    inline for (.{ .{ Section.query, "query verbs" }, .{ Section.lifecycle, "lifecycle" } }) |sec| {
        var first = true;
        for (face.verbs) |v| {
            if (v.section != sec[0]) continue;
            if (first) buf.print(gpa, "\n{s}:\n", .{sec[1]}) catch oom();
            first = false;
            form(buf, gpa, face.tool, v);
            var lines = std.mem.splitScalar(u8, v.blurb, '\n');
            while (lines.next()) |l| if (l.len > 0) buf.print(gpa, "      {s}\n", .{l}) catch oom();
        }
    }

    if (face.retired.len > 0) {
        buf.appendSlice(gpa, "\nfolded — the name is gone, the question is not:\n") catch oom();
        var widest: usize = 0;
        for (face.retired) |r| widest = @max(widest, r.name.len);
        for (face.retired) |r| {
            const at = r.invocation(face.tool);
            buf.print(gpa, "  {s}", .{r.name}) catch oom();
            buf.appendNTimes(gpa, ' ', widest - r.name.len + 4) catch oom();
            buf.print(gpa, "{s} {s}\n", .{ at[0], at[1] }) catch oom();
        }
    }

    if (face.epilogue.len > 0) buf.print(gpa, "\n{s}", .{face.epilogue}) catch oom();
}

/// `  relate similar <path> …`, continuation lines aligned under the args.
fn form(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, tool: []const u8, v: Verb) void {
    const indent = 2 + tool.len + 1 + v.name.len + 1;
    var lines = std.mem.splitScalar(u8, v.form, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (first) {
            buf.print(gpa, "  {s} {s}{s}{s}\n", .{ tool, v.name, if (l.len > 0) " " else "", l }) catch oom();
            first = false;
        } else {
            buf.appendNTimes(gpa, ' ', indent) catch oom();
            buf.print(gpa, "{s}\n", .{l}) catch oom();
        }
    }
}

// ── the manifest ─────────────────────────────────────────────────────────

/// The envelope both faces were maintaining as separate copies. Anything true
/// of every irregex-family binary belongs here, not in a face.
const trace_note =
    \\"trace":{"summary":"phase-trace diagnostics on stderr, off by default; on a --json run the stderr diagnostic is one NDJSON record, so timing is machine-parseable alongside stdout results","channel":"stderr","env":{"GIST_TRACE":"comma-separated lenses (amend,journal,reconcile,warm,rank,index,query,session,fault) or 'all'; off when unset","GIST_TRACE_FORMAT":"text|json; defaults to the run's --json format"}}
;

/// Render the JSON capability manifest.
pub fn schema(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, face: Face, version: []const u8) void {
    buf.appendSlice(gpa, "{\"tool\":") catch oom();
    emit.jsonStr(buf, gpa, face.tool);
    buf.appendSlice(gpa, ",\"version\":") catch oom();
    emit.jsonStr(buf, gpa, version);
    buf.appendSlice(gpa, ",\"summary\":") catch oom();
    emit.jsonStr(buf, gpa, face.summary);

    buf.appendSlice(gpa, ",\"verbs\":{") catch oom();
    for (face.verbs, 0..) |v, i| {
        if (i > 0) buf.append(gpa, ',') catch oom();
        emit.jsonStr(buf, gpa, v.name);
        buf.appendSlice(gpa, ":{\"summary\":") catch oom();
        emit.jsonStr(buf, gpa, v.summary);
        buf.appendSlice(gpa, ",\"args\":[") catch oom();
        for (v.args, 0..) |a, j| {
            if (j > 0) buf.append(gpa, ',') catch oom();
            buf.appendSlice(gpa, "{\"name\":") catch oom();
            emit.jsonStr(buf, gpa, a.name);
            buf.appendSlice(gpa, ",\"type\":") catch oom();
            emit.jsonStr(buf, gpa, a.kind);
            buf.print(gpa, ",\"required\":{s},\"description\":", .{if (a.required) "true" else "false"}) catch oom();
            emit.jsonStr(buf, gpa, a.doc);
            buf.append(gpa, '}') catch oom();
        }
        buf.appendSlice(gpa, "],\"flags\":[") catch oom();
        for (v.flags, 0..) |f, j| {
            if (j > 0) buf.append(gpa, ',') catch oom();
            buf.appendSlice(gpa, "{\"name\":") catch oom();
            emit.jsonStr(buf, gpa, f.name);
            buf.appendSlice(gpa, ",\"type\":") catch oom();
            emit.jsonStr(buf, gpa, f.kind);
            buf.appendSlice(gpa, ",\"default\":") catch oom();
            f.default.render(buf, gpa);
            if (f.required) buf.appendSlice(gpa, ",\"required\":true") catch oom();
            buf.appendSlice(gpa, ",\"description\":") catch oom();
            emit.jsonStr(buf, gpa, f.doc);
            buf.append(gpa, '}') catch oom();
        }
        buf.appendSlice(gpa, "]}") catch oom();
    }
    buf.append(gpa, '}') catch oom();

    if (face.retired.len > 0) {
        buf.appendSlice(gpa, ",\"retired\":{") catch oom();
        for (face.retired, 0..) |r, i| {
            if (i > 0) buf.append(gpa, ',') catch oom();
            const at = r.invocation(face.tool);
            emit.jsonStr(buf, gpa, r.name);
            // The whole invocation, tool included: an agent reading only this
            // manifest cannot know which binary owns the replacement, and for
            // the composed verbs it is not the one it just called.
            buf.appendSlice(gpa, ":{\"now\":") catch oom();
            emit.jsonStr(buf, gpa, std.fmt.allocPrint(gpa, "{s} {s}", .{ at[0], at[1] }) catch oom());
            buf.appendSlice(gpa, ",\"because\":") catch oom();
            emit.jsonStr(buf, gpa, r.because);
            buf.append(gpa, '}') catch oom();
        }
        buf.append(gpa, '}') catch oom();
    }

    for (face.notes) |n| {
        buf.append(gpa, ',') catch oom();
        emit.jsonStr(buf, gpa, n.key);
        buf.append(gpa, ':') catch oom();
        emit.jsonStr(buf, gpa, n.text);
    }

    buf.appendSlice(gpa, ",\"output_stream\":{\"results\":\"stdout\",\"diagnostics\":\"stderr\"},") catch oom();
    buf.appendSlice(gpa, trace_note) catch oom();

    buf.appendSlice(gpa, ",\"exit_codes\":{") catch oom();
    for (face.exits, 0..) |e, i| {
        buf.print(gpa, "{s}\"{d}\":", .{ if (i > 0) "," else "", e.code }) catch oom();
        emit.jsonStr(buf, gpa, e.means);
    }
    buf.appendSlice(gpa, "}}\n") catch oom();
}

fn emitUsage(face: Face) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    usage(&buf, arena.allocator(), face);
    corpus_mod.emitStdout(buf.items);
}

/// A version that was asked for is an answer, not a diagnostic: rg writes it
/// to stdout, so `gist --version | read` works, and so does every wrapper that
/// captures only stdout.
fn emitVersion(face: Face, version: []const u8) !void {
    var line: [96]u8 = undefined;
    corpus_mod.emitStdout(try std.fmt.bufPrint(&line, "{s} {s}\n", .{ face.tool, version }));
}

fn emitSchema(face: Face, version: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    schema(&buf, arena.allocator(), face, version);
    corpus_mod.emitStdout(buf.items);
}

// ── the process ──────────────────────────────────────────────────────────

/// Run a face as a process, start to exit: the whole body of a `main`.
///
/// Every irregex-family binary is the same program with a different verb
/// table, so a face's `main` names its repertoire and nothing else. The
/// conventions live here once — an agent that learns `--help`/`--version`/
/// `--schema`, the trace env, and the rg-shaped exit codes on one binary has
/// learned all of them, because there is only one implementation to learn.
///
/// Takes no error union on purpose: Zig's default handler exits 1 with a stack
/// trace, and 1 is "clean no-match" under the rg contract. Errors exit 2.
pub fn drive(face: Face, version: []const u8, init: std.process.Init) void {
    steer(face, version, init) catch |e| outcome.fatal(face.tool, e);
    // The third way a face can finish: no outcome, no verdict, just a verb that
    // ran out of rows to print. Sealing here rather than only at the two exit
    // sites is what makes the keep cover the kinship verbs at all.
    reprise.seal(0);
}

/// argv minus the token `honorNoConfig` already answered. A verb table cannot
/// carry a flag that is legal in front of every verb, so it is dropped here
/// rather than added to each repertoire — the same filter gist's face applies.
fn nextArg(it: *std.process.Args.Iterator) ?[]const u8 {
    while (it.next()) |a| if (!charter.consumed(a)) return a;
    return null;
}

fn steer(face: Face, version: []const u8, init: std.process.Init) !void {
    // Cold CLI diagnostic policy: stderr sink, lens mask + render format read
    // once from `GIST_TRACE`/`GIST_TRACE_FORMAT`.
    assay.install(.{});
    // Before anything reads the tree: relate and irregex resolve roots and skips
    // through the same committed charter gist does, so they honor the same
    // opt-out, and it has to be read from raw argv (see `charter.honorNoConfig`).
    charter.honorNoConfig(init.gpa, init.minimal.args);

    var it = try portal.argsIterator(init.minimal.args, init.gpa);
    _ = it.skip(); // argv[0]
    const mode = nextArg(&it) orelse return emitUsage(face);

    if (spelled(mode, "--help", "-h")) return emitUsage(face);
    if (spelled(mode, "--version", "-V")) return emitVersion(face, version);
    if (std.mem.eql(u8, mode, "--schema")) return emitSchema(face, version);

    // Same output-budget resolution as the gist CLI (GIST_UNCAP /
    // GIST_MAX_OUTPUT_*) so no face clips a grouped answer differently.
    corpus_mod.initOutputBudget(false);

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(init.gpa);
    while (nextArg(&it)) |arg| try rest.append(init.gpa, arg);
    // Clickable rows for the two verb-shaped faces. Every row relate and
    // irregex print names a file the reader's next move is to open, so the
    // whole layer is worth one call here. They share no flag struct with gist,
    // so the posture comes from `GIST_HYPERLINK` and the terminal probe alone
    // and the only thing argv has to say is whether this run prints records.
    beacon.install(beacon.resolve(init.gpa, .{
        .reader = if (mentions(rest.items, "--json")) .records else .human,
    }, init.io, init.environ_map));
    // A corpus-pure verb asks the resident keep first: a hit prints the held
    // answer and exits here, and a miss arms the stdout copy the verb's own
    // exit offers back (`reprise.zig`). Silent and fail-open — an unreachable
    // or stale daemon leaves the dispatch below exactly as it was.
    if (face.find(mode)) |v| {
        if (v.keeps) reprise.attempt(init.gpa, init.io, init.environ_map, face.tool, v.name, rest.items);
    }
    if (!try dispatch(face, mode, init.gpa, init.io, rest.items)) unknown(face, mode);
}

fn spelled(mode: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, mode, long) or std.mem.eql(u8, mode, short);
}

fn mentions(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn noop(_: std.mem.Allocator, _: std.Io, _: []const []const u8) anyerror!void {}

const sample = Face{
    .tool = "demo",
    .tagline = "demo — a face for the tests",
    .summary = "the whole face in one sentence",
    .verbs = &.{
        .{
            .name = "similar",
            .asks = "one file -> neighbors",
            .form = "<path> [--as copies|twins]\n[--top N]",
            .blurb = "nearest files\nlower is closer",
            .summary = "nearest files to <path>",
            .args = &.{.{ .name = "path", .required = true, .doc = "the probe file" }},
            .flags = &.{
                .{ .name = "--as", .kind = "string", .default = .{ .text = "copies" }, .doc = "the channel" },
                .{ .name = "--top", .kind = "int", .default = .{ .int = 20 }, .doc = "rows surfaced" },
                .{ .name = "-e", .kind = "string[]", .required = true, .doc = "a pattern" },
            },
            .run = noop,
        },
        .{ .name = "index", .form = "[--shelf]", .blurb = "build the atlas", .summary = "build + persist", .section = .lifecycle, .run = noop },
    },
    .retired = &.{
        .{ .name = "dups", .now = "similar --as copies", .because = "a channel flag is not a verb" },
        .{ .name = "context", .now = "pack --matching PAT", .because = "the job moved to a sibling face", .tool = "other" },
    },
    .notes = &.{.{ .key = "corpus_policy", .text = "the shared corpus" }},
    .exits = &.{ .{ .code = 0, .means = "verb ran" }, .{ .code = 2, .means = "usage error" } },
};

test "the manifest renders as valid JSON carrying every verb and typed defaults" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    schema(&buf, a, sample, "0.2.0");

    const parsed = try std.json.parseFromSlice(std.json.Value, a, buf.items, .{});
    const root = parsed.value.object;
    try t.expectEqualStrings("demo", root.get("tool").?.string);
    try t.expectEqualStrings("0.2.0", root.get("version").?.string);
    try t.expectEqualStrings("the shared corpus", root.get("corpus_policy").?.string);

    const verbs = root.get("verbs").?.object;
    try t.expect(verbs.contains("similar") and verbs.contains("index"));
    const flags = verbs.get("similar").?.object.get("flags").?.array.items;
    // A default keeps its JSON type — a string stays quoted, an int stays a number.
    try t.expectEqualStrings("copies", flags[0].object.get("default").?.string);
    try t.expectEqual(@as(i64, 20), flags[1].object.get("default").?.integer);
    try t.expectEqual(std.json.Value.null, flags[2].object.get("default").?);
    try t.expect(flags[2].object.get("required").?.bool);
    // A verb with no args still declares the key, so a reader never branches.
    try t.expectEqual(@as(usize, 0), verbs.get("index").?.object.get("args").?.array.items.len);
    // The envelope every face shares comes from one place.
    try t.expectEqualStrings("stderr", root.get("output_stream").?.object.get("diagnostics").?.string);
    try t.expect(root.get("trace").?.object.get("env").?.object.contains("GIST_TRACE"));
    try t.expectEqualStrings("usage error", root.get("exit_codes").?.object.get("2").?.string);
    // A folded name is in the manifest but NOT in the verb table, so an agent
    // reading the schema learns the new invocation instead of retrying the old.
    try t.expect(!verbs.contains("dups"));
    const folded = root.get("retired").?.object;
    try t.expectEqualStrings("demo similar --as copies", folded.get("dups").?.object.get("now").?.string);
    // A job that moved to a sibling binary names that binary, so the coaching
    // line an agent copies is runnable rather than `demo other …`.
    try t.expectEqualStrings("other pack --matching PAT", folded.get("context").?.object.get("now").?.string);
}

test "the help derives its index, its forms, and its continuation alignment" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    usage(&buf, arena.allocator(), sample);
    try t.expectEqualStrings(
        \\demo — a face for the tests
        \\
        \\ergonomics — ask the question, then choose the verb:
        \\  one file -> neighbors    similar
        \\
        \\query verbs:
        \\  demo similar <path> [--as copies|twins]
        \\               [--top N]
        \\      nearest files
        \\      lower is closer
        \\
        \\lifecycle:
        \\  demo index [--shelf]
        \\      build the atlas
        \\
        \\folded — the name is gone, the question is not:
        \\  dups       demo similar --as copies
        \\  context    other pack --matching PAT
        \\
    , buf.items);
}

test "a folded name is documented, not dispatchable" {
    // The whole point of the row: `find` still says no (so dispatch cannot
    // silently answer a moved question), while `folded` knows what to teach.
    try t.expect(sample.find("dups") == null);
    const r = sample.folded("dups").?;
    try t.expectEqualStrings("similar --as copies", r.now);
    try t.expect(sample.folded("similar") == null);
}

test "names renders the unknown-verb line's verb list" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    names(&buf, arena.allocator(), sample);
    try t.expectEqualStrings("similar | index", buf.items);
}

test "find is the one lookup dispatch and help share" {
    try t.expect(sample.find("similar") != null);
    try t.expect(sample.find("nope") == null);
}
