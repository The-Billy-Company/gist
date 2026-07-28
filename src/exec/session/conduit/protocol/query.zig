//! The request codec — how a search crosses the socket.
//!
//! Two opcodes carry every warm request: `query` (the unscoped classic) and
//! `query_ext` (length-prefixed pattern + the `PathFilter` and self-describing
//! rank/context/engine trailers). Encode and decode live together on purpose:
//! a trailer whose writer and reader disagree by one byte silently reinterprets
//! everything after it, so the two halves of each field are read side by side.
//!
//! Truncation and any flag bit outside `known_flags` fail closed
//! (`UnexpectedFrame` → decline → cold), never a dropped flag served warm.

const std = @import("std");
const request = @import("../../answer/request.zig");
const wire = @import("../wire.zig");
const frame = @import("opcodes.zig");

const WireError = frame.WireError;

// Query flags byte. Reserved bits join `known_flags` only with their engine semantics.
const flag_fixed: u8 = 1 << 0;
const flag_ignore_case: u8 = 1 << 1;
const flag_line_num: u8 = 1 << 2; // `-n` (lines mode)
const flag_word: u8 = 1 << 3; // `-w`
const flag_invert: u8 = 1 << 4; // `-v` (set-complement: non-matching lines)
const flag_smart_case: u8 = 1 << 5; // `-S` (raw; session resolves — see request.zig)
const flag_quiet: u8 = 1 << 6; // `-q` (existence-only; server answers a bare matched flag)
const flag_max_count_present: u8 = 1 << 7; // `-m` (a u64 LE cap follows the flags byte)

/// Flag bits this daemon implements. Any other set bit → `UnexpectedFrame` → decline → cold.
pub const known_flags: u8 = flag_fixed | flag_ignore_case | flag_line_num | flag_word | flag_invert | flag_smart_case | flag_quiet | flag_max_count_present;

/// The query flags byte — ONE derivation shared by `query` and `query_ext` so
/// the two opcodes can never disagree on what a set bit means.
fn packFlags(req: request.Request) u8 {
    var flags: u8 = 0;
    if (req.fixed) flags |= flag_fixed;
    if (req.ignore_case) flags |= flag_ignore_case;
    if (req.line_num) flags |= flag_line_num;
    if (req.word) flags |= flag_word;
    if (req.invert) flags |= flag_invert;
    if (req.smart_case) flags |= flag_smart_case;
    if (req.quiet) flags |= flag_quiet;
    if (req.max_count != null) flags |= flag_max_count_present;
    return flags;
}

pub fn encodeQuery(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, req: request.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(req.mode));
    try body.append(gpa, packFlags(req));
    // The optional `-m N` cap rides between the flags byte and the pattern (bit
    // 7 gates its presence) — the only variable-width field ahead of the pattern.
    if (req.max_count) |m| try wire.appendInt(u64, &body, gpa, m);
    try body.appendSlice(gpa, req.pattern);
    try frame.writeFrame(buf, gpa, .query, body.items);
}

/// Encode a scoped request (`query_ext`): the classic body, but the pattern is
/// length-prefixed so the four-list `PathFilter` trailer can follow (roots,
/// includes, excludes, exts). Each list's count is a u8 (`request.max_scope`
/// ≤ 255 keeps it there), so an empty filter is four `0` bytes.
pub fn encodeQueryExt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, req: request.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(req.mode));
    try body.append(gpa, packFlags(req));
    if (req.max_count) |m| try wire.appendInt(u64, &body, gpa, m);
    try wire.appendInt(u32, &body, gpa, @intCast(req.pattern.len));
    try body.appendSlice(gpa, req.pattern);
    try appendStrList(&body, gpa, req.filter.roots);
    try appendStrList(&body, gpa, req.filter.includes);
    try appendStrList(&body, gpa, req.filter.excludes);
    try appendStrList(&body, gpa, req.filter.exts);
    // The `--rank[=N]` trailer: a presence byte, then the u64 top-k only when set
    // (`0` = cold's default 20). Self-describing, so a non-rank scoped query costs
    // one extra `0` byte and a rank query rides the same opcode as any scoped one.
    try body.append(gpa, @intFromBool(req.rank_k != null));
    if (req.rank_k) |k| try wire.appendInt(u64, &body, gpa, k);
    // The `-A`/`-B`/`-C` context trailer: a presence byte, then two u64 (before,
    // after) only when a window is set. Self-describing like the rank trailer, so
    // a windowless scoped query costs one extra `0` byte.
    const has_ctx = req.before != 0 or req.after != 0;
    try body.append(gpa, @intFromBool(has_ctx));
    if (has_ctx) {
        try wire.appendInt(u64, &body, gpa, req.before);
        try wire.appendInt(u64, &body, gpa, req.after);
    }
    // The `-P`/`--pcre2` engine trailer: one self-describing byte (there is no
    // free bit in the flags byte — it is fully assigned). A `-P` query rides
    // `query_ext` even when rootless (the client routes it here), so an old
    // daemon — which never negotiates this protocol version — is not reached.
    try body.append(gpa, @intFromBool(req.pcre));
    try frame.writeFrame(buf, gpa, .query_ext, body.items);
}

/// Append a `[u8 count]{[u32 len][bytes]}` string list (count ≤ `max_scope`).
fn appendStrList(body: *std.ArrayList(u8), gpa: std.mem.Allocator, list: []const []const u8) !void {
    try body.append(gpa, @intCast(list.len));
    for (list) |s| {
        try wire.appendInt(u32, body, gpa, @intCast(s.len));
        try body.appendSlice(gpa, s);
    }
}

/// Build a `Request` from the decoded scalar fields + `pattern`/`filter` (both
/// alias the frame buffer / caller arena). Shared by `decodeQuery` and
/// `decodeQueryExt` so the two opcodes lower a set flag bit to the same field.
fn requestFrom(mode: request.Mode, flags: u8, max_count: ?u64, pattern: []const u8, filter: request.PathFilter, rank_k: ?usize, before: u64, after: u64, pcre: bool) request.Request {
    return .{
        .pattern = pattern,
        .mode = mode,
        .fixed = flags & flag_fixed != 0,
        .ignore_case = flags & flag_ignore_case != 0,
        .line_num = flags & flag_line_num != 0,
        .word = flags & flag_word != 0,
        .pcre = pcre,
        .invert = flags & flag_invert != 0,
        .smart_case = flags & flag_smart_case != 0,
        .quiet = flags & flag_quiet != 0,
        .max_count = max_count,
        .before = before,
        .after = after,
        .filter = filter,
        .rank_k = rank_k,
    };
}

/// The `[u8 mode][u8 flags][opt u64 max_count]` head both opcodes share; `rest`
/// is left pointing at the first byte past it (the pattern).
fn takeHead(rest: *[]const u8) WireError!struct { mode: request.Mode, flags: u8, max_count: ?u64 } {
    if (rest.len < 2) return WireError.UnexpectedFrame;
    const mode = std.enums.fromInt(request.Mode, rest.*[0]) orelse return WireError.UnexpectedFrame;
    const flags = rest.*[1];
    if (flags & ~known_flags != 0) return WireError.UnexpectedFrame;
    rest.* = rest.*[2..];
    // Bit 7 gates the u64 cap between the flags byte and the pattern; a payload
    // too short to hold it is a truncated frame, not an empty-pattern one.
    if (flags & flag_max_count_present == 0) return .{ .mode = mode, .flags = flags, .max_count = null };
    if (rest.len < 8) return WireError.UnexpectedFrame;
    const m = std.mem.readInt(u64, rest.*[0..8], .little);
    rest.* = rest.*[8..];
    return .{ .mode = mode, .flags = flags, .max_count = m };
}

/// Decode a `query` payload. `pattern` aliases into `payload` (caller keeps the
/// frame buffer alive). Any flag bit outside `known_flags` → `UnexpectedFrame`.
pub fn decodeQuery(payload: []const u8) WireError!request.Request {
    var rest = payload;
    const head = try takeHead(&rest);
    if (rest.len == 0) return WireError.UnexpectedFrame;
    // The classic `query` opcode carries no engine trailer — it is only ever
    // emitted for a rootless, non-`-P` request (the client routes `-P` through
    // `query_ext`), so `pcre` is always false here.
    return requestFrom(head.mode, head.flags, head.max_count, rest, .{}, null, 0, 0, false);
}

/// Decode a `query_ext` payload — the scoped query. Same head as `decodeQuery`
/// but the pattern is length-prefixed and a four-list `PathFilter` trailer
/// follows (roots, includes, excludes, exts). `pattern` and every token alias
/// `payload`; each list's SLICE (the headers) is allocated from `a` (the
/// caller's per-query arena). Truncation / an over-cap count fails closed
/// (→ decline → cold). A flag bit outside `known_flags` → UnexpectedFrame.
pub fn decodeQueryExt(a: std.mem.Allocator, payload: []const u8) WireError!request.Request {
    var rest = payload;
    const head = try takeHead(&rest);
    const pattern = try frame.takeLenPrefixed(&rest);
    if (pattern.len == 0) return WireError.UnexpectedFrame;
    const filter: request.PathFilter = .{
        .roots = try takeStrList(a, &rest),
        .includes = try takeStrList(a, &rest),
        .excludes = try takeStrList(a, &rest),
        .exts = try takeStrList(a, &rest),
    };
    const rank_k = try takeRank(&rest);
    const ctx = try takeContext(&rest);
    const pcre = takePcre(&rest);
    return requestFrom(head.mode, head.flags, head.max_count, pattern, filter, rank_k, ctx.before, ctx.after, pcre);
}

/// Consume the `[u8 pcre]` engine trailer. A same-version peer always writes it,
/// but a truncated tail tolerates as `false` (linear) — the same forward-lenient
/// rule as `takeRank`, so a stray short frame degrades to a correct linear
/// answer rather than a `UnexpectedFrame`.
fn takePcre(rest: *[]const u8) bool {
    if (rest.len == 0) return false;
    const b = rest.*[0];
    rest.* = rest.*[1..];
    return b != 0;
}

/// Consume the `[u8 present][opt u64 k]` rank trailer. Absent (a v3 peer always
/// writes at least the presence byte, but tolerate a truncated tail as null) →
/// not a rank query. Truncation of a present k → `UnexpectedFrame` (fail closed).
fn takeRank(rest: *[]const u8) WireError!?usize {
    if (rest.len < 1) return null;
    const present = rest.*[0] == 1;
    rest.* = rest.*[1..];
    if (!present) return null;
    if (rest.len < 8) return WireError.UnexpectedFrame;
    const k = std.mem.readInt(u64, rest.*[0..8], .little);
    rest.* = rest.*[8..];
    return @intCast(k);
}

/// Consume the `[u8 present][opt u64 before][opt u64 after]` context trailer.
/// A missing trailer (an older peer that stopped after rank) → no window;
/// truncation of a present pair → `UnexpectedFrame` (fail closed).
fn takeContext(rest: *[]const u8) WireError!struct { before: u64, after: u64 } {
    if (rest.len < 1) return .{ .before = 0, .after = 0 };
    const present = rest.*[0] == 1;
    rest.* = rest.*[1..];
    if (!present) return .{ .before = 0, .after = 0 };
    if (rest.len < 16) return WireError.UnexpectedFrame;
    const before = std.mem.readInt(u64, rest.*[0..8], .little);
    const after = std.mem.readInt(u64, rest.*[8..16], .little);
    rest.* = rest.*[16..];
    return .{ .before = before, .after = after };
}

/// Consume a `[u8 count]{[u32 len][bytes]}` string list, allocating the slice
/// of headers from `a` (tokens alias the frame). Truncation → `UnexpectedFrame`.
fn takeStrList(a: std.mem.Allocator, rest: *[]const u8) WireError![]const []const u8 {
    if (rest.len < 1) return WireError.UnexpectedFrame;
    const n = rest.*[0];
    rest.* = rest.*[1..];
    const out = a.alloc([]const u8, n) catch return WireError.UnexpectedFrame;
    for (out) |*s| s.* = try frame.takeLenPrefixed(rest);
    return out;
}
