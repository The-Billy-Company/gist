//! relate — the unit view: what a row of the comparison table IS.
//!
//! Every kinship question needs the same thing before it can answer: a table of
//! comparable units, each with a label, a line count, and whichever fingerprint
//! records the channel will score. What differs is only what a unit is, and
//! which population is admitted:
//!
//!   • **file** — the whole file. Answers from the persisted kinship atlas plus
//!     a freshness fold; live when the atlas is missing, `--no-index` was
//!     passed, or a root sits outside the indexed corpus.
//!   • **function** — one function fragment, so a 12-line helper cloned into six
//!     files surfaces as one six-member family instead of hiding inside six
//!     unrelated files. Answers from the persisted fragment index, or live.
//!   • **match** — a bounded window around each exact hit. Only meaningful with
//!     `--matching`, since without a pattern there is no hit to window.
//!
//! And orthogonally: `--matching` runs the exact engine FIRST and keeps only the
//! units it selects (ADR-367's composition, as a modifier rather than a second
//! face). Exact narrowing always reads live bytes — you cannot match a pattern
//! against a fingerprint — so it trades the warm tier for a scoped population.
//! That is the right trade: a pattern usually narrows 20k files to dozens.
//!
//! Four rungs, one type. The verbs above never learn which one answered beyond
//! `source()`, and the deletion gate is uniform: a fingerprint from a persisted
//! artifact may not surface a file that has since been deleted.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const frag = @import("../../../corpus/index/frag/frag.zig");
const candidates = @import("../../../kernel/compose/candidates.zig");
const regions = @import("../../../kernel/compose/regions.zig");
const patterns_mod = @import("../../../kernel/slate/patterns.zig");
const echoes = @import("../../../kernel/kinship/cluster/echoes.zig");
const sketch_mod = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const fingerprint = @import("../../../kernel/kinship/metric/fingerprint.zig");
const fault = @import("../../../fault.zig");
const flags = @import("../../cli/flags.zig");
const kinship = @import("kinship.zig");

const Sketch = sketch_mod.Sketch;
const Silhouette = silhouette_mod.Silhouette;
const die = @import("../../cli/outcome.zig").die;
const oom = @import("../../cli/outcome.zig").oom;

/// What one row of the comparison table is.
pub const Unit = enum {
    file,
    function,
    /// A bounded window around an exact hit — `--matching` only.
    match,

    pub fn parse(s: []const u8) ?Unit {
        return std.meta.stringToEnum(Unit, s);
    }

    /// The default shortest unit that can anchor a relation. Files carry no line
    /// count in the atlas, so the mass floor is all they have; a fragment
    /// shorter than five lines is a getter, not a consolidation target.
    pub fn lineFloor(self: Unit) usize {
        return switch (self) {
            .file => 0,
            .function, .match => 5,
        };
    }
};

/// An exact filter to apply before any kinship is scored.
pub const Narrow = struct {
    patterns: []const []const u8,
    match: candidates.Match = .any,
    fixed: bool = false,
    ignore_case: bool = false,
    /// Lines of context each side of a hit, for `unit == .match`.
    context: usize = 3,
};

/// What the caller needs resolved.
pub const Ask = struct {
    unit: Unit = .file,
    /// `bytes` = LZJD sketches only; `structure` = silhouettes too. The warm
    /// artifacts persist both, so this only spares a live rung one pass.
    wants: kinship.Wants = .structure,
    roots: []const []const u8 = &.{},
    narrow: ?Narrow = null,
    no_index: bool = false,
};

/// Which rung answered — a fact about the run, printed on stderr.
pub const Source = enum {
    /// The persisted kinship atlas + freshness fold (file unit).
    atlas,
    /// The persisted fragment index + freshness fold (function unit).
    index,
    /// A full read + fingerprint pass over the scoped corpus.
    live,
    /// A full read, narrowed by the exact engine before fingerprinting.
    matched,

    pub fn label(self: Source) []const u8 {
        return @tagName(self);
    }
};

/// The comparison table plus the state that owns it.
///
/// `labels` are `path` for files and `path#Lstart` for fragments — unique either
/// way (two functions cannot start on one line), which is what makes every
/// answer's tie-break order total. `bodies` is non-empty only when a rung read
/// the corpus, so a renderer that wants a headline must degrade gracefully.
pub const View = struct {
    labels: []const []const u8,
    /// The file each unit lives in — `labels` minus any `#L` anchor.
    paths: []const []const u8,
    lines: []const u32 = &.{},
    spans: []const frag.Span = &.{},
    bodies: []const []const u8 = &.{},
    sketches: []const Sketch = &.{},
    silhouettes: []const Silhouette = &.{},
    /// Per-unit bitset of the `--matching` patterns that admitted its file
    /// (empty when no exact filter ran).
    masks: []const u64 = &.{},

    unit: Unit,
    source: Source,
    refreshed: usize = 0,
    /// Units the exact filter examined before narrowing — the population an
    /// unnarrowed run would have scored.
    examined: usize = 0,

    gpa: std.mem.Allocator,
    io: std.Io,
    arena: ?std.heap.ArenaAllocator = null,
    file_view: ?kinship.View = null,
    frag_view: ?FragView = null,
    exact: ?Narrowed = null,
    owned_sketches: ?[]Sketch = null,
    owned_silhouettes: ?[]Silhouette = null,

    pub fn len(self: *const View) usize {
        return self.labels.len;
    }

    /// Did an exact filter narrow this population?
    pub fn narrowed(self: *const View) bool {
        return self.source == .matched;
    }

    /// The kernel's comparison table — the one conversion between "how the view
    /// was resolved" and "what the repetition kernel scores".
    pub fn table(self: *const View) echoes.Table {
        return .{
            .labels = self.labels,
            .lines = self.lines,
            .sketches = self.sketches,
            .silhouettes = self.silhouettes,
        };
    }

    /// Emit-time deletion gate: may `labels[i]` be surfaced? Live rungs are
    /// trivially current; an artifact-backed row proves its file still exists,
    /// so a deleted file's fingerprint can never answer. O(rows), not O(corpus).
    pub fn gate(self: *const View, i: usize) bool {
        return switch (self.source) {
            .live, .matched => true,
            .atlas, .index => frag.onDisk(self.io, self.paths[i]),
        };
    }

    /// Every member of a group still on disk (the gate, for a family row).
    pub fn groupLive(self: *const View, members: []const u32) bool {
        for (members) |m| if (!self.gate(m)) return false;
        return true;
    }

    /// The unit's live bytes, when the rung that answered read them.
    pub fn body(self: *const View, i: usize) ?[]const u8 {
        return if (self.bodies.len > i) self.bodies[i] else null;
    }

    /// Fill the byte channel for the units `wanted`, reading each file once.
    ///
    /// The fragment index persists silhouettes only — structure is what makes a
    /// warm function answer possible at all — so a byte-reading channel over the
    /// function unit has to go back to the source. It goes back for the
    /// PARTICIPANTS only: a `--unit function --as twins` query over the tree
    /// touches the few thousand fragments that could anchor a relation, never
    /// every fragment, and never a repo-wide byte pass. Idempotent; a view whose
    /// rung already read bytes (live, matched) is left alone.
    pub fn fillBytes(self: *View, wanted: []const bool) !void {
        if (self.sketches.len == self.labels.len and self.labels.len > 0) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var cache: std.StringHashMapUnmanaged([]const u8) = .empty;

        const out = try self.gpa.alloc(Sketch, self.labels.len);
        errdefer self.gpa.free(out);
        for (out) |*s| s.* = Sketch.empty;

        // Resolve every participant's bytes first, then fingerprint the whole
        // batch in one parallel pass. Building inline while walking made a
        // `--unit function` byte channel a single-threaded LZ78 march over
        // thousands of fragments with the other fifteen cores idle — and the
        // read-once cache is what forces the walk to be serial, so the two
        // concerns have to be separated rather than merged.
        var slices: std.ArrayList([]const u8) = .empty;
        defer slices.deinit(self.gpa);
        var owners: std.ArrayList(u32) = .empty;
        defer owners.deinit(self.gpa);
        for (wanted, 0..) |want, i| {
            if (!want) continue;
            const gop = try cache.getOrPut(a, self.paths[i]);
            if (!gop.found_existing)
                gop.value_ptr.* = std.Io.Dir.cwd().readFileAlloc(self.io, self.paths[i], a, .limited(corpus_mod.per_file_cap)) catch "";
            const bytes = gop.value_ptr.*;
            if (bytes.len == 0) continue;
            // A unit with no span IS its file (the file unit); a fragment is the
            // slice its span names, clamped to what the file now holds.
            const slice = if (self.spans.len > i) blk: {
                const s = self.spans[i];
                if (s.byte_end > bytes.len or s.byte_start > s.byte_end) continue;
                break :blk bytes[s.byte_start..s.byte_end];
            } else bytes;
            try slices.append(self.gpa, slice);
            try owners.append(self.gpa, @intCast(i));
        }

        const built = try self.gpa.alloc(Sketch, slices.items.len);
        defer self.gpa.free(built);
        _ = try fingerprint.fill(Sketch, sketch_mod.build, self.gpa, slices.items, built);
        for (owners.items, built) |i, s| out[i] = s;

        if (self.owned_sketches) |old| self.gpa.free(old);
        self.owned_sketches = out;
        self.sketches = out;
    }

    /// The stderr diagnostic's provenance clause: `"atlas, "` / `"matched, "`.
    pub fn provenance(self: *const View) []const u8 {
        return switch (self.source) {
            .atlas => "atlas, ",
            .index => "index, ",
            .live => "live, ",
            .matched => "matched, ",
        };
    }

    pub fn deinit(self: *View) void {
        if (self.owned_sketches) |s| self.gpa.free(s);
        if (self.owned_silhouettes) |s| self.gpa.free(s);
        if (self.exact) |*e| e.deinit();
        if (self.frag_view) |*f| f.deinit();
        if (self.file_view) |*f| f.deinit();
        if (self.arena) |*a| a.deinit();
    }
};

/// Make sure the byte channel is filled for every unit that could take part.
///
/// The fragment index persists silhouettes only, so a byte-reading channel over
/// the function unit has to go back to the source. It goes back for the
/// participants only — structural floors name them, since structure is the
/// record the index actually holds — and reads each file once. A view whose rung
/// already read bytes returns immediately.
pub fn ensureBytes(view: *View, gpa: std.mem.Allocator, params: echoes.Params) !void {
    if (view.sketches.len == view.len()) return;
    var floors = params;
    floors.channel = .shapes;
    const wanted = try echoes.participation(gpa, view.table(), floors);
    defer gpa.free(wanted);
    try view.fillBytes(wanted);
}

/// Resolve the cheapest sound view for `ask`. The rung is chosen, never
/// configured: a caller asks for a unit and a population, not for an artifact.
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, ask: Ask) !View {
    if (ask.narrow) |narrow| return matched(gpa, io, ask, narrow);
    return switch (ask.unit) {
        .file => files(gpa, io, ask),
        .function => fragments(gpa, io, ask),
        // Without a pattern there is no hit to window, so this is a usage error
        // rather than an empty answer.
        .match => die("--unit match needs --matching PATTERN (a window is a window around a hit)\n", .{}),
    };
}

// ── the file rung ──

fn files(gpa: std.mem.Allocator, io: std.Io, ask: Ask) !View {
    var fv = try kinship.resolve(gpa, io, ask.roots, ask.no_index, ask.wants);
    errdefer fv.deinit();
    return .{
        .labels = fv.paths,
        .paths = fv.paths,
        .sketches = fv.sketches,
        .silhouettes = fv.silhouettes,
        .unit = .file,
        .source = if (fv.from_atlas) .atlas else .live,
        .refreshed = fv.refreshed,
        .examined = fv.paths.len,
        .gpa = gpa,
        .io = io,
        .file_view = fv,
    };
}

// ── the function rung ──

/// The fragment table plus its keepalive, resolved warm or live. Kept private:
/// callers see `View`, which is the same shape for every unit.
const FragView = struct {
    paths: []const []const u8,
    spans: []const frag.Span,
    sils: []const Silhouette,
    from_index: bool,
    refreshed: usize,
    gpa: std.mem.Allocator,

    frag_idx: ?frag.Frag = null,
    folded: ?frag.Folded = null,
    corpus: ?corpus_mod.Corpus = null,
    build: ?frag.Build = null,
    scoped_paths: ?[][]const u8 = null,
    scoped_spans: ?[]frag.Span = null,
    scoped_sils: ?[]Silhouette = null,

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

fn fragments(gpa: std.mem.Allocator, io: std.Io, ask: Ask) !View {
    var fv = try resolveFragments(gpa, io, ask.roots, ask.no_index);
    errdefer fv.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const labels = try a.alloc([]const u8, fv.paths.len);
    for (fv.paths, fv.spans, labels) |p, span, *l|
        l.* = try std.fmt.allocPrint(a, "{s}#L{d}", .{ p, span.line_start });
    const lines = try a.alloc(u32, fv.spans.len);
    for (fv.spans, lines) |span, *n| n.* = @intCast(span.lines());

    return .{
        .labels = labels,
        .paths = fv.paths,
        .lines = lines,
        .spans = fv.spans,
        .silhouettes = fv.sils,
        .unit = .function,
        .source = if (fv.from_index) .index else .live,
        .refreshed = fv.refreshed,
        .examined = fv.paths.len,
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .frag_view = fv,
    };
}

/// The cheapest sound fragment table for `roots`: the persisted fragment index
/// folded for freshness when every root sits inside the indexed corpus, else a
/// live extract + build. Byte-identical answers either way.
fn resolveFragments(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, no_index: bool) !FragView {
    index: {
        if (no_index) break :index;
        var f = frag.loadQuiet(gpa, io) orelse break :index;
        for (roots) |r| if (!flags.underAnyRoot(r, f.roots)) {
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
            .gpa = gpa,
        };
        // An explicitly scoped query only needs the rows inside that scope; the
        // fold already paid freshness for them.
        if (roots.len > 0) {
            var n: usize = 0;
            for (folded.paths.items) |p| n += @intFromBool(flags.underAnyRoot(p, roots));
            const sp = try gpa.alloc([]const u8, n);
            errdefer gpa.free(sp);
            const ss = try gpa.alloc(frag.Span, n);
            errdefer gpa.free(ss);
            const sl = try gpa.alloc(Silhouette, n);
            errdefer gpa.free(sl);
            var w: usize = 0;
            for (folded.paths.items, folded.spans.items, folded.silhouettes.items) |p, span, sil| {
                if (!flags.underAnyRoot(p, roots)) continue;
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
        v.frag_idx = f;
        v.folded = folded;
        return v;
    }

    const rr = try flags.rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items, .contiguous);
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
        .gpa = gpa,
        .corpus = corpus,
        .build = build,
        .scoped_paths = paths,
    };
}

// ── the narrowed rung (exact first, kinship inside) ──

/// The corpus, the compiled patterns, and the docs they admitted — the exact
/// half of a composed query, owned as one value.
///
/// Every `--matching` verb needs precisely this trio, and `pack` needs the
/// `CandidateSet` itself (the compose kernel prices novelty inside it and rides
/// each pick's mask to output). Resolving it here means one place decides what
/// "the matching files" are, and one place reports a pattern that will not
/// compile.
pub const Narrowed = struct {
    corpus: corpus_mod.Corpus,
    set: patterns_mod.PatternSet,
    cset: candidates.CandidateSet,
    gpa: std.mem.Allocator,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, narrow: Narrow) !Narrowed {
        if (narrow.patterns.len == 0) die("--matching needs a pattern\n", .{});
        const rr = try flags.rootsOf(gpa, roots);
        defer rr.deinit(gpa);
        var corpus = try corpus_mod.load(gpa, io, rr.items, .contiguous);
        errdefer corpus.deinit();
        var set = compile(gpa, narrow) catch |e| dieCompile(e);
        errdefer set.deinit(gpa);
        const cset = candidates.select(gpa, corpus.docs, &set, narrow.match) catch |e| dieCompile(e);
        return .{ .corpus = corpus, .set = set, .cset = cset, .gpa = gpa };
    }

    /// How many files the patterns admitted, of how many examined.
    pub fn admitted(self: *const Narrowed) usize {
        return self.cset.count();
    }

    pub fn deinit(self: *Narrowed) void {
        self.cset.deinit();
        self.set.deinit(self.gpa);
        self.corpus.deinit();
    }
};

/// Exact-select the corpus, then build the comparison table over only what
/// matched. For the file unit a unit is a matching file; for function/match it
/// is a region lifted out of one (so a small implementation is not drowned by
/// the unrelated bytes of the file holding it).
fn matched(gpa: std.mem.Allocator, io: std.Io, ask: Ask, narrow: Narrow) !View {
    var exact = try Narrowed.open(gpa, io, ask.roots, narrow);
    errdefer exact.deinit();
    const corpus = &exact.corpus;
    const cset = &exact.cset;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var labels: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var bodies: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList(u32) = .empty;
    var spans: std.ArrayList(frag.Span) = .empty;
    var masks: std.ArrayList(u64) = .empty;

    if (ask.unit == .file) {
        for (cset.ids, cset.masks) |id, mask| {
            const doc = corpus.docs[id];
            try labels.append(a, corpus.paths[id]);
            try paths.append(a, corpus.paths[id]);
            try bodies.append(a, doc);
            try lines.append(a, @intCast(std.mem.count(u8, doc, "\n") + 1));
            try masks.append(a, mask);
        }
    } else {
        // Regions are selected over the candidate docs only, so a region's
        // `doc` field indexes the candidate set, not the corpus.
        const cand_docs = try a.alloc([]const u8, cset.count());
        for (cset.ids, cand_docs) |id, *d| d.* = corpus.docs[id];
        var found = try regions.select(
            gpa,
            cand_docs,
            &exact.set,
            if (ask.unit == .function) .function else .match,
            narrow.context,
        );
        defer found.deinit();
        for (found.items) |r| {
            const id = cset.ids[r.doc];
            const path = corpus.paths[id];
            try labels.append(a, try std.fmt.allocPrint(a, "{s}#L{d}", .{ path, r.line_start }));
            try paths.append(a, path);
            try bodies.append(a, corpus.docs[id][r.start..r.end]);
            try lines.append(a, r.line_end - r.line_start + 1);
            try spans.append(a, .{
                .byte_start = @intCast(r.start),
                .byte_end = @intCast(r.end),
                .line_start = r.line_start,
                .line_end = r.line_end,
            });
            try masks.append(a, cset.masks[r.doc]);
        }
    }

    const body_slice = bodies.items;
    const sketches = kinship.buildSketches(gpa, body_slice);
    errdefer gpa.free(sketches);
    const silhouettes: ?[]Silhouette = if (ask.wants == .structure)
        kinship.buildSilhouettes(gpa, body_slice)
    else
        null;
    return .{
        .labels = labels.items,
        .paths = paths.items,
        .lines = lines.items,
        .spans = spans.items,
        .bodies = body_slice,
        .sketches = sketches,
        .silhouettes = silhouettes orelse &.{},
        .masks = masks.items,
        .unit = ask.unit,
        .source = .matched,
        .examined = corpus.paths.len,
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .exact = exact,
        .owned_sketches = sketches,
        .owned_silhouettes = silhouettes,
    };
}

/// The CLI compiles ONE engine, so `-F`/`-i` apply to the whole `--matching`
/// set — the same constraint `relate patterns` enforces. Specs alias
/// `narrow.patterns`; the caller keeps those alive for the set's lifetime.
fn compile(gpa: std.mem.Allocator, narrow: Narrow) !patterns_mod.PatternSet {
    const specs = try gpa.alloc(patterns_mod.Spec, narrow.patterns.len);
    defer gpa.free(specs);
    for (narrow.patterns, specs) |p, *s|
        s.* = .{ .pattern = p, .fixed = narrow.fixed, .ignore_case = narrow.ignore_case };
    return patterns_mod.PatternSet.compile(gpa, specs);
}

/// The two fault domains a compile or a select can actually produce (ADR-373
/// law 2), rather than `anyerror` — so the switch below is exhaustive and a new
/// member of either domain is a compile error here instead of a mystery string
/// in someone's terminal. `--matching` offers no `-P`, so a pattern the linear
/// engine declines arrives already refused: a fault, not a declinature.
pub const Fault = fault.Pattern || fault.Resource;

/// Report an exact-filter failure as a usage-class exit (2) — the fail-closed
/// shape the rest of the CLI speaks.
fn dieCompile(e: Fault) noreturn {
    switch (e) {
        error.Unsupported => die("--matching: a pattern is outside gist's linear-time regex syntax (use -F for a literal, or simplify)\n", .{}),
        error.BadPattern => die("--matching: a pattern is not valid regex syntax (use -F to match it literally)\n", .{}),
        error.TooManyPatterns => die("--matching: too many patterns (max {d})\n", .{candidates.max_patterns}),
        // The rest have no bespoke guidance to give, so naming the fault is the
        // honest report — listed, never `else`-caught.
        error.PowersetCapHit,
        error.NeedleTooShort,
        error.OutOfMemory,
        error.TimedOut,
        error.Exhausted,
        => die("--matching: {s}\n", .{@errorName(e)}),
    }
}

/// One bitmask back into the patterns it stands for: borrowed slices plus a
/// `"a, b"` join for the human line. Bit order is ascending, so the labels read
/// in `--matching` order.
pub fn decode(gpa: std.mem.Allocator, pats: []const []const u8, mask: u64) Admission {
    var items: std.ArrayList([]const u8) = .empty;
    var joined: std.ArrayList(u8) = .empty;
    for (pats, 0..) |p, bit| {
        if (mask & (@as(u64, 1) << @intCast(bit)) == 0) continue;
        if (joined.items.len != 0) joined.appendSlice(gpa, ", ") catch oom();
        joined.appendSlice(gpa, p) catch oom();
        items.append(gpa, p) catch oom();
    }
    return .{
        .gpa = gpa,
        .items = items.toOwnedSlice(gpa) catch oom(),
        .joined = joined.toOwnedSlice(gpa) catch oom(),
    };
}

/// Which patterns admitted one unit. Caller `deinit`s.
pub const Admission = struct {
    gpa: std.mem.Allocator,
    items: [][]const u8,
    joined: []u8,

    pub fn deinit(self: *Admission) void {
        self.gpa.free(self.items);
        self.gpa.free(self.joined);
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "the line floor is the unit's, and only the unit's" {
    // The atlas carries no line counts, so the file unit has no line floor; a
    // fragment under five lines is a getter, not a consolidation target. Mass
    // deliberately does NOT appear here — thinness is a property of the record
    // the channel reads, so `echoes.massFloor` owns it beside `massy`.
    try t.expectEqual(@as(usize, 0), Unit.file.lineFloor());
    try t.expectEqual(@as(usize, 5), Unit.function.lineFloor());
    try t.expectEqual(@as(usize, 5), Unit.match.lineFloor());
}

test "unit names parse from the flag vocabulary" {
    try t.expectEqual(Unit.file, Unit.parse("file").?);
    try t.expectEqual(Unit.function, Unit.parse("function").?);
    try t.expectEqual(Unit.match, Unit.parse("match").?);
    try t.expectEqual(@as(?Unit, null), Unit.parse("module"));
}

test "provenance names the rung that answered, and only live rungs skip the gate" {
    const gpa = t.allocator;
    inline for (.{
        .{ Source.atlas, "atlas, " },
        .{ Source.index, "index, " },
        .{ Source.live, "live, " },
        .{ Source.matched, "matched, " },
    }) |row| {
        const v = View{ .labels = &.{}, .paths = &.{}, .unit = .file, .source = row[0], .gpa = gpa, .io = undefined };
        try t.expectEqualStrings(row[1], v.provenance());
    }
    // A live row needs no stat to prove it exists — it was just read.
    const live = View{ .labels = &.{"a.zig"}, .paths = &.{"a.zig"}, .unit = .file, .source = .live, .gpa = gpa, .io = undefined };
    try t.expect(live.gate(0));
    try t.expect(live.groupLive(&.{0}));
    // Only a narrowed view claims its population was filtered.
    try t.expect(!live.narrowed());
    const narrow = View{ .labels = &.{}, .paths = &.{}, .unit = .file, .source = .matched, .gpa = gpa, .io = undefined };
    try t.expect(narrow.narrowed());
}

test "the view hands the kernel a table, not its own arrays" {
    const gpa = t.allocator;
    const labels = [_][]const u8{ "a.zig#L1", "b.zig#L9" };
    const lines = [_]u32{ 12, 30 };
    const v = View{
        .labels = &labels,
        .paths = &.{ "a.zig", "b.zig" },
        .lines = &lines,
        .unit = .function,
        .source = .index,
        .gpa = gpa,
        .io = undefined,
    };
    const tbl = v.table();
    try t.expectEqual(@as(usize, 2), tbl.len());
    try t.expectEqualStrings("b.zig#L9", tbl.labels[1]);
    try t.expectEqual(@as(u32, 12), tbl.lines[0]);
    // No rung read bytes here, so a renderer asking for a headline gets null
    // rather than a slice into nothing.
    try t.expectEqual(@as(?[]const u8, null), v.body(0));
}
