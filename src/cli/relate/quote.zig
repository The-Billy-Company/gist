//! relate — the `quote` verb: corpus-global cross-parse over the codex shelf.
//!
//!   relate quote <text> [--json]
//!       rewrite <text> as a cento — a sequence of maximal verbatim quotations
//!       from the WHOLE corpus (Ziv–Merhav cross-parse on the FM-index shelf;
//!       src/index/codex/cento.zig) — and price it in bits. One pass, O(|text|)
//!       rank operations: corpus size never appears in the query cost.
//!
//! What `search` answers per-document ("which file describes this most
//! cheaply?"), `quote` answers corpus-globally ("how much of this does the
//! corpus already know, and where?"). Each matched phrase is attributed to
//! one exemplar file (a single-row locate); the summary's bits/byte is the
//! corpus-conditional compression rate — low = the corpus has seen it,
//! ~8+ = foreign bytes.
//!
//! Unlike the other relate verbs, quote reads the PERSISTED `codex.shelf`
//! (`gist codex build`) instead of building per-invocation: the cross-parse
//! is only corpus-global if the index actually spans the corpus, and an
//! FM-index build is a lifecycle event, not a query cost. Freshness is
//! reported the same way `gist codex` reports it.
//! Results on stdout (`--json` = summary line then NDJSON phrase rows),
//! diagnostics on stderr.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");
const fresh = @import("../../index/trigrams/fresh.zig");
const codex_face = @import("../gist/lifecycle/codex.zig");
const cli_args = @import("../../runtime/cold/argv/args.zig");
const shelf_mod = @import("../../index/codex/shelf.zig");
const cento = @import("../../index/codex/cento.zig");
const kinship = @import("kinship.zig");

const die = cli_args.die;
const oom = cli_args.oom;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;
const Dir = std.Io.Dir;

const jsonStr = kinship.jsonStr;

pub fn runQuote(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var query_text: ?[]const u8 = null;
    var json = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (query_text == null) {
            query_text = arg;
        } else die("usage: relate quote <text> [--json]\n", .{});
    }
    const query = query_text orelse die("usage: relate quote <text> [--json]\n", .{});
    if (query.len == 0) die("relate quote: empty query\n", .{});

    const t0 = nowNs(io);
    const blob = Dir.cwd().readFileAlloc(io, codex_face.shelf_file, gpa, .unlimited) catch
        die("no codex shelf at {s} — run `relate index --shelf` (or `gist codex build`) first\n", .{codex_face.shelf_file});
    defer gpa.free(blob);
    var shelf = shelf_mod.Shelf.load(gpa, blob) catch
        die("corrupt codex shelf at {s} — run `relate index --shelf` (or `gist codex build`) to rebuild\n", .{codex_face.shelf_file});
    defer shelf.deinit(gpa);
    const loaded_ns = nowNs(io);

    var parsed = try cento.parse(&shelf.cx, gpa, query);
    defer parsed.deinit(gpa);

    // Coverage: fraction of query bytes inside matched (non-escape) phrases.
    var quoted: usize = 0;
    var escapes: usize = 0;
    for (parsed.phrases) |ph| {
        if (ph.width == 0) escapes += 1 else quoted += ph.len;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (json) {
        out.print(gpa, "{{\"schema_version\":{d},\"bits\":{d:.1},\"bits_per_byte\":{d:.3},\"phrases\":{d},\"escapes\":{d},\"quoted_bytes\":{d},\"query_bytes\":{d}}}\n", .{
            codex_face.schema_version, parsed.bits, parsed.bitsPerByte(query.len), parsed.phrases.len, escapes, quoted, query.len,
        }) catch oom();
    } else {
        out.print(gpa, "{d:.1} bits · {d:.3} bits/byte · {d} phrase(s), {d} escape(s) · {d}/{d} bytes quoted\n", .{
            parsed.bits, parsed.bitsPerByte(query.len), parsed.phrases.len, escapes, quoted, query.len,
        }) catch oom();
    }
    for (parsed.phrases) |ph| {
        const text = query[ph.pos .. ph.pos + ph.len];
        // Attribute one exemplar occurrence (single-row locate). A shelf is
        // always built with locate marks; an escape has nowhere to point.
        const source: ?[]const u8 = if (ph.width == 0) null else blk: {
            const pos = shelf.cx.posOf(ph.row) catch break :blk null;
            break :blk shelf.paths[shelf.docOf(pos)];
        };
        if (json) {
            out.appendSlice(gpa, "{\"text\":") catch oom();
            jsonStr(&out, gpa, text);
            out.print(gpa, ",\"occurrences\":{d},\"bits\":{d:.1},\"source\":", .{ ph.width, ph.bits(shelf.cx.n) }) catch oom();
            if (source) |s| jsonStr(&out, gpa, s) else out.appendSlice(gpa, "null") catch oom();
            out.appendSlice(gpa, "}\n") catch oom();
        } else {
            out.print(gpa, "{d:>8}\u{00d7}  ", .{ph.width}) catch oom();
            jsonStr(&out, gpa, text);
            out.print(gpa, "  {s}\n", .{source orelse "(not in corpus)"}) catch oom();
        }
    }
    const parsed_ns = nowNs(io); // parse + attribution, before the freshness walk
    corpus_mod.emitStdout(out.items);

    const stale = fresh.staleCount(gpa, io, &corpus_mod.default_roots, shelf.built_ns);
    if (stale > 0)
        std.debug.print("quote: {d} file(s) changed since the shelf was built — `relate index --shelf` refreshes\n", .{stale});
    std.debug.print("quote: {d} files in shelf · load {d:.0} ms · parse {d:.2} ms\n", .{
        shelf.paths.len, ms(loaded_ns - t0), ms(parsed_ns - loaded_ns),
    });
}
