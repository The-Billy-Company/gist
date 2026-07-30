//! gist resident session — the warm `lines` renderer correctness suite
//! (ADR-352 rung 2.5).
//!
//! The one invariant the renderer must never break is byte-parity with the
//! cold presentation: `resident lines bytes == gist --no-index bytes == rg
//! bytes`. These tests pin the default (`path:text`) and `-n`
//! (`path:line:text`) frames, the regex / caseless / CR-keeping line
//! semantics, the `-w` word filter routed through the cold Emitter, the
//! implicit-binary cut policy, the data-parallel shard render's identity with
//! the serial core, and the fail-closed decline of an out-of-engine pattern —
//! all against hand-pinned oracles (ripgrep's frame / PCRE semantics), never a
//! self-run of the engine under test. Split from `render.zig` per the tier's
//! sibling-`*_test.zig` shape-cap convention; `render.zig`'s own `test` block
//! wires this file into `zig build test`.

const std = @import("std");
const render = @import("render.zig");
const request = @import("../answer/request.zig");
const slurp = @import("../../../corpus/read/slurp.zig");

const Doc = render.Doc;
const RenderError = render.RenderError;
const renderLines = render.renderLines;
const renderLinesParallel = render.renderLinesParallel;

fn renderToString(a: std.mem.Allocator, req: request.Request, docs: []const Doc) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    _ = try renderLines(a, req, docs, &out);
    return out.items;
}

test "renderLines: default and -n frames match the cold presentation" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = [_]Doc{
        .{ .path = "a.txt", .bytes = "alpha\nneedle one\n", .nul = null },
        .{ .path = "b.txt", .bytes = "needle two\nno\nneedle three", .nul = null }, // no trailing \n
    };
    // Expected bytes pinned from ripgrep's default piped frame (path:text,
    // recursive walk ⇒ filename prefix on; final line still terminated).
    try t.expectEqualStrings(
        "a.txt:needle one\nb.txt:needle two\nb.txt:needle three\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }, &docs),
    );
    try t.expectEqualStrings(
        "a.txt:2:needle one\nb.txt:1:needle two\nb.txt:3:needle three\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .line_num = true }, &docs),
    );
}

test "renderLines: one explicit file suppresses its name and keeps explicit binary semantics" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const filter: request.PathFilter = .{ .roots = &.{"simple.txt"} };

    const text = [_]Doc{.{ .path = "simple.txt", .bytes = "alpha\nbeta gamma\ndelta\n", .nul = null }};
    try t.expectEqualStrings(
        "1:alpha\n3:delta\n",
        try renderToString(a, .{ .pattern = "^\\w+$", .mode = .lines, .pcre = true, .line_num = true, .filter = filter }, &text),
    );

    // An exact root is explicit: unlike a walked binary file, cold scans the
    // whole body and reports the match instead of applying the implicit cut.
    const binary = [_]Doc{.{ .path = "simple.txt", .bytes = "needle\x00tail", .nul = 6 }};
    var out: std.ArrayList(u8) = .empty;
    try t.expect(try renderLines(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .filter = filter }, &binary, &out));
    try t.expectEqualStrings("binary file matches (found \"\\0\" byte around offset 6)\n", out.items);
}

test "renderLines: regex, caseless, and CR-keeping line semantics" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // rg keeps a trailing \r without --crlf; `n.edle` is a live regex; `-i`
    // folds case through the engine (escaped-literal path for -F -i).
    const docs = [_]Doc{.{ .path = "f.txt", .bytes = "Needle\r\nplain needle\n", .nul = null }};
    try t.expectEqualStrings(
        "f.txt:plain needle\n",
        try renderToString(a, .{ .pattern = "n.edle", .mode = .lines }, &docs),
    );
    try t.expectEqualStrings(
        "f.txt:Needle\r\nf.txt:plain needle\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .ignore_case = true }, &docs),
    );
    // -S resolves HERE (the renderer reads `effectiveIgnoreCase`, never the
    // raw bit): a lowercase pattern folds — identical bytes to the -i row —
    // and an uppercase pattern stays case-sensitive.
    try t.expectEqualStrings(
        "f.txt:Needle\r\nf.txt:plain needle\n",
        try renderToString(a, .{ .pattern = "needle", .mode = .lines, .fixed = true, .smart_case = true }, &docs),
    );
    try t.expectEqualStrings(
        "f.txt:Needle\r\n",
        try renderToString(a, .{ .pattern = "Needle", .mode = .lines, .fixed = true, .smart_case = true }, &docs),
    );
}

test "renderLines: -w flows through the cold Emitter's own word filter" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Substring hits (`runner`), Unicode-neighbor hits (`érun`), and a
    // word-rejected-then-valid line (`rerun run`) — the Emitter's wordOk /
    // nextSpan pass decides, the renderer only sets the flag.
    const docs = [_]Doc{.{ .path = "w.txt", .bytes = "run runner\nrerun run\nrunner only\n\xc3\xa9run there\n", .nul = null }};
    try t.expectEqualStrings(
        "w.txt:run runner\nw.txt:rerun run\n",
        try renderToString(a, .{ .pattern = "run", .mode = .lines, .fixed = true, .word = true }, &docs),
    );
    // -w composes with the resolved case fold; the word check runs on the
    // original bytes (`RUN` bounded by space/edge is word-valid once folded).
    const cased = [_]Doc{.{ .path = "c.txt", .bytes = "RUN loud\nrerunning\n", .nul = null }};
    try t.expectEqualStrings(
        "c.txt:RUN loud\n",
        try renderToString(a, .{ .pattern = "run", .mode = .lines, .fixed = true, .ignore_case = true, .word = true }, &cased),
    );
}

test "renderLines: implicit binary emits pre-NUL-buffer matches + WARNING, or nothing" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // NUL in the first 64 KiB buffer ⇒ nothing visible before the cut ⇒ rg
    // quits silently: no output, no match.
    const early = [_]Doc{.{ .path = "bin.dat", .bytes = "needle\x00tail", .nul = 6 }};
    var out1: std.ArrayList(u8) = .empty;
    try t.expect(!try renderLines(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }, &early, &out1));
    try t.expectEqualStrings("", out1.items);

    // A match in a complete buffer BEFORE the one holding the first NUL emits,
    // then the implicit-file WARNING (cold `handleBinary` verbatim).
    const pad = try a.alloc(u8, slurp.BUFCAP);
    @memset(pad, 'x');
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "needle early\n");
    try body.appendSlice(a, pad); // push the NUL past the first BUFCAP buffer
    try body.appendSlice(a, "\x00");
    const late = [_]Doc{.{ .path = "big.dat", .bytes = body.items, .nul = std.mem.indexOfScalar(u8, body.items, 0) }};
    var out2: std.ArrayList(u8) = .empty;
    try t.expect(try renderLines(a, .{ .pattern = "needle", .mode = .lines, .fixed = true }, &late, &out2));
    try t.expect(std.mem.startsWith(u8, out2.items, "big.dat:needle early\n"));
    try t.expect(std.mem.indexOf(u8, out2.items, "WARNING: stopped searching binary file") != null);
}

test "renderLinesParallel: byte-identical to the serial invert core" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Enough docs and bytes to cross `par_min_bytes` and fan across shards; a
    // per-doc line pattern guarantees each doc has both matching and
    // non-matching lines so the complement is non-trivial in every shard.
    var docs: std.ArrayList(Doc) = .empty;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var body: std.ArrayList(u8) = .empty;
        var l: usize = 0;
        while (l < 40) : (l += 1)
            try body.appendSlice(a, if (l % 3 == 0) "needle here\n" else "plain filler line\n");
        try docs.append(a, .{
            .path = try std.fmt.allocPrint(a, "d{d:0>4}.txt", .{i}),
            .bytes = body.items,
            .nul = null,
        });
    }
    const req = request.Request{ .pattern = "needle", .mode = .lines, .fixed = true, .invert = true, .line_num = true };

    var serial: std.ArrayList(u8) = .empty;
    const sm = try renderLines(a, req, docs.items, &serial);
    var par: std.ArrayList(u8) = .empty;
    const pm = try renderLinesParallel(t.allocator, a, req, docs.items, &par);

    try t.expectEqual(sm, pm);
    try t.expectEqualStrings(serial.items, par.items);

    // The POSITIVE emit (a large candidate set) is byte-identical too: same
    // pattern without `-v`, over the same doc slice, shards and concatenates to
    // exactly the serial render.
    const preq = request.Request{ .pattern = "needle", .mode = .lines, .fixed = true, .line_num = true };
    var pos_serial: std.ArrayList(u8) = .empty;
    const psm = try renderLines(a, preq, docs.items, &pos_serial);
    var pos_par: std.ArrayList(u8) = .empty;
    const ppm = try renderLinesParallel(t.allocator, a, preq, docs.items, &pos_par);
    try t.expectEqual(psm, ppm);
    try t.expectEqualStrings(pos_serial.items, pos_par.items);
}

test "renderLines: a pattern outside the linear engine declines (never dies)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try t.expectError(RenderError.Unsupported, renderLines(arena.allocator(), .{ .pattern = "(?<=look)behind", .mode = .lines }, &.{}, &out));
}

test "renderLines: -P renders the PCRE2 engine's lookahead (linear declines it)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `foo(?=bar)` is a lookahead the linear engine declines; under `-P` the
    // PCRE2 arm renders through the SAME cold Emitter, so only the line whose
    // assertion holds prints. Expected from PCRE semantics, never a self-run.
    const docs = [_]Doc{.{ .path = "look.txt", .bytes = "foobar yes\nfoobaz no\n", .nul = null }};
    try t.expectEqualStrings(
        "look.txt:foobar yes\n",
        try renderToString(a, .{ .pattern = "foo(?=bar)", .mode = .lines, .pcre = true }, &docs),
    );
    // The very same pattern WITHOUT `-P` stays a linear decline → cold.
    var out: std.ArrayList(u8) = .empty;
    try t.expectError(RenderError.Unsupported, renderLines(a, .{ .pattern = "foo(?=bar)", .mode = .lines }, &docs, &out));
}
