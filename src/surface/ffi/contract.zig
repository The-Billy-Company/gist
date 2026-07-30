//! Stable C-ABI data contract for the in-process search session.
//!
//! This module owns layout and status—not execution. `session.zig` translates
//! these types into resident requests; `root.zig` exports the session and
//! cursor C symbols.
//!
//! It also owns the **one** translation from the kernel's fault vocabulary into
//! that status (ADR-373 law 7: "the seam translates exactly once"). The
//! translation belongs here rather than in `fault.zig` because it is the
//! boundary's own job — `fault.zig` owns what a failure *is*, and only a
//! transport knows how to say it. Every rule below is read off
//! `contract/search_api.toml`; nothing here invents a mapping.

const std = @import("std");
const api = @import("irregex").api;
const fault = @import("irregex").fault;

/// Which of ADR-373's three channels an outcome belongs to — the `disposition`
/// column of `[status_codes]`, made executable.
///
/// It is the load-bearing field precisely because it is the one a consumer
/// would otherwise re-derive from the sign of an integer and get wrong: a
/// `declinature` is negative but is *not* an error (the caller answers one tier
/// down and gets the identical result), and a `fault` must never be flattened
/// into a `result`. With this enum both are properties a switch proves.
pub const Disposition = enum { result, declinature, fault };

/// Every entry returns one status; negative values always mean "decline safely."
pub const Status = enum(i32) {
    ok = 0,
    match = 1,
    stale = -1,
    out_of_memory = -2,
    open_failed = -3,
    invalid = -4,

    /// The channel this status belongs to, per `[status_codes].disposition`.
    pub fn disposition(self: Status) Disposition {
        return switch (self) {
            .ok, .match => .result,
            .stale => .declinature,
            .out_of_memory, .open_failed, .invalid => .fault,
        };
    }

    /// The status a fault crosses the seam as — the single translation, derived
    /// from the contract rather than chosen here. `[status_codes]` binds each
    /// fault-disposition status to one domain of `[fault_domains]`
    /// (`out_of_memory` ↔ resource, `open_failed` ↔ corpus, `invalid` ↔
    /// pattern), so each domain's members follow their own status. Two domains
    /// the C seam has no status for join `open_failed`, the only one whose
    /// subject is the corpus: `persist` (untrustworthy bytes for a corpus
    /// artifact — every one of which is *supposed* to fail closed to the live
    /// path before reaching here) and `wire`, which the contract says cannot
    /// cross this seam at all since the FFI is in-process with no daemon
    /// transport. Both stay total rather than trusted: what the fold loses,
    /// `irregex_last_fault`'s `name` restores per incident.
    ///
    /// Exhaustive on purpose — a twentieth fault member is a compile error here
    /// instead of a silent `else` prong that would report a new failure as a
    /// clean run.
    pub fn ofFault(f: fault.Fault) Status {
        return switch (f) {
            error.OutOfMemory, error.TimedOut, error.Exhausted => .out_of_memory,
            error.BadPattern, error.Unsupported, error.TooManyPatterns, error.PowersetCapHit, error.NeedleTooShort => .invalid,
            error.FileNotFound,
            error.AccessDenied,
            error.NotDir,
            error.SymLinkLoop,
            error.NameTooLong,
            error.Corrupt,
            error.Truncated,
            error.NonCanonical,
            error.VersionMismatch,
            error.GenerationMismatch,
            error.Oversized,
            error.ConnClosed,
            error.UnexpectedFrame,
            error.StreamTooLong,
            => .open_failed,
        };
    }
};

pub const flag_fixed: u32 = 1 << 0;
pub const flag_ignore_case: u32 = 1 << 1;
pub const flag_word: u32 = 1 << 2;
pub const flag_quiet: u32 = 1 << 3;
pub const flag_max_count: u32 = 1 << 4;
pub const flag_smart_case: u32 = 1 << 5;
pub const flag_no_unicode: u32 = 1 << 6;
pub const flag_invert: u32 = 1 << 7;

pub const known_flags = flag_fixed | flag_ignore_case | flag_word | flag_quiet |
    flag_max_count | flag_smart_case | flag_no_unicode | flag_invert;

/// One complete search shape. `struct_size` fails closed across ABI drift.
pub const SearchOptions = extern struct {
    struct_size: u32,
    flags: u32,
    max_count: u64,
    before_context: u64,
    after_context: u64,
};

pub const Submatch = extern struct {
    text: [*]const u8,
    len: usize,
    start: usize,
    end: usize,
};

pub const MatchKind = enum(u32) { match, context };

/// One selected line. Every pointer aliases session scratch for one callback.
pub const Match = extern struct {
    path: [*]const u8,
    path_len: usize,
    line_number: u64,
    line: [*]const u8,
    line_len: usize,
    submatches: [*]const Submatch,
    nsubmatches: usize,
    kind: MatchKind,
};

pub const MatchFn = *const fn (ctx: ?*anyopaque, match: *const Match) callconv(.c) i32;

// ── the pull-cursor surface (ADR-352) ──────────────────────────────────────
// The push callback above streams; this shape lets a host PULL. `irregex_engine`
// and `irregex_cancel` are opaque handles (`api.Engine` / `api.CancelToken` by
// pointer); `irregex_cursor` owns a materialized, arena-backed record buffer the
// host walks with `next` / `next_batch`. All additive — the legacy triad above
// keeps working, so `abi()` stays 2.

/// One complete cursor search shape. Append-only + `struct_size`-checked so a
/// newer field is a forward-compatible ABI extension, never a silent reinterpret.
/// `cancel` is an optional `irregex_cancel` handle; the budgets use 0 = "unset".
pub const SearchRequest = extern struct {
    struct_size: u32,
    flags: u32,
    max_count: u64,
    before_context: u64,
    after_context: u64,
    pattern: ?[*]const u8,
    pattern_len: usize,
    /// Monotonic wall-clock budget in ns (0 = no deadline).
    timeout_ns: u64,
    /// Result-count budget (0 = unbounded).
    max_results: usize,
    /// Optional `irregex_cancel` handle (null = no cancellation).
    cancel: ?*api.CancelToken,
};

// ── the last-fault pull (ADR-373 law 7) ────────────────────────────────────
// `sqlite3_errmsg` / `git_error_last` semantics: the host asks AFTER a non-OK
// status, the answer is its own thread's, and it is borrowed until that
// thread's next call. Being a PULL is what keeps it from being a second copy of
// assay's push sink — which the FFI session deliberately keeps `dark`
// (`session.zig`), so the two never carry the same bytes to the same place.
// This adds no sink, no env var, and no escaper: `fault.Detail` is an inert
// value and this entry copies six fields out of it.

/// Per-incident detail for this thread's last fault — what a static per-code
/// string cannot say: which fault, about which file, at which byte.
///
/// The C-ABI twin of `fault.Detail`. `struct_size` is set by the CALLER and the
/// layout is append-only, so a newer field is a forward-compatible extension
/// and an unknown size fails closed exactly like `SearchRequest`'s.
pub const FaultDetail = extern struct {
    struct_size: u32,
    /// The `Status` this fault translated to — always `fault` disposition.
    status: i32,
    /// 1 when `at` is meaningful; 0 when the fault is about the file as a whole
    /// (byte 0 is a real offset, so absence needs its own bit).
    has_at: i32,
    /// The fault's name — one of `[fault_domains]`' members (`Corrupt`,
    /// `AccessDenied`). NUL-terminated, static lifetime, never null.
    name: [*:0]const u8,
    /// The file the fault was about, or null when it was about no single one.
    /// Borrows the thread slot: NOT NUL-terminated (use `path_len`), valid
    /// until this thread's next work call.
    path: ?[*]const u8,
    path_len: usize,
    /// Byte offset within `path` at which the fault was detected.
    at: u64,
};

/// Fill `out` with this thread's last fault: `.match` when one was written,
/// `.ok` when the thread has none (`out` untouched), `.invalid` for a null or
/// wrongly-sized `out`. That is the same pull grammar `cursorNext` speaks, so
/// the surface gains no second vocabulary for "there is nothing more."
///
/// A non-OK status does **not** imply a detail exists, and `.ok` here is not a
/// contradiction of it. The seam's own argument guards (`.invalid` for a null
/// pointer or a stale `struct_size`) have no per-incident detail to add over
/// `irregex_status_message`, and a declinature is not a fault at all — so `.ok`
/// means "nothing further to say", never "the call succeeded".
///
/// Reading does not consume: a host may ask twice, or ask after
/// `irregex_status_message`, and get the same answer.
pub fn lastFault(out: ?*FaultDetail) Status {
    const slot = out orelse return .invalid;
    if (slot.struct_size != @sizeOf(FaultDetail)) return .invalid;
    const d = fault.last() orelse return .ok;
    slot.* = .{
        .struct_size = @sizeOf(FaultDetail),
        .status = @intFromEnum(Status.ofFault(d.code)),
        .has_at = @intFromBool(d.at != null),
        .name = @errorName(d.code).ptr,
        .path = if (d.path.len == 0) null else d.path.ptr,
        .path_len = d.path.len,
        .at = d.at orelse 0,
    };
    return .match;
}

/// Record `d` and hand back the status it crosses as — the seam's single act of
/// translation, so no entry point spells a fault's status without also leaving
/// the host the detail behind it.
///
/// A **declinature never comes through here**: `.stale` is returned directly by
/// its call sites, which is what keeps `irregex_last_fault` silent about a tier
/// that merely stepped aside.
pub fn report(d: fault.Detail) Status {
    fault.install(d);
    return Status.ofFault(d.code);
}

/// `report` for a failure whose error set the seam cannot switch over: the warm
/// engine's `open` path infers its errors from `std` (path joins, mmap, the
/// artifact loaders), so members outside the taxonomy ride it. One the taxonomy
/// names is reported in full; anything else returns `unknown` with **no**
/// detail, because naming a fault the kernel never declared would be worse than
/// silence.
pub fn reportAny(e: anyerror, unknown: Status) Status {
    inline for (@typeInfo(fault.Fault).error_set.?) |m|
        if (e == @field(fault.Fault, m.name)) return report(.{ .code = @field(fault.Fault, m.name) });
    return unknown;
}

/// Open one C-ABI call's fault window: drop whatever the PREVIOUS call on this
/// thread left in the slot, so a host asking after a **successful** call is
/// handed nothing rather than an earlier failure.
///
/// Deliberately unpaired with `Scope.end()`, which is the whole policy. The
/// fault a call installs must OUTLIVE that call — that is the borrow the header
/// promises — so the window closes at the NEXT work call's `beginCall`, not at
/// this one's return; ending the scope would restore precisely the stale fault
/// this exists to prevent. (Nested Zig cleanup paths still pair `scope`/`end`
/// normally: they must not displace the fault their caller is about to report.)
///
/// Only the entries that START work call it. Teardown (`close`, `cursorClose`,
/// `cancelFree`, `engineClose`) and the two pure readers
/// (`irregex_status_message`, `irregex_last_fault`) leave the slot alone, so a
/// host can still report the detail from its cleanup path — the one place a
/// uniform "every call clears" rule would silently eat it.
///
/// `clear`, not `scope`, because there is no "afterwards" to restore into — and
/// because `cursorNext` is a per-record entry, so the difference is a tag-byte
/// store instead of copying a 512-byte path buffer out to discard it.
pub fn beginCall() void {
    fault.clear();
}

test "each status keeps the channel the contract assigns it" {
    const t = std.testing;
    try t.expectEqual(Disposition.result, Status.ok.disposition());
    try t.expectEqual(Disposition.result, Status.match.disposition());
    // The row the whole field exists for: negative, but NOT an error value.
    try t.expectEqual(Disposition.declinature, Status.stale.disposition());
    try t.expectEqual(Disposition.fault, Status.out_of_memory.disposition());
    try t.expectEqual(Disposition.fault, Status.open_failed.disposition());
    try t.expectEqual(Disposition.fault, Status.invalid.disposition());
}

test "every fault crosses the seam as a fault — never a result, never a declinature" {
    const all = [_]fault.Fault{
        error.FileNotFound,    error.AccessDenied,       error.NotDir,         error.SymLinkLoop,
        error.NameTooLong,     error.Corrupt,            error.Truncated,      error.NonCanonical,
        error.VersionMismatch, error.GenerationMismatch, error.Oversized,      error.BadPattern,
        error.Unsupported,     error.TooManyPatterns,    error.PowersetCapHit, error.NeedleTooShort,
        error.OutOfMemory,     error.TimedOut,           error.Exhausted,      error.ConnClosed,
        error.UnexpectedFrame, error.StreamTooLong,
    };
    // Pinned to the taxonomy's own size, so a new member cannot slip past this
    // loop by simply not being listed (the switch in `ofFault` catches it too).
    try std.testing.expectEqual(@typeInfo(fault.Fault).error_set.?.len, all.len);
    for (all) |f| try std.testing.expectEqual(Disposition.fault, Status.ofFault(f).disposition());

    // The domain bindings themselves, one witness each.
    try std.testing.expectEqual(Status.out_of_memory, Status.ofFault(error.OutOfMemory));
    try std.testing.expectEqual(Status.invalid, Status.ofFault(error.TooManyPatterns));
    try std.testing.expectEqual(Status.open_failed, Status.ofFault(error.AccessDenied));
    try std.testing.expectEqual(Status.open_failed, Status.ofFault(error.Corrupt));
}

test "the pull hands back the leaf's detail, repeatably, and fails closed" {
    const t = std.testing;
    const sc = fault.scope();
    defer sc.end();

    var out: FaultDetail = undefined;
    out.struct_size = @sizeOf(FaultDetail);
    try t.expectEqual(Status.ok, lastFault(&out)); // a clean thread says nothing

    fault.install(.{ .code = error.Corrupt, .path = "kinship.atlas", .at = 12 });
    try t.expectEqual(Status.match, lastFault(&out));
    try t.expectEqual(@intFromEnum(Status.open_failed), out.status);
    try t.expectEqualStrings("Corrupt", std.mem.span(out.name));
    try t.expectEqualStrings("kinship.atlas", out.path.?[0..out.path_len]);
    try t.expectEqual(@as(u64, 12), out.at);
    try t.expectEqual(@as(i32, 1), out.has_at);
    try t.expectEqual(Status.match, lastFault(&out)); // reading is not consuming

    // A pathless fault reports absence, not a zero offset over a null pointer.
    fault.install(.{ .code = error.OutOfMemory });
    try t.expectEqual(Status.match, lastFault(&out));
    try t.expectEqual(@intFromEnum(Status.out_of_memory), out.status);
    try t.expect(out.path == null);
    try t.expectEqual(@as(i32, 0), out.has_at);

    out.struct_size = 0;
    try t.expectEqual(Status.invalid, lastFault(&out));
    try t.expectEqual(Status.invalid, lastFault(null));
}
