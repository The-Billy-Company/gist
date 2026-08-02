//! Gist's C-ABI dispatch — one entry, one cursor.
//!
//! This module materializes gist's one analytic answer — `rank`, the
//! definition-first view of an exact query — into a pull cursor of
//! self-describing `rows.Row`s. Kinship and sweep live in `librelate`;
//! compose lives in `libblast`. One verb, one entry, one params family.
//!
//! The cursor itself (`Answer`) and the four walk symbols (`irgx_rows_*`)
//! live in `libirgx`. This module only produces: it builds an Answer, fills
//! the arena, and hands it over. A host walks it with the shared substrate.
//!
//! ## Declinature is a feature, not a stub
//!
//! A verb this build cannot answer in-process returns `.stale`, which the ABI
//! defines as *this tier declines — answer through the subprocess fallback, the
//! answer there is identical*. That is the same fail-open contract the exact
//! plane uses for a pattern outside linear syntax, and it is what lets the
//! plane graduate verb by verb without any binding changing a line: a binding
//! calls the FFI, reads `.stale`, and shells the CLI exactly as it does today.
//!
//! ## Why the answer is materialized whole
//!
//! An analytic verb has no meaningful partial state. So the work runs to
//! completion into one arena, and the cursor walks a finished slice. Rows stay
//! valid until `irgx_rows_close`.

const std = @import("std");
const api = @import("irregex").api;
const answer = @import("irregex").ffi.answer;
const contract = @import("contract.zig");
const rows = @import("irregex").ffi.rows;

const Status = contract.Status;
const Row = rows.Row;
const table = rows.table;
const Answer = answer.Answer;

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

/// Run gist's analytic verb and materialize its cursor.
///
/// Fails closed before doing any work: an unknown op, an op this library does
/// not own, a params pointer of the wrong family or size, or an unassigned
/// flag bit is `.invalid` — never a reinterpret of memory the caller did not
/// write.
pub fn run(
    engine: *api.Engine,
    op: u32,
    params_ptr: ?*const rows.Params,
    cancel: ?*api.CancelToken,
    out: ?**Answer,
) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const params = params_ptr orelse return .invalid;
    if (op == 0 or op > table.verbs.len) return .invalid;
    const verb = table.verbs[op - 1];
    if (verb.op != .rank) return .invalid;

    // The family check is the whole point of declaring `params` per verb: it
    // catches a host that passed `KinshipParams` to `rank` HERE, at the
    // boundary, instead of reading a `[*]const u8` out of an f64's bytes.
    if (rows.params(rows.RankParams, &params.rank) == null) return .invalid;

    const cursor = Answer.begin() catch return contract.report(.{ .code = error.OutOfMemory });
    errdefer answer.close(cursor);

    var collected: std.ArrayList(Row) = .empty;
    const started = std.Io.Clock.now(.awake, engine.io).nanoseconds;
    var st = rows.Stats{ .struct_size = @sizeOf(rows.Stats) };
    var ctx = Ctx{
        .arena = cursor.arena.allocator(),
        .engine = engine,
        .cancel = cancel,
        .out = &collected,
        .stats = &st,
    };

    dispatch(&ctx, verb, params) catch |err| switch (err) {
        error.Decline => {
            answer.close(cursor);
            return .stale;
        },
        error.OutOfMemory => return contract.report(.{ .code = error.OutOfMemory }),
    };

    const items = collected.toOwnedSlice(ctx.arena) catch
        return contract.report(.{ .code = error.OutOfMemory });
    st.rows = items.len;
    const elapsed = std.Io.Clock.now(.awake, engine.io).nanoseconds - started;
    st.elapsed_ns = if (elapsed > 0) @intCast(elapsed) else 0;
    cursor.finish(items, st);
    slot.* = cursor;
    return .ok;
}

/// The verb table's one switch. Rank is not yet in-process, so it declines and
/// the binding answers through the CLI.
fn dispatch(ctx: *Ctx, verb: table.Verb, params: *const rows.Params) ArmError!void {
    _ = ctx;
    _ = params;
    return switch (verb.op) {
        .rank => error.Decline,

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
        .patterns,
        .pattern_counts,
        .context,
        .family,
        .provenance,
        .blast,
        => unreachable,
    };
}

test "an unknown op and a foreign verb both fail closed" {
    const t = std.testing;
    // No engine is dereferenced on these paths — validation precedes work, by
    // design, so a bad call cannot reach the corpus at all.
    const engine: *api.Engine = @ptrFromInt(@alignOf(api.Engine));
    var out: *Answer = undefined;

    var params = rows.Params{
        .rank = .{
            .struct_size = @sizeOf(rows.RankParams),
            .flags = 0,
            .pattern = null,
            .pattern_len = 0,
            .top = 0,
            .reserved = 0,
        },
    };
    try t.expectEqual(Status.invalid, run(engine, 0, &params, null, &out));
    try t.expectEqual(Status.invalid, run(engine, table.verbs.len + 1, &params, null, &out));
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.rank), &params, null, null));
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.rank), null, null, &out));

    // `patterns` is relate's verb: handed to gist_run, the ownership check
    // rejects it rather than declining into a CLI fallback for the wrong binary.
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), &params, null, &out));

    params.rank.flags = 1 << 30; // never assigned by this build
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.rank), &params, null, &out));
}

test "rank is either dispatched or declines — none can fall through" {
    // A `switch` over `table.Op` with no `else` makes this structural: adding a
    // verb to the contract fails the BUILD until this file names it. The test
    // pins the invariant that the table and the switch enumerate the same set.
    const t = std.testing;
    for (table.verbs, 1..) |verb, op| {
        try t.expectEqual(@as(u32, @intCast(op)), @intFromEnum(verb.op));
        try t.expect(@intFromEnum(verb.schema) >= 1 and @intFromEnum(verb.schema) <= table.schemas.len);
    }
}
