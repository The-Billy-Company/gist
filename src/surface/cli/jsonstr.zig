//! One JSON string escaper for every irregex face that writes JSON/NDJSON.
//!
//! `rg --json` (emit/json.zig), the relate/irregex NDJSON verb rows
//! (surface/cli/emit.zig, re-exported as `jsonStr`), and the gist `--schema`
//! manifest all need the identical operation: append a byte slice as a JSON
//! string literal, surrounding quotes included. They used to carry three
//! near-copies that had quietly diverged — the schema one emitted RAW control
//! bytes (invalid JSON), the relate one lacked the `\b`/`\f` short forms — so
//! this is the single source of truth they now share.
//!
//! The escaping is serde_json's / ripgrep's exact discipline (the strictest
//! master, `rg --json` byte-parity): `"` and `\` backslash-escaped; the five C0
//! short forms `\b \t \n \f \r`; every other control (`< 0x20`) as `\u00XX`;
//! valid multi-byte UTF-8 passes through raw (callers that may hold invalid
//! UTF-8 gate to base64 upstream — see emit/json.jsonData). OOM is fatal, the
//! CLI output contract.

const std = @import("std");
const oom = @import("outcome.zig").oom;

const vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vlen, u8);
const Mask = std.meta.Int(.unsigned, vlen);

/// Index of the first byte at/after `from` that JSON must escape — `"`, `\`, or
/// any control (`< 0x20`) — else `s.len`. The overwhelming majority of a source
/// line is none of these, so a vectorized run-scan lets `write` bulk-copy whole
/// spans between escapes instead of touching the ArrayList once per byte.
inline fn nextEscape(s: []const u8, from: usize) usize {
    const quote: Vec = @splat('"');
    const bslash: Vec = @splat('\\');
    const ctl: Vec = @splat(0x20);
    var i = from;
    while (i + vlen <= s.len) : (i += vlen) {
        const blk: Vec = s[i..][0..vlen].*;
        const hit: Mask = @bitCast((blk == quote) | (blk == bslash) | (blk < ctl));
        if (hit != 0) return i + @ctz(hit);
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return s.len;
}

/// Emit the escape sequence for one byte `nextEscape` flagged (≤6 bytes; the
/// caller has reserved that headroom, so every write is AssumeCapacity).
inline fn escape(out: *std.ArrayList(u8), c: u8) void {
    switch (c) {
        '"' => out.appendSliceAssumeCapacity("\\\""),
        '\\' => out.appendSliceAssumeCapacity("\\\\"),
        0x08 => out.appendSliceAssumeCapacity("\\b"),
        '\t' => out.appendSliceAssumeCapacity("\\t"),
        '\n' => out.appendSliceAssumeCapacity("\\n"),
        0x0C => out.appendSliceAssumeCapacity("\\f"),
        '\r' => out.appendSliceAssumeCapacity("\\r"),
        else => { // remaining C0 control → \u00XX (c < 0x20, top two nibbles zero)
            const hex = "0123456789abcdef";
            out.appendSliceAssumeCapacity("\\u00");
            out.appendAssumeCapacity(hex[c >> 4]);
            out.appendAssumeCapacity(hex[c & 0xf]);
        },
    }
}

/// Append `s` to `out` as a JSON string literal, surrounding quotes included.
/// Argument order matches the relate face's `(buf, gpa, s)` convention so
/// `kinship.jsonStr` re-exports this directly.
pub fn write(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) void {
    // Reserve the no-escape size (bytes + both quotes) up front. The bulk copy of
    // each escape-free run self-ensures (one comparison the reserve almost always
    // satisfies, then a single memcpy) instead of appending byte-by-byte; the rare
    // escape tops up its own ≤6-byte headroom and writes through AssumeCapacity.
    out.ensureUnusedCapacity(gpa, s.len + 2) catch oom();
    out.appendAssumeCapacity('"');
    var i: usize = 0;
    while (i < s.len) {
        const j = nextEscape(s, i);
        out.appendSlice(gpa, s[i..j]) catch oom();
        if (j == s.len) break;
        out.ensureUnusedCapacity(gpa, 6) catch oom();
        escape(out, s[j]);
        i = j + 1;
    }
    out.append(gpa, '"') catch oom();
}

const t = std.testing;

test "write: quotes, backslashes, and every C0 short form escape correctly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    write(&buf, t.allocator, "a\"b\\c\n\t\r\x08\x0c");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\r\\b\\f\"", buf.items);
}

test "write: other controls become \\u00XX; UTF-8 passes through raw" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    write(&buf, t.allocator, "\x01\x1f\u{00e9}");
    try t.expectEqualStrings("\"\\u0001\\u001f\u{00e9}\"", buf.items);
}
