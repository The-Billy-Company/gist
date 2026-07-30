//! relate — the `similar` verb: what else is like this ONE thing?
//!
//!   relate similar <path | path#Lnnn | text> [--as copies|twins|shapes|any]
//!                  [--unit file|function] [--matching PAT]... [--min-grade G]
//!                  [--top N] [--json] [--no-index] [ROOT...]
//!
//! One probe, one ranked answer. What differs is only what you hand it, and the
//! probe's SHAPE decides how it is priced — a flag never has to agree with the
//! argument:
//!
//!   | probe | scored as | the question |
//!   |---|---|---|
//!   | `libs/…/scan.py` | kinship (`copies`) | what resembles this file? |
//!   | `scan.py#L120` | kinship over fragments | where else is this function? |
//!   | `"how leases expire"` | `recall` (coding gain) | which files explain this? |
//!   | `"for (x) \|i\| sum += w(i)"` + `--as` | kinship against the text | what is shaped like this snippet? |
//!
//! This replaced two verbs — `search` (text only, gain, ungraded) and `similar`
//! (path only, distance, graded) — that were the same act with different
//! plumbing, and whose split forced the caller to know which one their question
//! was before asking it. Handing `search` a path scored the path STRING; handing
//! `similar` text died on `cannot read`.
//!
//! **The polarity is spelled, never fused.** A distance closes toward zero and a
//! coding gain grows, so the score column is named for what it is (`distance` /
//! `echo` / `gain`) and each has its own calibrated bands. Nothing averages a
//! distance with a gain.
//!
//! **A score is not an answer.** Ranking always returns rows, so a probe with no
//! real kin still prints its nearest strangers and reads exactly like a hit.
//! Every row carries a calibrated grade, `--min-grade` withholds background, and
//! an answer made only of background explains itself on stderr in gist's hint
//! grammar. Sub-mass units stay out of the population entirely: two files too
//! short to shed a real fingerprint sample land at distance ≈ 0 by arithmetic,
//! and a false `identical` is worse than no row.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const assay = @import("../../../assay/assay.zig");
const echoes = @import("../../../kernel/kinship/cluster/echoes.zig");
const sketch_mod = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const frag = @import("../../../corpus/index/frag/frag.zig");
const lexicon = @import("../../../kernel/kinship/recall/lexicon.zig");
const zipper = @import("../../../kernel/kinship/recall/zipper.zig");
const retrieval = @import("../../../exec/retrieval/retrieval.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");
const grade = @import("../../cli/grade.zig");
const options = @import("options.zig");
const units = @import("units.zig");

const Sketch = sketch_mod.Sketch;
const Silhouette = silhouette_mod.Silhouette;
const Dir = std.Io.Dir;
const die = @import("../../cli/outcome.zig").die;
const oom = @import("../../cli/outcome.zig").oom;

const usage =
    "usage: relate similar <path | path#Lnnn | text> [--as copies|twins|shapes|any]\n" ++
    "       [--unit file|function] [--matching PAT]... [--min-grade G] [--top N]\n" ++
    "       [--json] [--no-index] [ROOT...]\n";

pub fn runSimilar(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: options.Opts = .{ .top = 20 };
    defer o.deinit(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try options.parse(gpa, argv, &o, &roots, .{
        .no_index = true,
        .channel = true,
        .unit = true,
        .min_lines = true,
        .min_mass = true,
        .min_grade = true,
        .matching = true,
        .positional = true,
        .strict = "similar",
    });
    const arg = o.arg orelse die(usage, .{});
    if (arg.len == 0) die("relate similar: empty probe\n", .{});

    var probe = Probe.open(gpa, io, arg, &o);
    defer probe.deinit(gpa);

    var run = assay.Run.open(gpa, io, o.json);
    switch (probe) {
        .record => |*r| try rankKin(gpa, io, &o, roots.items, r, &run),
        .recall => |text| try rankRecall(gpa, io, &o, roots.items, text, &run),
    }
}

// ── the probe ──

/// What the caller handed us, already priced-by-shape.
const Probe = union(enum) {
    /// Bytes in hand — a file, one function out of a file, or text the caller
    /// asked to treat as a record with `--as`. Scored on a kinship channel.
    record: Record,
    /// Text with no channel named: scored by coding gain against the corpus.
    recall: []const u8,

    fn deinit(self: *Probe, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .record => |*r| r.deinit(gpa),
            .recall => {},
        }
    }

    /// Classify `arg` and load whatever it names. The probe's shape also seeds
    /// the defaults it implies, so `similar foo.py#L120` compares functions
    /// without being told to: a fragment probe against whole files would ask
    /// "which file resembles this function?", which is a category error dressed
    /// as a number.
    fn open(gpa: std.mem.Allocator, io: std.Io, arg: []const u8, o: *options.Opts) Probe {
        // `path#Lnnn` — a fragment, when the path half really is a file.
        if (std.mem.lastIndexOf(u8, arg, "#L")) |at| {
            const path = arg[0..at];
            const line: ?u32 = std.fmt.parseInt(u32, arg[at + 2 ..], 10) catch null;
            if (line) |number| {
                if (isFile(io, path)) {
                    if (!o.unit_set) o.adopt(.function);
                    return .{ .record = Record.openFragment(gpa, io, path, number) };
                }
            }
        }
        if (isFile(io, arg)) return .{ .record = Record.openFile(gpa, io, arg, o) };

        // Text. Without `--as` the honest reading is "explain this to me" —
        // retrieval, priced in bits — because prose has no code skeleton to
        // compare and a structural score over it is a number about nothing.
        if (!o.channel_set) return .{ .recall = arg };
        return .{ .record = Record.openText(gpa, arg, o) };
    }
};

/// A probe with bytes: its records, plus how to name it in the answer.
const Record = struct {
    label: []const u8,
    /// The file the probe came from, for self-exclusion. Null for text.
    path: ?[]const u8 = null,
    /// The fragment's start line, when the probe was one — a fragment probe must
    /// exclude only ITSELF, not every fragment in its file.
    line: ?u32 = null,
    bytes: Sketch,
    shape: Silhouette,
    owned: ?[]u8 = null,
    built: ?frag.Build = null,
    /// A fragment probe formats its own `path#Lnnn` label and owns those bytes.
    label_owned: bool = false,

    fn deinit(self: *Record, gpa: std.mem.Allocator) void {
        if (self.label_owned) gpa.free(self.label);
        if (self.built) |*b| b.deinit();
        if (self.owned) |b| gpa.free(b);
    }

    fn openFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, o: *const options.Opts) Record {
        const body = read(gpa, io, path);
        var r = fingerprint(gpa, path, body, o);
        r.path = path;
        r.owned = body;
        return r;
    }

    /// The function containing `line`, extracted from that ONE file — never the
    /// whole corpus, and never the fragment index, because the probe may be a
    /// file the index has never seen (a scratch file, a fresh edit).
    fn openFragment(gpa: std.mem.Allocator, io: std.Io, path: []const u8, line: u32) Record {
        const body = read(gpa, io, path);
        var build = frag.Build{ .gpa = gpa };
        build.addFile(path, body) catch oom();
        for (build.spans.items, 0..) |span, i| {
            if (line < span.line_start or line > span.line_end) continue;
            return .{
                .label = std.fmt.allocPrint(gpa, "{s}#L{d}", .{ path, span.line_start }) catch oom(),
                .path = path,
                .line = span.line_start,
                .bytes = sketch_mod.build(gpa, body[span.byte_start..span.byte_end]) catch .empty,
                // The Build owns this silhouette and outlives the record.
                .shape = build.silhouettes.items[i],
                .owned = body,
                .built = build,
                .label_owned = true,
            };
        }
        build.deinit();
        gpa.free(body);
        die("relate similar: no function contains {s}:{d} — pass the file alone to compare whole files\n", .{ path, line });
    }

    fn openText(gpa: std.mem.Allocator, text: []const u8, o: *const options.Opts) Record {
        return fingerprint(gpa, text, text, o);
    }

    /// Build whichever records the channel will read. `copies` never touches the
    /// silhouette, so a byte-only probe pays one pass. A fingerprint failure
    /// degrades to `.empty` — maximally far from real content, so it can hide a
    /// relation but never invent one.
    fn fingerprint(gpa: std.mem.Allocator, label: []const u8, body: []const u8, o: *const options.Opts) Record {
        return .{
            .label = label,
            .bytes = sketch_mod.build(gpa, body) catch .empty,
            .shape = if (o.channel == .copies) .empty else silhouette_mod.build(gpa, body) catch .empty,
        };
    }

    fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) []u8 {
        return Dir.cwd().readFileAlloc(io, path, gpa, .limited(corpus_mod.per_file_cap)) catch |e|
            die("cannot read {s}: {s}\n", .{ path, @errorName(e) });
    }
};

fn isFile(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

// ── kinship ranking (a record probe) ──

/// One scored neighbor.
const Scored = struct {
    score: f64,
    idx: u32,

    /// What the order needs beyond two rows: the tiebreak labels, and which
    /// direction is stronger on this channel.
    const Order = struct { labels: []const []const u8, stronger: bool };

    /// Stronger first, then label — a total order in either polarity.
    fn less(ctx: Order, x: Scored, y: Scored) bool {
        if (x.score != y.score) return if (ctx.stronger) x.score > y.score else x.score < y.score;
        return std.mem.order(u8, ctx.labels[x.idx], ctx.labels[y.idx]) == .lt;
    }
};

fn rankKin(
    gpa: std.mem.Allocator,
    io: std.Io,
    o: *const options.Opts,
    roots: []const []const u8,
    probe: *const Record,
    run: *assay.Run,
) !void {
    // Phase split under the `query` lens — the same prologue/query division
    // `echoes` reports, so the two verbs' costs are comparable line for line.
    var phase = assay.Span.open(io);
    var view = try units.resolve(gpa, io, o.ask(roots));
    defer view.deinit();
    assay.trace(.query, "similar phase: resolve {d:.1} ms\n", .{phase.lap(io).ms()});
    if (o.channel != .shapes) try units.ensureBytes(&view, gpa, participation(o));
    assay.trace(.query, "similar phase: bytes {d:.1} ms\n", .{phase.lap(io).ms()});

    // A probe asks about ONE thing, so generated units stay in the population —
    // "which generated file is closest to this hand-written one" is a real
    // question, and the drift answer is often exactly what the caller wants.
    // The mass floor stays: two units too small to fingerprint land at distance
    // ≈ 0 by arithmetic, and a false `identical` is worse than no row.
    const admissible = try echoes.participation(gpa, view.table(), participation(o));
    defer gpa.free(admissible);

    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (0..view.len()) |i| {
        if (!admissible[i] or isSelf(&view, probe, i)) continue;
        const bytes = if (view.sketches.len > i) sketch_mod.distance(&probe.bytes, &view.sketches[i]) else std.math.nan(f64);
        const structure = if (view.silhouettes.len > i) silhouette_mod.distance(&probe.shape, &view.silhouettes[i]) else std.math.nan(f64);
        const score = o.channel.score(bytes, structure);
        if (std.math.isNan(score)) continue;
        try scored.append(gpa, .{ .score = score, .idx = @intCast(i) });
    }
    std.mem.sort(Scored, scored.items, Scored.Order{
        .labels = view.labels,
        .stronger = o.channel.polarity() == .stronger,
    }, Scored.less);
    assay.trace(.query, "similar phase: score+sort {d:.1} ms\n", .{phase.lap(io).ms()});

    // Ranking admits nothing on a numeric threshold — the caller asked for the
    // nearest, not for everything under a bar — so only `--min-grade` withholds.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sift = grade.Sift.init(o.channel, o.top, o.min_grade, scored.items.len, roots.len > 0);
    sift.verdict.narrowed = view.narrowed();
    for (scored.items) |sc| {
        if (sift.full()) break;
        if (!view.gate(sc.idx)) continue; // deleted since the index anchor
        const g = sift.judge(sc.score) orelse continue;
        emit.emitRow(&buf, gpa, o.json, .{
            .{ "unit", "s", view.labels[sc.idx] },
            .{ o.channel.quantity(), "d:.4", sc.score },
            .{ "grade", "s", g.label() },
            .{ "channel", "s", @tagName(o.channel) },
        }, "{d:.4}  {s}\n", .{ sc.score, emit.anchor(gpa, view.labels[sc.idx]) });
    }
    corpus_mod.emitStdout(buf.items);

    const dur = run.elapsed().ms();
    run.emit("similar: {d} {s}(s) ({s}{d} refreshed) · as {s} · {d} scored · {d:.0} ms\n", .{
        view.len(),          @tagName(view.unit), view.provenance(), view.refreshed,
        @tagName(o.channel), scored.items.len,    dur,
    }, .{
        .{ "verb", "s", "similar" },
        .{ "probe", "s", probe.label },
        .{ "unit", "s", @tagName(view.unit) },
        .{ "units", "d", view.len() },
        .{ "source", "s", view.source.label() },
        .{ "refreshed", "d", view.refreshed },
        .{ "channel", "s", @tagName(o.channel) },
        .{ "metric", "s", o.channel.metric() },
        .{ "scored", "d", scored.items.len },
        .{ "ms", "d:.0", dur },
    });
    sift.settle("relate", probe.label);
}

/// The population floors for a probe query: mass (small-sample protection) and
/// the unit's line floor, with codegen left IN.
fn participation(o: *const options.Opts) echoes.Params {
    var p = o.params();
    p.include_generated = true;
    return p;
}

/// Is unit `i` the probe itself? Compared on canonical paths, because a corpus
/// path under an explicit `.` root arrives `./`-prefixed while the arg may not,
/// and byte equality would leave the probe ranked first at 0.0000. A fragment
/// probe excludes only its own fragment — its siblings in the same file are
/// legitimate answers ("this function is repeated twice in one file").
fn isSelf(view: *const units.View, probe: *const Record, i: usize) bool {
    const path = probe.path orelse return false;
    if (!std.mem.eql(u8, flags.stripDotSlash(view.paths[i]), flags.stripDotSlash(path))) return false;
    const line = probe.line orelse return true;
    return view.lines.len > i and view.spans.len > i and view.spans[i].line_start == line;
}

// ── recall ranking (a text probe) ──

/// Which files explain this text most cheaply. The score is coding GAIN
/// (1 − cost/cold): one means the corpus makes the text nearly free, zero means
/// it costs the literal baseline. Higher is closer — the inverse orientation of
/// a distance, which is why it is a channel of its own with its own bands rather
/// than a number crammed into the `distance` column.
fn rankRecall(
    gpa: std.mem.Allocator,
    io: std.Io,
    o: *const options.Opts,
    roots: []const []const u8,
    text: []const u8,
    run: *assay.Run,
) !void {
    const cold = zipper.coldBits(text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sift = grade.Sift.init(.recall, o.top, o.min_grade, 0, roots.len > 0);

    // Narrowed: price the text against only the files an exact pattern admitted
    // ("among the files that mention X, which explains this best?"). The lexicon
    // is built over that subset, so the fingerprint prices are relative to it.
    if (o.narrow() != null) {
        var view = try units.resolve(gpa, io, o.ask(roots));
        defer view.deinit();
        sift.verdict.narrowed = true;
        sift.verdict.scored = view.len();
        var lex = try lexicon.Lexicon.build(gpa, view.bodies);
        defer lex.deinit();
        const hits = try lex.retrieve(gpa, text, o.top);
        defer gpa.free(hits);
        for (hits) |h| {
            if (sift.full()) break;
            const gain = gainOf(h.cost.bits, cold);
            if (sift.judge(gain) == null) continue;
            emitGain(&buf, gpa, o.json, view.labels[h.doc], gain, h.cost, h.bits_saved);
        }
        corpus_mod.emitStdout(buf.items);
        const dur = run.elapsed().ms();
        run.emit("similar: {d} matching file(s) · {d} hit(s) · recall · {d:.0} ms\n", .{
            view.len(), sift.verdict.shown, dur,
        }, .{
            .{ "verb", "s", "similar" },
            .{ "probe", "s", text },
            .{ "channel", "s", "recall" },
            .{ "matched", "d", view.len() },
            .{ "hits", "d", sift.verdict.shown },
            .{ "ms", "d:.0", dur },
        });
        sift.settle("relate", text);
        return;
    }

    // The warm rung: the persisted codex shelf nominates by corpus-priced
    // evidence, then the suffix-automaton cross-parse decides over bounded
    // query-bearing windows (the ΔAb shape of "Language Trees and Zipping",
    // without rebuilding the corpus per query).
    if (try retrieval.retrieve(gpa, io, text, roots, o.top, .load)) |warm_value| {
        var warm = warm_value;
        defer warm.deinit();
        sift.verdict.scored = warm.candidates;
        for (warm.hits) |h| {
            if (sift.full()) break;
            const gain = gainOf(h.cost.bits, cold);
            if (sift.judge(gain) == null) continue;
            emitGain(&buf, gpa, o.json, h.path, gain, h.cost, h.evidence_bits);
        }
        corpus_mod.emitStdout(buf.items);
        const dur = run.elapsed().ms();
        run.emit("similar: {d} files indexed · {d} candidate(s) · {d} refreshed · {d} hit(s) · recall · {d:.0} ms\n", .{
            warm.indexed_files, warm.candidates, warm.refreshed, sift.verdict.shown, dur,
        }, .{
            .{ "verb", "s", "similar" },
            .{ "probe", "s", text },
            .{ "channel", "s", "recall" },
            .{ "indexed_files", "d", warm.indexed_files },
            .{ "candidates", "d", warm.candidates },
            .{ "refreshed", "d", warm.refreshed },
            .{ "hits", "d", sift.verdict.shown },
            .{ "ms", "d:.0", dur },
        });
        sift.settle("relate", text);
        return;
    }

    // Live: build the fingerprint lexicon for this invocation. Same answers,
    // whole-corpus cost.
    const rr = try flags.rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items, .contiguous);
    defer corpus.deinit();
    var lex = try lexicon.Lexicon.build(gpa, corpus.docs);
    defer lex.deinit();
    const index_dur = run.lap();
    sift.verdict.scored = corpus.docs.len;

    const hits = try lex.retrieve(gpa, text, o.top);
    defer gpa.free(hits);
    for (hits) |h| {
        if (sift.full()) break;
        const gain = gainOf(h.cost.bits, cold);
        if (sift.judge(gain) == null) continue;
        emitGain(&buf, gpa, o.json, corpus.paths[h.doc], gain, h.cost, h.bits_saved);
    }
    corpus_mod.emitStdout(buf.items);
    const query_dur = run.elapsed().ms();
    run.emit("similar: {d} files indexed · {d} hit(s) · recall · index {d:.0} ms · query {d:.0} ms\n", .{
        corpus.docs.len, sift.verdict.shown, index_dur.ms(), query_dur,
    }, .{
        .{ "verb", "s", "similar" },
        .{ "probe", "s", text },
        .{ "channel", "s", "recall" },
        .{ "indexed_files", "d", corpus.docs.len },
        .{ "hits", "d", sift.verdict.shown },
        .{ "index_ms", "d:.0", index_dur.ms() },
        .{ "query_ms", "d:.0", query_dur },
    });
    sift.settle("relate", text);
}

/// 1 − cost/cold, the coding gain. A zero-cold query (empty text) has no
/// baseline to save against, so its gain is zero rather than infinite.
fn gainOf(bits: f64, cold: f64) f64 {
    return if (cold > 0.0) 1.0 - bits / cold else 0.0;
}

fn emitGain(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    json: bool,
    label: []const u8,
    gain: f64,
    cost: zipper.Cost,
    saved: f64,
) void {
    emit.emitRow(buf, gpa, json, .{
        .{ "unit", "s", label },
        .{ "gain", "d:.4", gain },
        .{ "grade", "s", grade.of(.recall, gain).label() },
        .{ "cost_bits", "d:.1", cost.bits },
        .{ "bits_saved", "d:.1", saved },
        .{ "factors", "d", cost.factors },
        .{ "literals", "d", cost.literals },
    }, "{d:.4}  {s}\n", .{ gain, emit.anchor(gpa, label) });
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "Scored.less is a total order in both polarities" {
    const labels = [_][]const u8{ "a", "b" };
    const near = Scored{ .score = 0.10, .idx = 0 };
    const far = Scored{ .score = 0.90, .idx = 1 };
    const by_distance = Scored.Order{ .labels = &labels, .stronger = false };
    const by_gap = Scored.Order{ .labels = &labels, .stronger = true };
    // A distance channel ranks the smaller score first…
    try t.expect(Scored.less(by_distance, near, far));
    try t.expect(!Scored.less(by_distance, far, near));
    // …a gap or a gain ranks the larger one first.
    try t.expect(Scored.less(by_gap, far, near));
    // Ties break on label, and nothing is ever less than itself.
    const tie_a = Scored{ .score = 0.5, .idx = 0 };
    const tie_b = Scored{ .score = 0.5, .idx = 1 };
    try t.expect(Scored.less(by_distance, tie_a, tie_b));
    try t.expect(!Scored.less(by_distance, tie_a, tie_a));
}

test "the probe excludes itself, and a fragment excludes only its own span" {
    const labels = [_][]const u8{ "a.zig#L1", "a.zig#L40", "b.zig#L1" };
    const paths = [_][]const u8{ "a.zig", "a.zig", "b.zig" };
    const lines = [_]u32{ 20, 12, 9 };
    const spans = [_]frag.Span{
        .{ .byte_start = 0, .byte_end = 10, .line_start = 1, .line_end = 20 },
        .{ .byte_start = 10, .byte_end = 20, .line_start = 40, .line_end = 51 },
        .{ .byte_start = 0, .byte_end = 10, .line_start = 1, .line_end = 9 },
    };
    const view = units.View{
        .labels = &labels,
        .paths = &paths,
        .lines = &lines,
        .spans = &spans,
        .unit = .function,
        .source = .index,
        .gpa = t.allocator,
        .io = undefined,
    };

    // A fragment probe: only the identical span is self. The sibling function in
    // the same file is a legitimate answer — that IS the finding when a helper
    // was pasted twice into one file.
    const fragment = Record{ .label = "a.zig#L1", .path = "a.zig", .line = 1, .bytes = .empty, .shape = .empty };
    try t.expect(isSelf(&view, &fragment, 0));
    try t.expect(!isSelf(&view, &fragment, 1));
    try t.expect(!isSelf(&view, &fragment, 2));

    // A file probe excludes every unit of that file, `./` prefix or not.
    const whole = Record{ .label = "./a.zig", .path = "./a.zig", .bytes = .empty, .shape = .empty };
    try t.expect(isSelf(&view, &whole, 0));
    try t.expect(isSelf(&view, &whole, 1));
    try t.expect(!isSelf(&view, &whole, 2));

    // Text has no path, so nothing is ever excluded as "itself".
    const text = Record{ .label = "some words", .bytes = .empty, .shape = .empty };
    try t.expect(!isSelf(&view, &text, 0));
}

test "coding gain is relative to the cold baseline, and safe at zero" {
    // The corpus quoting the probe back nearly verbatim: cost ≪ cold.
    try t.expectApproxEqAbs(@as(f64, 0.95), gainOf(5.0, 100.0), 1e-9);
    // Costing exactly the literal baseline is zero gain, not a relation.
    try t.expectEqual(@as(f64, 0.0), gainOf(100.0, 100.0));
    // A reference that makes the text MORE expensive scores negative — real,
    // and reported rather than clamped.
    try t.expect(gainOf(120.0, 100.0) < 0.0);
    // No baseline, no claim.
    try t.expectEqual(@as(f64, 0.0), gainOf(50.0, 0.0));
}

test "a probe's population keeps codegen but never sub-mass units" {
    // A probe asks about one thing: its generated twin is a legitimate answer.
    // Sub-mass units are not — they land at ≈ 0 by arithmetic, and a false
    // `identical` is worse than no row. The mass floor itself is the channel's,
    // resolved where it is measured, so what a probe overrides is only codegen.
    var o = options.Opts{ .top = 20, .unit = .file };
    const p = participation(&o);
    try t.expect(p.include_generated);
    try t.expectEqual(@as(?usize, null), p.min_mass);
    try t.expectEqual(echoes.sketch_mass, echoes.massFloor(.copies));
    try t.expectEqual(echoes.silhouette_mass, echoes.massFloor(.shapes));
    o.unit = .function;
    try t.expectEqual(@as(usize, 5), participation(&o).min_lines);
}
