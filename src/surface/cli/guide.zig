//! Shared CLI vocabulary — the stderr guidance grammar.
//!
//! Every face owes the caller who got a useless answer an explanation on
//! stderr, in one grammar: an outcome line, then ranked suggestion lines
//! (`<tool>: try <flag or move> — <why>`) and explanatory lines
//! (`<tool>: note: <fact>`) — rustc's help/note split.
//!
//!     gist:   no matches for 'Pattern' · 1204 files scanned
//!     gist:   try -i — the pattern has uppercase; retry case-insensitive
//!     relate: no strong kin for fresh.zig · nearest 0.7813 (weak)
//!     relate: try --as shapes — byte kinship cannot see renamed vocabulary
//!
//! gist's no-match hints (`exec/cold/emit/hints.zig`) and relate's
//! weak-result verdict (`grade.zig`) are the same channel wearing different
//! evidence, so the voice lives here once and each face passes its own name.
//! Callers own the budget: hints are capped so a caller reads guidance
//! instead of scrolling it.

const std = @import("std");

/// The two hint voices. `.act` names a concrete retry the caller can run;
/// `.note` states a fact they should know but cannot flag away.
pub const Voice = enum { act, note };

/// One guidance line, spending a slot from `left`. A no-op once the budget is
/// exhausted, so callers can offer hints in priority order and let the cap
/// drop the tail.
pub fn line(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    left: *usize,
    tool: []const u8,
    voice: Voice,
    text: []const u8,
) !void {
    if (left.* == 0) return;
    left.* -= 1;
    try out.print(a, "{s}: {s} {s}\n", .{ tool, switch (voice) {
        .act => "try",
        .note => "note:",
    }, text });
}

/// `line`, but the text is formatted — for hints that must quote a measured
/// number (a distance, a threshold) rather than a fixed sentence.
pub fn linef(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    left: *usize,
    tool: []const u8,
    voice: Voice,
    comptime fmt: []const u8,
    fmt_args: anytype,
) !void {
    if (left.* == 0) return;
    left.* -= 1;
    try out.print(a, "{s}: {s} ", .{ tool, switch (voice) {
        .act => "try",
        .note => "note:",
    } });
    try out.print(a, fmt, fmt_args);
    try out.append(a, '\n');
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "voices render rustc's help/note split under the caller's tool name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var left: usize = 3;
    try line(a, &out, &left, "gist", .act, "-i — retry case-insensitive");
    try line(a, &out, &left, "relate", .note, "every row is past 0.50");
    try t.expectEqualStrings(
        \\gist: try -i — retry case-insensitive
        \\relate: note: every row is past 0.50
        \\
    , out.items);
}

test "budget caps the tail and linef formats measured evidence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var left: usize = 1;
    try linef(a, &out, &left, "relate", .act, "--as shapes — nearest was {d:.4}", .{0.7813});
    try line(a, &out, &left, "relate", .act, "dropped: no budget left");
    try t.expectEqualStrings("relate: try --as shapes — nearest was 0.7813\n", out.items);
    try t.expectEqual(@as(usize, 0), left);
}
