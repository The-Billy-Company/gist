//! Stable C-ABI data contract for the in-process search session.
//!
//! This module owns layout and status—not execution. `session.zig` translates
//! these types into resident requests; `root.zig` alone exports C symbols.

/// Every entry returns one status; negative values always mean "decline safely."
pub const Status = enum(i32) {
    ok = 0,
    match = 1,
    stale = -1,
    out_of_memory = -2,
    open_failed = -3,
    invalid = -4,
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
