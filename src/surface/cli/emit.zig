//! Shared CLI vocabulary — NDJSON / text row emission.
//!
//! Every face's `--json` arm escapes strings and frames rows the same way, so
//! the shapes live here rather than per verb. `jsonStr` is the single escaper
//! (re-exported from the cold emit floor) so all faces escape identically;
//! `jsonRow` frames one object from a comptime field spec and `emitRow` routes
//! text vs JSON off one `json` bool.

const std = @import("std");

const oom = @import("outcome.zig").oom;

/// Append `s` JSON-string-escaped (quotes included) — the one escaper every
/// face shares (arg order matches these `(buf, gpa, s)` callers).
pub const jsonStr = @import("jsonstr.zig").write;

/// Make a printed row clickable: `anchor` for a bare unit label (which may
/// carry its own `#Lnnn`), `locator` for the `path:line` shape. Both hand the
/// bytes back unchanged when this run emits no links — see `beacon.zig`.
///
/// Re-exported here because every face that prints a row already imports
/// `emit`, and they belong on the TEXT side of `emitRow` only: a record carries
/// its path as data, and a JSON consumer wants the path, not an escape sequence
/// wrapped around one.
pub const anchor = @import("beacon.zig").anchor;
pub const locator = @import("beacon.zig").locator;

/// One NDJSON result row from a comptime field spec — the shared emitter
/// behind every verb's `--json` arm. Each entry is `.{ "key", kind, value }`
/// with kind `"s"` (escaped string), `"s?"` (escaped string or `null`), or a
/// `std.fmt` spec like `"d:.4"` applied verbatim.
///
/// The kind is comptime (it selects the branch) but the KEY need not be: a
/// kinship row names its score column for the channel that produced it
/// (`distance` / `echo` / `gain`), which is only known at runtime. Keys are
/// internal identifiers — never caller bytes — so they are appended unescaped.
pub fn jsonRow(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, fields: anytype) void {
    jsonFields(buf, gpa, fields);
    buf.appendSlice(gpa, "}\n") catch oom();
}

/// `jsonRow` without the closing brace — for the one row shape that carries a
/// trailing array (a family's members). The caller appends `,"key":[…]}` and the
/// newline, so the scalar columns still get exactly one escaping and NaN policy
/// instead of a hand-rolled `buf.print` per face.
pub fn jsonFields(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, fields: anytype) void {
    inline for (fields, 0..) |f, i| {
        buf.appendSlice(gpa, if (i == 0) "{\"" else ",\"") catch oom();
        buf.appendSlice(gpa, f[0]) catch oom();
        buf.appendSlice(gpa, "\":") catch oom();
        if (comptime std.mem.eql(u8, f[1], "s")) {
            jsonStr(buf, gpa, f[2]);
        } else if (comptime std.mem.eql(u8, f[1], "s?")) {
            if (f[2]) |v| jsonStr(buf, gpa, v) else buf.appendSlice(gpa, "null") catch oom();
        } else if (comptime @typeInfo(@TypeOf(f[2])) == .float) {
            // JSON has no NaN, and a bare `nan` token is not parseable by any
            // conforming reader (Python's `json` raises on it). A NaN here means
            // "this channel was never resolved for this row" — the byte score on
            // a silhouette-only view, say — which is precisely `null`.
            if (std.math.isNan(f[2]))
                buf.appendSlice(gpa, "null") catch oom()
            else
                buf.print(gpa, "{" ++ f[1] ++ "}", .{f[2]}) catch oom();
        } else {
            buf.print(gpa, "{" ++ f[1] ++ "}", .{f[2]}) catch oom();
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "an unresolved channel is JSON null, never a bare nan token" {
    const gpa = t.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    jsonRow(&buf, gpa, .{
        .{ "a", "s", "one.py" },
        .{ "distance", "d:.4", @as(f64, 0.375) },
        .{ "structure", "d:.4", std.math.nan(f64) },
        .{ "note", "s?", @as(?[]const u8, null) },
    });
    try t.expectEqualStrings(
        \\{"a":"one.py","distance":0.3750,"structure":null,"note":null}
        \\
    , buf.items);
}

test "a runtime key names the column its channel produced" {
    const gpa = t.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 0; // defeat comptime folding of the key
    const keys = [_][]const u8{ "distance", "echo", "gain" };
    i += 1;
    jsonRow(&buf, gpa, .{.{ keys[i], "d:.2", @as(f64, 0.5) }});
    try t.expectEqualStrings("{\"echo\":0.50}\n", buf.items);
}

/// One result row: `--json` routes through `jsonRow`, text prints `tfmt`.
pub fn emitRow(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, json: bool, jfields: anytype, comptime tfmt: []const u8, targs: anytype) void {
    if (json) jsonRow(buf, gpa, jfields) else buf.print(gpa, tfmt, targs) catch oom();
}
