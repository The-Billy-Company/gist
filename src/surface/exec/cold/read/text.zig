//! gist `rg` — what the matcher actually sees.
//!
//! Raw file bytes normalized into matchable UTF-8 — the `auto` encoding leg
//! `ingest.zig` dispatches to (BOM sniff, UTF-16 transcode) — and split under
//! ripgrep's line model. THE one definition of "where does a line start and
//! does a trailing terminator make another", shared by both walk engines, the
//! binary quit strategy (`binary.zig`), and the warm face, so none of them can
//! drift on the unit every other per-file decision is expressed in.

const std = @import("std");
const oom = @import("../argv/args.zig").oom;

/// Strip a leading UTF-8 BOM (ripgrep transparently skips it so `^` anchors to
/// the first real byte). Downstream of `decodeBom` this is a no-op for files (the
/// BOM is already gone); it still guards the stdin path, which isn't BOM-decoded.
pub fn stripBom(buf: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, buf, "\xEF\xBB\xBF")) buf[3..] else buf;
}

/// BOM-driven encoding auto-detection, applied once per file at ingest — ripgrep's
/// default (`--encoding auto`) behavior. A UTF-8 BOM is stripped; a UTF-16 LE/BE
/// BOM transcodes the whole file to UTF-8 so the (UTF-8) pattern matches and the
/// UTF-16 NULs never trip binary detection. BOM-less UTF-16 is NOT sniffed (rg
/// needs explicit `-E utf-16` for that, which stays NA); anything else is bytes.
pub fn decodeBom(a: std.mem.Allocator, buf: []const u8) []const u8 {
    if (std.mem.startsWith(u8, buf, "\xFF\xFE")) return utf16ToUtf8(a, buf[2..], .little);
    if (std.mem.startsWith(u8, buf, "\xFE\xFF")) return utf16ToUtf8(a, buf[2..], .big);
    return stripBom(buf);
}

/// Transcode UTF-16 (BOM already consumed) to UTF-8, resolving surrogate pairs;
/// a lone/invalid surrogate or trailing odd byte becomes U+FFFD (rust-encoding's
/// lossy behavior, which ripgrep uses).
pub fn utf16ToUtf8(a: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, bytes[i..][0..2], endian);
        if (cp >= 0xD800 and cp <= 0xDBFF) { // high surrogate → need a low one
            const lo: u16 = if (i + 3 < bytes.len) std.mem.readInt(u16, bytes[i + 2 ..][0..2], endian) else 0;
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else cp = 0xFFFD;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) cp = 0xFFFD; // stray low surrogate
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch blk: {
            // U+FFFD REPLACEMENT CHARACTER — its UTF-8 encoding is a fixed 3 bytes.
            enc[0..3].* = .{ 0xEF, 0xBF, 0xBD };
            break :blk 3;
        };
        out.appendSlice(a, enc[0..n]) catch oom();
    }
    return out.toOwnedSlice(a) catch oom();
}

/// rg line semantics: `\n` terminates; trailing `\n` yields no phantom empty
/// line; content after the last `\n` is still a line. `\r` is KEPT (ripgrep's
/// default without `--crlf`). Pre-sized from one `\n` count pass (same idiom
/// as `persist.zig`'s NUL-count split) so appending a file's lines is a single
/// allocation instead of the list's usual grow-and-copy doubling — the search
/// loop calls this once per candidate file, so the saved reallocations
/// scale with the corpus, not just one file.
pub fn collectLines(a: std.mem.Allocator, buf: []const u8, term: u8, out: *std.ArrayList([]const u8)) void {
    out.ensureUnusedCapacity(a, std.mem.count(u8, buf, &.{term}) + 1) catch oom();
    var it = std.mem.splitScalar(u8, buf, term);
    while (it.next()) |line| out.appendAssumeCapacity(line);
    // split's tail after a trailing terminator (or on empty input) is rg's phantom empty line — drop it.
    if (buf.len == 0 or buf[buf.len - 1] == term) _ = out.pop();
}
