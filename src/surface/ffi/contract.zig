//! Gist's own C-ABI data contract for the in-process search session.
//!
//! The shared status vocabulary, fault pull, and pattern-semantics bits live
//! in `@import("irregex").ffi.contract` — this file re-exports them and adds
//! only what the search product owns: the behavioral flag bits, the match
//! callback shapes, and the pull-cursor search request.
//!
//! `session.zig` translates these types into resident requests; `root.zig`
//! exports the session and cursor C symbols as `gist_*`.

const std = @import("std");
const api = @import("irregex").api;
const substrate = @import("irregex").ffi.contract;

// ── substrate, re-exported so session/cursor keep one import ──────────────

pub const Disposition = substrate.Disposition;
pub const Status = substrate.Status;
pub const FaultDetail = substrate.FaultDetail;
pub const lastFault = substrate.lastFault;
pub const report = substrate.report;
pub const reportAny = substrate.reportAny;
pub const beginCall = substrate.beginCall;

/// Pattern semantics — same bit values as `libirgx`, so "ignore case" has
/// one definition across the ecosystem.
pub const flag_fixed = substrate.flag_fixed;
pub const flag_ignore_case = substrate.flag_ignore_case;
pub const flag_word = substrate.flag_word;
pub const flag_smart_case = substrate.flag_smart_case;
pub const flag_no_unicode = substrate.flag_no_unicode;

// ── gist's own behavioral bits ────────────────────────────────────────────
// Gaps at 3, 4, and 7 are reserved for these (the engine's PCRE bit is 8).

pub const flag_quiet: u32 = 1 << 3;
pub const flag_max_count: u32 = 1 << 4;
pub const flag_invert: u32 = 1 << 7;

/// Flags the session and cursor search paths accept. PCRE is the engine's
/// plane, not the warm session's — an unknown bit (including that one) still
/// fails closed at the seam.
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

// ── the pull-cursor surface ──────────────────────────────────────
// The push callback above streams; this shape lets a host PULL. `gist_engine`
// and `gist_cancel` are opaque handles (`api.Engine` / `api.CancelToken` by
// pointer); `gist_cursor` owns a materialized, arena-backed record buffer the
// host walks with `next` / `next_batch`. All additive — the legacy triad above
// keeps working, so `abi()` stays 2.

/// One complete cursor search shape. Append-only + `struct_size`-checked so a
/// newer field is a forward-compatible ABI extension, never a silent reinterpret.
/// `cancel` is an optional `gist_cancel` handle; the budgets use 0 = "unset".
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
    /// Optional `gist_cancel` handle (null = no cancellation).
    cancel: ?*api.CancelToken,
};

test "known_flags covers every session bit and leaves the PCRE gap alone" {
    const t = std.testing;
    try t.expect(known_flags & flag_quiet != 0);
    try t.expect(known_flags & flag_max_count != 0);
    try t.expect(known_flags & flag_invert != 0);
    // Bit 8 is the engine's; the warm session must not silently accept it.
    try t.expect(known_flags & substrate.flag_pcre == 0);
}
