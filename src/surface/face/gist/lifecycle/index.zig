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
//!
//! A full build closes by publishing `tree.root` — the absolute directory the
//! whole artifact set describes (`corpus/index/frame/frame.zig`). Anchors date
//! files; only this says WHICH files, and every reader that trusts an anchor
//! re-proves it first.

const std = @import("std");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const codicil = @import("../../../../corpus/index/trigrams/codicil.zig");
const journal = @import("../../../../corpus/tree/journal.zig");
const client = @import("../daemon/client/client.zig");
const session_spawn = @import("../../../exec/session/conduit/spawn.zig");
const crest_sidecar = @import("../../../../corpus/index/crest/sidecar.zig");
const frame = @import("../../../../corpus/index/frame/frame.zig");
const treemap = @import("../../../../corpus/index/phantom/treemap.zig");
const shard = @import("../../../../corpus/index/content/shard.zig");
const Index = @import("../../../../corpus/index/trigrams/trigram.zig").Index;
const assay = @import("../../../../assay/assay.zig");
const fault = @import("../../../../fault.zig");
const portal = @import("../../../../portal.zig");

/// Refresh the persisted index: amend incrementally when the base admits it,
/// else build + persist the full pair.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    if (!envDisabled("GIST_NO_AMEND") and (amend(gpa, io, roots) catch false)) return;
    try full(gpa, io, roots);
}

fn full(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    const span = assay.Span.open(io);
    // Filesystem-journal since-token, minted BEFORE the anchor so a replay
    // from it strictly over-covers (built_ns, now) — the token is what lets
    // later freshness questions (amends, T3 query overlays) skip the stat
    // walk entirely. Null (non-macOS, no journal) costs only that fast path.
    const jtok = journal.capture(io);
    // Wall-clock anchor captured BEFORE the read, so a file touched during the
    // build has mtime or status-ctime ≥ anchor and is re-verified next query.
    // Typed `Anchor` (assay): only this producer can mint one, so a monotonic
    // stamp can never reach `writeAnchor`/the persisted generation.
    const built = assay.anchor(io);
    // `GIST_TRACE=index` splits what the summary can only report as one total.
    // "The index build got slow" has four unrelated causes — a colder corpus
    // walk, more trigram postings, a slower disk on publish, or a sidecar
    // stalling — and one wall-clock number distinguishes none of them.
    var phase = assay.Span.open(io);
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    assay.trace(.index, "index phase: corpus load {d:.1} ms · {d} docs · {d:.1} MiB\n", .{
        phase.lap(io).ms(), corpus.docs.len, @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
    });
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    assay.trace(.index, "index phase: trigram build {d:.1} ms\n", .{phase.lap(io).ms()});
    // Crest sidecar (the class-run sieve, research/crest/): one parallel pass
    // over the already-loaded docs. Best-effort — an OOM here costs only the
    // sieve, never the index build.
    const crest_vectors: ?[]const @import("../../../../kernel/primitives/crest.zig").Vector =
        crest_sidecar.build(gpa, corpus.docs) catch null;
    defer if (crest_vectors) |cv| gpa.free(cv);
    assay.trace(.index, "index phase: crest sieve {d:.1} ms · {s}\n", .{
        phase.lap(io).ms(), if (crest_vectors == null) "declined" else "built",
    });

    // Generation-atomic publish: all blobs stage under gens/<id>/, then
    // pair.gen flips — concurrent loaders never see a mixed old/new set.
    const index_bytes = try persist.persistIndexAndPaths(gpa, io, &idx, corpus.paths, roots, crest_vectors, built.ns());
    assay.trace(.index, "index phase: publish {d:.1} ms · {d:.1} MiB\n", .{
        phase.lap(io).ms(), @as(f64, @floatFromInt(index_bytes)) / (1 << 20),
    });
    try fresh.writeAnchor(io, built); // T3 freshness anchor
    if (jtok) |t| fresh.writeJournalToken(io, t); // journal since-token (best-effort)
    // Phantom tree.map (self-anchored, whole-CWD corpora only): best-effort —
    // a failure costs the phantom walk tier, never the index build.
    fault.spare("phantom tree.map (costs the phantom walk tier)", treemap.build(gpa, io, roots));
    // Content shard (self-anchored on the SAME `built_ns`, sharing this exact
    // corpus snapshot): best-effort — a failure costs the shard read tier, so a
    // full-scan query falls back to opening every file, never the index build.
    fault.spare(
        "content shard (costs the shard read tier)",
        shard.build(gpa, io, corpus.docs, corpus.paths, built.ns()),
    );
    // Bind the directory to this tree LAST: until it lands, every reader still
    // sees whatever binding was here before, so a rebuild that repurposes a
    // foreign artifact directory never exposes a window where the new anchor
    // vouches for the old tree's snapshot and shard. Best-effort — an
    // unwritable binding costs the warm tiers, never a wrong answer.
    frame.publishBinding(io, frame.treeRootFile());
    // The accelerator sidecars as one segment: each is individually best-effort
    // (`fault.spare`), so what matters here is what they cost together.
    assay.trace(.index, "index phase: sidecars {d:.1} ms · anchor+journal+treemap+shard+binding\n", .{phase.lap(io).ms()});

    const dur = span.read(io).ms();
    assay.summary(gpa, false, "indexed {d} files · {d:.1} MiB corpus · {d:.1} MiB index · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(index_bytes)) / (1 << 20),
        dur,
        corpus_mod.outDir(),
    }, .{
        .{ "artifact", "s", "index" },
        .{ "mode", "s", "full" },
        .{ "files", "d", corpus.docs.len },
        .{ "corpus_mib", "d:.1", @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20) },
        .{ "index_mib", "d:.1", @as(f64, @floatFromInt(index_bytes)) / (1 << 20) },
        .{ "ms", "d:.0", dur },
        .{ "path", "s", corpus_mod.outDir() },
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
    const span = assay.Span.open(io);
    const trace = assay.lit(.amend);
    const out_dir = corpus_mod.outDir();
    // Re-mint the journal since-token on EVERY amend (same before-the-anchor
    // discipline as the full build, so a replay from it strictly over-covers
    // the new anchor). Without this the token aged from the last FULL build
    // and the replay window only ever grew — on a busy tree the journal fast
    // path lost its race permanently. A per-amend token keeps the window at
    // "since the last amend", the size the per-query replay budget can answer.
    const jtok = journal.capture(io);
    // New anchor, captured BEFORE the changed-set derivation (same discipline
    // as the full build): a file touched while we amend is re-verified by the
    // next query. The daemon consult stays sound against it because the
    // FlushSync barrier runs AFTER this instant — every event that occurred
    // before it has been noted by the time the annals answer.
    const built = assay.anchor(io);

    // An artifact directory that isn't bound to this tree has nothing to amend
    // — its base describes other files, and its anchor dates them. Decline so
    // the caller runs the full build, which republishes the binding: pointing
    // `GIST_DIR` at a foreign directory and re-indexing is how you adopt it.
    if (!frame.boundHere()) return false;

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
    const since_ns = @max(if (fresh.readAnchor(gpa, io)) |a| a.ns() else base_ns, base_ns);
    if (trace) assay.diag("amend: probe {d:.1} ms\n", .{span.read(io).ms()});

    // Three tiers, each the next one's fallback: daemon annals → journal
    // replay → the T3 stat walk (the latter two live in `fresh.changedSince`).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var changed: std.ArrayList([]const u8) = .empty;
    const walk_span = assay.Span.open(io);
    if (!annalsChanged(gpa, io, disk_roots.roots.items, since_ns, arena.allocator(), &changed)) {
        // No daemon answer this time — fire a detached spawn so the NEXT
        // amend lands warm (flock-singleton, so racers are free), then run
        // the proven fallback.
        spawnForNextAmend(gpa, io);
        fresh.changedSince(gpa, io, disk_roots.roots.items, since_ns, arena.allocator(), &changed) catch return false;
    } else if (trace) assay.diag("amend: annals answered\n", .{});
    if (trace) assay.diag("amend: changed-set {d:.1} ms ({d} changed)\n", .{ walk_span.read(io).ms(), changed.items.len });

    if (changed.items.len == 0) {
        // Nothing moved: advance the anchor and stop — the pair never loads.
        fresh.writeAnchor(io, built) catch return false;
        if (jtok) |t| fresh.writeJournalToken(io, t); // re-arm the journal fast path
        // This path publishes no generation, so it never reaches the retention
        // that rides a publish. Run it anyway: `gist index` is the maintenance
        // verb, and a run that finds nothing to index is exactly when there is
        // time to retire what earlier runs superseded.
        persist.reclaimSuperseded(io, out_dir, gen);
        const dur = span.read(io).ms();
        assay.summary(gpa, false, "amended 0 docs (fresh) · {d:.1} ms → {s}\n", .{ dur, out_dir }, .{
            .{ "artifact", "s", "index" },
            .{ "mode", "s", "amend" },
            .{ "docs", "d", @as(usize, 0) },
            .{ "fresh", "s", "true" },
            .{ "ms", "d:.1", dur },
            .{ "path", "s", out_dir },
        });
        return true;
    }

    // Changes exist: NOW pay the pair load (mmap + path table) the codicil
    // build needs. Re-bind to the generation we probed — a concurrent publish
    // between probe and load means our changed set describes a stale base.
    var p = (persist.loadQuiet(gpa, io) catch return false) orelse return false;
    defer p.deinit();
    if (trace) assay.diag("amend: load {d:.1} ms\n", .{span.read(io).ms()});
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
        const build_span = assay.Span.open(io);
        // Mint the NEW generation id up front: the blob embeds the id it will
        // be published as, binding it to its own gens/<id>/ directory.
        var gen_buf: [32]u8 = undefined;
        const new_gen = persist.newGenId(io, &gen_buf) catch return false;
        // Classify against the BASE doc space only (paths beyond doc_count
        // were appended by the previous codicil; the new one re-derives them).
        const blob = (codicil.build(gpa, io, new_gen, base_ns, p.paths.items[0..base_docs], changed.items, &stats) catch return false) orelse null;
        if (trace) assay.diag("amend: codicil build {d:.1} ms\n", .{build_span.read(io).ms()});
        if (blob) |b| {
            defer gpa.free(b);
            const pub_span = assay.Span.open(io);
            persist.publishCodicil(io, out_dir, gen, new_gen, b) catch return false;
            if (trace) assay.diag("amend: publish {d:.1} ms\n", .{pub_span.read(io).ms()});
        }
        // else: every changed path is a non-member (binary/oversize) — the
        // corpus is untouched, so advancing the anchor alone is sound.
    }
    fresh.writeAnchor(io, built) catch return false;
    if (jtok) |t| fresh.writeJournalToken(io, t); // re-arm the journal fast path

    const dur = span.read(io).ms();
    assay.summary(gpa, false, "amended {d} docs (+{d} new, {d} gone) of {d} · {d:.1} ms → {s}\n", .{
        stats.docs,
        stats.new,
        stats.tombs,
        base_docs,
        dur,
        out_dir,
    }, .{
        .{ "artifact", "s", "index" },
        .{ "mode", "s", "amend" },
        .{ "docs", "d", stats.docs },
        .{ "new", "d", stats.new },
        .{ "gone", "d", stats.tombs },
        .{ "base_docs", "d", base_docs },
        .{ "ms", "d:.1", dur },
        .{ "path", "s", out_dir },
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
    const cwd_abs = portal.realpath(".", &path_buf) orelse return false;
    if (!std.mem.eql(u8, cwd_abs, ans.prefix)) return false;

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
    fault.spare("detach serve for the next amend", session_spawn.detach(gpa, io, "serve"));
}

fn envDisabled(name: [*:0]const u8) bool {
    const v = std.c.getenv(name) orelse return false;
    const s = std.mem.span(v);
    return s.len != 0 and !std.mem.eql(u8, s, "0") and
        !std.ascii.eqlIgnoreCase(s, "false") and !std.ascii.eqlIgnoreCase(s, "no");
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
    return std.mem.lessThan(u8, a, b);
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
