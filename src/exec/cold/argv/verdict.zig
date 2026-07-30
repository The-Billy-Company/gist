//! What a flag's VALUE may be — and what a malformed one costs.
//!
//! Every function here reads one raw argv token and returns either a typed
//! value or nothing at all: a bad number, an unrepresentable size, an unknown
//! enum member, and an unclosed escape each end the run with ripgrep's exit 2
//! rather than being coerced into a plausible default. That is the whole reason
//! the value grammar is its own module — a silently-clamped `--max-filesize` or
//! a silently-ignored `--sort` key produces a *wrong result set* that looks like
//! a right one, which `contract/search_api.toml` forbids outright.
//!
//! It sits at the bottom of the argv package: it knows nothing about `Opts`,
//! the flag catalog, or the parse loop, so every layer above may lean on it.

const std = @import("std");
const paths = @import("../../../corpus/scope/paths.zig");
const uni = @import("../../../kernel/regex/regex.zig").unicode;
const udec = @import("../../../kernel/regex/regex.zig").decode;
const outcome = @import("../../../surface/cli/outcome.zig");

/// Fatal exit with ripgrep's error code (2), and the OOM exit for the ubiquitous
/// `… catch oom()`. Both live in `cli/outcome.zig` with the other two ways a
/// face ends; re-exported through the package facade so the shape of a bad-argv
/// exit stays a property of the CLI, not of this parser.
pub const die = outcome.die;
pub const oom = outcome.oom;

/// Does the pattern carry an uppercase letter? Codepoint-aware for smart-case
/// (`-S`): any Unicode uppercase (`Ä`, `Σ`, …) — not just ASCII `A-Z` — disables
/// the automatic fold, matching rg's Unicode default. Ill-formed bytes are
/// skipped (never counted as uppercase). Public so the no-match hint module
/// (`emit/hints.zig`) shares the exact detection smart-case uses.
pub fn hasUpper(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            if (s[i] >= 'A' and s[i] <= 'Z') return true;
            i += 1;
        } else if (udec.decode(s[i..])) |d| {
            if (uni.isUpper(d.cp)) return true;
            i += d.len;
        } else i += 1;
    }
    return false;
}

// The shared ASCII case fold (`paths.zig`) — one definition for the caseless
// glob path here and ignore.zig's git config-key folding.
pub const lowerDup = paths.lowerDup;

/// A leading `/` anchors a gitignore-style glob to the search root; gist already
/// matches such (slash-bearing) globs against the full path, so dropping the
/// anchor byte yields the same root-relative semantics.
pub fn stripAnchor(g: []const u8) []const u8 {
    return if (g.len > 0 and g[0] == '/') g[1..] else g;
}

pub fn toU(s: []const u8) usize {
    return std.fmt.parseInt(usize, s, 10) catch die("bad number '{s}'\n", .{s});
}

/// Resolve a value to its enum member, or fail loud with the flag's own
/// message — the shared back end of `--color`/`--engine`/`--sort`/`--sortr`.
pub fn enumOrDie(comptime T: type, comptime fmt: []const u8, s: []const u8) T {
    return std.meta.stringToEnum(T, s) orelse die(fmt, .{s});
}

/// Decode ripgrep's C-style escapes in a separator value (`--field-*-separator`,
/// `--context-separator`): `\n \r \t \0 \\` and `\xNN`. Anything else after a
/// backslash is kept verbatim (rg's lenient rule). Returns `s` unchanged when it
/// has no backslash (the common case).
pub fn unescape(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            out.append(a, s[i]) catch oom();
            continue;
        }
        i += 1;
        out.append(a, switch (s[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            '\\' => '\\',
            'x' => blk: {
                if (i + 2 >= s.len) die("bad \\x escape\n", .{});
                defer i += 2;
                break :blk std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch die("bad \\x escape\n", .{});
            },
            else => |c| blk: {
                out.append(a, '\\') catch oom();
                break :blk c;
            },
        }) catch oom();
    }
    return out.toOwnedSlice(a) catch oom();
}

/// Parse a `--max-filesize` value: a decimal with an optional `K`/`M`/`G` (1024-
/// based) suffix, e.g. `50`, `4K`, `1M` (ripgrep's grammar). A value that
/// overflows `usize` after applying the suffix fails loud (exit 2) exactly like
/// ripgrep — `34359738368G` names ~2^65 bytes, which cannot be represented, and
/// silently wrapping it into a tiny cap would drop files the user meant to keep.
pub fn toBytes(s: []const u8) usize {
    if (s.len == 0) die("bad size ''\n", .{});
    const mult: usize = switch (s[s.len - 1]) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    return std.math.mul(usize, toU(digits), mult) catch
        die("invalid --max-filesize: {s} overflows the maximum representable size\n", .{s});
}

/// Expand glob `{a,b,c}` alternations into every concrete pattern (cartesian
/// product across groups, nesting-aware). A pattern with no brace group yields
/// itself; an unbalanced `{` is left literal.
pub fn braceExpand(a: std.mem.Allocator, pat: []const u8, out: *std.ArrayList([]const u8)) void {
    // Find the first balanced `{…}` group; no group (or an unbalanced `{`) ⇒
    // the pattern is emitted literally.
    const grp: ?[2]usize = blk: {
        const open = std.mem.indexOfScalar(u8, pat, '{') orelse break :blk null;
        var depth: usize = 0;
        for (open..pat.len) |i| {
            if (pat[i] == '{') depth += 1 else if (pat[i] == '}') {
                depth -= 1;
                if (depth == 0) break :blk .{ open, i };
            }
        }
        break :blk null;
    };
    const open, const c = grp orelse {
        out.append(a, a.dupe(u8, pat) catch oom()) catch oom();
        return;
    };
    const prefix = pat[0..open];
    const suffix = pat[c + 1 ..];
    const inner = pat[open + 1 .. c];
    var start: usize = 0;
    var d: usize = 0;
    var j: usize = 0;
    while (j <= inner.len) : (j += 1) {
        const at_end = j == inner.len;
        if (!at_end and inner[j] == '{') d += 1 else if (!at_end and inner[j] == '}') d -= 1;
        if (at_end or (inner[j] == ',' and d == 0)) {
            const combined = std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, inner[start..j], suffix }) catch oom();
            braceExpand(a, combined, out); // recurse to expand any remaining groups
            start = j + 1;
        }
    }
}
