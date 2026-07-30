//! gist resident session — the warm `lines` renderer (ADR-352 rung 2.5).
//!
//! Renders the default `gist <pattern>` presentation (`path:text`, `-n` for
//! `path:line:text`) for a pre-gated, path-sorted document list — through the
//! cold engine's OWN `Emitter` and `binary.handleBinary`, not a re-derived
//! formatter. Byte-parity is therefore by construction: the same line split
//! (`collectLines`), the same binary policy (emit up to the buffer that
//! revealed the first NUL, then the implicit-file WARNING), the same
//! `--max-columns`/trim/terminator behavior (all at their defaults here — the
//! classifier admits no flag that changes them), the same rendering code.
//!
//! The eligible warm surface never reaches the presentation states that need
//! run-wide resolution in `run.zig`: the client declines a TTY stdout (color +
//! the interactive long-line cap), and context/heading/replace flags are
//! classifier-ineligible. Scoped requests derive explicit-file identity and
//! the run-wide filename prefix from their roots, matching cold's auto mode.
//! What remains is exactly the default piped frame, reproduced verbatim.
//!
//! Fail-closed like the rest of the session: a pattern the chosen engine
//! declines (the linear default, or the PCRE2 backend under `-P`) is
//! `error.Unsupported` (→ decline → certified cold answer), never
//! a `die()`. (The Emitter's own internal OOM `die` remains the documented
//! catastrophic-OOM fail-open: the daemon exits, the client's dropped
//! connection falls back cold.)

const std = @import("std");
const args = @import("../../cold/argv/args.zig");
const output = @import("../../cold/emit/output.zig");
const binary = @import("../../cold/read/binary.zig");
const legible = @import("../../../corpus/read/legible.zig");
const parallel = @import("../../../kernel/math/parallel.zig");
const query_mod = @import("../../../kernel/query/query.zig");
const request = @import("../answer/request.zig");
const shm = @import("../conduit/shm.zig");
const Regex = @import("../../../kernel/regex/regex.zig").Regex;
const matcher_mod = @import("../../../kernel/regex/regex.zig");
const Matcher = matcher_mod.Matcher;
const Pcre = matcher_mod.Pcre;

pub const RenderError = error{ Unsupported, OutOfMemory };

/// One renderable document: display path, decoded resident bytes, and the
/// byte offset of the first NUL (null ⇒ text). Mirrors `mirror.Doc` + path.
pub const Doc = struct { path: []const u8, bytes: []const u8, nul: ?usize };

/// A root names an explicit file iff it exactly names the resident document.
/// Directory roots only prefix their descendants, so this also distinguishes
/// walked files without another stat or an extra wire-protocol field.
fn explicitRoot(req: request.Request, path: []const u8) bool {
    for (req.filter.roots) |root| if (std.mem.eql(u8, root, path)) return true;
    return false;
}

/// Cold's auto rule suppresses filenames only for one explicit file. Multiple
/// roots always show them; a single directory root has no exact document.
fn showFilename(req: request.Request, docs: []const Doc) bool {
    if (req.filter.roots.len != 1) return true;
    for (docs) |d| if (explicitRoot(req, d.path)) return false;
    return true;
}

/// The shared parallel floor + shard cap (`parallel.min_bytes`/`max_shards`),
/// re-exported so every warm face (this render emit, the resident `-l`/`-c`
/// fold, the FFI record stream) and the cold match/emit cross into parallelism
/// at the SAME corpus size — one definition, no drift.
pub const par_min_bytes = parallel.min_bytes;
pub const par_max_shards = parallel.max_shards;

/// Render every doc's matching lines into `out`, in the docs' given order
/// (the caller path-sorts with `run.pathLess`, the warm canonical order). Returns
/// whether any file matched — cold's exit-code boolean (a binary doc whose only
/// matches sit past its NUL buffer produces no output and no match, exactly
/// like the cold loop). `a` should be a per-query arena: the compiled emission
/// engine, line lists, and every transient are freed with it as a unit.
pub fn renderLines(a: std.mem.Allocator, req: request.Request, docs: []const Doc, out: *std.ArrayList(u8)) RenderError!bool {
    // Compile the SAME effective pattern the cold path feeds `buildMatcher`:
    // `-F` escapes the literal (`combinePatterns`), the RESOLVED case state
    // (`effectiveIgnoreCase` — `-i`, or `-S` folded through the single
    // session-side smart-case resolution) sets the engine's case fold,
    // Unicode stays at the rg-parity default. A pattern outside the chosen
    // engine's syntax is the caller's cue to answer cold.
    const caseless = req.effectiveIgnoreCase();
    const eff = if (req.fixed) try query_mod.escapeLiteral(a, req.pattern) else req.pattern;
    // The SAME engine seam the shared core compiles through (`query.zig`): `-P`
    // (never under `-F`, where fixed wins) realizes the PCRE2 backend —
    // lookaround/backreferences the linear engine declines — else the linear
    // arm. A pattern the CHOSEN engine rejects is `Unsupported`, the caller's
    // cue to answer cold. Multiline/dotall stay off (classifier-ineligible).
    var re: Matcher = if (req.pcre and !req.fixed)
        .{ .pcre = Pcre.compileOpts(a, eff, .{ .caseless = caseless, .unicode = true }) catch |e| switch (e) {
            error.OutOfMemory => return RenderError.OutOfMemory,
            else => return RenderError.Unsupported,
        } }
    else
        .{ .linear = Regex.compileOpts(a, eff, .{ .caseless = caseless, .unicode = true }) catch |e| switch (e) {
            error.OutOfMemory => return RenderError.OutOfMemory,
            else => return RenderError.Unsupported,
        } };
    // The linear arm lives in `a` (arena-freed as a unit); the PCRE2 arm holds
    // libc-owned program memory, so `re` must self-free regardless of the arena.
    defer re.deinit();
    // `requiredLiteralGate` (run.zig): the SIMD line gate is sound only when
    // the engine isn't folding case (RESOLVED, so a folding `-S` declines it
    // exactly like `-i`). It stays sound under `-w` too: the gate only SKIPS
    // engine work on needle-FREE lines, and no needle ⇒ no match ⇒ no
    // word-valid match (a needle-bearing line with zero word-valid spans is
    // still classified by the Emitter's own word scan). It also stays sound
    // under `-v`: the gate never changes the per-line match VERDICT (a
    // needle-free line has zero matches whether or not we invert), only which
    // verdict the Emitter selects, so the complement it prints is identical.
    const req_lit = re.required();
    const needle: ?[]const u8 = if (!caseless and req_lit.len > 0) req_lit else null;

    // Defaults everywhere except `-n`, `-w`, and `-m N`: exactly the option
    // state a piped rootless `gist <pattern> [-n] [-w] [-m N]` reaches the cold
    // emit loop with. The cold Emitter owns the whole `-w` presentation (its
    // wordOk / nextSpan span filter) AND the per-file `-m` cap (it breaks each
    // file at `max_per_file` emitted lines — 0 = unlimited), so wiring the
    // options here IS the parity. `-m0` (match nothing) never reaches this
    // renderer — the session short-circuits it (`Request.matchNothing`).
    const o = args.Opts{
        .line_num = req.line_num,
        .word = req.word,
        // `-v`: the cold Emitter's own line loop selects the complement
        // (`if (hit == o.invert) continue`), so wiring the flag here IS the
        // parity — a non-matching line is framed as a match row (`:`) with its
        // own line number, exactly as a piped `rg -v` produces.
        .invert = req.invert,
        // `-A`/`-B`/`-C`: the cold Emitter's `file` path draws the whole context
        // window and the intra-file `--` group separator off these two fields, so
        // wiring them here IS the parity (the classifier admits only the default
        // separator/terminator, which `Opts`'s defaults already carry). The
        // inter-file `--` is drawn below, exactly as cold's serial `renderFile`.
        // Clamped like `max_per_file` below: the wire carries these counts at the
        // protocol's u64 width, and a context window wider than this address space
        // is indistinguishable from "the whole file" anyway.
        .before = std.math.cast(usize, req.before) orelse std.math.maxInt(usize),
        .after = std.math.cast(usize, req.after) orelse std.math.maxInt(usize),
        .max_per_file = if (req.max_count) |m| std.math.cast(usize, m) orelse std.math.maxInt(usize) else 0,
        .max_per_file_set = req.max_count != null,
    };
    const show_name = showFilename(req, docs);
    var em = output.Emitter{ .a = a, .re = &re, .o = o, .show_name = show_name, .out = out, .needle = if (needle) |n| .of(n) else null };

    var matched = false;
    // rg's cross-file context separator: a `--` line precedes every EMITTING file
    // after the first whenever a window is active — the serial-only state cold
    // gates onto `renderFile` (`serial.zig`), so a context answer renders serial
    // (see `renderLinesParallel`/`renderLinesShm`) and this loop owns the join.
    const join_groups = o.wantsContext();
    var first = true;
    for (docs) |d| {
        if (d.bytes.len == 0) continue; // cold skips empty bodies in every mode
        // The window, BOTH ends, exactly as cold's `render.zig` sets it per file.
        // Every fused whole-buffer pass inside `Emitter.file` reconstructs its
        // body as `base[0 .. body_end - base]`, and `lineTerminated` decides the
        // unterminated-tail framing off `body_end` — so a stale end is not a lost
        // optimization, it is a scan over another document's address range.
        // `handleBinary` below re-points the pair at its committed prefix, so
        // leaving `body_end` unassigned here let the NEXT text doc inherit a
        // binary doc's end address: `panic|0x` (pure literals, no single needle ⇒
        // `litCandidates` engages) then walked `litCandidates`'s SIMD sweep off
        // the end of the mirror's shard mapping and killed the daemon.
        em.base = @intFromPtr(d.bytes.ptr);
        em.body_end = em.base + d.bytes.len;
        if (d.nul) |nul| {
            // Walked (implicit) binary file: cold's exact policy — matches from
            // complete buffers before the NUL, then the WARNING note. Cold's
            // `renderFile` returns on this path before the join-groups insert, so
            // a binary answer neither draws nor consumes the `--` separator.
            if (binary.handleBinary(a, &re, o, out, &em, d.path, explicitRoot(req, d.path), d.bytes, nul, show_name)) matched = true;
            continue;
        }
        var lines: std.ArrayList([]const u8) = .empty;
        legible.collectLines(a, d.bytes, o.term(), &lines);
        const before = out.items.len;
        if (em.file(d.path, lines.items) > 0) {
            if (join_groups and !first and out.items.len > before) {
                if (o.groupSep()) |s| {
                    out.insertSlice(a, before, s[1]) catch return RenderError.OutOfMemory;
                    out.insertSlice(a, before, s[0]) catch return RenderError.OutOfMemory;
                }
            }
            first = false;
            matched = true;
        }
    }
    return matched;
}

/// The warm `lines` emit, data-parallel over documents (both faces).
///
/// The emit walk can be the whole corpus, not a pruned candidate set: bare
/// `gist -v` selects (nearly) EVERY line of EVERY text doc, and a common
/// positive token (`fn`, `pub`, `import`) prunes to a candidate set so LARGE
/// that the serial render is exactly the 1-core-vs-16-core loss to cold's fused
/// scan. This shards the docs by byte weight (`parallel.shardBounds` →
/// `greedyBounds`, so one huge file can't stall a thread), renders each shard
/// through the SAME serial `renderLines` core into its own arena buffer, then
/// concatenates the buffers in ORIGINAL doc order. Output is therefore
/// byte-identical to the serial render — the shards are contiguous doc ranges and
/// every transient (compiled engine, line lists) lives in that shard's arena,
/// freed here as a unit. Invert and positive share this ONE primitive: the
/// caller path-sorts `docs`, `req.invert` flows straight into each shard's
/// `renderLines`. Returns cold's exit-code boolean (any file matched). Below
/// `par_min_bytes` or with one usable core it falls straight through to the
/// serial core — no thread, no extra arena.
pub fn renderLinesParallel(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    req: request.Request,
    docs: []const Doc,
    out: *std.ArrayList(u8),
) RenderError!bool {
    const shards = (try fanRender(gpa, a, req, docs)) orelse return renderLines(a, req, docs, out);
    defer release(shards);
    var matched = false;
    for (shards) |*sh| {
        if (sh.err) |e| return e;
        try out.appendSlice(a, sh.buf.items);
        matched = matched or sh.matched;
    }
    return matched;
}

/// One shard of a sharded render: a contiguous doc range, the private arena its
/// whole render lives in (compiled engine, line lists, output buffer), and the
/// bytes the serial core produced for it.
const Shard = struct {
    req: request.Request,
    docs: []const Doc,
    buf: std.ArrayList(u8) = .empty,
    arena: std.heap.ArenaAllocator = undefined,
    matched: bool = false,
    err: ?RenderError = null,

    fn run(sh: *Shard) void {
        sh.matched = renderLines(sh.arena.allocator(), sh.req, sh.docs, &sh.buf) catch |e| {
            sh.err = e;
            return;
        };
    }
};

/// The one sharded render both parallel faces ride: split `docs` by byte weight
/// (`greedyBounds`, so one huge file can't stall a thread), render each range
/// through the SAME serial `renderLines` core in parallel, and hand the shards
/// back in ORIGINAL doc order — which is what makes either face's concatenation
/// byte-identical to the serial render.
///
/// `null` ⇒ the split declined and the caller must render serial: below
/// `par_min_bytes`, one usable core, one doc, or a context window whose
/// cross-file `--` separator state an order-free split can't reproduce (cold
/// gates that onto its own serial loop, so we do too; context queries are
/// narrow and the walk-elimination win still stands).
///
/// Every `buf` points into its shard's arena, so the caller must finish reading
/// them BEFORE calling `release`.
fn fanRender(gpa: std.mem.Allocator, a: std.mem.Allocator, req: request.Request, docs: []const Doc) RenderError!?[]Shard {
    if (req.before != 0 or req.after != 0) return null;
    const bounds = parallel.shardBounds(Doc, docs, {}, docWeight, par_min_bytes, par_max_shards, a) orelse return null;
    const shards = try a.alloc(Shard, bounds.len - 1);
    for (shards, 0..) |*sh, i| sh.* = .{
        .req = req,
        .docs = docs[bounds[i]..bounds[i + 1]],
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    errdefer release(shards);
    const threads = try a.alloc(std.Thread, shards.len);
    parallel.fanOut(Shard, shards, threads, Shard.run);
    return shards;
}

fn release(shards: []Shard) void {
    for (shards) |*sh| sh.arena.deinit();
}

/// The scanned-byte weight of one doc — the sharding key every warm face
/// balances threads by (this render emit and the resident record stream), so a
/// few large files can't stall one thread.
pub fn docWeight(_: void, d: Doc) usize {
    return d.bytes.len;
}

/// A `lines` answer assembled in shared memory (the fd-transport daemon path):
/// filled but NOT yet frozen. The caller freezes it, hands off `buffer.fd`, then
/// closes its own handle — the object lives until the client's fd closes.
pub const ShmLines = struct { buffer: shm.Buffer, len: usize, matched: bool };

/// How a rendered `lines` answer leaves `renderLinesShm`: either a shared-memory
/// buffer to pass as an fd (answer ≥ `floor`, shm available — the zero-socket-copy
/// win), or the rendered bytes to stream as ordinary `chunk` frames (answer below
/// the floor, or shm unavailable — the fail-open path). Byte-identical either way;
/// `chunk` is never a new failure mode.
pub const LinesEmit = union(enum) {
    fd: ShmLines,
    chunk: struct { bytes: []const u8, matched: bool },
};

/// Render the warm `lines` answer and choose its transport by ANSWER SIZE, not
/// shard count: at/above `floor` the bytes are gathered into a shared-memory
/// buffer the daemon hands off as an fd (`sendChunkFd`) so the multi-MB answer
/// never traverses the socket; below it — or if shm setup fails — the same bytes
/// come back to stream as `chunk` frames. A large SINGLE-doc answer is fd-eligible
/// too: the win is the eliminated socket copy, independent of how many docs (or
/// shards) produced it.
///
/// The bytes are byte-identical to `renderLinesParallel`: the same shards, the
/// same per-shard `renderLines` core, the same doc-order concatenation. For the
/// fd case the shard buffers are copied STRAIGHT into shm (one copy, no arena
/// concatenation first); for the chunk case a single shard's bytes are returned
/// as-is and multiple shards are concatenated into the arena.
pub fn renderLinesShm(
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    req: request.Request,
    docs: []const Doc,
    floor: usize,
) RenderError!LinesEmit {
    // Serial render (the `fanRender` decline — corpus below `par_min_bytes`, one
    // core, a single doc a shard split can't divide, OR a context window whose
    // cross-file `--` state resists an order-free split): one CALLER-arena buffer
    // holds the whole answer, then the same floor decision — a huge single doc
    // still earns the fd path, and its `chunk` bytes outlive this frame.
    const shards = (try fanRender(gpa, a, req, docs)) orelse {
        var out: std.ArrayList(u8) = .empty;
        const matched = try renderLines(a, req, docs, &out);
        return emit(a, &.{out.items}, matched, floor);
    };
    defer release(shards);

    const pieces = try a.alloc([]const u8, shards.len);
    var matched = false;
    for (shards, pieces) |*sh, *p| {
        if (sh.err) |e| return e;
        p.* = sh.buf.items;
        matched = matched or sh.matched;
    }
    return emit(a, pieces, matched, floor);
}

/// Hand the rendered `pieces` (in doc order, ≥1) to the caller as an fd or a
/// chunk stream. At/above `floor` they're copied contiguously into a fresh shm
/// buffer (one copy); on an shm failure or below the floor they fall to `chunk` —
/// a single piece as-is, several concatenated into `a`.
///
/// Returning a single piece BY REFERENCE is sound only because a lone piece is
/// always the serial render's caller-arena buffer: `fanRender` yields shards
/// only when `shardBounds` found ≥2, so a sharded answer never hands back one
/// arena-owned piece that `release` would then free under the caller.
fn emit(a: std.mem.Allocator, pieces: []const []const u8, matched: bool, floor: usize) RenderError!LinesEmit {
    var total: usize = 0;
    for (pieces) |p| total += p.len;
    // A declined shm buffer falls open to the chunk frames below — same bytes.
    if (total >= floor) switch (shm.Buffer.create(total)) {
        .declined => {},
        .got => |created| {
            var buffer = created;
            var off: usize = 0;
            for (pieces) |p| {
                @memcpy(buffer.map[off..][0..p.len], p);
                off += p.len;
            }
            return .{ .fd = .{ .buffer = buffer, .len = total, .matched = matched } };
        },
    };
    if (pieces.len == 1) return .{ .chunk = .{ .bytes = pieces[0], .matched = matched } };
    var out: std.ArrayList(u8) = .empty;
    for (pieces) |p| try out.appendSlice(a, p);
    return .{ .chunk = .{ .bytes = out.items, .matched = matched } };
}

test {
    // The warm `lines` renderer's correctness suite lives in the sibling
    // `render_test.zig` per this tier's `*_test.zig` shape-cap convention
    // (see `root.zig`). root.zig imports THIS file, so referencing the sibling
    // here wires the suite into `zig build test` without a root.zig edit.
    _ = @import("render_test.zig");
}
