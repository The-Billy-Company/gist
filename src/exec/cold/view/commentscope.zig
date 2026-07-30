//! gist `--in-comments` / `--in-code` — the native comment/code match view.
//!
//! A contained, early-branching view (the same discipline as `--rank`): it runs
//! BEFORE the certified ripgrep-parity per-line engine and returns, so the
//! rg-compatible walk/emit paths in `serial.zig` are never threaded with
//! comment awareness and their byte-parity certificate stands untouched.
//!
//! Mechanism: reuse the already-compiled `Matcher` and the shared span lexer
//! (`kernel/compose/lexspan.zig`). For each file, `commentMask` maps which bytes
//! fall inside a comment; each line's first qualifying match span is classified
//! by that mask — `--in-comments` keeps spans that begin inside a comment,
//! `--in-code` keeps spans outside every comment. The exact engine still
//! decides IF a line matches; this only filters WHICH matches survive, so a
//! comment-scoped result is always a subset of the same query's plain result.
//!
//! Honored flags: `-i`/`-F`/`-w`/`-P` (already baked into `re`), `-l`
//! (`files_only` → one path per file), `-q` (`quiet` → exit code only, no
//! stream), `--column`, `-a`/`--binary` (binary-file inclusion), `--json`, and
//! the filename-visibility rule the caller resolves. Line numbers are always
//! shown — this is a locator view, not an rg presentation clone.

const std = @import("std");
const output = @import("../emit/output.zig");
const lexspan = @import("../../../kernel/anatomy/lexspan.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const emit = @import("../../../surface/cli/emit.zig");
const args = @import("../argv/args.zig");
const writ = @import("../writ/writ.zig");

const Opts = args.Opts;
const oom = @import("../../../surface/cli/outcome.zig").oom;
const Matcher = @import("../../../kernel/regex/regex.zig").Matcher;

/// A searchable file: its display path and (BOM-stripped) body. The caller
/// (`serial.zig`) projects its `InFile` set into this so this module needs no
/// back-import of the engine shell (no import cycle).
pub const File = struct { path: []const u8, bytes: []const u8 };

/// Whether a match span beginning at byte offset `abs` should survive under the
/// active scope. Exactly one of `in_comments`/`in_code` is set by the caller.
inline fn keep(o: Opts, mask: []const bool, abs: usize) bool {
    const in_comment = abs < mask.len and mask[abs];
    return if (o.in_comments) in_comment else !in_comment;
}

/// Run the comment/code-scoped view over `files`, appending result rows to
/// `out` (unless `-q`). Returns the number of matches kept (files kept, under
/// `-l`) so the caller can pick the rg-shaped exit code.
pub fn run(a: std.mem.Allocator, re: *const Matcher, o: Opts, files: []const File, show_name: bool, out: *std.ArrayList(u8)) usize {
    var ss = Matcher.SpanSim.init(a, re) catch return 0;
    defer ss.deinit();
    const scope: []const u8 = if (o.in_comments) "comment" else "code";
    const binary_detect = writ.binaryDetect(o);
    var kept: usize = 0;

    for (files) |f| {
        const body = f.bytes;
        if (binary_detect and body.len > 0 and corpus_mod.isBinary(body)) continue;
        const mask = lexspan.commentMask(a, body) catch continue;
        var off: usize = 0;
        var lineno: usize = 1;
        var file_hit = false;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, body, off, '\n') orelse body.len;
            const line = body[off..nl];
            const view = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
            var from: usize = 0;
            var col: usize = 0;
            var ok = false;
            while (output.nextSpan(re, &ss, o, view, &from)) |sp| {
                if (keep(o, mask, off + sp.start)) {
                    ok = true;
                    col = sp.start + 1;
                    break;
                }
            }
            if (ok) {
                kept += 1;
                file_hit = true;
                if (o.mode == .files_with_matches) break; // one path per file; count the file once
                if (!o.quiet) emitRow(out, a, o, show_name, scope, f.path, lineno, col, view);
            }
            if (nl >= body.len) break;
            off = nl + 1;
            lineno += 1;
        }
        if (o.mode == .files_with_matches and file_hit and !o.quiet)
            out.print(a, "{s}{s}", .{ f.path, if (o.null_sep) "\x00" else o.outTerm() }) catch oom();
    }
    return kept;
}

/// One result row: `--json` frames an object, text prints `path:line[:col]:text`
/// (path only when the caller resolved filenames on).
fn emitRow(out: *std.ArrayList(u8), a: std.mem.Allocator, o: Opts, show_name: bool, scope: []const u8, path: []const u8, line: usize, col: usize, text: []const u8) void {
    if (o.mode == .json) {
        out.appendSlice(a, "{\"path\":") catch oom();
        emit.jsonStr(out, a, path);
        out.print(a, ",\"line\":{d},\"col\":{d},\"scope\":\"{s}\",\"text\":", .{ line, col, scope }) catch oom();
        emit.jsonStr(out, a, std.mem.trim(u8, text, " \t\r"));
        out.appendSlice(a, "}\n") catch oom();
        return;
    }
    if (show_name) out.print(a, "{s}:", .{path}) catch oom();
    if (o.column) {
        out.print(a, "{d}:{d}:{s}{s}", .{ line, col, text, o.outTerm() }) catch oom();
    } else {
        out.print(a, "{d}:{s}{s}", .{ line, text, o.outTerm() }) catch oom();
    }
}
