//! gist in-process FFI — the PULL-cursor surface (ADR-352).
//!
//! The rung-3 `open`/`search`/`close` triad (`session.zig`) streams matches to a
//! host callback (PUSH). This module is its pull sibling over the curated Zig
//! facade (`api.zig`): a host opens an `Engine`, runs a `search` that
//! materializes an owned `Cursor`, then walks it with `next` / `next_batch` —
//! inverting control so a caller that can't (or won't) yield its stack to a
//! callback (Go's cgo, an async runtime, a REPL) still drives the warm engine.
//!
//! Every entry returns a `contract.Status` and never `die()`s — the same
//! fail-closed property ADR-352 gated the search ABI on. Handles are opaque and
//! owned: `Engine` and `CancelToken` are heap-boxed `api` values; a `Cursor`
//! wrapper owns the facade cursor plus a reusable submatch scratch. Each has one
//! NULL-safe destructor.
//!
//! ## View lifetime
//!
//! A `contract.Match` filled by `next` / `next_batch` BORROWS: its `path` and
//! `line` alias the cursor's arena (valid until `cursorClose`), and its
//! `submatches` alias the wrapper's reusable scratch (valid only until the next
//! `next` / `next_batch` on that cursor). The host copies anything it keeps —
//! exactly the discipline the callback path already documents.

const std = @import("std");
const api = @import("../../api.zig");
const contract = @import("contract.zig");

/// Share the host's C heap so a boxed handle frees without a Zig GPA.
const gpa = std.heap.c_allocator;
const Status = contract.Status;

/// A pull cursor: the facade cursor (owns the records) plus a reusable submatch
/// buffer the view structs point into. One `subs` scratch is refilled per
/// `next`; `nextBatch` fills it once for the whole batch (offsets computed so a
/// realloc can't dangle a mid-batch view).
pub const Cursor = struct {
    inner: *api.Cursor,
    subs: std.ArrayList(contract.Submatch) = .empty,

    fn deinit(self: *Cursor) void {
        self.subs.deinit(gpa);
        self.inner.deinit();
    }
};

/// Open a warm engine over `roots[0..nroots]` (NUL-terminated paths; `nroots ==
/// 0` = the rootless CWD walk). Writes the handle to `out`; `.invalid` on a null
/// `out` or a null `roots` with `nroots > 0`.
pub fn engineOpen(roots_ptr: ?[*]const [*:0]const u8, nroots: usize, out: ?**api.Engine) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const roots = gpa.alloc([]const u8, nroots) catch return contract.report(.{ .code = error.OutOfMemory });
    defer gpa.free(roots);
    if (nroots != 0) {
        const rp = roots_ptr orelse return .invalid;
        for (roots, 0..) |*r, i| r.* = std.mem.span(rp[i]);
    }
    const engine = api.Engine.open(gpa, roots) catch |e| return contract.reportAny(e, .open_failed);
    slot.* = engine;
    return .ok;
}

/// Tear down an engine opened by `engineOpen`.
pub fn engineClose(engine: *api.Engine) void {
    engine.close();
}

/// Allocate a fresh cancellation token (unset). Writes it to `out`.
pub fn cancelNew(out: ?**api.CancelToken) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const token = gpa.create(api.CancelToken) catch return contract.report(.{ .code = error.OutOfMemory });
    token.* = .{};
    slot.* = token;
    return .ok;
}

/// Request cancellation — thread-safe; any thread may call it during a search.
pub fn cancelRequest(token: *api.CancelToken) void {
    token.cancel();
}

/// Free a token allocated by `cancelNew` (after every search using it returns).
pub fn cancelFree(token: *api.CancelToken) void {
    gpa.destroy(token);
}

/// Run one search and materialize a pull cursor. Null / wrongly-sized / unknown
/// options fail closed with `.invalid`; an unsupported pattern returns `.stale`
/// (answer cold), never a cursor.
pub fn searchCursor(engine: *api.Engine, req_ptr: ?*const contract.SearchRequest, out: ?**Cursor) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const req = req_ptr orelse return .invalid;
    if (req.struct_size != @sizeOf(contract.SearchRequest) or req.flags & ~contract.known_flags != 0)
        return .invalid;
    const pattern: []const u8 = if (req.pattern_len == 0) "" else blk: {
        const p = req.pattern orelse return .invalid;
        break :blk p[0..req.pattern_len];
    };
    const flags = req.flags;
    const query = api.SearchQuery{
        .pattern = pattern,
        .fixed = flags & contract.flag_fixed != 0,
        .ignore_case = flags & contract.flag_ignore_case != 0,
        .smart_case = flags & contract.flag_smart_case != 0,
        .word = flags & contract.flag_word != 0,
        .invert = flags & contract.flag_invert != 0,
        .unicode = flags & contract.flag_no_unicode == 0,
        .before = req.before_context,
        .after = req.after_context,
        .max_count = if (flags & contract.flag_max_count != 0) req.max_count else null,
    };
    const run = api.RunOptions{
        .cancel = req.cancel,
        .timeout_ns = if (req.timeout_ns == 0) null else req.timeout_ns,
        .max_results = if (req.max_results == 0) null else req.max_results,
    };
    const inner = engine.search(query, run) catch |e| return switch (e) {
        error.OutOfMemory => contract.report(.{ .code = error.OutOfMemory }),
        // The hosted spelling of a declinature — the caller answers cold and
        // gets the identical result, so nothing lands in the fault slot.
        error.UnsupportedPattern => .stale,
    };
    const handle = gpa.create(Cursor) catch {
        inner.deinit();
        return contract.report(.{ .code = error.OutOfMemory });
    };
    handle.* = .{ .inner = inner };
    slot.* = handle;
    return .ok;
}

/// Fill `out` with the next record. Returns `.match` (a record was written),
/// `.ok` (end of stream — `out` untouched), or `.invalid` / `.out_of_memory`.
pub fn cursorNext(cursor: *Cursor, out: ?*contract.Match) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const rec = cursor.inner.next() orelse return .ok;
    cursor.subs.clearRetainingCapacity();
    cursor.subs.ensureTotalCapacity(gpa, rec.spans.len) catch return contract.report(.{ .code = error.OutOfMemory });
    for (rec.spans) |sp| cursor.subs.appendAssumeCapacity(spanView(rec.text, sp));
    slot.* = viewOf(rec, cursor.subs.items.ptr, cursor.subs.items.len);
    return .match;
}

/// Fill up to `cap` records into `out[0..cap]`; writes the count to `written`.
/// Returns `.match` when ≥1 record was written, `.ok` at end of stream (0
/// written), or a failure. All views in the batch share the wrapper's scratch,
/// so the batch is valid only until the next call on this cursor.
pub fn cursorNextBatch(cursor: *Cursor, out_ptr: ?[*]contract.Match, cap: usize, written: ?*usize) Status {
    contract.beginCall();
    const count_slot = written orelse return .invalid;
    count_slot.* = 0;
    if (cap == 0) return .ok;
    const out = (out_ptr orelse return .invalid)[0..cap];

    // Gather the batch of owned records first (the facade cursor advances), so
    // one pass sizes the shared submatch scratch before any view points into it
    // — a mid-batch realloc then can't dangle an already-written view.
    var gathered = std.ArrayList(api.OwnedMatch).empty;
    defer gathered.deinit(gpa);
    var total_spans: usize = 0;
    while (gathered.items.len < cap) {
        const rec = cursor.inner.next() orelse break;
        gathered.append(gpa, rec) catch return contract.report(.{ .code = error.OutOfMemory });
        total_spans += rec.spans.len;
    }
    if (gathered.items.len == 0) return .ok;

    cursor.subs.clearRetainingCapacity();
    cursor.subs.ensureTotalCapacity(gpa, total_spans) catch return contract.report(.{ .code = error.OutOfMemory });
    var offset: usize = 0;
    for (gathered.items, 0..) |rec, i| {
        for (rec.spans) |sp| cursor.subs.appendAssumeCapacity(spanView(rec.text, sp));
        out[i] = viewOf(rec, cursor.subs.items.ptr + offset, rec.spans.len);
        offset += rec.spans.len;
    }
    count_slot.* = gathered.items.len;
    return .match;
}

/// Whether any file matched (cold's exit-code boolean), even if a budget cut the
/// scan short. 1 = matched, 0 = none.
pub fn cursorMatched(cursor: *Cursor) i32 {
    return @intFromBool(cursor.inner.anyMatched());
}

/// Free a cursor (and its record buffer + scratch).
pub fn cursorClose(cursor: *Cursor) void {
    cursor.deinit();
    gpa.destroy(cursor);
}

fn spanView(text: []const u8, sp: api.Span) contract.Submatch {
    return .{ .text = text.ptr + sp.start, .len = sp.end - sp.start, .start = sp.start, .end = sp.end };
}

fn viewOf(rec: api.OwnedMatch, subs: [*]const contract.Submatch, nsubs: usize) contract.Match {
    return .{
        .path = rec.path.ptr,
        .path_len = rec.path.len,
        .line_number = rec.line_number,
        .line = rec.text.ptr,
        .line_len = rec.text.len,
        .submatches = subs,
        .nsubmatches = nsubs,
        .kind = @enumFromInt(@intFromEnum(rec.kind)),
    };
}

test "a successful entry hands back no fault, however the previous call failed" {
    const t = std.testing;
    const fault = @import("../../fault.zig");
    const sc = fault.scope();
    defer sc.end();

    // The failure a host would have just been told about, still in the slot.
    fault.install(.{ .code = error.Corrupt, .path = "kinship.atlas", .at = 7 });
    var detail: contract.FaultDetail = .{ .struct_size = @sizeOf(contract.FaultDetail), .status = 0, .has_at = 0, .name = "", .path = null, .path_len = 0, .at = 0 };
    try t.expectEqual(Status.match, contract.lastFault(&detail));

    var token: *api.CancelToken = undefined;
    try t.expectEqual(Status.ok, cancelNew(&token));
    defer cancelFree(token);

    // The assertion the scope policy exists for: no stale fault survives a call
    // that succeeded. Without `beginCall` at this entry the pull still reports
    // `Corrupt`, and a host would blame a clean run for an earlier failure.
    try t.expectEqual(Status.ok, contract.lastFault(&detail));
}

/// A stable, static, NUL-terminated message for a status code — the pragmatic
/// structured-error surface (a host maps the typed code; this names it for logs).
pub fn statusMessage(code: i32) [*:0]const u8 {
    return switch (code) {
        @intFromEnum(Status.ok) => "ok: ran, no (further) match",
        @intFromEnum(Status.match) => "match: a record is available",
        @intFromEnum(Status.stale) => "stale: pattern outside linear syntax or freshness unprovable — answer cold",
        @intFromEnum(Status.out_of_memory) => "out of memory",
        @intFromEnum(Status.open_failed) => "open failed: could not stand up the warm corpus",
        @intFromEnum(Status.invalid) => "invalid: null or wrongly-sized argument",
        else => "unknown status",
    };
}
