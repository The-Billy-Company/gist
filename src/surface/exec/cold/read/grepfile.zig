// MONOLITHIC: per-file search machinery shared by BOTH walk engines — BOM/UTF-16 ingest, binary policy, staged reads, the portable raw-stat shim, and stats tally must stay one module or the serial and parallel engines drift on per-file semantics
//! gist `rg` — the per-FILE search machinery, shared by the two walk engines.
//!
//! Split from `run.zig` when the parallel pipeline (`pipeline.zig`) landed:
//! everything here answers "given one file's bytes, produce ripgrep-shaped
//! output for it" with no dependence on HOW the file was discovered or which
//! thread is asking — byte ingest (BOM decode / UTF-16 transcode), rg line
//! semantics, binary-file handling, and the `--stats` tally. `run.zig` (the
//! serial engine that keeps the full exotic flag surface) and `pipeline.zig`
//! (the work-stealing parallel engine behind the common recursive-walk case)
//! both call these, so the two engines cannot drift on per-file semantics.

const std = @import("std");
const builtin = @import("builtin");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const fault = @import("../../../../fault.zig");
const args = @import("../argv/args.zig");
const assay = @import("../../../../assay/assay.zig");
const output = @import("../emit/output.zig");
const Opts = args.Opts;
const die = args.die;
const oom = args.oom;
const multiline = @import("../emit/multiline.zig");
const Emitter = output.Emitter;
const Dir = std.Io.Dir;
const Regex = @import("../../../../kernel/match/regex/regex.zig").Regex;
const Matcher = @import("../../../../kernel/match/regex/regex.zig").Matcher;
const simd = @import("../../../../kernel/match/scan/simd.zig");

/// ripgrep's default read-buffer capacity. Binary detection scans each fill's
/// newly-read bytes for a NUL; the searched region is what `committedPrefix`
/// computes from that fill geometry.
pub const BUFCAP: usize = 65536;

/// How many bytes of a NUL-bearing implicit file ripgrep actually SEARCHES
/// before its quit strategy stops it. Not a 64K-aligned cut: rg's line buffer
/// sits behind a BOM-sniffing decoder whose FIRST read returns ≤ 3 bytes, and
/// each fill() then reads into the free buffer (64 KiB, doubling only when a
/// line outgrows it) until a `\n` lands in the newly-read bytes. A fill
/// commits — and the searcher consumes — only up to the LAST `\n` it read;
/// the remainder rolls into the next fill. The NUL scan runs per newly-read
/// chunk BEFORE the terminator scan, and a hit discards that entire fill
/// unsearched (even complete lines it had just read). So the searched prefix
/// is the last committed boundary before the fill that would read the NUL —
/// e.g. `P5\n16 16\n255\n<NUL>…` commits exactly 3 (`P5\n` from the sniff
/// read), and a 67-KiB text prefix commits its last newline under 64 KiB.
pub fn committedPrefix(body: []const u8, nul: usize) usize {
    var committed: usize = 0; // absolute searched/consumed boundary (ends at \n+1)
    var buf_start: usize = 0; // absolute offset of the buffer's first byte
    var end: usize = 0; // absolute end of everything read so far
    var cap: usize = BUFCAP;
    var first = true;
    while (true) { // one fill() per iteration
        while (true) { // fill's inner read loop
            var free = cap - (end - buf_start);
            while (free == 0) : (free = cap - (end - buf_start)) cap *= 2;
            var n = @min(free, body.len - end);
            if (first) {
                n = @min(3, n);
                first = false;
            }
            if (n == 0) return body.len; // EOF (unreachable while nul < len; keeps the fn total)
            const lo = end;
            end += n;
            if (nul >= lo and nul < end) return committed; // NUL in newbytes ⇒ fill discarded
            if (std.mem.lastIndexOfScalar(u8, body[lo..end], '\n')) |i| {
                committed = lo + i + 1;
                buf_start = committed; // roll: consumed up to the last terminator
                break;
            }
        }
    }
}

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

/// Is a NUL at `nul` "binary" to rg's `-U` slice searcher? That searcher
/// sniffs only the first `min(len, 64K)` bytes up front: a NUL inside the
/// sniff quits BEFORE searching anything; a NUL beyond it is never noticed —
/// the implicit file is searched as ordinary text, matches after the NUL
/// included, `binary_offset` null.
pub fn multilineBinary(body_len: usize, nul: usize) bool {
    return nul < @min(body_len, BUFCAP);
}

/// ripgrep binary-file handling (a NUL is present, no `--text`/`--null-data`).
///
/// Two geometries, selected exactly as rg's `multi_line_with_matcher` does:
/// the SLICE model (`-U` whose pattern can actually match `\n`) sniffs
/// `min(len, 64K)` up front — see `handleBinaryMulti`; everything else —
/// line mode, and `-U` whose pattern provably can't match the terminator —
/// is the LINE model: an implicit (walked) file is searched only through
/// `committedPrefix` (the bytes rg's quit strategy consumed before the
/// NUL-bearing fill) with the WARNING note after a printed match; an explicit
/// path arg or stdin is searched in full ("convert" strategy), but the
/// standard printer suppresses match lines once binary is reported — so only
/// the prefix's lines print, plus the `binary file matches` summary.
/// Returns whether the file counts as a match (drives the exit code).
pub fn handleBinary(a: std.mem.Allocator, re: *const Matcher, o: Opts, out: *std.ArrayList(u8), em: *Emitter, path: []const u8, explicit: bool, body: []const u8, nul: usize, show_name: bool) bool {
    if (em.re.multiline() and em.re.canMatchNewline())
        return handleBinaryMulti(a, re, o, out, em, path, explicit, body, nul, show_name);

    const prefix = body[0..committedPrefix(body, nul)];
    if (!explicit) {
        // Implicit (walk/glob): only the committed prefix was ever searched —
        // every mode (-l included) answers from it, and `-c`/`--count-matches`
        // are suppressed entirely (rg's Summary printer drops binary files).
        if (o.count_only or o.count_matches) return false;
        const hits = emitRegion(a, em, o, path, prefix);
        if (o.files_only) return hits > 0;
        // A WARNING only when we actually printed a match in the prefix;
        // otherwise rg quits silently (no output, no match).
        if (hits == 0) return false;
        binNote(a, out, o, path, nul, show_name, "WARNING: stopped searching binary file after match");
        return true;
    }

    // -l/--files-with-matches scans an explicit file as text and emits no binary
    // warning; -c counts every match across the whole body (rg's convert strategy
    // treats an explicit binary as text).
    if (o.files_only or o.count_only or o.count_matches)
        return emitRegion(a, em, o, path, body) > 0;

    const before = out.items.len;
    _ = emitRegion(a, em, o, path, prefix);
    if (regionMatches(a, re, o, em, body)) {
        binNote(a, out, o, path, nul, show_name, "binary file matches");
        return true;
    }
    out.shrinkRetainingCapacity(before);
    return false;
}

/// Render a body region through the emitter in the run's own shape — split rg
/// lines for the per-line model, the whole-buffer emitter under `-U` (a `-U`
/// run downgraded to line-model binary semantics still RENDERS whole-buffer;
/// its pattern can't cross lines, so the two shapes coincide). Returns hits.
fn emitRegion(a: std.mem.Allocator, em: *Emitter, o: Opts, path: []const u8, region: []const u8) usize {
    // The fused whole-buffer fast paths inside `file`/`buffer` read the
    // emitter's `[base, body_end)` window DIRECTLY — the `-l` doc-match
    // (`output.zig`), the `-c`/`-o` miss-skip — bypassing the `lines` slice. The
    // caller (`handleBinary`, via both walk engines) has that window pointed at
    // the WHOLE body, but the binary quit strategy searches only this `region`
    // (the committed prefix). Re-point the window at exactly `region` — a
    // contiguous slice of that body — so a fused pass can't escape past rg's NUL
    // cutoff and match bytes in the discarded tail. An empty prefix collapses
    // `body_end == base`, which disables every fused path (they gate on
    // `body_end > base`), so nothing is searched — rg parity.
    em.base = @intFromPtr(region.ptr);
    em.body_end = em.base + region.len;
    if (em.re.multiline()) return em.buffer(path, region);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    collectLines(a, region, o.term(), &lines);
    return em.file(path, lines.items);
}

/// Does the pattern match anywhere in the FULL body? (Drives the explicit
/// binary summary — rg reports the whole file as a binary match even when the
/// only hits sit past the NUL.)
fn regionMatches(a: std.mem.Allocator, re: *const Matcher, o: Opts, em: *Emitter, body: []const u8) bool {
    if (em.re.multiline()) return bufAnyMatch(a, re, body);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    collectLines(a, body, o.term(), &lines);
    return anyLinesMatch(a, re, o, lines.items);
}

/// The slice-model twin of `handleBinary` (`-U` whose pattern can match `\n`).
/// An implicit file never gets here with a beyond-sniff NUL (the engines fall
/// through to the text path — see `multilineBinary`), so implicit ⇒ the sniff
/// quit: nothing searched, nothing printed, no match. An explicit file is
/// searched in full (`-c`/`-l` treat it as text), but the slice searcher
/// reports binary BEFORE searching, so the standard printer suppresses every
/// match line — only the summary prints.
fn handleBinaryMulti(a: std.mem.Allocator, re: *const Matcher, o: Opts, out: *std.ArrayList(u8), em: *Emitter, path: []const u8, explicit: bool, body: []const u8, nul: usize, show_name: bool) bool {
    if (!explicit) return false;
    // -l / -c treat the explicit file as text over the FULL body (convert).
    if (o.files_only or o.count_only or o.count_matches) return em.buffer(path, body) > 0;
    if (bufAnyMatch(a, re, body)) {
        binNote(a, out, o, path, nul, show_name, "binary file matches");
        return true;
    }
    return false;
}

/// Does the pattern match anywhere in the whole buffer under `-U` semantics?
/// (The multiline twin of `anyLinesMatch`, for the explicit binary summary.)
fn bufAnyMatch(a: std.mem.Allocator, re: *const Matcher, body: []const u8) bool {
    var sim = Matcher.Sim.init(a, re) catch return false;
    defer sim.deinit();
    return re.bufMatch(&sim, body);
}

/// Append ripgrep's binary note: `[<path>: ]<msg> (found "\0" byte around offset
/// N)`. The path prefix (with `: ` separator) is shown only when filenames are on.
pub fn binNote(a: std.mem.Allocator, out: *std.ArrayList(u8), o: Opts, path: []const u8, nul: usize, show_name: bool, msg: []const u8) void {
    if (show_name) out.print(a, "{s}: ", .{path}) catch oom();
    out.print(a, "{s} (found \"\\0\" byte around offset {d}){c}", .{ msg, nul, o.term() }) catch oom();
}

/// Does any line match (used for the explicit binary summary)? Honors `-w` and
/// the `--crlf` view; ignores `-v` (rg's binary summary reflects real matches).
pub fn anyLinesMatch(a: std.mem.Allocator, re: *const Matcher, o: Opts, lines: []const []const u8) bool {
    var sim = Matcher.Sim.init(a, re) catch return false;
    defer sim.deinit();
    var wss: ?Matcher.SpanSim = if (o.word) (Matcher.SpanSim.init(a, re) catch null) else null;
    defer if (wss) |*s| s.deinit();
    var em = Emitter{ .a = a, .re = re, .o = o, .show_name = false, .out = undefined };
    for (lines) |line| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        const hit = if (wss) |*s| em.lineHitWord(s, mv) else re.lineMatch(&sim, mv);
        if (hit) return true;
    }
    return false;
}

/// Unified search-stats counter set — one `assay.Tally` schema shared by rg's
/// `--stats` block (below) and the `--json` summary record (`emit/json.zig`),
/// collapsing what were two near-identical hand-rolled structs. Timing fields
/// are intentionally omitted: they are non-deterministic and the differential
/// harness normalizes the two `seconds` lines away (ripgrep's own tests only
/// `contains`-check them). Named by rg's `--stats` vocabulary; the JSON emitter
/// renders `files_searched`→`searches` and `files_with_match`→`searches_with_match`.
/// `bytes_printed` is set once by whoever owns the final output buffer — a worker
/// never accumulates it, so per-worker folds use `foldExcept(.., &.{.bytes_printed})`;
/// the JSON summary always reports it as 0.
pub const StatField = enum {
    matches,
    matched_lines,
    files_with_match,
    files_searched,
    bytes_printed,
    bytes_searched,
};
pub const Stats = assay.Tally(StatField);

pub const FileStat = struct { matches: usize, lines: usize, bytes: usize };

/// Count total match spans and matching lines in one file (for `--stats`),
/// honoring `-w` word bounds and the `--crlf` match view. Empty spans don't
/// count (ripgrep counts non-empty matches). Under `-m/--max-count`, ripgrep
/// stops reading after the Nth matching line, so `bytes` reports only the bytes
/// actually searched (ADR-parity with rg's `r2944` regression) rather than the
/// whole file.
pub fn fileMatchStats(re: *const Matcher, a: std.mem.Allocator, o: Opts, body: []const u8, lines: []const []const u8, needle: ?simd.Gate) FileStat {
    // The required-literal gate is sound for the tally exactly as it is for
    // emission: a body/line without the literal every match must contain holds
    // zero matches, so it contributes (0 matches, 0 lines) and only its bytes to
    // `bytes_searched`. This replaces a full NFA sweep of every line with one
    // SIMD `contains` — the same scan `--stats` used to skip. `bytes` still
    // reports the whole body (rg counts non-matching bytes as searched).
    if (needle) |g| if (!g.in(body)) return .{ .matches = 0, .lines = 0, .bytes = body.len };
    // `-U`: the tally is over whole-buffer spans, not split lines. `matches`
    // counts non-empty spans; `lines` the union of lines they cover (rg's
    // `matched lines`). `-m` already capped the span list, and rg reports the
    // whole body as searched here (no line-wise early stop).
    if (re.multiline()) {
        const grid = multiline.splitLines(a, body, o.term());
        var real: std.ArrayList(multiline.Span) = .empty;
        for (multiline.collect(a, re, o, body)) |sp| if (sp.end > sp.start) real.append(a, sp) catch return .{ .matches = 0, .lines = 0, .bytes = body.len };
        return .{ .matches = real.items.len, .lines = multiline.countMatchedLines(grid, real.items), .bytes = body.len };
    }
    var ss = Matcher.SpanSim.init(a, re) catch return .{ .matches = 0, .lines = 0, .bytes = body.len };
    defer ss.deinit();
    var m: usize = 0;
    var l: usize = 0;
    for (lines) |line| {
        const mv = if (o.crlf) std.mem.trimEnd(u8, line, "\r") else line;
        if (needle) |g| if (!g.in(mv)) continue;
        var from: usize = 0;
        var line_hit = false;
        while (from <= mv.len) {
            const sp = re.matchSpan(&ss, mv, from) orelse break;
            from = if (sp.end == sp.start) sp.start + 1 else sp.end;
            if (sp.end == sp.start) continue;
            if (o.word and !output.wordOk(o.unicode, mv, sp.start, sp.end)) continue;
            m += 1;
            line_hit = true;
        }
        if (line_hit) l += 1;
        if (o.max_per_file != 0 and l >= o.max_per_file) {
            // rg stops after the Nth matching line; bytes searched = end of that
            // line (its terminator included when one follows).
            var end = (@intFromPtr(line.ptr) - @intFromPtr(body.ptr)) + line.len;
            if (end < body.len) end += 1;
            return .{ .matches = m, .lines = l, .bytes = end };
        }
    }
    return .{ .matches = m, .lines = l, .bytes = body.len };
}

/// Emit ripgrep's `--stats` block (leading blank line, one field per line). The
/// two `seconds` lines now carry the run's real monotonic `elapsed` (formatted
/// `{d:.6}`, ripgrep's precision); the differential harness still normalizes
/// both wall-clock lines away, so this is byte-parity-safe and rg-faithful.
pub fn emitStats(a: std.mem.Allocator, out: *std.ArrayList(u8), s: Stats, elapsed: assay.Duration) void {
    const secs = @as(f64, @floatFromInt(elapsed.ns())) / 1e9;
    out.print(a,
        \\
        \\{d} matches
        \\{d} matched lines
        \\{d} files contained matches
        \\{d} files searched
        \\{d} bytes printed
        \\{d} bytes searched
        \\{d:.6} seconds spent searching
        \\{d:.6} seconds total
        \\
    , .{ s.get(.matches), s.get(.matched_lines), s.get(.files_with_match), s.get(.files_searched), s.get(.bytes_printed), s.get(.bytes_searched), secs, secs }) catch oom();
}

/// Lens-gated machine-readable diagnostic for a completed search — the stderr
/// peer of the stdout `--stats`/`--json` summary, emitted ONLY under
/// `GIST_TRACE=query` (default runs emit nothing here, preserving byte parity).
/// It renders as one NDJSON record on a `--json` run (or `GIST_TRACE_FORMAT=
/// json`) and as one text line otherwise, routed through the assay sink — so a
/// warm daemon query carries it back to the client's stderr like every other
/// diagnostic. Shared by both walk engines so their reported counts can't drift.
pub fn diagSearch(gpa: std.mem.Allocator, json: bool, s: Stats, elapsed: assay.Duration) void {
    if (!assay.lit(.query)) return;
    assay.summary(gpa, json, "gist: {d} files searched · {d} with match · {d} matches · {d} matched lines · {d} bytes searched · {d:.1} ms\n", .{ s.get(.files_searched), s.get(.files_with_match), s.get(.matches), s.get(.matched_lines), s.get(.bytes_searched), elapsed.ms() }, .{
        .{ "verb", "s", "search" },
        .{ "files_searched", "d", s.get(.files_searched) },
        .{ "files_with_match", "d", s.get(.files_with_match) },
        .{ "matches", "d", s.get(.matches) },
        .{ "matched_lines", "d", s.get(.matched_lines) },
        .{ "bytes_searched", "d", s.get(.bytes_searched) },
        .{ "ms", "d:.1", elapsed.ms() },
    });
}

/// ripgrep's `<bin>: <path>: <errno phrase>` note for a path that can't be
/// opened/descended — an explicit PATH arg or an unreadable directory hit
/// mid-walk. The differential harness keys only on the errno phrase and the
/// exit class (never the `rg:`/`gist:` prefix or the exact number — see
/// `bench/rgsuite/run.py`), so the phrases are contract.
///
/// The phrases themselves live in `fault.pathNote`, whose switch is exhaustive
/// over `fault.Corpus` (ADR-373 law 2). All this decides is whether a walk
/// error IS one of that domain's members, and it asks the domain instead of
/// re-listing it: a sixth corpus member picks up rg's phrasing here the moment
/// `fault.pathNote` names it, and cannot reach the arm below by omission.
///
/// A real descent produces a much wider set than the corpus domain (EMFILE,
/// ENODEV, a bad UTF-8 name), and ripgrep prints the OS string for those too,
/// so the widening is the walk's truth rather than an erased domain.
fn pathErrNote(err: WalkFault) []const u8 {
    inline for (@typeInfo(fault.Corpus).error_set.?) |m| {
        const member = @field(fault.Corpus, m.name);
        if (err == member) return fault.pathNote(member);
    }
    return @errorName(err);
}

/// Everything the three descent call sites can hand this renderer: the serial
/// engine's `std.Io` open + selective walk, the parallel engine's raw `openat`
/// + iterate, and the explicit-PATH probe's `openat`. It is the UNION of the
/// two engines' own `WalkFault` sets, each of which coerces into it — naming it
/// (ADR-373 law 2) rather than taking `anyerror` means a widened std set is a
/// build failure at the one place that decides how a walk failure reads, not a
/// mystery string on a user's stderr.
pub const WalkFault = Dir.OpenError || Dir.Iterator.Error || Dir.SelectiveWalker.Error || std.posix.OpenError;

/// ripgrep's walk-error stderr line (`rg: <path>: <errno>` → `gist: …`) — THE
/// one rendering, shared by the serial and parallel engines' `reportWalkError`
/// so a directory neither could descend is reported byte-identically. Each
/// engine layers its own exit-2 flagging on top (plain bool vs queue atomic).
pub fn printWalkError(rel: []const u8, e: WalkFault) void {
    assay.diag("gist: {s}: {s}\n", .{ rel, pathErrNote(e) });
}

/// ripgrep's `-L` cycle report (walk_entry_err in its ignore crate): a symlink
/// directory pointing at an ancestor of the walk is announced with both
/// DISPLAY paths and refused — the walk continues past it, exit 2 (errored).
pub fn printLoopError(link: []const u8, ancestor: []const u8) void {
    assay.diag("gist: File system loop found: {s} points to an ancestor {s}\n", .{ link, ancestor });
}

/// ripgrep's implicit-path heuristic (`eprint_nothing_searched`, main.rs): the
/// walk of the GUESSED path — no PATH args, CWD assumed — yielded zero
/// searchable files, so some filter (type/glob/ignore/hidden) excluded
/// everything. rg treats this as an error (stderr message + exit 2), never a
/// silent exit-1 "no matches"; an EXPLICIT path stays silent by design (rg:
/// "it can otherwise be noisy when it is intended that there is nothing to
/// search"). Both engines print through here so the wording cannot drift.
pub fn printNothingSearched() void {
    assay.diag(
        \\gist: No files were searched, which means gist probably applied a filter you didn't expect.
        \\gist: try -uu (fold hidden + gitignored files in), or `gist --files` to see what the walk admits.
        \\
    , .{});
}

/// One candidate's raw bytes: POSIX open/read/close into the caller's reused
/// `scratch` (sized `corpus.per_file_cap`); a file that fills `scratch`
/// completely is ambiguous (exactly cap-sized, or bigger), so `readTail` keeps
/// reading past it into a growable `a`-owned buffer instead of silently
/// truncating (ripgrep has no default max file size). Returns null when the
/// file can't be opened — the walk's truth degrades to "found nothing here",
/// never an invented match. The returned slice may alias `scratch`: consume it
/// before the next call.
pub fn readFileRaw(a: std.mem.Allocator, scratch: []u8, disk: []const u8) ?[]const u8 {
    const sf = StagedFile.open(scratch, std.posix.AT.FDCWD, disk) orelse return null;
    defer sf.close();
    return sf.readRest(a, scratch);
}

/// Read one file fully into `scratch` (capped at its length); returns bytes
/// read or null when the file can't be opened. The allocation-free sibling of
/// `readFileRaw` for callers that own a fixed per-worker buffer.
pub fn readFileInto(path: []const u8, scratch: []u8) ?usize {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    return drain(fd, scratch);
}

/// Fill `buf` from `fd`; returns bytes read. A short read on a regular
/// local file means EOF (the walk only yields regular files, and gist's
/// corpus model is a local filesystem — see `corpus/README.md`), so the
/// common sub-cap file costs ONE read syscall, not read-then-read-zero.
fn drain(fd: std.posix.fd_t, buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const want = buf.len - n;
        const r = std.posix.read(fd, buf[n..]) catch break;
        n += r;
        if (r < want) break;
    }
    return n;
}

/// A candidate opened and read in TWO stages: the first `BUFCAP` bytes now, the
/// tail only if the caller still needs it. ripgrep's streaming reader decides
/// most files from its first 64 KiB buffer — binary triage (a NUL in buffer 0
/// makes an implicit file contribute nothing) and the `-l` first-match exit
/// both fire there — and on this corpus 86% of all bytes are tails of >64 KiB
/// files, so NOT reading them is the single biggest IO saving available.
///
/// Opens relative to `dirfd`: the parallel walk holds each directory open
/// while searching its files, so the kernel resolves ONE path component
/// instead of re-walking the full `dir/sub/…/name` chain per file (namei is
/// the dominant per-file open cost on a deep monorepo tree; ~21k opens/scan).
pub const StagedFile = struct {
    fd: std.posix.fd_t,
    prefix: []const u8, // first ≤BUFCAP bytes, in the caller's scratch
    more: bool, // the prefix filled BUFCAP exactly ⇒ a tail may exist

    pub fn open(scratch: []u8, dirfd: std.posix.fd_t, name: []const u8) ?StagedFile {
        const fd = std.posix.openat(dirfd, name, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        const cap = @min(scratch.len, BUFCAP);
        const n = drain(fd, scratch[0..cap]);
        return .{ .fd = fd, .prefix = scratch[0..n], .more = n == cap };
    }

    /// The whole body: the prefix plus whatever remains on `fd`, contiguous in
    /// `scratch` (spilling to `readTail` past the scratch cap). Call at most once.
    pub fn readRest(self: *const StagedFile, a: std.mem.Allocator, scratch: []u8) ?[]const u8 {
        if (!self.more) return self.prefix;
        const n = self.prefix.len + drain(self.fd, scratch[self.prefix.len..]);
        if (n == scratch.len) return readTail(a, self.fd, scratch);
        return scratch[0..n];
    }

    pub fn close(self: *const StagedFile) void {
        _ = std.posix.system.close(self.fd);
    }
};

/// `scratch` (already full) plus whatever remains on `fd`, as one contiguous
/// buffer — the uncommon path for a file at/above `per_file_cap`, kept out of
/// the hot common-case function above. A regular file this large is
/// memory-MAPPED read-only rather than slurped through a read loop: the copy
/// loop paid 2× the bytes (kernel→ArrayList reads plus growth memcpys) on
/// multi-GB leaked-in blobs (explicit-root scoping admits gitignored
/// training corpora — `gist pat services libs` spent ~0.5 s copying one 2.1 GB
/// text file rg mmaps in ~0.2 s), while the map costs one syscall, faults in
/// only the pages the SIMD gate actually touches before its first hit, and
/// rides the page cache across runs. ripgrep's own default does the same for
/// large single files (grep-searcher's mmap strategy). The mapping is never
/// munmapped — both walk engines are one-shot processes (the resident session
/// reads through its own mirror, not this path) — and any fstat/mmap failure
/// (FIFO stdin, racing truncation below the already-read prefix) falls back to
/// the proven read loop, so no input shape is lost.
pub fn readTail(a: std.mem.Allocator, fd: std.posix.fd_t, scratch: []const u8) ?[]const u8 {
    if (mapWhole(fd, scratch.len)) |mapped| return mapped;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, scratch) catch return null;
    var tmp: [64 * 1024]u8 = undefined;
    var r = std.posix.read(fd, &tmp) catch 0;
    while (r > 0) : (r = std.posix.read(fd, &tmp) catch 0)
        out.appendSlice(a, tmp[0..r]) catch return null;
    return out.toOwnedSlice(a) catch null;
}

// ─────────────────────── raw stat plane (portable) ───────────────────────

/// The slice of `stat(2)` gist actually consumes, projected portably: device
/// identity (`--one-file-system`), type+mode bits (fd classification, lstat
/// reconcile), byte size (mmap bounds), and birth time where the platform
/// records one. THE one raw-stat definition — Zig 0.16's `std.c` deliberately
/// declares no `fstat`/`fstatat` on Linux (libc wrappers there are legacy
/// shims), so the Linux leg rides `statx(2)` directly while every other libc
/// target keeps the `fstatat`/`fstat` calls this replaced, byte-identically.
pub const RawStat = struct {
    dev: i128,
    mode: u32,
    size: u64,
    /// Birth (creation) time in ns when the platform+filesystem record one
    /// (macOS `st_birthtimespec`, Linux `statx` BTIME); null otherwise —
    /// callers fall back rather than mislabel ctime as creation.
    birthtime_ns: ?i96,
    /// Modification + status-change clocks in ns — the same conservative
    /// freshness pair the T3 overlay compares against the build anchor
    /// (`bulkstat.needsLiveRead`). Null when the platform didn't report one.
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

/// `stat(2)` following symlinks — `--one-file-system` device ids and
/// `--sort created` birth times. Null on any failure (caller falls back).
pub fn statPath(path: []const u8) ?RawStat {
    return statAt(path, false);
}

/// `lstat(2)` — never follows the final symlink (the walk treats a symlink
/// as its own entry). Null when the path is gone/unreachable.
pub fn lstatPath(path: []const u8) ?RawStat {
    return statAt(path, true);
}

fn statAt(path: []const u8, nofollow: bool) ?RawStat {
    const cpath = std.posix.toPosixPath(path) catch return null;
    if (comptime builtin.os.tag == .linux) {
        const flags: u32 = if (nofollow) std.os.linux.AT.SYMLINK_NOFOLLOW else 0;
        return statxCall(std.os.linux.AT.FDCWD, &cpath, flags);
    }
    var st: std.posix.Stat = undefined;
    const flags: u32 = if (nofollow) std.posix.AT.SYMLINK_NOFOLLOW else 0;
    if (std.c.fstatat(std.posix.AT.FDCWD, &cpath, &st, flags) != 0) return null;
    return fromStat(st);
}

/// `fstat(2)` on an already-open fd — stdin classification and mmap sizing.
pub fn statFd(fd: std.posix.fd_t) ?RawStat {
    if (comptime builtin.os.tag == .linux) {
        return statxCall(fd, "", std.os.linux.AT.EMPTY_PATH);
    }
    var st: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return fromStat(st);
}

/// The one `statx(2)` invocation both Linux legs ride (path-relative and
/// fd-only via `AT.EMPTY_PATH`); null on any errno.
fn statxCall(dirfd: std.posix.fd_t, path: [*:0]const u8, flags: u32) ?RawStat {
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(dirfd, path, flags, statx_mask, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return fromStatx(stx);
}

/// Exactly the fields `RawStat` projects — BTIME rides along; the kernel's
/// returned mask (not this request) decides whether it was actually filled.
const statx_mask: std.os.linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .BTIME = true, .MTIME = true, .CTIME = true };

fn fromStatx(stx: std.os.linux.Statx) RawStat {
    return .{
        // statx splits dev_t into major/minor; recombine losslessly — only
        // equality matters (mount-point detection), not the packed encoding.
        .dev = (@as(i128, stx.dev_major) << 32) | stx.dev_minor,
        .mode = stx.mode,
        .size = stx.size,
        .birthtime_ns = if (stx.mask.BTIME) @as(i96, stx.btime.sec) * std.time.ns_per_s + stx.btime.nsec else null,
        .mtime_ns = if (stx.mask.MTIME) @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec else null,
        .ctime_ns = if (stx.mask.CTIME) @as(i128, stx.ctime.sec) * std.time.ns_per_s + stx.ctime.nsec else null,
    };
}

fn fromStat(st: std.posix.Stat) RawStat {
    return .{
        .dev = st.dev,
        .mode = st.mode,
        .size = std.math.cast(u64, st.size) orelse 0,
        // Darwin records birth time in `struct stat` itself; gist declines to
        // invent one on libc targets that don't (matching ripgrep).
        .birthtime_ns = if (comptime builtin.os.tag.isDarwin()) @as(i96, st.birthtime().sec) * std.time.ns_per_s + st.birthtime().nsec else null,
        .mtime_ns = @as(i128, st.mtime().sec) * std.time.ns_per_s + st.mtime().nsec,
        .ctime_ns = @as(i128, st.ctime().sec) * std.time.ns_per_s + st.ctime().nsec,
    };
}

/// Map the whole regular file behind `fd` read-only, from offset 0 (the bytes
/// already drained into scratch are simply re-viewed through the mapping — one
/// consistent snapshot instead of a scratch+tail stitch). Null when the fd is
/// not a regular file, the file shrank below what was already read (a racing
/// truncation the read loop handles conservatively), or `mmap` itself fails —
/// the caller then takes the copying path, never a silent drop.
/// Map a regular file at `disk` read-only when it is at least `min` bytes — the
/// large-file path that skips the read-loop + arena dupe entirely: the bytes
/// fault in lazily during the scan, and a SHARDED scan faults its ranges in
/// PARALLEL (the copy this replaces was serial, the Amdahl tail under single-file
/// sharding). Null — caller takes the copying read path — for a sub-`min` file, a
/// non-regular fd, or any open/stat/mmap failure, so no input shape is lost. The
/// map is never unmapped (the cold engine is a one-shot process; the OS reclaims
/// it at exit), matching the `readTail` large-file mapping's lifetime.
pub fn mapFile(disk: []const u8, min: usize) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, disk, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    return mapWhole(fd, min);
}

fn mapWhole(fd: std.posix.fd_t, min_len: usize) ?[]const u8 {
    const st = statFd(fd) orelse return null;
    if (st.mode & std.posix.S.IFMT != std.posix.S.IFREG) return null;
    const size = std.math.cast(usize, st.size) orelse return null;
    if (size < min_len) return null;
    const mapped = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return null;
    // The scan is one strictly-forward SIMD pass, so tell the pager: SEQUENTIAL
    // widens readahead + drops pages behind the cursor, WILLNEED starts the
    // fault-in immediately instead of one page-cluster per fault. Measured on
    // the 2.1 GiB page-cached blob this mapping exists for: 13.7 → ~40 GiB/s
    // (~160 ms → ~54 ms), the difference between fault-per-cluster and
    // batched fault-ahead. Advice is best-effort; failure changes nothing.
    fault.spare("advise sequential access", std.posix.madvise(mapped.ptr, size, std.posix.MADV.SEQUENTIAL));
    fault.spare("advise fault-ahead", std.posix.madvise(mapped.ptr, size, std.posix.MADV.WILLNEED));
    return mapped[0..size];
}

test "multiline binary: match before the NUL prints; after the NUL is elided" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Matcher{ .linear = try Regex.compileOpts(a, "a\\nb", .{ .multiline = true }) };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    const o = Opts{ .multiline = true, .line_num = true };
    var em = Emitter{ .a = a, .re = &m, .o = o, .show_name = false, .out = &out, .base = 0 };

    // NUL in the first buffer (offset 5): its whole buffer is discarded, so the
    // cross-line match wholly before it (bytes 0-2) never prints — rg's rule.
    const body = "a\nb\x00a\nb\n";
    em.base = @intFromPtr(body.ptr);
    _ = handleBinary(a, &m, o, &out, &em, "x.bin", false, body, 5, true);
    // cut = (5/65536)*65536 = 0 ⇒ nothing before the NUL buffer is emitted.
    try t.expectEqualStrings("", out.items);
}

test "multiline --stats tallies spans and covered lines over the whole buffer" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Matcher{ .linear = try Regex.compileOpts(a, "a\\nb", .{ .multiline = true }) };
    defer m.deinit();
    const body = "a\nb\nx\na\nb\n";
    const fs = fileMatchStats(&m, a, .{ .multiline = true }, body, &.{}, null);
    try t.expectEqual(@as(usize, 2), fs.matches); // two cross-line matches
    try t.expectEqual(@as(usize, 4), fs.lines); // they cover four physical lines
    try t.expectEqual(body.len, fs.bytes);
}

test "walked -l stops at the NUL buffer without scanning its tail" {
    const t = std.testing;
    var m = Matcher{ .linear = try Regex.compile(t.allocator, "panic") };
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    const o = Opts{ .files_only = true };
    var em = Emitter{ .a = t.allocator, .re = &m, .o = o, .show_name = true, .out = &out };
    // Both walk engines point the emitter's whole-body window at the file
    // BEFORE binary handling (serial `renderFile`, parallel `emitBody`), and the
    // fused `-l` doc-match reads that window. The test MUST mirror that state or
    // it silently exercises an unset (empty) window and cannot catch a fused
    // pass escaping the NUL cutoff — `setWindow` re-points it per body.
    const setWindow = struct {
        fn f(e: *Emitter, body: []const u8) void {
            e.base = @intFromPtr(body.ptr);
            e.body_end = e.base + body.len;
        }
    }.f;

    const same_buffer = "panic\x00panic after cutoff";
    setWindow(&em, same_buffer);
    try t.expect(!handleBinary(t.allocator, &m, o, &out, &em, "same.bin", false, same_buffer, 5, true));
    try t.expectEqual(@as(usize, 0), out.items.len);

    // No line terminator ever lands before the NUL ⇒ no fill commits ⇒ rg
    // searches ZERO bytes — even though the match sits a full buffer before
    // the NUL (verified against rg: `-l` exits 1, stats say bytes_searched:0).
    const uncommitted = try t.allocator.alloc(u8, BUFCAP + 1);
    defer t.allocator.free(uncommitted);
    @memset(uncommitted, 'x');
    @memcpy(uncommitted[0..5], "panic");
    uncommitted[BUFCAP] = 0;
    setWindow(&em, uncommitted);
    try t.expect(!handleBinary(t.allocator, &m, o, &out, &em, "uncommitted.bin", false, uncommitted, BUFCAP, true));
    try t.expectEqual(@as(usize, 0), out.items.len);

    // A committed line before the NUL-bearing fill IS searched: `panic\n`
    // commits in the first fill, the NUL discards only the next one.
    const committed = try t.allocator.alloc(u8, BUFCAP + 1);
    defer t.allocator.free(committed);
    @memset(committed, 'x');
    @memcpy(committed[0..6], "panic\n");
    committed[BUFCAP] = 0;
    setWindow(&em, committed);
    try t.expect(handleBinary(t.allocator, &m, o, &out, &em, "committed.bin", false, committed, BUFCAP, true));
    try t.expectEqualStrings("committed.bin\n", out.items);
}
