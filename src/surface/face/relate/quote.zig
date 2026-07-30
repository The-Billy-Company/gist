//! relate — the `quote` verb: corpus-global cross-parse over the codex shelf.
//!
//!   relate quote <text> [--json]
//!       rewrite <text> as a cento — a sequence of maximal verbatim quotations
//!       from the WHOLE corpus (Ziv–Merhav cross-parse on the FM-index shelf;
//!       src/corpus/index/codex/cento.zig) — and price it in bits. One pass, O(|text|)
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
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const shelf_mod = @import("../../../corpus/index/shelf/shelf.zig");
const outcome = @import("../../cli/outcome.zig");
const lifecycle = @import("lifecycle.zig");
const assay = @import("../../../assay/assay.zig");
const cento = @import("../../../kernel/codex/cento.zig");
const emit = @import("../../cli/emit.zig");

const die = @import("../../cli/outcome.zig").die;
const oom = @import("../../cli/outcome.zig").oom;

const jsonStr = emit.jsonStr;

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

    var run = assay.Run.open(gpa, io, json);
    var shelf = shelf_mod.open(gpa, io) catch |e| outcome.needArtifact(
        e,
        "codex shelf",
        shelf_mod.shelfFile(),
        "`relate index --shelf` (or `gist codex build`)",
    );
    defer shelf.deinit(gpa);
    const load_dur = run.lap();

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
            lifecycle.schema_version, parsed.bits, parsed.bitsPerByte(query.len), parsed.phrases.len, escapes, quoted, query.len,
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
            const pos = switch (shelf.cx.posOf(ph.row)) {
                .declined => break :blk null,
                .got => |p| p,
            };
            break :blk shelf.paths[shelf.docOf(pos)];
        };
        if (json) {
            emit.jsonRow(&out, gpa, .{
                .{ "text", "s", text },
                .{ "occurrences", "d", ph.width },
                .{ "bits", "d:.1", ph.bits(shelf.cx.n) },
                .{ "source", "s?", source },
            });
        } else {
            out.print(gpa, "{d:>8}\u{00d7}  ", .{ph.width}) catch oom();
            jsonStr(&out, gpa, text);
            out.print(gpa, "  {s}\n", .{if (source) |s| emit.anchor(gpa, s) else "(not in corpus)"}) catch oom();
        }
    }
    const parse_dur = run.elapsed(); // parse + attribution, before the freshness walk
    corpus_mod.emitStdout(out.items);

    const stale = shelf_mod.staleCount(gpa, io, shelf.built_ns);
    if (stale > 0)
        assay.diag("quote: {d} file(s) changed since the shelf was built — `relate index --shelf` refreshes\n", .{stale});
    run.emit("quote: {d} files in shelf · load {d:.0} ms · parse {d:.2} ms\n", .{
        shelf.paths.len, load_dur.ms(), parse_dur.ms(),
    }, .{
        .{ "verb", "s", "quote" },
        .{ "shelf_files", "d", shelf.paths.len },
        .{ "load_ms", "d:.0", load_dur.ms() },
        .{ "parse_ms", "d:.2", parse_dur.ms() },
    });
}
