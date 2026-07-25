//! The raw C-ABI surface, mirroring `include/irregex.h` symbol-for-symbol.
//!
//! Two halves with deliberately different compilation rules:
//!
//! * The **layouts** — every `#[repr(C)]` struct and every `IRREGEX_*` constant
//!   — are compiled unconditionally. They describe bytes, not symbols, so they
//!   cost nothing without a library and they let the analytic row decoder (and
//!   its tests) be exercised against synthesized buffers on a plain subprocess
//!   build. A decoder that can only run when a `.so` is present is a decoder
//!   nobody tests.
//! * The **exact-plane entry points** are `extern` declarations behind the
//!   `native` feature, so a default build links no archive at all.
//!
//! The analytic plane is deliberately *not* declared `extern` on either path:
//! it is resolved at run time in [`super::plane`], because a link-time
//! dependency on symbols the kernel is still landing would make the crate
//! unbuildable rather than degrade it to subprocess.
//!
//! Nothing here is exported from the crate. The opaque handles are `enum {}` so
//! a raw pointer to one can never be dereferenced on the Rust side.
#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_int, c_void};

/// Opaque warm engine (`api.Engine`), shared by the exact and analytic planes.
pub enum irregex_engine {}
/// Opaque materialized pull cursor (owns its record arena).
pub enum irregex_cursor {}
/// Opaque thread-safe cancellation token (`api.CancelToken`).
pub enum irregex_cancel {}
/// Opaque analytic row cursor (owns the arena every row borrows).
pub enum irregex_rows {}

// ── the exact plane ────────────────────────────────────────────────────────

/// Mirrors `irregex_submatch`: a borrowed span view into the line bytes.
#[repr(C)]
pub struct Submatch {
    pub text: *const u8,
    pub len: usize,
    pub start: usize,
    pub end: usize,
}

/// Mirrors `irregex_match`: one borrowed record view (valid only until the cursor
/// is advanced again — the wrapper copies out immediately).
#[repr(C)]
pub struct MatchView {
    pub path: *const u8,
    pub path_len: usize,
    pub line_number: u64,
    pub line: *const u8,
    pub line_len: usize,
    pub submatches: *const Submatch,
    pub nsubmatches: usize,
    pub kind: u32,
}

/// Mirrors `irregex_search_request`: the append-only, `struct_size`-checked shape.
#[repr(C)]
pub struct SearchRequest {
    pub struct_size: u32,
    pub flags: u32,
    pub max_count: u64,
    pub before_context: u64,
    pub after_context: u64,
    pub pattern: *const u8,
    pub pattern_len: usize,
    pub timeout_ns: u64,
    pub max_results: usize,
    pub cancel: *mut irregex_cancel,
}

// Flag bits (mirror `contract.zig` / the IRREGEX_* header macros).
pub const FLAG_FIXED: u32 = 1 << 0;
pub const FLAG_IGNORE_CASE: u32 = 1 << 1;
pub const FLAG_WORD: u32 = 1 << 2;
pub const FLAG_QUIET: u32 = 1 << 3;
pub const FLAG_MAX_COUNT: u32 = 1 << 4;
pub const FLAG_SMART_CASE: u32 = 1 << 5;
pub const FLAG_NO_UNICODE: u32 = 1 << 6;
pub const FLAG_INVERT: u32 = 1 << 7;

// The status vocabulary is mirrored contract-side (see `crate::contract`) so a
// subprocess-only build still carries it; these are the `c_int`-typed aliases
// the FFI call sites compare against.
pub const OK: c_int = crate::contract::STATUS_OK;
pub const MATCH: c_int = crate::contract::STATUS_MATCH;
pub const STALE: c_int = crate::contract::STATUS_STALE;
pub const OOM: c_int = crate::contract::STATUS_OOM;
pub const OPEN_FAILED: c_int = crate::contract::STATUS_OPEN_FAILED;
pub const INVALID: c_int = crate::contract::STATUS_INVALID;

#[cfg(feature = "native")]
unsafe extern "C" {
    pub fn irregex_engine_open(
        roots: *const *const c_char,
        nroots: usize,
        out: *mut *mut irregex_engine,
    ) -> c_int;
    pub fn irregex_engine_close(engine: *mut irregex_engine);
    pub fn irregex_cancel_new(out: *mut *mut irregex_cancel) -> c_int;
    pub fn irregex_cancel_request(token: *mut irregex_cancel);
    pub fn irregex_cancel_free(token: *mut irregex_cancel);
    pub fn irregex_search_cursor(
        engine: *mut irregex_engine,
        request: *const SearchRequest,
        out: *mut *mut irregex_cursor,
    ) -> c_int;
    pub fn irregex_cursor_next(cursor: *mut irregex_cursor, out: *mut MatchView) -> c_int;
    pub fn irregex_cursor_next_batch(
        cursor: *mut irregex_cursor,
        out: *mut MatchView,
        cap: usize,
        written: *mut usize,
    ) -> c_int;
    pub fn irregex_cursor_matched(cursor: *mut irregex_cursor) -> c_int;
    pub fn irregex_cursor_close(cursor: *mut irregex_cursor);
}

// ── the analytic plane (ADR-377) ───────────────────────────────────────────

// Value tags. A field's tag comes from its `[row_schemas]` declaration, so the
// decoder knows the shape before it reads; the tag on the wire is what lets it
// fail rather than mis-read when the two disagree.
pub const VAL_TEXT: u32 = 0;
pub const VAL_I64: u32 = 1;
pub const VAL_F64: u32 = 2;
pub const VAL_BOOL: u32 = 3;
pub const VAL_ENUM: u32 = 4;
pub const VAL_TEXTS: u32 = 5;
pub const VAL_ROWS: u32 = 6;

// Analytic params flags. The presence bits exist because 0.0 is a *meaningful*
// threshold (`max_distance = 0.0` = byte-identical only), so "unset" cannot be
// spelled as zero the way an integer budget can.
pub const AN_MAX_DISTANCE: u32 = 1 << 0;
pub const AN_MIN_ECHO: u32 = 1 << 1;
pub const AN_NO_INDEX: u32 = 1 << 2;
pub const AN_FIXED: u32 = 1 << 3;
pub const AN_IGNORE_CASE: u32 = 1 << 4;
pub const AN_MATCH_ALL: u32 = 1 << 5;
pub const AN_BY_PATTERN: u32 = 1 << 6;
pub const AN_BY_FILE: u32 = 1 << 7;
pub const AN_DISTINCT: u32 = 1 << 8;

// Which tier answered (`irregex_stats.source`).
pub const SOURCE_LIVE: u32 = 0;
pub const SOURCE_ATLAS: u32 = 1;
pub const SOURCE_SHELF: u32 = 2;

/// A borrowed UTF-8 span. NOT NUL-terminated; `len` is authoritative.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Text {
    pub ptr: *const u8,
    pub len: usize,
}

/// One field of one row: a flat tagged record (not a union — the 16 bytes buy
/// every binding an FFI layer that can parse it).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Value {
    pub tag: u32,
    pub reserved: u32,
    pub integer: i64,
    pub real: f64,
    pub ptr: *const c_void,
    pub len: usize,
}

/// One result row. `schema_id` names a `[row_schemas]` table whose field order
/// *is* `values`; `present` bit i is clear when field i is absent — which is not
/// the same as zero.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct Row {
    pub schema_id: u32,
    pub nvalues: u32,
    pub present: u64,
    pub values: *const Value,
}

/// One declared field, for `irregex_schema_get`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Field {
    pub name: *const c_char,
    pub tag: u32,
    pub nested: u32,
    pub optional: c_int,
    pub reserved: c_int,
}

/// One declared row schema, for `irregex_schema_get`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Schema {
    pub struct_size: u32,
    pub id: u32,
    pub name: *const c_char,
    pub nfields: u32,
    pub reserved: u32,
    pub fields: *const Field,
}

/// Answer-level facts no row can carry.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Stats {
    pub struct_size: u32,
    pub source: u32,
    pub elapsed_ns: u64,
    pub files_considered: u64,
    pub refreshed: u64,
    pub foreign: u64,
    pub omitted: u64,
    pub rows: u64,
}

/// `similar · dups · clusters · echoes · concepts · fragments · distinct`.
#[repr(C)]
pub struct KinshipParams {
    pub struct_size: u32,
    pub flags: u32,
    pub target: *const u8,
    pub target_len: usize,
    pub channel: u32,
    pub unit: u32,
    pub max_distance: f64,
    pub min_echo: f64,
    pub min_grade: u32,
    pub min_size: u32,
    pub min_lines: u32,
    pub top: u32,
}

/// `recall · pack · quote` — free text priced against the corpus.
#[repr(C)]
pub struct RetrievalParams {
    pub struct_size: u32,
    pub flags: u32,
    pub query: *const u8,
    pub query_len: usize,
    pub top: u32,
    pub reserved: u32,
}

/// `patterns · pattern_counts` — N patterns, one walk, exact attribution.
#[repr(C)]
pub struct SweepParams {
    pub struct_size: u32,
    pub flags: u32,
    pub patterns: *const Text,
    pub npatterns: usize,
    pub under: *const u8,
    pub under_len: usize,
    pub top: u32,
    pub reserved: u32,
}

/// `context · family · provenance · blast` — exact narrows, compression reasons.
#[repr(C)]
pub struct ComposeParams {
    pub struct_size: u32,
    pub flags: u32,
    pub text: *const u8,
    pub text_len: usize,
    pub patterns: *const Text,
    pub npatterns: usize,
    pub max_distance: f64,
    pub min_echo: f64,
    pub budget: u32,
    pub top: u32,
}

/// `rank` — the definition-first view of an exact query.
#[repr(C)]
pub struct RankParams {
    pub struct_size: u32,
    pub flags: u32,
    pub pattern: *const u8,
    pub pattern_len: usize,
    pub top: u32,
    pub reserved: u32,
}

/// Detail for the last failing call on this thread (ADR-373 law 7).
#[repr(C)]
pub struct Fault {
    pub struct_size: u32,
    pub status: c_int,
    pub has_at: c_int,
    pub name: *const c_char,
    pub path: *const u8,
    pub path_len: usize,
    pub at: u64,
}

// Typed shapes for the analytic entry points. These are function *pointers*, not
// declarations: [`super::plane`] resolves them at run time, so an engine built
// before ADR-377 landed leaves the crate working rather than unlinkable.
pub type AnalyticRunFn = unsafe extern "C" fn(
    engine: *mut irregex_engine,
    op: u32,
    params: *const c_void,
    cancel: *mut irregex_cancel,
    out: *mut *mut irregex_rows,
) -> c_int;
pub type RowsNextFn = unsafe extern "C" fn(rows: *mut irregex_rows, out: *mut Row) -> c_int;
pub type RowsNextBatchFn = unsafe extern "C" fn(
    rows: *mut irregex_rows,
    out: *mut Row,
    cap: usize,
    written: *mut usize,
) -> c_int;
pub type RowsStatsFn = unsafe extern "C" fn(rows: *mut irregex_rows, out: *mut Stats) -> c_int;
pub type RowsCloseFn = unsafe extern "C" fn(rows: *mut irregex_rows);
pub type SchemaDigestFn = unsafe extern "C" fn() -> *const c_char;
pub type SchemaCountFn = unsafe extern "C" fn() -> u32;
pub type SchemaGetFn = unsafe extern "C" fn(id: u32, out: *mut Schema) -> c_int;
pub type LastFaultFn = unsafe extern "C" fn(out: *mut Fault) -> c_int;
pub type EngineOpenFn = unsafe extern "C" fn(
    roots: *const *const c_char,
    nroots: usize,
    out: *mut *mut irregex_engine,
) -> c_int;
pub type EngineCloseFn = unsafe extern "C" fn(engine: *mut irregex_engine);

// ── run-time symbol resolution ─────────────────────────────────────────────

#[cfg(unix)]
unsafe extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

/// `RTLD_DEFAULT` — search every object already loaded into this process, in
/// load order. Its value is platform ABI, not a header constant we can import.
#[cfg(all(unix, target_vendor = "apple"))]
const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;
#[cfg(all(unix, not(target_vendor = "apple")))]
const RTLD_DEFAULT: *mut c_void = std::ptr::null_mut();

/// Look up `name` (which MUST be NUL-terminated) among the symbols already in
/// this process, returning `None` when it is absent.
///
/// Absence is the expected answer on a subprocess-only build and on any engine
/// predating the analytic plane, so it is not an error — the caller falls back.
#[cfg(unix)]
pub fn symbol(name: &'static str) -> Option<*mut c_void> {
    debug_assert!(name.ends_with('\0'), "symbol name must be NUL-terminated");
    let found = unsafe { dlsym(RTLD_DEFAULT, name.as_ptr().cast::<c_char>()) };
    (!found.is_null()).then_some(found)
}

#[cfg(not(unix))]
pub fn symbol(_name: &'static str) -> Option<*mut c_void> {
    None
}
