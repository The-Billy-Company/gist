//! The raw `-sys` FFI surface for the pull-cursor C ABI (ADR-352), compiled only
//! under the `native` feature. These declarations mirror `include/irregex.h`
//! symbol-for-symbol; every safe wrapper lives in [`crate::cursor`]. Nothing here
//! is exported from the crate — the opaque handle types are `enum {}` so a raw
//! pointer to one can never be dereferenced on the Rust side.
#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_int};

/// Opaque warm engine (`api.Engine`).
pub enum irregex_engine {}
/// Opaque materialized pull cursor (owns its record arena).
pub enum irregex_cursor {}
/// Opaque thread-safe cancellation token (`api.CancelToken`).
pub enum irregex_cancel {}

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

// Status codes (mirror `contract.Status`).
pub const OK: c_int = 0;
pub const MATCH: c_int = 1;
pub const STALE: c_int = -1;
pub const OOM: c_int = -2;
pub const OPEN_FAILED: c_int = -3;
pub const INVALID: c_int = -4;

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
