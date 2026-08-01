//! gist bench — per-function micro-profiles for the WARM SESSION tier.
//!
//!   zig build -Doptimize=ReleaseFast sessionprof  [-- <dirs…>]  [--reps N]
//!                                                 [--baseline <path>] [--gate]
//!
//! `bench -- session` measures the whole persistent-client → daemon product path
//! (socket, frames, dispatch); `certify` measures the cold fresh-process race.
//! Neither can tell you whether a change to ONE warm function moved the needle —
//! the transport and the reconcile walk drown it. This isolates each seam of
//! `exec/session/` over a real corpus, in-process, and times it directly:
//!
//!   * `gatedLineCount`     — the binary NUL-cut body rule, over every mirror doc.
//!   * `query -l` / `-c`    — the fold faces (candidate walk + Accumulator).
//!   * `query -v -l`/`-v -c`— the set-complement invert fold (`gatedMatches`).
//!   * `queryLines`         — the default `path:text` emit through the cold Emitter.
//!   * `queryLinesShm`      — the same bytes, fd-transport lane.
//!   * `search`             — the FFI record stream (the per-line emit walk).
//!   * `renderLines`        — the serial render core, called directly on gathered docs.
//!   * `renderLinesParallel`— the sharded render over the same docs.
//!
//! Every seam is also CHECKED, not just timed: each answer is folded into an
//! FNV-1a digest and the digest is asserted stable across all reps, and the two
//! render lanes (serial vs sharded vs shm) are asserted byte-identical to each
//! other. A refactor that silently changed an answer fails here before its
//! timing is ever reported.
//!
//! `--baseline <path>` reads a previously written report and prints the per-seam
//! delta with a Mann-Whitney verdict, so a "this refactor is perf-neutral" claim
//! is a measurement rather than an assertion. `--gate` makes a `loss` verdict
//! exit nonzero. The report is written to
//! `.gist/sessionprof.json`.
//!
//! ## Why it profiles a SNAPSHOT, not the live tree
//!
//! Every seam here runs the session's reconcile, and ~10 coworker agents edit
//! this repo continuously — a live-tree profile silently measures a different
//! corpus every rep, which the answer-digest check catches as `UnstableAnswer`.
//! So the harness freezes its corpus once into a scratch tree outside the
//! repository (`$TMPDIR/gist-sessionprof-corpus`, reused across runs unless
//! `--refresh`) and profiles the session over that. Before/after runs therefore
//! see byte-identical input, which is the only footing on which "this refactor
//! changed nothing" is a claim rather than a hope.
//!
//! ## Why reps are INTERLEAVED and the verdict is corroborated by best-of-N
//!
//! The same ~10 coworker agents also keep this machine at a load average near
//! its core count, and that load drifts over tens of seconds. Profiling seam A's
//! whole rep block, then seam B's, therefore measures the two seams in DIFFERENT
//! load epochs — measured here at up to 5× apparent movement between two runs of
//! byte-identical code. So every rep sweeps ALL seams once (round-robin), which
//! puts every seam in the same epochs and makes the sample sets comparable.
//!
//! Against ambient contention the noise is additive and one-sided, so the sample
//! MINIMUM is the least-contaminated estimator of a seam's true cost — the same
//! two identical-code runs that moved p50 by 1.2–5× held min to within 0.1% on
//! every seam whose work is one self-contained call. A regression therefore has
//! to satisfy BOTH tests: the distributional Mann-Whitney verdict says `loss`
//! AND best-of-N moved by more than `min_corroboration`. Either alone is noise
//! on a loaded box.
//!
//! Best-of-N still can't see a SUSTAINED tax — a run where every rep is slower
//! because the box is busier for the whole run. So each seam declares a `Class`
//! (single-threaded `scan` vs thread-per-shard `fanout`) and the harness profiles
//! a frozen CALIBRATOR per class: harness-owned work no refactor can touch, in
//! the same shape as the seams it stands for (the fan-out one reproduces the
//! product lane's exact `parallel.shardBounds` geometry). `compare` divides each
//! seam's best-of-N ratio by its class's calibrator, so the reported `norm r`
//! answers the only question that matters — did this seam slow down by more than
//! the machine did at that kind of work? Two classes rather than one because
//! measurement showed a bandwidth probe holds `scan` to 1.4% while leaving
//! `fanout` swinging 2.5×: they contend for different resources.

const std = @import("std");
const gist = @import("irregex");
const stats = @import("stats");

const session = gist.session;
const Request = session.request.Request;
const ResidentSession = session.resident.ResidentSession;
const render = session.render;
const parallel = gist.parallel;
const Dir = std.Io.Dir;
const Span = gist.assay.Span; // the package instrumentation floor: monotonic Span

const corpus_mod = gist.corpus;

/// Enough reps to make the bootstrap CI meaningful without turning a profile run
/// into a coffee break; every seam here is sub-100 ms on the host tree.
const default_reps: usize = 40;

/// A prevent-elision sink — every seam XOR-folds its answer in, so the optimizer
/// cannot delete the timed work as dead.
var sink: u64 = 0;

/// FNV-1a over an answer's bytes: the cheap identity witness each seam asserts
/// stable across reps (and, for the render lanes, across transports).
fn digest(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn digestPaths(paths: []const []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (paths) |p| h = digest(h, p);
    return h;
}

/// One profiled seam: its wall-ns sample set plus the answer digest every rep
/// agreed on.
const Seam = struct {
    name: []const u8,
    unit: []const u8,
    class: Class,
    samples: []f64,
    summary: stats.Summary,
    fingerprint: u64,
};

/// What kind of ambient noise a seam is exposed to — and therefore which frozen
/// calibrator its delta must be read against. Measured on this box with
/// identical code: a bandwidth calibrator holds the `scan` class to within 1.4%
/// while the `fanout` class still swings 2.5×, because the two classes contend
/// for different resources (DRAM/LLC bandwidth vs runnable-thread slots against
/// ~10 cores at load 38). One calibrator per class is what makes both readable.
const Class = enum {
    /// Single-threaded, memory-bandwidth bound: one straight walk of the corpus.
    scan,
    /// Spawns a thread per shard, so its cost tracks how oversubscribed the box is.
    fanout,
};

/// A seam registered for the interleaved sweep: its identity, its noise class,
/// its sample row, and a type-erased call into the closure that does the work.
/// Erasure is what lets one loop drive seams whose contexts are unrelated
/// anonymous structs, so every seam is timed once per rep instead of once per
/// block.
const Probe = struct {
    name: []const u8,
    unit: []const u8,
    class: Class,
    call: *const fn (*Probe) anyerror!u64,
    samples: []f64,
    fingerprint: ?u64 = null,
};

/// The seam registry plus the sweep that drives it. Registration and execution
/// are separate phases on purpose: nothing is timed until every seam exists, so
/// the sweep can round-robin them and share load epochs (see the module header).
const Bench = struct {
    gpa: std.mem.Allocator,
    reps: usize,
    probes: std.ArrayList(*Probe) = .empty,

    /// Register one seam. `ctx` is any struct with `fn call(self) !u64` returning
    /// the answer digest; it is boxed so the erased thunk can outlive this frame.
    /// `pattern`, when given, is folded into the reported name as `face /pat/`.
    fn add(self: *Bench, face: []const u8, pattern: ?[]const u8, unit: []const u8, class: Class, ctx: anytype) !void {
        const Ctx = @TypeOf(ctx);
        const Box = struct {
            probe: Probe,
            ctx: Ctx,

            fn call(probe: *Probe) anyerror!u64 {
                const box: *@This() = @fieldParentPtr("probe", probe);
                return box.ctx.call();
            }
        };
        const box = try self.gpa.create(Box);
        box.* = .{
            .probe = .{
                .name = if (pattern) |p|
                    try std.fmt.allocPrint(self.gpa, "{s} /{s}/", .{ face, p })
                else
                    try self.gpa.dupe(u8, face),
                .unit = unit,
                .class = class,
                .call = Box.call,
                .samples = try self.gpa.alloc(f64, self.reps),
            },
            .ctx = ctx,
        };
        try self.probes.append(self.gpa, &box.probe);
    }

    /// One warm pass (caches, first-touch of the arena pages), then `reps` sweeps
    /// over every seam in registration order, asserting each seam's answer digest
    /// never moves. Summarizes into caller-owned `Seam`s.
    fn sweep(self: *Bench, io: std.Io, scratch: []f64, rng: std.Random) ![]Seam {
        for (self.probes.items) |p| _ = try p.call(p);
        for (0..self.reps) |i| {
            for (self.probes.items) |p| {
                const sp = Span.open(io);
                const got = try p.call(p);
                p.samples[i] = @floatFromInt(sp.read(io).ns());
                if (p.fingerprint) |f| {
                    if (f != got) {
                        std.debug.print("FAIL: {s} answer changed between reps ({x} vs {x})\n", .{ p.name, f, got });
                        return error.UnstableAnswer;
                    }
                } else p.fingerprint = got;
            }
        }
        const seams = try self.gpa.alloc(Seam, self.probes.items.len);
        for (self.probes.items, seams) |p, *s| s.* = .{
            .name = p.name,
            .unit = p.unit,
            .class = p.class,
            .samples = p.samples,
            .summary = stats.summarize(p.samples, scratch, rng),
            .fingerprint = p.fingerprint.?,
        };
        return seams;
    }
};

/// The record sink for the `search` face: counts lines and folds their bytes, so
/// the stream is both driven to completion and identity-checked. Declares no
/// `runBudget`, so the gather runs unbounded (the daemon's own shape).
const Counter = struct {
    lines: u64 = 0,
    hash: u64 = 0xcbf29ce484222325,

    pub fn emit(self: *Counter, rec: session.resident.MatchRecord) bool {
        self.lines += 1;
        self.hash = digest(self.hash, rec.text);
        return false; // never stop early — profile the whole stream
    }
};

/// Per-shard passes inside the fan-out calibrator's single spawn round. Six puts
/// it at ~2.3 ms on the host tree — the median cost of the `fanout` seams it
/// stands for — while keeping ONE spawn round, exactly like those seams. Paying
/// the magnitude in spawn rounds instead over-weights spawn and over-corrects the
/// whole class (measured 1.52× while its seams held 1.1×).
const fanout_passes = 6;

/// One shard of the fan-out calibrator: a contiguous doc range and the line count
/// its thread found. Frozen on purpose — the point is to price the SHARD GEOMETRY
/// (spawn, join, oversubscription) around a body of real per-shard compute, so
/// neither the body nor the pass count may change.
const Tally = struct {
    docs: []const render.Doc,
    lines: u64 = 0,

    fn run(sh: *Tally) void {
        for (0..fanout_passes) |_| {
            for (sh.docs) |d| sh.lines += std.mem.count(u8, d.bytes, "\n");
        }
    }
};

/// The pattern slate: one very common token (huge candidate set — the sharded
/// lanes' real workload), one mid-frequency identifier, one rare literal, and a
/// regex with a required literal (the SIMD gate's path).
const slate = [_][]const u8{ "pub fn", "ResidentSession", "gatedLineCount", "pgxpool\\.\\w+" };

/// The default source tree to freeze: the engine's own sources — a real, dense
/// corpus well above `parallel.min_bytes` (256 KiB), so the sharded lanes
/// genuinely shard instead of falling through to their serial cores.
const default_source = "src";

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: *std.process.Args.Iterator) !void {
    var reps = default_reps;
    var gate = false;
    var refresh = false;
    var baseline: ?[]const u8 = null;
    var roots_list: std.ArrayList([]const u8) = .empty;
    defer roots_list.deinit(gpa);
    while (argv.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gate")) {
            gate = true;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--reps")) {
            reps = std.fmt.parseInt(usize, argv.next() orelse "40", 10) catch default_reps;
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            baseline = argv.next();
        } else try roots_list.append(gpa, arg);
    }

    const sources: []const []const u8 = if (roots_list.items.len > 0) roots_list.items else &.{default_source};
    const snapshot = try freeze(gpa, io, sources, refresh);
    defer gpa.free(snapshot);

    var sess = try ResidentSession.init(gpa, io, &.{snapshot});
    defer sess.deinit();
    if (sess.mir.docs.len == 0) {
        std.debug.print("sessionprof: snapshot {s} mirrored zero docs — nothing to profile\n", .{snapshot});
        return error.EmptyCorpus;
    }
    std.debug.print(
        "gist sessionprof · warm-session per-function micro-profile\nfrozen corpus {s}\ndocs {d} · {d:.2} MiB · {d} lines · reps {d}\n\n",
        .{ snapshot, sess.mir.docs.len, @as(f64, @floatFromInt(sess.mir.bytes)) / (1 << 20), sess.mir.total_lines, reps },
    );

    var bench = Bench{ .gpa = gpa, .reps = reps };
    defer bench.probes.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();
    const scratch = try gpa.alloc(f64, reps);
    defer gpa.free(scratch);

    // The doc set both the render lanes and the fan-out calibrator run over: every
    // mirror doc, path-ordered exactly as the session hands them over, so the
    // serial core, the sharded lane, and the calibrator all see identical input
    // (and no gather cost lands inside anyone's timing).
    const docs = try gpa.alloc(render.Doc, sess.mir.docs.len);
    defer gpa.free(docs);
    for (sess.mir.paths, sess.mir.docs, sess.mir.nuls, docs) |p, b, n, *d|
        d.* = .{ .path = p, .bytes = b, .nul = n };

    // ── the ambient calibrators, one per noise class ──
    // Frozen harness-local work over the same mirror bytes, deliberately owned by
    // NO session module so no refactor can ever change it. Each one's run-to-run
    // movement IS this box's ambient tax for its class, and `compare` divides
    // every seam's best-of-N ratio by its class's calibrator — which is what makes
    // "the code didn't get slower" separable from "the machine got busier".
    try bench.add(calibrators[@intFromEnum(Class.scan)], null, "ns/corpus", .scan, struct {
        s: *ResidentSession,
        fn call(ctx: @This()) !u64 {
            var total: u64 = 0;
            for (ctx.s.mir.docs) |bytes| total += std.mem.count(u8, bytes, "\n");
            sink ^= total;
            return total;
        }
    }{ .s = &sess });

    // The same scan, split across the SAME shard geometry the render and query
    // lanes use (`parallel.shardBounds` → thread per shard), so it prices thread
    // spawn plus oversubscription rather than bandwidth. Without this the sharded
    // seams are unreadable on a loaded box: measured at up to 2.5× movement on
    // byte-identical code, none of which a single-threaded probe can see.
    //
    // Its per-shard body is sized (`fanout_passes`) to land in the same decade as
    // the seams it calibrates: a calibrator an order of magnitude cheaper than its
    // seams is the noisiest term in the ratio and over-corrects the class, and an
    // over-corrected `norm r` hides regressions — the one direction that must not
    // happen.
    try bench.add(calibrators[@intFromEnum(Class.fanout)], null, "ns/corpus", .fanout, struct {
        gpa: std.mem.Allocator,
        docs: []const render.Doc,
        fn call(ctx: @This()) !u64 {
            var arena = std.heap.ArenaAllocator.init(ctx.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var total: u64 = 0;
            if (parallel.shardBounds(render.Doc, ctx.docs, {}, render.docWeight, render.par_min_bytes, render.par_max_shards, a)) |bounds| {
                const shards = try a.alloc(Tally, bounds.len - 1);
                for (shards, bounds[0 .. bounds.len - 1], bounds[1..]) |*sh, lo, hi|
                    sh.* = .{ .docs = ctx.docs[lo..hi] };
                const threads = try a.alloc(std.Thread, shards.len);
                parallel.fanOut(Tally, shards, threads, Tally.run);
                for (shards) |sh| total += sh.lines;
            } else {
                // Below the shard floor the product lanes run serial too, so the
                // calibrator degrades the same way rather than fake a fan-out.
                var one = Tally{ .docs = ctx.docs };
                Tally.run(&one);
                total = one.lines;
            }
            sink ^= total;
            return total;
        }
    }{ .gpa = gpa, .docs = docs });

    // ── the corpus-invariant body rule, over every mirror doc ──
    try bench.add("gatedLineCount", null, "ns/corpus", .scan, struct {
        s: *ResidentSession,
        fn call(ctx: @This()) !u64 {
            var total: u64 = 0;
            for (ctx.s.mir.docs, ctx.s.mir.nuls) |bytes, nul|
                total += session.corpus.gatedLineCount(bytes, nul);
            sink ^= total;
            return total;
        }
    }{ .s = &sess });

    // ── the answer faces, per pattern ──
    for (slate) |pat| {
        try bench.add("query -l", pat, "ns", .fanout, struct {
            s: *ResidentSession,
            pat: []const u8,
            fn call(ctx: @This()) !u64 {
                var arena = std.heap.ArenaAllocator.init(ctx.s.gpa);
                defer arena.deinit();
                const r = (try ctx.s.query(arena.allocator(), .{ .pattern = ctx.pat, .mode = .files })).got;
                sink ^= r.files.len;
                return digestPaths(r.files);
            }
        }{ .s = &sess, .pat = pat });

        try bench.add("query -c", pat, "ns", .fanout, struct {
            s: *ResidentSession,
            pat: []const u8,
            fn call(ctx: @This()) !u64 {
                var arena = std.heap.ArenaAllocator.init(ctx.s.gpa);
                defer arena.deinit();
                const r = (try ctx.s.query(arena.allocator(), .{ .pattern = ctx.pat, .mode = .count })).got;
                sink ^= r.count;
                return r.count;
            }
        }{ .s = &sess, .pat = pat });

        try bench.add("query -v -c", pat, "ns", .fanout, struct {
            s: *ResidentSession,
            pat: []const u8,
            fn call(ctx: @This()) !u64 {
                var arena = std.heap.ArenaAllocator.init(ctx.s.gpa);
                defer arena.deinit();
                const r = (try ctx.s.query(arena.allocator(), .{ .pattern = ctx.pat, .mode = .count, .invert = true })).got;
                sink ^= r.count;
                return r.count;
            }
        }{ .s = &sess, .pat = pat });

        try bench.add("queryLines", pat, "ns", .fanout, struct {
            s: *ResidentSession,
            pat: []const u8,
            fn call(ctx: @This()) !u64 {
                var arena = std.heap.ArenaAllocator.init(ctx.s.gpa);
                defer arena.deinit();
                const r = (try ctx.s.queryLines(arena.allocator(), .{ .pattern = ctx.pat, .mode = .lines })).got;
                sink ^= r.out.len;
                return digest(0xcbf29ce484222325, r.out);
            }
        }{ .s = &sess, .pat = pat });

        try bench.add("queryLinesShm", pat, "ns", .fanout, struct {
            s: *ResidentSession,
            pat: []const u8,
            fn call(ctx: @This()) !u64 {
                var arena = std.heap.ArenaAllocator.init(ctx.s.gpa);
                defer arena.deinit();
                // Floor at maxInt keeps the answer on the chunk lane, so the
                // digest is directly comparable to `queryLines` (an fd answer
                // lives in shm and would need a map to hash) while the SAME
                // shard machinery is what gets timed.
                const e = (try ctx.s.queryLinesShm(arena.allocator(), .{ .pattern = ctx.pat, .mode = .lines }, std.math.maxInt(usize))).got;
                const bytes = switch (e) {
                    .chunk => |c| c.bytes,
                    .fd => |f| blk: {
                        var b = f.buffer;
                        b.close();
                        break :blk "";
                    },
                };
                sink ^= bytes.len;
                return digest(0xcbf29ce484222325, bytes);
            }
        }{ .s = &sess, .pat = pat });

        try bench.add("search", pat, "ns", .fanout, struct {
            s: *ResidentSession,
            pat: []const u8,
            fn call(ctx: @This()) !u64 {
                var arena = std.heap.ArenaAllocator.init(ctx.s.gpa);
                defer arena.deinit();
                var c = Counter{};
                _ = try ctx.s.search(arena.allocator(), .{ .pattern = ctx.pat, .mode = .lines }, &c);
                sink ^= c.lines;
                return c.hash;
            }
        }{ .s = &sess, .pat = pat });
    }

    // ── the render lanes, over that same pre-gathered doc set ──
    const render_req = Request{ .pattern = "pub fn", .mode = .lines };
    try bench.add("renderLines", null, "ns", .scan, struct {
        gpa: std.mem.Allocator,
        docs: []const render.Doc,
        req: Request,
        fn call(ctx: @This()) !u64 {
            var arena = std.heap.ArenaAllocator.init(ctx.gpa);
            defer arena.deinit();
            var out: std.ArrayList(u8) = .empty;
            _ = try render.renderLines(arena.allocator(), ctx.req, ctx.docs, &out);
            sink ^= out.items.len;
            return digest(0xcbf29ce484222325, out.items);
        }
    }{ .gpa = gpa, .docs = docs, .req = render_req });

    try bench.add("renderLinesParallel", null, "ns", .fanout, struct {
        gpa: std.mem.Allocator,
        docs: []const render.Doc,
        req: Request,
        fn call(ctx: @This()) !u64 {
            var arena = std.heap.ArenaAllocator.init(ctx.gpa);
            defer arena.deinit();
            var out: std.ArrayList(u8) = .empty;
            _ = try render.renderLinesParallel(ctx.gpa, arena.allocator(), ctx.req, ctx.docs, &out);
            sink ^= out.items.len;
            return digest(0xcbf29ce484222325, out.items);
        }
    }{ .gpa = gpa, .docs = docs, .req = render_req });

    const seams = try bench.sweep(io, scratch, rng);
    defer gpa.free(seams);

    // The parity the sharded lane exists to preserve: same bytes as the serial
    // core. Asserted here so a render refactor can never report a speedup it
    // bought by changing the answer.
    for (seams) |a| {
        if (!std.mem.eql(u8, a.name, "renderLines")) continue;
        for (seams) |b| {
            if (!std.mem.eql(u8, b.name, "renderLinesParallel")) continue;
            if (a.fingerprint != b.fingerprint) {
                std.debug.print("FAIL: renderLinesParallel bytes differ from renderLines\n", .{});
                return error.RenderParityBroken;
            }
        }
    }

    try report(gpa, io, seams);
    if (baseline) |path| {
        const regressed = try compare(gpa, io, path, seams);
        if (gate and regressed) return error.PerfRegression;
    }
    std.debug.print("\n(sink {x})\n", .{sink});
}

/// Materialize an immutable copy of `sources` outside the repository and return
/// its absolute path (caller-owned). Reused across runs when it already exists —
/// that reuse IS the before/after contract, so a refactor is measured over
/// byte-identical input; `--refresh` re-mints it from the current tree.
///
/// The corpus is selected by the SAME loader `bench` uses (rg-style: ignored
/// subtrees and binaries already pruned), and each doc is written under a
/// flattened, collision-free name — the seams profiled here read bytes and
/// render `path:text`, so tree shape is irrelevant while a flat directory keeps
/// the copy a straight-line write with no `makePath` walk.
fn freeze(gpa: std.mem.Allocator, io: std.Io, sources: []const []const u8, refresh: bool) ![]const u8 {
    const tmp = if (std.c.getenv("TMPDIR")) |v| std.mem.span(v) else "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}{s}gist-sessionprof-corpus", .{ tmp, if (std.mem.endsWith(u8, tmp, "/")) "" else "/" });
    errdefer gpa.free(dir);

    if (refresh) Dir.cwd().deleteTree(io, dir) catch {};
    if (!refresh) {
        // A present, non-empty snapshot is authoritative — do not re-mint it, or
        // the "after" run would measure a different corpus than the "before".
        if (Dir.cwd().openDir(io, dir, .{ .iterate = true })) |opened| {
            var d = opened;
            defer d.close(io);
            var it = d.iterate();
            if (try it.next(io) != null) {
                std.debug.print("sessionprof: reusing frozen corpus {s} (--refresh to re-mint)\n", .{dir});
                return dir;
            }
        } else |_| {}
    }

    var src = try corpus_mod.load(gpa, io, sources, .contiguous);
    defer src.deinit();
    try Dir.cwd().createDirPath(io, dir);
    var out = try Dir.cwd().openDir(io, dir, .{});
    defer out.close(io);
    var name: [64]u8 = undefined;
    for (src.paths, src.docs, 0..) |p, body, i| {
        // Keep the extension (the `-t`/type machinery and the renderer both read
        // it) and make the stem unique by index — two `mod.zig`s must not collide.
        const ext = std.fs.path.extension(p);
        const leaf = try std.fmt.bufPrint(&name, "d{d:0>6}{s}", .{ i, ext });
        try out.writeFile(io, .{ .sub_path = leaf, .data = body });
    }
    std.debug.print("sessionprof: froze {d} docs ({d:.2} MiB) → {s}\n", .{ src.paths.len, @as(f64, @floatFromInt(src.bytes)) / (1 << 20), dir });
    return dir;
}

const out_dir = ".gist";

fn report(gpa: std.mem.Allocator, io: std.Io, seams: []const Seam) !void {
    std.debug.print("{s:<34} {s:>11} {s:>11} {s:>11}  {s:>7}  {s}\n", .{ "seam", "p50", "p95", "min", "n", "answer" });
    std.debug.print("{s:-<34} {s:->11} {s:->11} {s:->11}  {s:->7}  {s:-<16}\n", .{ "", "", "", "", "", "" });
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\n  \"seams\": [\n");
    for (seams, 0..) |s, i| {
        std.debug.print("{s:<34} {d:>11.3} {d:>11.3} {d:>11.3}  {d:>7}  {x:0>16}\n", .{
            s.name, s.summary.median / 1000.0, s.summary.p95 / 1000.0, s.summary.min / 1000.0, s.summary.n, s.fingerprint,
        });
        try json.print(gpa, "    {{\"name\": \"{f}\", \"p50_ns\": {d:.1}, \"p95_ns\": {d:.1}, \"min_ns\": {d:.1}, \"mean_ns\": {d:.1}, \"n\": {d}, \"answer\": \"{x}\", \"samples\": [", .{
            std.zig.fmtString(s.name), s.summary.median, s.summary.p95, s.summary.min, s.summary.mean, s.summary.n, s.fingerprint,
        });
        for (s.samples, 0..) |v, j| try json.print(gpa, "{s}{d:.0}", .{ if (j == 0) "" else ",", v });
        try json.appendSlice(gpa, "]}");
        try json.appendSlice(gpa, if (i + 1 == seams.len) "\n" else ",\n");
    }
    try json.appendSlice(gpa, "  ]\n}\n");
    std.debug.print("\n(all figures µs; `answer` is the per-seam identity digest)\n", .{});
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/sessionprof.json", .data = json.items });
    std.debug.print("wrote {s}/sessionprof.json\n", .{out_dir});
}

/// Diff this run against a saved report: per seam, the median ratio plus a
/// two-sided Mann-Whitney verdict over the two sample sets, and an ANSWER check
/// — a seam whose identity digest moved is a behavior change, reported as such
/// rather than as a timing delta. Returns whether any seam regressed.
fn compare(gpa: std.mem.Allocator, io: std.Io, path: []const u8, seams: []const Seam) !bool {
    const bytes = Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch {
        std.debug.print("\nbaseline {s}: unreadable — skipping comparison\n", .{path});
        return false;
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch {
        std.debug.print("\nbaseline {s}: unparseable — skipping comparison\n", .{path});
        return false;
    };
    defer parsed.deinit();

    const rows = parsed.value.object.get("seams").?.array.items;

    // The ambient tax per class first: everything below is read against its own
    // class's calibrator, so a run on a busier box reports the machine's slowdown
    // once per cost class instead of once per seam. A calibrator missing from
    // either run leaves its class at 1.0 — uncalibrated, and reported as such.
    var ambient = std.enums.directEnumArray(Class, f64, 0, .{ .scan = 1.0, .fanout = 1.0 });
    for (seams) |s| {
        for (calibrators, 0..) |name, class| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            const row = rowFor(rows, name) orelse continue;
            ambient[class] = leastOf(s.samples) / @max(baseLeast(row), 1.0);
        }
    }

    std.debug.print("\nvs baseline {s}\n", .{path});
    for (calibrators, ambient) |name, tax| {
        if (tax == 1.0)
            std.debug.print("{s}: absent from one run — that class's `norm r` is uncalibrated\n", .{name})
        else
            std.debug.print("{s}: ambient tax {d:.3}× (its own best-of-N ratio)\n", .{ name, tax });
    }
    std.debug.print("{s:<34} {s:>11} {s:>11} {s:>8}  {s:>8}  {s:>8}  {s:>9}  {s}\n", .{ "seam", "base p50", "now p50", "p50 r", "best r", "norm r", "p", "verdict" });
    std.debug.print("{s:-<34} {s:->11} {s:->11} {s:->8}  {s:->8}  {s:->8}  {s:->9}  {s:-<16}\n", .{ "", "", "", "", "", "", "", "" });

    var regressed = false;
    for (seams) |s| {
        const row = rowFor(rows, s.name) orelse {
            std.debug.print("{s:<34} {s:>11} {s:>11} {s:>8}  {s:>8}  {s:>8}  {s:>9}  new\n", .{ s.name, "-", "-", "-", "-", "-", "-" });
            continue;
        };
        const base_samples = row.get("samples").?.array.items;
        const base = try gpa.alloc(f64, base_samples.len);
        defer gpa.free(base);
        for (base_samples, base) |v, *b| b.* = switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => 0,
        };
        const now = try gpa.dupe(f64, s.samples);
        defer gpa.free(now);

        const base_answer = std.fmt.parseInt(u64, row.get("answer").?.string, 16) catch 0;
        if (base_answer != s.fingerprint) {
            std.debug.print("{s:<34} {s:>11} {s:>11} {s:>8}  {s:>8}  {s:>8}  {s:>9}  ANSWER CHANGED ({x} → {x})\n", .{ s.name, "-", "-", "-", "-", "-", "-", base_answer, s.fingerprint });
            regressed = true;
            continue;
        }
        // Sized from the two sets actually being ranked, never from this run's
        // `--reps`: a baseline taken at a different rep count is the normal case,
        // and `dominance` sorts the buffer in place over all of it.
        const rk = try gpa.alloc(f64, base.len + now.len);
        defer gpa.free(rk);
        const d = stats.dominance(now, base, rk, 0.05);
        // Best-of-N survives transient contention and the calibrator divides out
        // the sustained bandwidth tax, so a distributional `loss` only counts as a
        // regression when the normalized minima agree — else the box moved, not
        // the code. The calibrator itself is never a regression: it IS the box.
        const best = leastOf(s.samples) / @max(leastOf(base), 1.0);
        const norm = best / ambient[@intFromEnum(s.class)];
        const own = std.mem.eql(u8, s.name, calibrators[@intFromEnum(s.class)]);
        const real = d.verdict == .loss and !own and norm > min_corroboration;
        if (real) regressed = true;
        std.debug.print("{s:<34} {d:>11.3} {d:>11.3} {d:>8.3}  {d:>8.3}  {d:>8.3}  {d:>9.4}  {s}{s}\n", .{
            s.name,          d.b_median / 1000.0, d.a_median / 1000.0,
            1.0 / d.speedup, best,                norm,
            d.p,             @tagName(d.verdict),
            if (d.verdict == .loss and !real)
                if (own) " (this IS the ambient tax)" else " (ambient, not the code)"
            else
                "",
        });
    }
    std.debug.print(
        \\
        \\(ratios are now/base; <1 faster. `p50 r` is the median ratio, and `p50`/`p` come from a
        \\ two-sided Mann-Whitney at alpha=0.05, so `parity` means statistically indistinguishable.
        \\ `best r` is best-of-N — the estimator that survives coworker load — and `norm r` divides
        \\ that by the frozen calibrator for the seam's own cost class, i.e. asks whether the seam
        \\ slowed by MORE than the machine did at that kind of work. A `loss` is called a regression
        \\ only when `norm r` exceeds {d:.2}.)
        \\
    , .{min_corroboration});
    return regressed;
}

/// Threshold the calibrator-normalized best-of-N ratio must clear before a
/// distributional `loss` is believed. 2% is comfortably above the run-to-run
/// drift left once the ambient tax is divided out, and far below the smallest
/// regression worth acting on.
const min_corroboration = 1.02;

/// The frozen ambient probes' seam names, indexed by `Class` — the rows `compare`
/// reads before any other, and the only seams whose own delta is a statement about
/// the machine rather than about the code.
const calibrators = std.enums.directEnumArray(Class, []const u8, 0, .{
    .scan = "calibrate memscan",
    .fanout = "calibrate fanout",
});

fn leastOf(samples: []const f64) f64 {
    var lo = samples[0];
    for (samples[1..]) |v| lo = @min(lo, v);
    return lo;
}

/// The baseline row for `name`, or null when the baseline predates that seam.
fn rowFor(rows: []const std.json.Value, name: []const u8) ?std.json.ObjectMap {
    for (rows) |r| if (std.mem.eql(u8, r.object.get("name").?.string, name)) return r.object;
    return null;
}

/// A baseline row's sample minimum, read straight out of the report.
fn baseLeast(row: std.json.ObjectMap) f64 {
    return switch (row.get("min_ns").?) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => 0,
    };
}
