//! relate — the `concepts` verb: function-level concept discovery.
//!
//!   relate concepts [TEXT] [--lens structure|bytes|echo] [--max-distance T]
//!                   [--min-lines N] [--min-size N] [--top N] [--brief]
//!                   [--json] [--no-index] [ROOT...]
//!
//! The finer sibling of `clusters`/`echoes`: those answer "which FILES are
//! forks?"; this answers "which FUNCTIONS across the tree are the same idea?" —
//! the repeated engine, the duplicated JSON dump, the copy-pasted validator,
//! regardless of name or file. The comparison unit is the function fragment
//! (regions.extractAll over authored Zig/C-family + Python), so a 12-line helper
//! cloned into six files surfaces as one six-member family, not six files each
//! hiding it.
//!
//!   • no TEXT → package-wide FAMILIES of theoretically-similar functions,
//!     ranked by consolidation opportunity (conservative repeated lines, then
//!     channel confidence — never a fused score).
//!   • TEXT → the nearest function fragments to that text ("is this concept
//!     already implemented somewhere?").
//!
//! Lenses stay separate: STRUCTURE (silhouette, default, warm-only) nominates
//! and groups; BYTES (LZJD) and ECHO (byte−structure gap, the renamed-twin
//! signal) are opt-in, and their sketches are computed only for the fragments
//! this query nominates — never a repo-wide byte pass.
//!
//! Warm tier: the `concepts.frag` artifact (silhouette per fragment) folded for
//! freshness like the atlas; `--no-index` (or a missing/corrupt artifact) is the
//! live oracle — a full extract + build with byte-identical answers.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");
const cli_args = @import("../../runtime/cold/argv/args.zig");
const sketch = @import("../../search/similarity/sketch.zig");
const silhouette_mod = @import("../../search/similarity/silhouette.zig");
const concepts = @import("../../search/similarity/concepts.zig");
const frag = @import("../../index/frag/frag.zig");
const kinship = @import("kinship.zig");
const glob = @import("../../corpus/scope/glob.zig");

const Sketch = sketch.Sketch;
const Silhouette = silhouette_mod.Silhouette;
const Dir = std.Io.Dir;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;
const die = cli_args.die;
const oom = cli_args.oom;

const Args = struct {
    text: ?[]const u8 = null,
    params: concepts.Params = .{},
    top: usize = 20,
    brief: bool = false,
    json: bool = false,
    no_index: bool = false,
};

fn parse(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, roots: *std.ArrayList([]const u8)) Args {
    var a = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--lens")) {
            a.params.lens = std.meta.stringToEnum(concepts.Lens, kinship.need(argv, &i, "--lens needs structure|bytes|echo\n")) orelse
                die("--lens: structure, bytes, or echo, not {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--max-distance")) {
            a.params.max_dist = kinship.unitFloat(kinship.need(argv, &i, "--max-distance needs a number in [0,1]\n"), "--max-distance");
        } else if (std.mem.eql(u8, arg, "--min-echo")) {
            a.params.min_echo = kinship.unitFloat(kinship.need(argv, &i, "--min-echo needs a number in [0,1]\n"), "--min-echo");
        } else if (std.mem.eql(u8, arg, "--min-lines")) {
            a.params.min_lines = kinship.count(argv, &i, "--min-lines");
        } else if (std.mem.eql(u8, arg, "--min-size")) {
            a.params.min_size = kinship.minSize(argv, &i);
        } else if (std.mem.eql(u8, arg, "--top")) {
            a.top = kinship.count(argv, &i, "--top");
        } else if (std.mem.eql(u8, arg, "--brief")) {
            a.brief = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            a.json = true;
        } else if (std.mem.eql(u8, arg, "--no-index")) {
            a.no_index = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            die("relate concepts: unknown flag {s}\n", .{arg});
        } else if (a.text == null and !looksLikeRoot(io, arg)) {
            a.text = arg;
        } else {
            roots.append(gpa, glob.normalizeRoot(arg)) catch oom();
        }
    }
    return a;
}

/// The first bare arg is the query TEXT unless it names an existing path — then
/// it is a ROOT. A discovery sweep (no text) over `services/backend` must not be
/// misread as a text query for the literal string "services/backend"; quote a
/// text query that collides with a path.
fn looksLikeRoot(io: std.Io, arg: []const u8) bool {
    _ = Dir.cwd().statFile(io, arg, .{}) catch return false;
    return true;
}

pub fn runConcepts(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    const a = parse(gpa, io, argv, &roots);

    const t0 = nowNs(io);
    var view = try resolveFragments(gpa, io, roots.items, a.no_index);
    defer view.deinit();

    // Labels are `path#Lstart` — unique (two functions can't start on one line),
    // so they give discover/retrieve their deterministic total order.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const labels = try makeLabels(arena.allocator(), view.paths, view.spans);
    const lines = try lineCounts(gpa, view.spans);
    defer gpa.free(lines);

    const part = try concepts.participation(gpa, labels, lines, view.sils, a.params);
    defer gpa.free(part);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    if (a.text) |text| {
        const query = silhouette_mod.build(gpa, text) catch Silhouette.empty;
        var ranked = try concepts.retrieve(gpa, labels, view.sils, part, &query, a.top);
        defer ranked.deinit();
        for (ranked.hits) |h| {
            if (!view.gate(h.frag)) continue;
            emitHit(&buf, gpa, a.json, view.paths[h.frag], view.spans[h.frag], h.distance);
        }
        corpus_mod.emitStdout(buf.items);
        std.debug.print("concepts: {d} fragment(s) ({s}{d} refreshed) · {d} match(es) · {d:.0} ms\n", .{
            view.sils.len, view.provenance(), view.refreshed, ranked.hits.len, ms(nowNs(io) - t0),
        });
        return;
    }

    // Discovery. A byte/echo lens sketches only the nominated fragments' live
    // bytes (never the whole tree); structure needs no byte pass.
    var sketches: []Sketch = &.{};
    defer if (sketches.len > 0) gpa.free(sketches);
    if (a.params.lens != .structure) {
        const involved = try concepts.byteTargets(gpa, view.sils, part);
        defer gpa.free(involved);
        sketches = try fillByteSketches(gpa, io, view.paths, view.spans, involved);
    }

    var found = try concepts.discover(gpa, labels, lines, view.sils, sketches, part, a.params);
    defer found.deinit();
    concepts.rank(found.list, labels);

    var shown: usize = 0;
    for (found.list) |*f| {
        if (shown >= a.top) break;
        if (!familyLive(&view, f.members)) continue; // a member deleted since the anchor
        shown += 1;
        emitFamily(&buf, gpa, a, view.paths, view.spans, f);
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("concepts: {d} fragment(s) ({s}{d} refreshed) · {d} candidate(s) · {d} edge(s) · {d} famil{s} · {d:.0} ms\n", .{
        view.sils.len, view.provenance(), view.refreshed,                          found.candidates,
        found.edges,   found.list.len,    if (found.list.len == 1) "y" else "ies", ms(nowNs(io) - t0),
    });
}

// ── output ──

fn emitHit(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, json: bool, path: []const u8, span: frag.Span, dist: f64) void {
    kinship.emitRow(buf, gpa, json, .{
        .{ "path", "s", path },
        .{ "line_start", "d", span.line_start },
        .{ "line_end", "d", span.line_end },
        .{ "distance", "d:.4", dist },
    }, "{d:.4}  {s}#L{d}-{d}\n", .{ dist, path, span.line_start, span.line_end });
}

fn emitFamily(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, a: Args, paths: []const []const u8, spans: []const frag.Span, f: *const concepts.Family) void {
    if (a.json) {
        buf.print(gpa, "{{\"members\":[", .{}) catch oom();
        for (f.members, 0..) |m, k| {
            if (k != 0) buf.append(gpa, ',') catch oom();
            buf.appendSlice(gpa, "{\"path\":") catch oom();
            kinship.jsonStr(buf, gpa, paths[m]);
            buf.print(gpa, ",\"line_start\":{d},\"line_end\":{d}}}", .{ spans[m].line_start, spans[m].line_end }) catch oom();
        }
        buf.print(gpa, "],\"count\":{d},\"repeated_lines\":{d},\"confidence\":{d:.4},\"structure\":{d:.4}", .{
            f.members.len, f.repeated_lines, f.confidence, f.structure,
        }) catch oom();
        if (!std.math.isNan(f.bytes)) buf.print(gpa, ",\"bytes\":{d:.4}", .{f.bytes}) catch oom();
        if (!std.math.isNan(f.echo)) buf.print(gpa, ",\"echo\":{d:.4}", .{f.echo}) catch oom();
        buf.appendSlice(gpa, "}\n") catch oom();
        return;
    }
    // Compact: the family's shape + opportunity, then its member locations.
    // --brief drops the location list to just the exemplar + a "+k more" tail.
    buf.print(gpa, "{d}x  ~{d}L  conf={d:.2}", .{ f.members.len, f.repeated_lines, f.confidence }) catch oom();
    if (!std.math.isNan(f.echo))
        buf.print(gpa, "  echo={d:.2}", .{f.echo}) catch oom()
    else if (!std.math.isNan(f.bytes))
        buf.print(gpa, "  bytes={d:.2}", .{f.bytes}) catch oom()
    else
        buf.print(gpa, "  structure={d:.2}", .{f.structure}) catch oom();
    if (a.brief) {
        const ex = f.members[0];
        buf.print(gpa, "  ·  {s}#L{d}", .{ paths[ex], spans[ex].line_start }) catch oom();
        if (f.members.len > 1) buf.print(gpa, "  (+{d} more)", .{f.members.len - 1}) catch oom();
    } else {
        buf.appendSlice(gpa, "  ·") catch oom();
        for (f.members) |m| buf.print(gpa, "  {s}#L{d}-{d}", .{ paths[m], spans[m].line_start, spans[m].line_end }) catch oom();
    }
    buf.append(gpa, '\n') catch oom();
}

// ── the fragment view (warm frag fold ∪ live build) ──

const FragView = struct {
    paths: []const []const u8,
    spans: []const frag.Span,
    sils: []const Silhouette,
    from_index: bool,
    refreshed: usize,
    io: std.Io,
    gpa: std.mem.Allocator,

    // keepalive (whichever rung answered)
    frag_idx: ?frag.Frag = null,
    folded: ?frag.Folded = null,
    corpus: ?corpus_mod.Corpus = null,
    build: ?frag.Build = null,
    scoped_paths: ?[][]const u8 = null,
    scoped_spans: ?[]frag.Span = null,
    scoped_sils: ?[]Silhouette = null,

    fn gate(self: *const FragView, i: u32) bool {
        if (!self.from_index) return true;
        return frag.onDisk(self.io, self.paths[i]);
    }

    fn provenance(self: *const FragView) []const u8 {
        return if (self.from_index) "index, " else "live, ";
    }

    fn deinit(self: *FragView) void {
        if (self.scoped_paths) |p| self.gpa.free(p);
        if (self.scoped_spans) |s| self.gpa.free(s);
        if (self.scoped_sils) |s| self.gpa.free(s);
        if (self.build) |*b| b.deinit();
        if (self.corpus) |*c| c.deinit();
        if (self.folded) |*f| f.deinit();
        if (self.frag_idx) |*f| f.deinit(self.gpa);
    }
};

/// The cheapest sound fragment view for `roots`: the warm `concepts.frag` fold
/// when every root sits inside the indexed corpus, else a live extract + build.
fn resolveFragments(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, no_index: bool) !FragView {
    index: {
        if (no_index) break :index;
        var f = frag.loadQuiet(gpa, io) orelse break :index;
        for (roots) |r| if (!kinship.underAnyRoot(r, f.roots)) {
            f.deinit(gpa);
            break :index;
        };
        errdefer f.deinit(gpa);
        var folded = frag.fold(gpa, io, &f, if (roots.len > 0) roots else f.roots) catch {
            f.deinit(gpa);
            break :index;
        };
        errdefer folded.deinit();

        var v = FragView{
            .paths = folded.paths.items,
            .spans = folded.spans.items,
            .sils = folded.silhouettes.items,
            .from_index = true,
            .refreshed = folded.refreshed,
            .io = io,
            .gpa = gpa,
        };
        if (roots.len > 0) try scopeView(&v, gpa, &folded, roots);
        v.frag_idx = f;
        v.folded = folded;
        return v;
    }

    const rr = try kinship.rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items);
    errdefer corpus.deinit();
    var build = try frag.buildAll(gpa, &corpus);
    errdefer build.deinit();
    const n = build.count();
    const paths = try gpa.alloc([]const u8, n);
    errdefer gpa.free(paths);
    for (0..n) |i| paths[i] = build.pathOf(i);
    return .{
        .paths = paths,
        .spans = build.spans.items,
        .sils = build.silhouettes.items,
        .from_index = false,
        .refreshed = 0,
        .io = io,
        .gpa = gpa,
        .corpus = corpus,
        .build = build,
        .scoped_paths = paths,
    };
}

/// Scope a folded fragment table to the queried roots (id-parallel copy) — the
/// same shape `kinship.resolve` uses so a one-package query never pays whole-tree
/// coworker churn beyond the fold.
fn scopeView(v: *FragView, gpa: std.mem.Allocator, folded: *const frag.Folded, roots: []const []const u8) !void {
    var n: usize = 0;
    for (folded.paths.items) |p| n += @intFromBool(kinship.underAnyRoot(p, roots));
    const sp = try gpa.alloc([]const u8, n);
    errdefer gpa.free(sp);
    const ss = try gpa.alloc(frag.Span, n);
    errdefer gpa.free(ss);
    const sl = try gpa.alloc(Silhouette, n);
    errdefer gpa.free(sl);
    var w: usize = 0;
    for (folded.paths.items, folded.spans.items, folded.silhouettes.items) |p, span, sil| {
        if (!kinship.underAnyRoot(p, roots)) continue;
        sp[w] = p;
        ss[w] = span;
        sl[w] = sil;
        w += 1;
    }
    v.scoped_paths = sp;
    v.scoped_spans = ss;
    v.scoped_sils = sl;
    v.paths = sp;
    v.spans = ss;
    v.sils = sl;
}

// ── helpers ──

fn makeLabels(a: std.mem.Allocator, paths: []const []const u8, spans: []const frag.Span) ![]const []const u8 {
    const labels = try a.alloc([]const u8, paths.len);
    for (paths, spans, labels) |p, span, *l| l.* = try std.fmt.allocPrint(a, "{s}#L{d}", .{ p, span.line_start });
    return labels;
}

fn lineCounts(gpa: std.mem.Allocator, spans: []const frag.Span) ![]u32 {
    const out = try gpa.alloc(u32, spans.len);
    for (spans, out) |span, *n| n.* = @intCast(span.lines());
    return out;
}

/// Byte sketches for exactly the `involved` fragments — read each file once
/// (cached) and sketch its fragment span. Others stay `.empty` (never compared,
/// they were not nominated). The only byte pass a `concepts` query makes.
fn fillByteSketches(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8, spans: []const frag.Span, involved: []const bool) ![]Sketch {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var cache: std.StringHashMapUnmanaged([]const u8) = .empty;

    const out = try gpa.alloc(Sketch, paths.len);
    errdefer gpa.free(out);
    for (out) |*s| s.* = Sketch.empty;
    for (involved, 0..) |inv, i| {
        if (!inv) continue;
        const gop = try cache.getOrPut(a, paths[i]);
        if (!gop.found_existing)
            gop.value_ptr.* = Dir.cwd().readFileAlloc(io, paths[i], a, .limited(corpus_mod.per_file_cap)) catch "";
        const body = gop.value_ptr.*;
        const sp = spans[i];
        if (body.len != 0 and sp.byte_end <= body.len and sp.byte_start <= sp.byte_end)
            out[i] = sketch.build(gpa, body[sp.byte_start..sp.byte_end]) catch Sketch.empty;
    }
    return out;
}

/// True when every family member still exists (the emit-time deletion gate for
/// an index-backed answer; live views are trivially current).
fn familyLive(view: *const FragView, members: []const u32) bool {
    if (!view.from_index) return true;
    for (members) |m| if (!view.gate(m)) return false;
    return true;
}
