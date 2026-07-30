//! gist `--rank` — the definition-first ranked view, gist's one output shape
//! ripgrep can't express.
//!
//! `gist <pattern>` (and `gist rg`) answer WHERE a pattern appears, ripgrep-
//! identically (`run.zig`). `--rank` answers WHICH of those hits matters most:
//! over the bytes the caller's walk already gathered it extracts a few per-file
//! ranking features, fuses them with the weighted RRF kernel in `rank/rank.zig`,
//! and prints the top-K as `path:line [kind] ×count line` — a symbol's
//! DEFINITION outranking its call sites, codegen demoted.
//!
//! This file therefore ranks a file SET; it never decides one. That is the whole
//! seam: an earlier version enumerated candidates straight out of the persisted
//! index's path table, which made the index answer "what is in the corpus"
//! instead of merely "which of these files can possibly match" (ADR-373 law 1),
//! and quietly cost the view every file the index's own corpus policy excludes —
//! all of `vendor/`, plus any walk-widening flag (`-uu`) the table knows nothing
//! about. The caller (`view.zig`) now hands over the walk's own file set, still
//! index-ACCELERATED through read elision, so the ranked set is the same query's
//! `gist -l` set by construction rather than by coincidence.
//!
//! Pattern semantics match the line engine: the caller compiles via
//! `combinePatterns` + `Regex.compileOpts`, so alternations (`foo|bar`),
//! wildcards (`claim.*job`), `-F`/`-i`/`-x`, and multi-`-e` OR all rank the
//! same hits the unranked search would emit. Path semantics match it because
//! they ARE the walk's: roots, `-t`/`-T`/`-g`, and the genus flags are settled
//! before a byte reaches this file.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const Regex = @import("../../../kernel/regex/regex.zig").Regex;
const mirror = @import("../../../kernel/rank/replica.zig");
const signals = @import("../../../kernel/rank/signals.zig");
const rank_mod = @import("../../../kernel/rank/rank.zig");
const assay = @import("../../../assay/assay.zig");
const beacon = @import("../../../surface/cli/beacon.zig");

const Doc = rank_mod.Doc;
pub const LiveFile = struct { path: []const u8, bytes: []const u8 };

/// The ranked rows' backing store: `Doc.id` indexes it, so a row can recover its
/// path and re-read its own best line for the snippet. It is always the caller's
/// gathered set — a `Doc` cannot exist for a file this slice does not hold.
const Source = []const LiveFile;

/// Slash COUNT (not walker depth — `run.zig`'s `pathDepth` is slashes+1):
/// a shallow-path prior for the ranked view, u16 to pack the score row.
fn pathDepth(path: []const u8) u16 {
    var d: u16 = 0;
    for (path) |c| d +%= @intFromBool(c == '/');
    return d;
}

const LineSignals = struct { definition: u8 = 0, shape_hash: u64 = 0 };

/// Query-relative, parser-free geometry for one matching line. Prefer the
/// analyzer's required literal; otherwise keep the strongest alternation.
fn lineSignals(line: []const u8, re: *const Regex) LineSignals {
    if (re.required.len > 0) return .{
        .definition = signals.declarationConfidence(line, re.required),
        .shape_hash = signals.shapeFingerprint(line, re.required),
    };
    var best: LineSignals = .{};
    for (re.alts) |alt| if (std.mem.indexOf(u8, line, alt) != null) {
        const candidate = LineSignals{
            .definition = signals.declarationConfidence(line, alt),
            .shape_hash = signals.shapeFingerprint(line, alt),
        };
        if (candidate.definition > best.definition or best.shape_hash == 0) best = candidate;
    };
    return best;
}

/// One pass over a candidate file's bytes → its ranking features (matching-line
/// count, whether any match is a definition, the best line to surface). Returns
/// null when the regex doesn't actually match (a trigram false positive).
///
/// `binary_detect` mirrors the locate/`-l` path's default (`!-a`): a walked file
/// carrying a NUL is searched only through the bytes rg's quit strategy committed
/// before it (`committedPrefix`), so `--rank`'s file SET matches `gist -l`
/// exactly — a compiled binary whose only "match" sits past the NUL in its symbol
/// table is excluded, never surfaced as ranked noise. Under `-a` the whole body
/// is scanned as text, again matching the locate path.
fn fileDoc(buf_in: []const u8, path: []const u8, re: *const Regex, sim: *Regex.Sim, id: u32, binary_detect: bool) ?Doc {
    const buf = if (binary_detect) blk: {
        const nul = std.mem.indexOfScalar(u8, buf_in, 0) orelse break :blk buf_in;
        break :blk buf_in[0..committedPrefix(buf_in, nul)];
    } else buf_in;
    // Reject non-matchers with ONE fused whole-buffer pass first (`docMatch`
    // early-exits on the first hit). A trigram false positive — the common
    // candidate — used to pay a full per-line pass AND a full docMatch pass;
    // now it pays exactly the one-pass verify floor, and only real matchers
    // fund the per-line feature extraction below. This is also the parity
    // gate: `docMatch` speaks rg's line model, so the ranked SET is decided
    // by the same machine `gist -l` uses.
    if (!re.docMatch(sim, buf)) return null;
    var line_no: u32 = 0;
    var match_lines: u32 = 0;
    var first: u32 = 0;
    var defline: u32 = 0;
    var definition: u8 = 0;
    var shape_hash: u64 = 0;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        // rg line model: `\n` TERMINATES a line — a newline-terminated buffer
        // has no phantom empty final line (splitScalar emits one). Without
        // this, `^$`-shaped patterns counted a match rg never reports.
        if (line.len == 0 and it.peek() == null and buf.len > 0 and buf[buf.len - 1] == '\n') break;
        line_no += 1;
        if (!re.lineMatch(sim, line)) continue;
        match_lines += 1;
        const sig = lineSignals(line, re);
        if (first == 0) {
            first = line_no;
            shape_hash = sig.shape_hash;
        }
        if (sig.definition > definition) {
            definition = sig.definition;
            defline = line_no;
            shape_hash = sig.shape_hash;
        }
    }
    // match_lines == 0 with a fired docMatch ⇒ a multi-line / whole-buffer
    // match the per-line scan can't see: keep the file, surface L1 (the
    // `@max`es below resolve to matches=1 / best_line=1 for that case).
    return .{ .id = id, .matches = @max(match_lines, 1), .is_def = definition > 0, .definition = definition, .shape_hash = shape_hash, .best_line = if (defline != 0) defline else @max(first, 1), .depth = pathDepth(path), .is_generated = signals.isGenerated(path, buf), .is_mirror = mirror.isPath(path), .content_hash = mirror.fingerprint(buf), .content_len = buf.len };
}

const committedPrefix = @import("../read/binary.zig").committedPrefix;

/// Ranked-row snippet budget — enough for a decl + a little neighborhood, small
/// enough that 20 ranked rows stay cheap in an agent's context window.
const snippet_budget: usize = 120;

/// Byte index ≤ `i` on a UTF-8 boundary (never split a multi-byte scalar).
fn utf8Floor(s: []const u8, i: usize) usize {
    var n = @min(i, s.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// A ≤`budget`-byte window of `line` that keeps the match span visible.
/// Prefix-only truncation hid matches past column 120 (agents saw `×××…` with
/// the hit token gone — the whole point of surfacing the line). Prefer a
/// window that contains `[sp.start, sp.end)`; fall back to a leading prefix
/// when there is no span or the match itself is wider than the budget.
fn windowAround(line: []const u8, span: ?Regex.Span, budget: usize) []const u8 {
    if (line.len <= budget) return line;
    const sp = span orelse return line[0..budget];
    if (sp.end <= sp.start or sp.start >= line.len) return line[0..budget];
    const end = @min(sp.end, line.len);
    const match_len = end - sp.start;
    if (match_len >= budget) {
        // Match alone fills the budget — show its leading bytes (still the token).
        return line[sp.start..utf8Floor(line, sp.start + budget)];
    }
    // Bias a little left of center so a `fn foo(` / `class Foo` decl keeps its
    // keyword; clamp so the full match stays inside the window.
    const ideal = sp.start -| (budget - match_len) / 3;
    var start = utf8Floor(line, ideal);
    if (start + budget < end) start = utf8Floor(line, end - budget);
    if (start + budget > line.len) start = utf8Floor(line, line.len - budget);
    const cut = utf8Floor(line, start + budget);
    if (cut <= start) return line[start..@min(start + budget, line.len)];
    return line[start..cut];
}

/// First non-empty match span on `line`, or null when the engine can't init /
/// finds nothing (trigram false-positive lines shouldn't reach here, but the
/// snippet path must still degrade to a prefix rather than crash).
fn firstSpan(gpa: std.mem.Allocator, re: *const Regex, line: []const u8) ?Regex.Span {
    var ssim = Regex.SpanSim.init(gpa, re) catch return null;
    defer ssim.deinit();
    var from: usize = 0;
    while (from <= line.len) {
        const sp = re.matchSpan(&ssim, line, from) orelse return null;
        if (sp.end > sp.start) return sp;
        from = sp.start + 1;
    }
    return null;
}

/// The trimmed, match-anchored, 120-col-capped text of 1-based `line` in `path`
/// — the one line shown per ranked file. Display-only (not benchmarked), so
/// io reads are fine. `…` marks a truncated edge so agents can tell the
/// matched token sits in a window, not the raw file prefix.
fn snippetFrom(gpa: std.mem.Allocator, data: []const u8, line: u32, re: *const Regex) ![]u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    var ln: u32 = 0;
    while (it.next()) |l| {
        ln += 1;
        if (ln != line) continue;
        const t = std.mem.trim(u8, l, " \t\r");
        const sp = firstSpan(gpa, re, t);
        const win = windowAround(t, sp, snippet_budget);
        const off = @intFromPtr(win.ptr) - @intFromPtr(t.ptr);
        const left = off > 0;
        const right = off + win.len < t.len;
        if (!left and !right) return gpa.dupe(u8, win);
        var out: std.ArrayList(u8) = .empty;
        if (left) try out.appendSlice(gpa, "…");
        try out.appendSlice(gpa, win);
        if (right) try out.appendSlice(gpa, "…");
        return out.toOwnedSlice(gpa);
    }
    return gpa.dupe(u8, "");
}

/// Render the ranked top-K rows INTO `out` (no stdout, no diagnostics) — the
/// pure kernel `emitRanked` and the warm daemon both build on. Returns the
/// surfaced-row count (`k`, default 20, clamped to the ranked set). `out` and
/// every transient (order permutation, per-row snippet) draw from `gpa`.
fn renderRanked(gpa: std.mem.Allocator, re: *const Regex, docs: []const Doc, source: Source, k: usize, out: *std.ArrayList(u8)) !usize {
    const order = try rank_mod.rank(gpa, docs, .{}, null);
    defer gpa.free(order);
    const top = @min(order.len, if (k == 0) 20 else k);
    for (order[0..top], 0..) |di, i| {
        const doc = docs[di];
        const path = source[doc.id].path;
        const snip = try snippetFrom(gpa, source[doc.id].bytes, doc.best_line, re);
        defer gpa.free(snip);
        const kind = if (doc.is_mirror) "mirror" else if (doc.is_generated) "gen" else if (doc.is_def) "def" else "use";
        // The ranked row's whole point is that its top line is the one to open,
        // so the locator is the click target — the same `path:line` the other
        // faces frame, written in place.
        try out.print(gpa, "{d:>2}. ", .{i + 1});
        beacon.writeLocator(gpa, out, path, doc.best_line);
        try out.print(gpa, "  [{s}]  ×{d}  {s}", .{ kind, doc.matches, snip });
        if (doc.is_mirror) if (mirror.canonical(Doc, docs, doc)) |canonical| try out.print(gpa, "  (mirror of {s})", .{beacon.anchor(gpa, source[canonical].path)});
        try out.append(gpa, '\n');
    }
    return top;
}

fn emitRanked(gpa: std.mem.Allocator, re: *const Regex, docs: []const Doc, source: Source, k: usize) !usize {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const top = try renderRanked(gpa, re, docs, source, k, &buf);
    corpus_mod.emitStdout(buf.items);
    return top;
}

/// Rank bytes already gathered by the rg-compatible walk — the one cold entry
/// point. `binary_detect` (the locate path's `!-a` default) scans a NUL-bearing
/// file only to its committed prefix, the same bound the locate path uses, so a
/// binary's symbol table is never surfaced as ranked noise. Returns the
/// ranked-match count (0 ⇒ the caller may hint).
pub fn run(gpa: std.mem.Allocator, io: std.Io, re: *const Regex, files: []const LiveFile, k: usize, binary_detect: bool) !usize {
    const query_span = assay.Span.open(io);
    var phase = assay.Span.open(io);
    var docs: std.ArrayList(Doc) = .empty;
    defer docs.deinit(gpa);
    var sim = try Regex.Sim.init(gpa, re);
    defer sim.deinit();
    for (files, 0..) |file, id| if (fileDoc(file.bytes, file.path, re, &sim, @intCast(id), binary_detect)) |doc| try docs.append(gpa, doc);
    assay.trace(.rank, "rank phase: feature {d:.1} ms · {d} scanned · {d} matched (live)\n", .{
        phase.lap(io).ms(), files.len, docs.items.len,
    });
    const top = try emitRanked(gpa, re, docs.items, files, k);
    assay.trace(.rank, "rank phase: fuse+render {d:.1} ms · top {d} (live)\n", .{ phase.lap(io).ms(), top });
    const query = query_span.read(io);
    assay.summary(gpa, false, "gist: {d} ranked matches (top {d}) · live-scanned {d} files · rank {d:.1} ms\n", .{ docs.items.len, top, files.len, query.ms() }, .{
        .{ "verb", "s", "rank" },
        .{ "ranked_matches", "d", docs.items.len },
        .{ "top", "d", top },
        .{ "live_scanned", "d", files.len },
        .{ "rank_ms", "d:.1", query.ms() },
    });
    return docs.items.len;
}

/// Warm-daemon rank: extract features over in-memory `files`, fuse, and render
/// the top-K INTO `out` — the byte-identical twin of `run`'s emission, but
/// returned to the caller (to stream over the session wire) instead of written
/// to stdout. `out` and every transient draw from `gpa`. Returns the ranked-
/// match count (0 ⇒ the daemon streams an empty answer; cold's hint is stderr-
/// only and outside the byte-parity envelope). The timing summary routes through
/// the current sink — the daemon worker runs this under a `.buffer` sink, so the
/// line rides a `diag` frame to the client's stderr instead of vanishing (the
/// warm-path measurability the buffer sink exists for).
pub fn renderLive(gpa: std.mem.Allocator, io: std.Io, re: *const Regex, files: []const LiveFile, k: usize, out: *std.ArrayList(u8), binary_detect: bool) !usize {
    const query_span = assay.Span.open(io);
    var phase = assay.Span.open(io);
    var docs: std.ArrayList(Doc) = .empty;
    defer docs.deinit(gpa);
    var sim = try Regex.Sim.init(gpa, re);
    defer sim.deinit();
    for (files, 0..) |file, id| if (fileDoc(file.bytes, file.path, re, &sim, @intCast(id), binary_detect)) |doc| try docs.append(gpa, doc);
    assay.trace(.rank, "rank phase: feature {d:.1} ms · {d} scanned · {d} matched (warm)\n", .{
        phase.lap(io).ms(), files.len, docs.items.len,
    });
    const top = try renderRanked(gpa, re, docs.items, files, k, out);
    assay.trace(.rank, "rank phase: fuse+render {d:.1} ms · top {d} (warm)\n", .{ phase.lap(io).ms(), top });
    const query = query_span.read(io);
    assay.summary(gpa, false, "gist: {d} ranked matches (top {d}) · warm-scanned {d} files · rank {d:.1} ms\n", .{ docs.items.len, top, files.len, query.ms() }, .{
        .{ "verb", "s", "rank" },
        .{ "ranked_matches", "d", docs.items.len },
        .{ "top", "d", top },
        .{ "warm_scanned", "d", files.len },
        .{ "rank_ms", "d:.1", query.ms() },
    });
    return docs.items.len;
}

test "a ranked row names and quotes the caller's own file set" {
    const t = std.testing;
    const a = t.allocator;

    // Path scope used to be re-derived here against the persisted index's path
    // table, so a row could name a file the walk never admitted. `Source` is now
    // the caller's gathered set and `Doc.id` indexes it, which is what makes the
    // ranked set the walk's set: there is no other slice a row could come from.
    var re = try Regex.compile(a, "WalletService");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();

    const files = [_]LiveFile{
        .{ .path = "services/backend/api/wallet.go", .bytes = "type WalletService struct {\n\tdb *pgxpool.Pool\n}\n" },
        .{ .path = "scripts/vendor/graphify/uses.py", .bytes = "import wallet\nwallet.WalletService.grant(user)\n" },
    };
    var docs: std.ArrayList(Doc) = .empty;
    defer docs.deinit(a);
    for (files, 0..) |f, id| if (fileDoc(f.bytes, f.path, &re, &sim, @intCast(id), true)) |d| try docs.append(a, d);
    try t.expectEqual(@as(usize, 2), docs.items.len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try t.expectEqual(@as(usize, 2), try renderRanked(a, &re, docs.items, &files, 0, &out));

    // Both paths surface, the declaration outranks the call site, and each row's
    // snippet is quoted from the bytes the caller passed — not re-read from disk
    // (neither path exists), which is why a vendored file can be ranked at all.
    try t.expect(std.mem.indexOf(u8, out.items, "services/backend/api/wallet.go:1") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "scripts/vendor/graphify/uses.py:2") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "[def]") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "type WalletService struct {") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "wallet.WalletService.grant(user)") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "wallet.go").? < std.mem.indexOf(u8, out.items, "uses.py").?);
}

test "fileDoc matches alternation and wildcard regexes, not raw pattern bytes" {
    const t = std.testing;
    const a = t.allocator;

    // The bug: treating `FOO|BAR` as a literal meant zero hits unless a file
    // contained the characters `FOO|BAR`. Ranking must use the compiled engine.
    var re_alt = try Regex.compile(a, "FOO_CLAIM|BAR_CLAIM");
    defer re_alt.deinit();
    var sim_alt = try Regex.Sim.init(a, &re_alt);
    defer sim_alt.deinit();
    const hay_alt =
        \\const x = 1;
        \\fn BAR_CLAIM() void {}
        \\use FOO_CLAIM here
    ;
    const doc_alt = fileDoc(hay_alt, "src/claim.zig", &re_alt, &sim_alt, 7, true) orelse {
        try t.expect(false); // must match both branches
        return;
    };
    try t.expectEqual(@as(u32, 2), doc_alt.matches);
    try t.expect(doc_alt.is_def);
    try t.expectEqual(@as(u32, 2), doc_alt.best_line);

    var re_wild = try Regex.compile(a, "claim.*job");
    defer re_wild.deinit();
    var sim_wild = try Regex.Sim.init(a, &re_wild);
    defer sim_wild.deinit();
    const hay_wild =
        \\// claim the job via SET NX
        \\const other = 1;
    ;
    const doc_wild = fileDoc(hay_wild, "queue.py", &re_wild, &sim_wild, 3, true) orelse {
        try t.expect(false); // must match claim…job span
        return;
    };
    try t.expectEqual(@as(u32, 1), doc_wild.matches);
    try t.expectEqual(@as(u32, 1), doc_wild.best_line);

    // No claim…job span at all ⇒ not a match (the old literal path would also
    // miss this; the point is the engine doesn't false-positive on noise).
    try t.expect(fileDoc("no relevant tokens here", "doc.md", &re_wild, &sim_wild, 1, true) == null);
}

test "fileDoc honors rg's default binary policy: a match past a NUL is excluded unless -a" {
    const t = std.testing;
    const a = t.allocator;

    // The bug the `--rank` no-fabrication invariant caught: `--rank` read the
    // FULL bytes of every candidate and matched a symbol inside a committed Go
    // binary (`atomic.(*Int32).Store`) that `gist -l` (and ripgrep) skip by
    // default — so the ranked set was a strict SUPERSET of the located set, not
    // a reordering. A walked file whose only hit sits past an early NUL must be
    // excluded under the locate default, and searched whole only under `-a`.
    var re = try Regex.compile(a, "Store");
    defer re.deinit();
    var sim = try Regex.Sim.init(a, &re);
    defer sim.deinit();

    // NUL at byte 3, "Store" only after it — a compiled-binary shape in
    // miniature. `committedPrefix` commits nothing before the NUL-bearing fill.
    const bin = "hi\x00 internal.atomic.Store here\n";
    try t.expect(fileDoc(bin, "mdns_verify", &re, &sim, 0, true) == null); // default: excluded
    const forced = fileDoc(bin, "mdns_verify", &re, &sim, 0, false) orelse { // -a: read as text
        try t.expect(false);
        return;
    };
    try t.expectEqual(@as(u32, 1), forced.matches);

    // A text file (no NUL) with the same match is unaffected by binary detection.
    const text = "internal.atomic.Store here\n";
    const doc = fileDoc(text, "wallet.go", &re, &sim, 0, true) orelse {
        try t.expect(false);
        return;
    };
    try t.expectEqual(@as(u32, 1), doc.matches);
}

test "windowAround keeps a late match token inside the budget" {
    const t = std.testing;
    // The bug: a leading 120-byte slice dropped any hit past column 120, so
    // `--rank` printed a line of filler with the matched token gone.
    const pad = "x" ** 130;
    const line = pad ++ "UniqueMangleTokenXYZ" ++ ("y" ** 20);
    const sp = Regex.Span{ .start = 130, .end = 130 + "UniqueMangleTokenXYZ".len };
    const win = windowAround(line, sp, snippet_budget);
    try t.expect(win.len <= snippet_budget);
    try t.expect(std.mem.indexOf(u8, win, "UniqueMangleTokenXYZ") != null);
    // No span ⇒ prefix fallback (legacy behavior for non-matching lines).
    try t.expectEqualStrings(line[0..snippet_budget], windowAround(line, null, snippet_budget));
    // Short lines pass through untouched.
    try t.expectEqualStrings("short", windowAround("short", sp, snippet_budget));
}
