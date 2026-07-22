//! gist `index` — build + persist the trigram index and freshness anchor.
//!
//! The one mutating lifecycle action behind the `gist index` verb. Two speeds:
//!
//!   • AMEND (the default fast path): when a generation-published base exists
//!     for the same roots, derive the changed set since the LAST ANCHOR
//!     (daemon annals → journal replay → the T3 stat walk), union in the
//!     prior codicil's covered paths, and publish a CODICIL over just those
//!     docs — `corpus/index/trigrams/codicil.zig`. The base blobs are
//!     hardlinked forward, so the whole amend is milliseconds instead of a
//!     whole-corpus read. Zero changed files ⇒ a pure anchor advance. Falls
//!     back to the full build on ANY doubt: no base, different roots, a
//!     missing/torn `base.ns`, a walk failure, or too much drift (the
//!     compaction threshold — codicils always rebuild from the base, they
//!     never chain). `GIST_NO_AMEND=1` forces the full build (parity gate +
//!     escape hatch); `GIST_AMEND_MAX=N` overrides the drift threshold.
//!
//!   • FULL: scan the corpus (every non-binary file under the resolved roots),
//!     build the trigram `Index`, and generation-publish it plus the doc→path
//!     table, the build roots (`roots.list`), the base instant (`base.ns`),
//!     and the freshness anchor (`corpus/fresh.zig`) that later queries map
//!     back zero-copy. The persisted index is what the unified engine's
//!     read-elision path (`run.zig` `IndexSkip`) and the ranked view
//!     (`rank.zig`) consume.
//!
//! The self-anchored side artifacts (phantom `tree.map`, `content.shard`)
//! refresh only on a FULL build: both fail open per file (a stale entry means
//! a live list/read, never a wrong answer), so an amend soundly leaves them.

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const codicil = @import("../../../../corpus/index/trigrams/codicil.zig");
const journal = @import("../../../../corpus/tree/journal.zig");
const client = @import("../daemon/client/client.zig");
const session_spawn = @import("../../../exec/session/spawn.zig");
const crest_sidecar = @import("../../../../corpus/index/crest/sidecar.zig");
const treemap = @import("../../../../corpus/index/phantom/treemap.zig");
const shard = @import("../../../../corpus/index/content/shard.zig");
const Index = @import("../../../../corpus/index/trigrams/trigram.zig").Index;
const nowNs = @import("../../../exec/cold/argv/args.zig").nowNs;
const ms = @import("../../../exec/cold/argv/args.zig").ms;

/// Refresh the persisted index: amend incrementally when the base admits it,
/// else build + persist the full pair.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    if (!amendDisabled()) {
        if (amend(gpa, io, roots) catch false) return;
    }
    try full(gpa, io, roots);
}

fn full(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    const t0 = nowNs(io);
    // Filesystem-journal since-token, minted BEFORE the anchor so a replay
    // from it strictly over-covers (built_ns, now) — the token is what lets
    // later freshness questions (amends, T3 query overlays) skip the stat
    // walk entirely. Null (non-macOS, no journal) costs only that fast path.
    const jtok = journal.capture(io);
    // Wall-clock anchor captured BEFORE the read, so a file touched during the
    // build has mtime or status-ctime ≥ anchor and is re-verified next query.
    const built_ns = std.Io.Clock.now(.real, io).nanoseconds;
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    // Crest sidecar (the class-run sieve, research/crest/): one parallel pass
    // over the already-loaded docs. Best-effort — an OOM here costs only the
    // sieve, never the index build.
    const crest_vectors: ?[]const @import("../../../../kernel/primitives/crest.zig").Vector =
        crest_sidecar.build(gpa, corpus.docs) catch null;
    defer if (crest_vectors) |cv| gpa.free(cv);

    // Generation-atomic publish: all blobs stage under gens/<id>/, then
    // pair.gen flips — concurrent loaders never see a mixed old/new set.
    const index_bytes = try persist.persistIndexAndPaths(gpa, io, &idx, corpus.paths, roots, crest_vectors, built_ns);
    try fresh.writeAnchor(io, built_ns); // T3 freshness anchor
    if (jtok) |t| fresh.writeJournalToken(io, t); // journal since-token (best-effort)
    // Phantom tree.map (self-anchored, whole-CWD corpora only): best-effort —
    // a failure costs the phantom walk tier, never the index build.
    treemap.build(gpa, io, roots) catch {};
    // Content shard (self-anchored on the SAME `built_ns`, sharing this exact
    // corpus snapshot): best-effort — a failure costs the shard read tier, so a
    // full-scan query falls back to opening every file, never the index build.
    shard.build(gpa, io, corpus.docs, corpus.paths, built_ns) catch {};

    std.debug.print("indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(index_bytes)) / (1 << 20),
        ms(nowNs(io) - t0),
        corpus_mod.outDir(),
    });
}

/// The incremental path. True ⇒ published (or proved fresh) and reported;
/// false ⇒ the caller runs the full build. Every failure inside is a `false`,
/// never a wrong index — the codicil layer is fail-closed end to end.
///
/// Structured so the NO-CHANGE case (the overwhelmingly common re-index) pays
/// only header reads: `pair.gen` + `roots.list` + `base.ns` are each a tiny
/// file, the changed set comes from the resident daemon's annals (one warm
/// map lookup behind a FlushSync barrier) or the journal replay, and the pair
/// itself — the mmap + doc path-table parse — is loaded ONLY once changes
/// provably exist and a codicil must be built.
fn amend(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !bool {
    const t0 = nowNs(io);
    const trace = std.c.getenv("GIST_AMEND_TRACE") != null;
    const out_dir = corpus_mod.outDir();
    // New anchor, captured BEFORE the changed-set derivation (same discipline
    // as the full build): a file touched while we amend is re-verified by the
    // next query. The daemon consult stays sound against it because the
    // FlushSync barrier runs AFTER this instant — every event that occurred
    // before it has been noted by the time the annals answer.
    const built_ns = std.Io.Clock.now(.real, io).nanoseconds;

    // Cheap header reads only — no mmap, no path table.
    const gen = persist.readPublishedGeneration(gpa, io) catch return false;
    defer gpa.free(gen);
    if (gen.len == 0) return false; // legacy layout: no generation to bind to
    var disk_roots = persist.readRootsAt(gpa, io, out_dir, gen) orelse return false;
    defer disk_roots.deinit();
    if (!rootsEquivalent(gpa, roots, disk_roots.roots.items)) return false;
    const base_ns = persist.readBaseNs(gpa, io, out_dir, gen) orelse return false;
    // The changed-set question is asked since the LAST ANCHOR, not the base
    // build: the published pair already reflects everything up to the anchor
    // (that is the anchor's induction invariant — it only advances after a
    // covering publish), and the prior codicil's own covered paths are
    // unioned back in below before the new codicil builds from base. A
    // seconds-old window is what makes the daemon consult work at all: the
    // annals only cover from daemon boot, so "since base" (hours ago) would
    // decline forever, while "since the last amend" is answerable one round
    // after boot. Anchor missing/behind-base ⇒ the base instant itself.
    const since_ns = @max(fresh.readAnchor(gpa, io) orelse base_ns, base_ns);
    if (trace) std.debug.print("amend: probe {d:.1} ms\n", .{ms(nowNs(io) - t0)});

    // Three tiers, each the next one's fallback: daemon annals → journal
    // replay → the T3 stat walk (the latter two live in `fresh.changedSince`).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var changed: std.ArrayList([]const u8) = .empty;
    const t_walk = nowNs(io);
    if (!annalsChanged(gpa, io, disk_roots.roots.items, since_ns, arena.allocator(), &changed)) {
        // No daemon answer this time — fire a detached spawn so the NEXT
        // amend lands warm (flock-singleton, so racers are free), then run
        // the proven fallback.
        spawnForNextAmend(gpa, io);
        fresh.changedSince(gpa, io, disk_roots.roots.items, since_ns, arena.allocator(), &changed) catch return false;
    } else if (trace) std.debug.print("amend: annals answered\n", .{});
    if (trace) std.debug.print("amend: changed-set {d:.1} ms ({d} changed)\n", .{ ms(nowNs(io) - t_walk), changed.items.len });

    if (changed.items.len == 0) {
        // Nothing moved: advance the anchor and stop — the pair never loads.
        fresh.writeAnchor(io, built_ns) catch return false;
        std.debug.print("amended 0 docs (fresh) · {d:.1} ms → {s}\n", .{ ms(nowNs(io) - t0), out_dir });
        return true;
    }

    // Changes exist: NOW pay the pair load (mmap + path table) the codicil
    // build needs. Re-bind to the generation we probed — a concurrent publish
    // between probe and load means our changed set describes a stale base.
    var p = (persist.loadQuiet(gpa, io) catch return false) orelse return false;
    defer p.deinit();
    if (trace) std.debug.print("amend: load {d:.1} ms\n", .{ms(nowNs(io) - t0)});
    const pgen = p.gen orelse return false;
    if (!std.mem.eql(u8, pgen, gen)) return false;

    const base_docs: usize = p.idx.doc_count;
    // Union the PRIOR codicil's covered paths back in: `changed` only spans
    // (anchor, now), but the new codicil replaces the old one and must retell
    // everything since the BASE. Every path the old blob touched — re-indexed
    // docs, tombstoned docs, appended new docs — gets re-derived from live
    // bytes (unchanged ones rebuild byte-identical rows; `codicil.build`
    // dedupes). Slices alias `p`, which outlives the build call.
    if (p.cod) |c| {
        for (c.ids) |id| try changed.append(arena.allocator(), p.paths.items[id]);
        for (c.tombs) |id| try changed.append(arena.allocator(), p.paths.items[id]);
        for (p.paths.items[base_docs..]) |np| try changed.append(arena.allocator(), np);
    }
    if (changed.items.len > amendLimit(base_docs)) return false; // drifted too far — compact (full rebuild)

    var stats: codicil.BuildStats = .{};
    {
        const t_build = nowNs(io);
        // Mint the NEW generation id up front: the blob embeds the id it will
        // be published as, binding it to its own gens/<id>/ directory.
        var gen_buf: [32]u8 = undefined;
        const new_gen = persist.newGenId(io, &gen_buf) catch return false;
        // Classify against the BASE doc space only (paths beyond doc_count
        // were appended by the previous codicil; the new one re-derives them).
        const blob = (codicil.build(gpa, io, new_gen, base_ns, p.paths.items[0..base_docs], changed.items, &stats) catch return false) orelse null;
        if (trace) std.debug.print("amend: codicil build {d:.1} ms\n", .{ms(nowNs(io) - t_build)});
        if (blob) |b| {
            defer gpa.free(b);
            const t_pub = nowNs(io);
            persist.publishCodicil(io, out_dir, gen, new_gen, b) catch return false;
            if (trace) std.debug.print("amend: publish {d:.1} ms\n", .{ms(nowNs(io) - t_pub)});
        }
        // else: every changed path is a non-member (binary/oversize) — the
        // corpus is untouched, so advancing the anchor alone is sound.
    }
    fresh.writeAnchor(io, built_ns) catch return false;

    std.debug.print("amended {d} docs (+{d} new, {d} gone) of {d} · {d:.1} ms → {s}\n", .{
        stats.docs,
        stats.new,
        stats.tombs,
        base_docs,
        ms(nowNs(io) - t0),
        out_dir,
    });
    return true;
}

/// Tier-0 changed-set: ask the resident daemon's annals (one warm map lookup
/// behind the daemon's FlushSync barrier) instead of replaying the journal or
/// walking the tree. True ⇒ `out` holds the CONFIRMED walk-shaped changed set
/// (possibly empty — the fast path's whole prize). False on any uncertainty:
/// no daemon, version skew, an unarmed/poisoned ledger, a foreign watch
/// prefix, or a failed confirm — the caller falls back, never guesses.
fn annalsChanged(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, base_ns: i128, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) bool {
    if (comptime !journal.supported) return false; // annals arm off FSEvents only
    if (envDisabled("GIST_NO_ANNALS")) return false; // parity gate + escape hatch
    var sock_buf: [512]u8 = undefined;
    const sock = if (std.c.getenv("GIST_SESSION_SOCK")) |v|
        std.mem.span(v)
    else
        std.fmt.bufPrint(&sock_buf, "{s}/gistd.sock", .{corpus_mod.outDir()}) catch return false;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ans = client.consultChanged(gpa, io, arena.allocator(), sock, @intCast(base_ns)) orelse return false;

    // The ledger vouches for the daemon's WATCHED tree; it must be exactly the
    // tree this amend describes. The daemon arms its prefix as `realpath` of
    // its single watch root (the rootless daemon watches `.` from this same
    // repo), so equality with OUR realpath'd CWD proves both identity and
    // whole-tree coverage — a daemon scoped to a subtree fails this check.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_abs = std.c.realpath(".", &path_buf) orelse return false;
    if (!std.mem.eql(u8, std.mem.span(cwd_abs), ans.prefix)) return false;

    // Same confirm + admission pipeline the journal replay's answer runs, so
    // a daemon answer and a walk answer describe the same corpus surface
    // (the stat confirm also prunes the annals' sound-superset extras).
    return fresh.confirmChanged(gpa, io, roots, base_ns, ans.paths, a, out);
}

/// After a tier-0 miss, fire a detached `gist serve` so the next amend finds a
/// warm daemon — same opt-outs as the query path's auto-spawn (`spawn.zig`),
/// same flock-singleton safety. Best-effort; this amend proceeds regardless.
fn spawnForNextAmend(gpa: std.mem.Allocator, io: std.Io) void {
    if (comptime !session_spawn.can_spawn) return;
    for ([_][*:0]const u8{ "GIST_NO_AUTOSERVE", "GIST_NO_PARALLEL", "GIST_SESSION_SOCK" }) |k|
        if (std.c.getenv(k) != null) return;
    session_spawn.detach(gpa, io, "serve") catch {};
}

fn envDisabled(name: [*:0]const u8) bool {
    const v = std.c.getenv(name) orelse return false;
    const s = std.mem.span(v);
    return s.len != 0 and !std.mem.eql(u8, s, "0") and
        !std.ascii.eqlIgnoreCase(s, "false") and !std.ascii.eqlIgnoreCase(s, "no");
}

fn amendDisabled() bool {
    return envDisabled("GIST_NO_AMEND");
}

/// Above this many changed paths an amend stops paying: reading the drift
/// costs a meaningful fraction of the full build, and the codicil's postings
/// stop being "small". Compaction = the full rebuild the caller falls back to.
fn amendLimit(base_docs: usize) usize {
    if (std.c.getenv("GIST_AMEND_MAX")) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10) catch null) |n| return n;
    }
    return @max(512, base_docs / 8);
}

fn normalizeRoot(r: []const u8) []const u8 {
    var s = r;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    s = std.mem.trimEnd(u8, s, "/");
    return if (s.len == 0) "." else s;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Do this invocation's roots cover the SAME corpus the base was built over?
/// (Set equality after normalization; order-free.) Anything else — a narrower
/// or wider scope — must not amend: the codicil would bind a walk set the
/// base paths don't describe.
fn rootsEquivalent(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    const na = gpa.alloc([]const u8, a.len) catch return false;
    defer gpa.free(na);
    const nb = gpa.alloc([]const u8, b.len) catch return false;
    defer gpa.free(nb);
    for (a, na) |r, *n| n.* = normalizeRoot(r);
    for (b, nb) |r, *n| n.* = normalizeRoot(r);
    std.mem.sort([]const u8, na, {}, strLess);
    std.mem.sort([]const u8, nb, {}, strLess);
    for (na, nb) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}
