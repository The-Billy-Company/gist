//! relate — the `echoes` verb: what repeats in this corpus?
//!
//!   relate echoes [--unit file|function|match] [--as copies|twins|shapes|any]
//!                 [--shape pairs|families|distinct] [--max-distance T]
//!                 [--min-echo E] [--min-size N] [--min-lines N] [--min-mass N]
//!                 [--include-generated] [--matching PAT]... [--min-grade G]
//!                 [--top N] [--brief] [--json] [--no-index] [ROOT...]
//!
//! One question, asked along three axes. Repetition is not four verbs; it is a
//! unit, a channel, and a shape, and the four verbs this replaced were four
//! points in that space that each grew their own flags, their own noise floors,
//! and their own idea of what a grade meant:
//!
//!   | retired verb | the query it was |
//!   |---|---|
//!   | `dups`     | `--as copies` |
//!   | `clusters` | `--as copies --shape families` |
//!   | `concepts` | `--as shapes --shape families --unit function` |
//!   | `echoes`   | (the default) `--as twins` |
//!
//! **Unit** — what a row IS. A file, a function fragment, or a window around an
//! exact hit. The unit matters more than it sounds: a 12-line helper cloned into
//! six unrelated files is invisible at file granularity (the files share 3% of
//! their bytes) and obvious at function granularity.
//!
//! **Channel** — which repetition. `copies` is copy-paste and its drift;
//! `shapes` is a shared skeleton whether or not the vocabulary matches; `twins`
//! is the DIFFERENCE (bytes − structure), which is the one signal no other tool
//! reports: two modules repeating a shape under different identifiers (Type-2
//! clones, Roy–Cordy taxonomy). Byte distance calls that pair unrelated, and
//! structure distance alone has no clean absolute threshold — measured on the
//! graduation eval, family-max and cross-min overlap at every winnow setting.
//! The gap self-calibrates per pair, and hit P@10 = 100% against an 11.9% base
//! rate on the Python family corpus.
//!
//! **Shape** — what an answer is FOR. `pairs` to inspect two things; `families`
//! to act (the transitive closure, so a caller never re-runs union-find over a
//! pair list — every consumer did, in Python); `distinct` for the complement,
//! which turns "which of these 14 implementations is genuinely unique?" into a
//! measurement with a receipt (each unit's nearest miss, priced) instead of an
//! absence.
//!
//! Two noise classes are withheld from the population uniformly, because the
//! measured answers without them were unusable: **codegen** (twin templates are
//! the densest structural clones there are — identical shape, renamed symbols —
//! but the fix lives in the template, so a generated pair is never a refactor
//! candidate; `--include-generated` turns the sweep into a drift audit) and
//! **sub-mass units** (an 86-member family of one-line `__init__.py` re-exports
//! at distance 0.0000 is arithmetic, not a finding).
//!
//! `--matching PAT` runs the exact engine first and asks the repetition question
//! only inside what matched — ADR-367's composition as a modifier. The exact and
//! statistical scores stay in separate columns; they are never fused.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const assay = @import("../../../assay/assay.zig");
const echoes = @import("../../../kernel/kinship/cluster/echoes.zig");
const emit = @import("../../cli/emit.zig");
const grade = @import("../../cli/grade.zig");
const options = @import("options.zig");
const units = @import("units.zig");

const oom = @import("../../cli/outcome.zig").oom;

pub fn runEchoes(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: options.Opts = .{ .top = 50, .channel = .twins };
    defer o.deinit(gpa);
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try options.parse(gpa, argv, &o, &roots, .{
        .max_dist = true,
        .min_echo = true,
        .min_size = true,
        .min_lines = true,
        .min_mass = true,
        .include_generated = true,
        .no_index = true,
        .channel = true,
        .unit = true,
        .shape = true,
        .min_grade = true,
        .brief = true,
        .matching = true,
        .strict = "echoes",
    });

    const run = assay.Run.open(gpa, io, o.json);
    // Phase split under the `query` lens. `echoes` is the package's most
    // expensive verb, and its cost divides cleanly into a corpus-shaped prologue
    // (resolve + ensureBytes — the same for every query over one tree) and the
    // query-shaped survey. Knowing which half dominates is what decides whether
    // holding the view resident can pay, so the split is measurable rather than
    // inferred from a total.
    var phase = assay.Span.open(io);
    var view = try units.resolve(gpa, io, o.ask(roots.items));
    defer view.deinit();
    assay.trace(.query, "echoes phase: resolve {d:.1} ms\n", .{phase.lap(io).ms()});

    // A byte-reading channel over fragments has to go back to the source: the
    // fragment index persists structure only.
    if (o.channel != .shapes) try units.ensureBytes(&view, gpa, o.params());
    assay.trace(.query, "echoes phase: bytes {d:.1} ms\n", .{phase.lap(io).ms()});

    var found = try echoes.survey(gpa, view.table(), o.params());
    defer found.deinit();
    // The survey's own cost is driven by the two populations it derives, not by
    // the corpus size the prologue saw: pair admission is quadratic in the
    // candidates that passed participation, and the shape step is linear in the
    // edges admitted. Reporting both beside the duration is what makes a slow
    // survey diagnosable from one trace line — a large candidate set and a large
    // edge set are different problems with different fixes (`--min-mass` /
    // `--min-lines` narrows the former, `--max-distance` the latter).
    assay.trace(.query, "echoes phase: survey {d:.1} ms · {d} candidates · {d} edges\n", .{
        phase.lap(io).ms(), found.candidates, found.edges,
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sift = grade.Sift.init(o.channel, o.top, o.min_grade, found.candidates, roots.items.len > 0);
    sift.verdict.narrowed = view.narrowed();
    // The complement finds the opposite of kin, and an empty complement is the
    // strong answer there ("everything here has a relative"), so it says so.
    if (found.shape == .distinct) sift.verdict.noun = "distinct units";
    switch (found.shape) {
        .pairs => emitPairs(&buf, gpa, &sift, &view, &o, found.pairs),
        .families => emitFamilies(&buf, gpa, &sift, &view, &o, found.families),
        .distinct => emitDistinct(&buf, gpa, &sift, &view, &o, found.distinct),
    }
    corpus_mod.emitStdout(buf.items);

    const dur = run.elapsed().ms();
    run.emit("echoes: {d} {s}(s) ({s}{d} refreshed) · {d} candidate(s) · {d} edge(s) · {d} {s} · {d:.0} ms\n", .{
        view.len(),  @tagName(view.unit), view.provenance(),     view.refreshed, found.candidates,
        found.edges, found.rows(),        @tagName(found.shape), dur,
    }, .{
        .{ "verb", "s", "echoes" },
        .{ "unit", "s", @tagName(view.unit) },
        .{ "units", "d", view.len() },
        .{ "source", "s", view.source.label() },
        .{ "refreshed", "d", view.refreshed },
        .{ "channel", "s", @tagName(o.channel) },
        .{ "shape", "s", @tagName(found.shape) },
        .{ "candidates", "d", found.candidates },
        .{ "edges", "d", found.edges },
        .{ "rows", "d", found.rows() },
        .{ "floor", "d:.2", o.floor() },
        .{ "ms", "d:.0", dur },
    });
    sift.settle("relate", subject(&view));
}

/// What the verdict is about: the scope the caller named, or the corpus.
fn subject(view: *const units.View) []const u8 {
    return if (view.narrowed()) "the matching units" else "this corpus";
}

// ── the three shapes ──

fn emitPairs(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    sift: *grade.Sift,
    view: *const units.View,
    o: *const options.Opts,
    rows: []const echoes.Pair,
) void {
    for (rows) |p| {
        if (sift.full()) break;
        if (!view.gate(p.i) or !view.gate(p.j)) continue; // deleted since the anchor
        const g = sift.judge(p.score) orelse continue;
        emit.emitRow(buf, gpa, o.json, .{
            .{ "a", "s", view.labels[p.i] },
            .{ "b", "s", view.labels[p.j] },
            .{ o.channel.quantity(), "d:.4", p.score },
            .{ "bytes", "d:.4", p.bytes },
            .{ "structure", "d:.4", p.structure },
            .{ "grade", "s", g.label() },
        }, "{d:.4}  (bytes {d:.4} · structure {d:.4})  {s}  {s}\n", .{
            p.score, p.bytes, p.structure, emit.anchor(gpa, view.labels[p.i]), emit.anchor(gpa, view.labels[p.j]),
        });
    }
}

fn emitFamilies(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    sift: *grade.Sift,
    view: *const units.View,
    o: *const options.Opts,
    rows: []const echoes.Family,
) void {
    for (rows) |f| {
        if (sift.full()) break;
        if (!view.groupLive(f.members)) continue; // a member deleted since the anchor
        // Families rank by consolidation opportunity, not by score, so the
        // strongest family can land anywhere in the list.
        const g = sift.judgeUnordered(f.edge) orelse continue;
        if (o.json) {
            emit.jsonFields(buf, gpa, .{
                .{ "size", "d", f.members.len },
                .{ "repeated_lines", "d", f.repeated_lines },
                .{ o.channel.quantity(), "d:.4", f.edge },
                .{ "bytes", "d:.4", f.bytes },
                .{ "structure", "d:.4", f.structure },
                .{ "grade", "s", g.label() },
            });
            buf.appendSlice(gpa, ",\"members\":[") catch oom();
            for (f.members, 0..) |m, k| {
                if (k != 0) buf.append(gpa, ',') catch oom();
                emit.jsonStr(buf, gpa, view.labels[m]);
            }
            buf.appendSlice(gpa, "]}\n") catch oom();
            continue;
        }
        buf.print(gpa, "{d}x", .{f.members.len}) catch oom();
        if (f.repeated_lines > 0) buf.print(gpa, "  ~{d}L", .{f.repeated_lines}) catch oom();
        buf.print(gpa, "  {s}={d:.4}  [{s}]", .{ o.channel.quantity(), f.edge, g.label() }) catch oom();
        if (o.brief) {
            buf.print(gpa, "  ·  {s}", .{emit.anchor(gpa, view.labels[f.members[0]])}) catch oom();
            if (f.members.len > 1) buf.print(gpa, "  (+{d} more)", .{f.members.len - 1}) catch oom();
            buf.append(gpa, '\n') catch oom();
        } else {
            buf.append(gpa, '\n') catch oom();
            for (f.members) |m| buf.print(gpa, "  {s}\n", .{emit.anchor(gpa, view.labels[m])}) catch oom();
        }
    }
}

/// The complement. `distinct` inverts the question, so it inverts the verdict
/// too: a strong nearest-miss score means the unit is NOT distinct, and there is
/// nothing to withhold — every row is a genuine answer. Grading it on the
/// kinship bands would tell the caller their result was "weak" precisely when it
/// was strongest, so the rows carry the miss and the verdict counts them.
fn emitDistinct(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    sift: *grade.Sift,
    view: *const units.View,
    o: *const options.Opts,
    rows: []const echoes.Lonely,
) void {
    for (rows) |d| {
        if (sift.full()) break;
        if (!view.gate(d.unit)) continue;
        sift.count();
        const nearest = if (d.nearest) |n| view.labels[n] else "—";
        // The em dash stands for "no nearest unit at all" — a placeholder, not
        // a path, so it is the one label on this row with nothing to open.
        const goto = if (d.nearest == null) nearest else emit.anchor(gpa, nearest);
        emit.emitRow(buf, gpa, o.json, .{
            .{ "unit", "s", view.labels[d.unit] },
            .{ "nearest", "s", nearest },
            .{ "bytes", "d:.4", d.bytes },
            .{ "structure", "d:.4", d.structure },
        }, "{s}\n  nearest miss  (bytes {d:.4} · structure {d:.4})  {s}\n", .{
            emit.anchor(gpa, view.labels[d.unit]), d.bytes, d.structure, goto,
        });
    }
}
