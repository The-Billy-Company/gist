//! The analytic plane's C-ABI dispatch (ADR-377) — one entry, one cursor.
//!
//! `cursor.zig` is this module's sibling on the exact plane: it materializes a
//! search into a pull cursor. This one materializes an ANALYTIC answer —
//! kinship, retrieval, sweep, composed — into a pull cursor of self-describing
//! `rows.Row`s. Seventeen verbs share the entry because a verb is a `u32` op
//! plus one of five params families, so a new verb adds no C symbol.
//!
//! ## Declinature is a feature, not a stub
//!
//! A verb this build cannot answer in-process returns `.stale`, which the ABI
//! defines as *this tier declines — answer through the subprocess fallback, the
//! answer there is identical*. That is the same fail-open contract the exact
//! plane uses for a pattern outside linear syntax, and it is what lets the
//! plane graduate verb by verb without any binding changing a line: a binding
//! calls the FFI, reads `.stale`, and shells the CLI exactly as it does today.
//! The alternative — holding the ABI back until all seventeen land — would
//! force every binding to re-plumb its transport twice.
//!
//! ## Why the answer is materialized whole
//!
//! An analytic verb has no meaningful partial state: `clusters` must see every
//! edge before it knows a component, `pack` prices each pick against the picks
//! before it. So the work runs to completion into one arena, and the cursor
//! walks a finished slice. That buys the row lifetime documented in
//! `include/irregex.h`: rows stay valid until `close`, not merely until the
//! next pull, so a batching host holds every batch it pulled without copying.

const std = @import("std");
const api = @import("../../api.zig");
const contract = @import("contract.zig");
const rows = @import("rows.zig");

const gpa = std.heap.c_allocator;
const Status = contract.Status;
const Row = rows.Row;
const Value = rows.Value;
const table = rows.table;

/// A materialized analytic answer plus its read position. Heap-stable: the
/// arena's allocator interface captures `&self.arena`.
pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Row,
    at: usize = 0,
    stats: rows.Stats,

    fn deinit(self: *Rows) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// What one dispatch arm is handed: the arena its rows must live in, the warm
/// engine, and the cancellation token the host may trip mid-answer.
const Ctx = struct {
    arena: std.mem.Allocator,
    engine: *api.Engine,
    cancel: ?*const api.CancelToken,
    out: *std.ArrayList(Row),
    stats: *rows.Stats,
};

/// `Decline` is the hosted spelling of `.stale`: not an error, a tier boundary.
const ArmError = error{ OutOfMemory, Decline };

/// Run one analytic verb and materialize its cursor.
///
/// Fails closed before doing any work: an unknown op, a params pointer of the
/// wrong family or size, or an unassigned flag bit is `.invalid` — never a
/// reinterpret of memory the caller did not write.
pub fn run(
    engine: *api.Engine,
    op: u32,
    params_ptr: ?*const rows.Params,
    cancel: ?*api.CancelToken,
    out: ?**Rows,
) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const params = params_ptr orelse return .invalid;
    if (op == 0 or op > table.verbs.len) return .invalid;
    const verb = table.verbs[op - 1];

    // The family check is the whole point of declaring `params` per verb: it
    // catches a host that passed `KinshipParams` to `pack` HERE, at the
    // boundary, instead of reading a `[*]const u8` out of an f64's bytes.
    switch (verb.params) {
        .kinship => if (rows.params(rows.KinshipParams, &params.kinship) == null) return .invalid,
        .retrieval => if (rows.params(rows.RetrievalParams, &params.retrieval) == null) return .invalid,
        .sweep => if (rows.params(rows.SweepParams, &params.sweep) == null) return .invalid,
        .compose => if (rows.params(rows.ComposeParams, &params.compose) == null) return .invalid,
        .rank => if (rows.params(rows.RankParams, &params.rank) == null) return .invalid,
    }

    const cursor = gpa.create(Rows) catch return contract.report(.{ .code = error.OutOfMemory });
    cursor.* = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .items = &.{},
        .stats = .{ .struct_size = @sizeOf(rows.Stats) },
    };
    errdefer cursor.deinit();

    var collected: std.ArrayList(Row) = .empty;
    const started = std.Io.Clock.now(.awake, engine.io).nanoseconds;
    var ctx = Ctx{
        .arena = cursor.arena.allocator(),
        .engine = engine,
        .cancel = cancel,
        .out = &collected,
        .stats = &cursor.stats,
    };

    dispatch(&ctx, verb, params) catch |err| switch (err) {
        error.Decline => {
            cursor.deinit();
            return .stale;
        },
        error.OutOfMemory => return contract.report(.{ .code = error.OutOfMemory }),
    };

    cursor.items = collected.toOwnedSlice(ctx.arena) catch
        return contract.report(.{ .code = error.OutOfMemory });
    cursor.stats.rows = cursor.items.len;
    const elapsed = std.Io.Clock.now(.awake, engine.io).nanoseconds - started;
    cursor.stats.elapsed_ns = if (elapsed > 0) @intCast(elapsed) else 0;
    slot.* = cursor;
    return .ok;
}

/// The verb table's one switch. Every arm not yet in-process declines, so the
/// binding answers through the CLI and the caller sees the same rows.
fn dispatch(ctx: *Ctx, verb: table.Verb, params: *const rows.Params) ArmError!void {
    return switch (verb.op) {
        .patterns => sweepHits(ctx, &params.sweep),
        .pattern_counts => sweepCounts(ctx, &params.sweep),

        // Graduating in ADR-377's staged order: the kinship family needs the
        // atlas resolve, retrieval the fingerprint lexicon, compose both.
        .similar,
        .dups,
        .clusters,
        .echoes,
        .concepts,
        .fragments,
        .distinct,
        .recall,
        .pack,
        .quote,
        .context,
        .family,
        .provenance,
        .blast,
        .rank,
        => error.Decline,
    };
}

// ── the sweep family ────────────────────────────────────────────────────────
// N patterns, exact attribution. The verb's promise is *one corpus traversal
// per question set* rather than N cold walks — which a warm engine already
// satisfies structurally: the corpus, index, and mmaps stay resident across
// the loop, so each pattern pays a scan of memory the first one warmed, not a
// fresh tree walk. Attribution is exact by construction (the pattern index is
// the loop variable), which is the property `relate patterns` actually sells.

fn sweepQuery(p: *const rows.SweepParams, pattern: []const u8) api.SearchQuery {
    return .{
        .pattern = pattern,
        .fixed = p.flags & rows.an_fixed != 0,
        .ignore_case = p.flags & rows.an_ignore_case != 0,
    };
}

fn sweepPatterns(p: *const rows.SweepParams) []const rows.Text {
    if (p.npatterns == 0) return &.{};
    return (p.patterns orelse return &.{})[0..p.npatterns];
}

/// `patterns` — one `pattern_hit` row per matching line, attributed to the
/// pattern index that found it.
fn sweepHits(ctx: *Ctx, p: *const rows.SweepParams) ArmError!void {
    const patterns = sweepPatterns(p);
    if (patterns.len == 0) return error.Decline;
    const budget: usize = if (p.top == 0) std.math.maxInt(usize) else p.top;

    for (patterns, 0..) |pattern, index| {
        var cursor = ctx.engine.search(sweepQuery(p, pattern.slice()), .{ .cancel = ctx.cancel }) catch |err| switch (err) {
            // One unsupported pattern makes the whole ANSWER unsupported: a
            // partial sweep silently missing a pattern's hits is worse than
            // declining, because the caller cannot tell the difference from a
            // pattern that genuinely matched nothing.
            error.UnsupportedPattern => return error.Decline,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer cursor.deinit();

        while (cursor.next()) |rec| {
            if (rec.kind != .match) continue;
            if (ctx.out.items.len >= budget) {
                ctx.stats.omitted += 1;
                continue;
            }
            var b = try rows.Builder.begin(ctx.arena, .pattern_hit);
            b.set(Value.text(try rows.dupe(ctx.arena, rec.path)));
            b.set(Value.int(@intCast(rec.line_number)));
            b.set(Value.int(@intCast(index)));
            try ctx.out.append(ctx.arena, b.end());
        }
    }
}

/// `pattern_counts` — engine-side totals, keyed by pattern (`an_by_pattern`,
/// the default) or by file (`an_by_file`). The point is to never cross the FFI
/// boundary once per hit when the caller only wants the tallies.
fn sweepCounts(ctx: *Ctx, p: *const rows.SweepParams) ArmError!void {
    const patterns = sweepPatterns(p);
    if (patterns.len == 0) return error.Decline;
    const by_file = p.flags & rows.an_by_file != 0;

    // Insertion-ordered so a tally set is deterministic across runs — a map's
    // iteration order would make two identical queries disagree.
    var labels: std.ArrayList([]const u8) = .empty;
    var counts: std.ArrayList(i64) = .empty;
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(ctx.arena);

    for (patterns) |pattern| {
        var cursor = ctx.engine.search(sweepQuery(p, pattern.slice()), .{ .cancel = ctx.cancel }) catch |err| switch (err) {
            error.UnsupportedPattern => return error.Decline,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer cursor.deinit();

        var tally: i64 = 0;
        while (cursor.next()) |rec| {
            if (rec.kind != .match) continue;
            if (!by_file) {
                tally += 1;
                continue;
            }
            const gop = try seen.getOrPut(ctx.arena, rec.path);
            if (gop.found_existing) {
                counts.items[gop.value_ptr.*] += 1;
            } else {
                // The map keys the arena copy, not the cursor's record: the
                // cursor's arena dies at the end of this iteration.
                const owned = try rows.dupe(ctx.arena, rec.path);
                gop.key_ptr.* = owned;
                gop.value_ptr.* = labels.items.len;
                try labels.append(ctx.arena, owned);
                try counts.append(ctx.arena, 1);
            }
        }
        if (!by_file) {
            try labels.append(ctx.arena, try rows.dupe(ctx.arena, pattern.slice()));
            try counts.append(ctx.arena, tally);
        }
    }

    for (labels.items, counts.items) |label, count| {
        var b = try rows.Builder.begin(ctx.arena, .pattern_count);
        b.set(Value.text(label));
        b.set(Value.int(count));
        try ctx.out.append(ctx.arena, b.end());
    }
}

// ── the cursor surface ──────────────────────────────────────────────────────

/// Write the next row. `.match` when one was written, `.ok` at the end.
pub fn next(cursor: *Rows, out: ?*Row) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (cursor.at >= cursor.items.len) return .ok;
    slot.* = cursor.items[cursor.at];
    cursor.at += 1;
    return .match;
}

/// Fill up to `cap` rows. One crossing amortized over N rows — the whole reason
/// a binding batches. `.match` when at least one landed, `.ok` at the end.
pub fn nextBatch(cursor: *Rows, out_ptr: ?[*]Row, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count = written orelse return .invalid;
    count.* = 0;
    if (cap == 0) return .ok;
    const out = (out_ptr orelse return .invalid)[0..cap];

    const take = @min(cap, cursor.items.len - cursor.at);
    @memcpy(out[0..take], cursor.items[cursor.at..][0..take]);
    cursor.at += take;
    count.* = take;
    return if (take == 0) .ok else .match;
}

/// Answer-level facts no row carries — the tier that answered, the freshness
/// fold, and `foreign`, which is how a caller tells "not in this corpus" from
/// "no results".
pub fn stats(cursor: *Rows, out: ?*rows.Stats) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(rows.Stats)) return .invalid;
    const size = slot.struct_size;
    slot.* = cursor.stats;
    slot.struct_size = size;
    return .ok;
}

/// Free a cursor and everything its rows borrow.
pub fn close(cursor: *Rows) void {
    cursor.deinit();
}

test "an unknown op and a mismatched params family both fail closed" {
    const t = std.testing;
    // No engine is dereferenced on these paths — validation precedes work, by
    // design, so a bad call cannot reach the corpus at all.
    const engine: *api.Engine = @ptrFromInt(@alignOf(api.Engine));
    var out: *Rows = undefined;

    var params = rows.Params{
        .sweep = .{
            .struct_size = @sizeOf(rows.SweepParams),
            .flags = 0,
            .patterns = null,
            .npatterns = 0,
            .under = null,
            .under_len = 0,
            .top = 0,
        },
    };
    try t.expectEqual(Status.invalid, run(engine, 0, &params, null, &out));
    try t.expectEqual(Status.invalid, run(engine, table.verbs.len + 1, &params, null, &out));
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), &params, null, null));
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), null, null, &out));

    // `similar` is a kinship verb: handed a sweep struct, the size check
    // rejects it rather than reading `npatterns` out of `max_distance`.
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.similar), &params, null, &out));

    params.sweep.flags = 1 << 30; // never assigned by this build
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), &params, null, &out));
}

test "every verb is either dispatched or declines — none can fall through" {
    // A `switch` over `table.Op` with no `else` makes this structural: adding a
    // verb to the contract fails the BUILD until this file names it. The test
    // pins the invariant that the table and the switch enumerate the same set.
    const t = std.testing;
    for (table.verbs, 1..) |verb, op| {
        try t.expectEqual(@as(u32, @intCast(op)), @intFromEnum(verb.op));
        try t.expect(@intFromEnum(verb.schema) >= 1 and @intFromEnum(verb.schema) <= table.schemas.len);
    }
}

test "the cursor surface walks, batches, and reports stats over a fixed answer" {
    const t = std.testing;
    var cursor = Rows{
        .arena = std.heap.ArenaAllocator.init(t.allocator),
        .items = &.{},
        .stats = .{ .struct_size = @sizeOf(rows.Stats), .rows = 3, .foreign = 7 },
    };
    defer cursor.arena.deinit();
    const arena = cursor.arena.allocator();

    var built: [3]Row = undefined;
    for (&built, 0..) |*slot, i| {
        var b = try rows.Builder.begin(arena, .pattern_count);
        b.set(Value.text("p"));
        b.set(Value.int(@intCast(i)));
        slot.* = b.end();
    }
    cursor.items = &built;

    var one: Row = undefined;
    try t.expectEqual(Status.match, next(&cursor, &one));
    try t.expectEqual(@as(i64, 0), one.values[1].integer);

    var batch: [8]Row = undefined;
    var n: usize = 0;
    try t.expectEqual(Status.match, nextBatch(&cursor, &batch, batch.len, &n));
    try t.expectEqual(@as(usize, 2), n); // the tail, not the whole answer
    try t.expectEqual(@as(i64, 2), batch[1].values[1].integer);

    // Drained: both pulls report end, neither errors.
    try t.expectEqual(Status.ok, next(&cursor, &one));
    try t.expectEqual(Status.ok, nextBatch(&cursor, &batch, batch.len, &n));
    try t.expectEqual(@as(usize, 0), n);
    try t.expectEqual(Status.ok, nextBatch(&cursor, &batch, 0, &n));

    var st = rows.Stats{ .struct_size = @sizeOf(rows.Stats) };
    try t.expectEqual(Status.ok, stats(&cursor, &st));
    try t.expectEqual(@as(u64, 7), st.foreign);
    try t.expectEqual(@sizeOf(rows.Stats), st.struct_size);

    st.struct_size = 8;
    try t.expectEqual(Status.invalid, stats(&cursor, &st));
    try t.expectEqual(Status.invalid, stats(&cursor, null));
    try t.expectEqual(Status.invalid, nextBatch(&cursor, null, 4, &n));
    try t.expectEqual(Status.invalid, nextBatch(&cursor, &batch, 4, null));
    try t.expectEqual(Status.invalid, next(&cursor, null));
}
