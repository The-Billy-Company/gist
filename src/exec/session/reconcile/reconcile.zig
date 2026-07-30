//! The fail-closed read-your-writes barrier — the only writer in the resident
//! session, and the reason a warm answer cannot drift from a cold one.
//!
//! `barrier` is the entry point every query passes through when the watcher
//! cannot prove the roots quiescent. It brings the overlay current against the
//! set the cold path would walk RIGHT NOW, by one of two routes:
//!
//!   - **scoped** (O(changed)) — verify ONLY the paths an exact watcher backend
//!     drained, each verdict re-derived through the cold walk's own `Ignore`
//!     machinery (`delta.zig`). Sound only downstream of one covering full pass,
//!     under a doubt-free exact log; any refusal degrades to the full route.
//!   - **full** (O(tree)) — re-derive the whole authoritative set through the
//!     parallel fused walk and diff it against base + overlay.
//!
//! Fail-closed is the load-bearing property, not an error-handling detail: a
//! rebuilt index or a WALK ERROR (an unreadable
//! directory — cold reports it and exits 2, so a clean-looking warm answer over
//! the gap would silently drop files) declines with `freshness_unprovable`, and
//! the daemon answers on the certified cold path. Allocation failure remains a
//! real `OutOfMemory` fault. Nothing here ever trusts stale bytes to avoid work.
//!
//! `guardExtras` rides along because it is the same double-checked dance over a
//! held lease, applied to the one derived artifact a scoped pass cannot refresh.

const std = @import("std");
const assay = @import("../../../assay/assay.zig");
const bulkstat = @import("../../../corpus/tree/bulkstat.zig");
const delta_mod = @import("delta.zig");
const answer = @import("../answer/answer.zig");
const overlay = @import("../warm/overlay.zig");
const request = @import("../answer/request.zig");
const resident = @import("../warm/resident.zig");
// `underRoot` only — the same root-containment rule `PathFilter` scopes an
// answer with, so the coverage guard and the pruning it protects agree.
const scope = @import("../../../corpus/scope/filter.zig");
// The resident file set is the certified rg-default walk the cold path uses, NOT
// `haystack`'s coarse superset — this is what makes `resident == --no-index ==
// rg` true for hidden files, `.gitignore` precedence, and root scope.
const run = @import("../../cold/engine/serial.zig");
// The parallel fused walk (`cold/engine/swarm/`), reached ONLY through its callable
// `collectFileSet` — the full-reconcile file set via the same work-stealing
// getattrlistbulk walk the cold `--files` path uses, ~3x faster than the serial
// `defaultFileSet` readdir walk.
const pengine = @import("../../cold/engine/swarm/roster.zig");
const ResidentSession = resident.ResidentSession;
const Ceiling = answer.Ceiling;
const QueryError = answer.QueryError;
const Dir = std.Io.Dir;

/// Bring the overlay current against the certified rg-default walk. No-op on
/// the watcher-clean fast path. Re-derives the authoritative file set the
/// cold path would walk RIGHT NOW and diffs it against the resident base +
/// overlay: a file that left the set (deleted, or newly hidden/ignored) is
/// tombstoned; a new file is read in; a file whose mtime/ctime advanced past
/// the freshness cursor is re-read. This is the whole read-your-writes
/// barrier — the set comes from the SAME walk as cold, so warm answers can't
/// drift from `gist --no-index`/`rg`. A walk error (unreadable directory —
/// cold reports it and exits 2) declines with `freshness_unprovable`; allocation
/// failure remains `OutOfMemory`.
pub fn barrier(self: *ResidentSession, ceil: Ceiling) QueryError!bool {
    if (!try maybeReload(self)) return false;
    if (self.seqlock.skip()) return true;

    const seq0 = self.seqlock.enter();
    const now = std.Io.Clock.now(.real, self.io).nanoseconds;

    // Drain the exact dirty set (always — even a full walk must consume
    // it, or stale entries would replay forever). The scoped path is taken
    // only when EVERY soundness gate holds: a live watcher whose backend
    // reports exact paths, no doubt (overflow/drop/unclassifiable event),
    // no poison, and one prior full pass that overlapped the stream.
    var drained = self.dirty_log.drain(self.gpa);
    defer drained.deinit(self.gpa);
    const scoped_eligible = self.seqlock.eligible() and
        self.full_pass_done and drained.exact and !drained.doubt;
    const applied = scoped_eligible and try scoped(self, drained.paths);
    if (applied) {
        _ = self.scoped_reconciles.fetchAdd(1, .monotonic);
        // A scoped pass touched only the changed paths, never the whole-tree
        // extras derivation — so a `-t`/`-g` query must refresh before it can
        // trust the list (`guardExtras` → `refreshExtras`).
        self.extras_stale = true;
    } else {
        if (!try full(self, ceil)) return false;
        if (self.seqlock.armed()) self.full_pass_done = true;
        _ = self.full_reconciles.fetchAdd(1, .monotonic);
    }

    self.fresh_ns = now;
    // Republish the clean short-circuit only if a watcher is live AND no
    // event raced this reconcile (the seqlock recheck). Without a watcher,
    // `commit` is a no-op and the session stays dirty.
    self.seqlock.commit(seq0);
    return true;
}

/// Rebuild the resident corpus/index when the on-disk index generation has
/// advanced (someone ran `gist index`). Heavy but rare; holds the caller's
/// lock. On a non-allocation rebuild failure the session keeps its old state
/// and declines so the query is answered cold.
fn maybeReload(self: *ResidentSession) QueryError!bool {
    const cur = try resident.readGen(self.gpa, self.io);
    defer self.gpa.free(cur);
    if (std.mem.eql(u8, cur, self.index_gen)) return true;

    // Build the replacement engine BEFORE tearing the stale one down, so a
    // rebuild failure leaves this session fully intact (→ Stale, cold
    // fallback). init dupes `self.roots` into its own arena before we free
    // the old roots_arena below.
    var fresh = ResidentSession.init(self.gpa, self.io, self.roots) catch |e| return switch (e) {
        error.OutOfMemory => QueryError.OutOfMemory,
        else => false,
    };
    // The watcher notes into THIS session's log + annals; the replacement's
    // own (empty) pair is surplus. `full_pass_done` survives: the event
    // stream ran across the rebuild, so init's fresh corpus read IS a
    // covering full pass and pending events stay queued for the next drain.
    fresh.dirty_log.deinit();
    fresh.annals.deinit();

    // Free only the stale DATA.
    overlay.clear(self);
    self.overlay.deinit();
    overlay.freeNonAscii(&self.nonascii_keys, self.gpa);
    self.gpa.free(self.index_gen);
    self.by_path.deinit();
    self.idx.deinit();
    self.mir.deinit();
    self.extras_arena.deinit();
    self.roots_arena.deinit();

    // Move the fresh engine's data fields into place, field-by-field, and
    // leave the synchronization + identity fields alone: the `ward` is HELD
    // exclusively by the caller (reconcile is the writer; a whole-struct
    // `self.* = fresh` would reset it, dropping the write lock out from under
    // the caller's `defer`); the `seqlock` (event counter, clean witness,
    // arm/poison state) stays monotonic; `gpa`/`io`/`daemon_gen` are
    // unchanged. `fresh`'s own ward/seqlock/identity are
    // default-initialized and unused, and every owning field has been moved
    // out of it, so it needs no deinit.
    self.roots_arena = fresh.roots_arena;
    self.roots = fresh.roots;
    self.mir = fresh.mir;
    self.idx = fresh.idx;
    self.by_path = fresh.by_path;
    self.index_gen = fresh.index_gen;
    self.fresh_ns = fresh.fresh_ns;
    self.overlay = fresh.overlay;
    // The rebuilt corpus carries its own freshly-seeded non-ASCII key set.
    self.nonascii_keys = fresh.nonascii_keys;
    // The fresh init re-walked the extras from the rebuilt corpus (fresh and
    // authoritative); move the arena + list and drop the scoped-stale latch.
    self.extras_arena = fresh.extras_arena;
    self.extras = fresh.extras;
    self.extras_stale = fresh.extras_stale;

    self.markDirty(); // a rebuilt index demands a reconcile pass
    return true;
}

/// The O(tree) barrier: re-derive the whole authoritative set and diff it
/// against base + overlay. Always sound; the scoped path's fallback.
fn full(self: *ResidentSession, ceil: Ceiling) QueryError!bool {
    const trace = assay.lit(.reconcile);
    var span: assay.Span = if (trace) assay.Span.open(self.io) else undefined;
    var walk_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer walk_arena.deinit();
    // Re-derive the whole authoritative set through the parallel fused walk
    // (`collectFileSet`) — the same ignore-certified work-stealing
    // getattrlistbulk enumeration the cold `--files` path uses, ~3x faster
    // than the serial readdir walk. Ground truth: no phantom snapshot, so a
    // file created since the last index build is seen. Its `-t`/`-g` extras
    // are NOT gathered here (a files-only walk drops rejected entries), so
    // they are deferred below exactly as the scoped path defers them.
    const fs = try pengine.collectFileSet(self.gpa, self.io, self.roots, walk_arena.allocator());
    // An errored walk is a GAPPED set. Cold would report the unreadable
    // directory to stderr and exit 2; serving a clean-looking warm answer
    // over the gap would silently drop its files. Decline (and never mark
    // clean) until a walk completes without error.
    if (fs.walk_error) return false;
    const cur = fs.entries;
    const walk_dur: assay.Duration = if (trace) span.lap(self.io) else undefined;

    var cur_set = std.StringHashMap(void).init(self.gpa);
    defer cur_set.deinit();
    try cur_set.ensureTotalCapacity(@intCast(cur.len));
    for (cur) |e| cur_set.putAssumeCapacity(e.path, {});

    for (cur, 0..) |e, i| {
        if (ceil.over(self.io, i)) {
            self.noteBudgetAbort();
            return false;
        }
        try one(self, e.path, e.mtime_ns, e.ctime_ns);
    }
    if (trace) {
        assay.diag("reconcileFull: walk {d:.1} ms ({d} files) · reread {d:.1} ms\n", .{
            walk_dur.ms(), cur.len, span.read(self.io).ms(),
        });
    }
    try tombstoneVanished(self, &cur_set);
    // The parallel files walk yields no `-t`/`-g` extras, so latch them stale
    // (like the scoped path): the next `-t`/`-g` query fail-closed-refreshes
    // via `guardExtras` → `refreshExtras`. Set only after a clean, complete
    // pass — a budget abort above returns first, keeping the prior list.
    self.extras_stale = true;
    return true;
}

/// The O(changed) barrier: verify ONLY the drained watcher paths against
/// the live tree, with `delta.Delta` re-deriving each membership verdict
/// through the walk's own ignore machinery. Returns false whenever ANY
/// resolution cannot be scoped soundly (ignore-source edit, root event,
/// unmappable path, unreadable directory) — the caller then runs the full
/// walk. Partial overlay mutations before a false return are harmless: each
/// only moved a path toward its current on-disk truth, and the full walk
/// re-derives everything. Non-ASCII paths ARE scoped (the `realpath` oracle
/// canonicalizes them); a stale normalization/case twin the batch never
/// named is caught by the closing `sweepNonAscii` on a case-insensitive fs.
fn scoped(self: *ResidentSession, abs_paths: []const []const u8) QueryError!bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dl = try delta_mod.Delta.init(a, self.io, self.roots);
    if (!dl.enabled) return false;

    var gones: std.StringHashMapUnmanaged(void) = .empty; // ASCII-folded gone keys
    var subtrees: std.ArrayList([]const u8) = .empty;
    for (abs_paths) |p| {
        const verdict = try dl.resolve(p);
        switch (verdict) {
            .skip => {},
            .needs_full => return false,
            .file => |rel| try one(self, rel, null, null),
            .subtree => |rel| try subtrees.append(a, rel),
            .gone => |rel| try gones.put(a, try delta_mod.foldLower(a, rel), {}),
        }
        // A case-insensitive filesystem resolves an event's own spelling to
        // a possibly-different canonical key (a case-rename's OLD spelling
        // realpaths to the NEW file). When they differ, the raw spelling
        // names a corpus key that may have just become stale — sweep it
        // like a gone (its keys survive only if still provably current).
        const canon_rel: ?[]const u8 = switch (verdict) {
            .file, .subtree, .gone => |rel| rel,
            else => null,
        };
        if (canon_rel) |rel| if (dl.rawKey(p)) |raw| {
            if (!std.mem.eql(u8, raw, rel)) try gones.put(a, try delta_mod.foldLower(a, raw), {});
        };
    }
    for (subtrees.items) |rel| if (!try applySubtree(self, &dl, a, rel)) return false;
    if (gones.count() != 0) try applyGones(self, &dl, a, &gones);
    if (comptime overlay.is_macos) try sweepNonAscii(self, &dl);
    return true;
}

/// Re-verify every live corpus key carrying a byte ≥ 0x80 against the
/// `realpath` oracle, tombstoning any that is no longer a current,
/// canonically-spelled member. This is the one aliasing the ASCII fold in
/// `applyGones`/`applySubtree` can't model: on a case-insensitive fs a stale
/// Unicode normalization/case TWIN of a path this batch never named (café
/// NFC vs NFD, café.txt after a case-rename its own event didn't carry) is
/// invisible to byte/ASCII-fold matching but resolves — through realpath — to
/// a DIFFERENT on-disk key than it spells. O(|non-ASCII keys|), zero when the
/// set is empty (the overwhelming common case). macOS-only (the caller gates
/// it); Linux scopes only byte-exact roots, so no twin can exist.
fn sweepNonAscii(self: *ResidentSession, dl: *delta_mod.Delta) QueryError!void {
    if (self.nonascii_keys.count() == 0) return;
    var doomed: std.ArrayList([]const u8) = .empty;
    defer doomed.deinit(self.gpa);
    var it = self.nonascii_keys.keyIterator();
    while (it.next()) |k| if (!try dl.keyIsCurrent(k.*)) try doomed.append(self.gpa, k.*);
    // `overlay.put(.tombstone)` retires each doomed key FROM the set as it
    // goes; `doomed` holds the distinct backing slices, so this drains the
    // snapshot without mutating the map mid-iteration.
    for (doomed.items) |k| try overlay.put(self, k, .tombstone);
}

/// Fold one live-directory event into the overlay: read/refresh everything
/// the walk admits under it right now, then tombstone every corpus key in
/// its (ASCII-fold) scope that the fresh enumeration didn't produce and
/// that is no longer a current, canonically-spelled member — deletes,
/// newly-hidden files, and stale case spellings after a rename all fall
/// out of the same predicate.
fn applySubtree(self: *ResidentSession, dl: *delta_mod.Delta, a: std.mem.Allocator, rel: []const u8) QueryError!bool {
    var sink: std.StringHashMapUnmanaged(void) = .empty;
    switch (try dl.walkSubtree(rel, &sink)) {
        .declined => return false, // unenumerable subtree — only the full walk is sound
        .got => {},
    }
    var it = sink.keyIterator();
    while (it.next()) |k| try one(self, k.*, null, null);

    const fold_rel = try delta_mod.foldLower(a, rel);
    var doomed: std.ArrayList([]const u8) = .empty;
    defer doomed.deinit(self.gpa);
    var keys = overlay.liveKeys(self);
    while (keys.next()) |k| {
        if (!delta_mod.foldUnderLower(k, fold_rel)) continue;
        if (sink.contains(k)) continue; // freshly verified member
        if (try dl.keyIsCurrent(k)) continue; // distinct sibling on a case-sensitive fs
        try doomed.append(self.gpa, k);
    }
    for (doomed.items) |k| try overlay.put(self, k, .tombstone);
    return true;
}

/// Fold the drained gone-set into the overlay: any corpus key at-or-under
/// a gone path (ASCII-folded, so a case-variant event spelling still finds
/// its canonical key) is tombstoned unless the live tree proves it is
/// still a current, canonically-spelled member.
fn applyGones(self: *ResidentSession, dl: *delta_mod.Delta, a: std.mem.Allocator, gones: *const std.StringHashMapUnmanaged(void)) QueryError!void {
    var doomed: std.ArrayList([]const u8) = .empty;
    defer doomed.deinit(self.gpa);
    var keys = overlay.liveKeys(self);
    while (keys.next()) |k| {
        const lk = try delta_mod.foldLower(a, k);
        var hit = gones.contains(lk);
        var i: usize = 0;
        while (!hit) {
            const slash = std.mem.indexOfScalarPos(u8, lk, i, '/') orelse break;
            hit = gones.contains(lk[0..slash]);
            i = slash + 1;
        }
        if (!hit) continue;
        if (try dl.keyIsCurrent(k)) continue;
        try doomed.append(self.gpa, k);
    }
    for (doomed.items) |k| try overlay.put(self, k, .tombstone);
}

/// Fold one currently-authoritative path into the overlay. A new or
/// reappeared (previously tombstoned) path is read unconditionally; an
/// already-known path is re-read only when its mtime/ctime advanced past the
/// freshness cursor — the incremental catch-up that keeps reconcile from
/// re-reading an unchanged corpus every query. `mtime_ns`/`ctime_ns` are the
/// clocks the enumerating walk already captured (`collectFileSet`'s
/// `getattrlistbulk` listing); null (the scoped/subtree callers) falls back
/// to one `statFile`. Using the walk-time clocks is sound: `fresh_ns` is
/// anchored BEFORE the walk (see `barrier`), so any write the walk didn't
/// observe is caught on the next pass — the same window `statFile` raced.
fn one(self: *ResidentSession, p: []const u8, mtime_ns: ?i128, ctime_ns: ?i128) QueryError!void {
    if (self.overlay.get(p)) |ov| switch (ov) {
        .tombstone => return overlay.readInto(self, p), // reappeared since its delete
        .doc => {}, // already substituted — fall through to the mtime gate
    } else if (!self.by_path.contains(p)) {
        return overlay.readInto(self, p); // brand-new file, not in the base corpus
    }
    var mt = mtime_ns;
    var ct = ctime_ns;
    if (mt == null or ct == null) {
        const st = Dir.cwd().statFile(self.io, p, .{}) catch return overlay.readInto(self, p);
        mt = st.mtime.nanoseconds;
        ct = st.ctime.nanoseconds;
    }
    if (bulkstat.needsLiveRead(self.fresh_ns, mt, ct)) return overlay.readInto(self, p);
}

/// Tombstone every base doc or overlaid file that is no longer in the
/// authoritative set (deleted, or newly hidden/gitignored). Removals are
/// collected before mutating `overlay` (no mutation mid-iteration).
fn tombstoneVanished(self: *ResidentSession, cur_set: *const std.StringHashMap(void)) QueryError!void {
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(self.gpa);
    var keys = overlay.liveKeys(self);
    while (keys.next()) |k| if (!cur_set.contains(k)) try gone.append(self.gpa, k);
    for (gone.items) |p| try overlay.put(self, p, .tombstone);
}

/// Dupe an `Extra` slice (path bytes + kind) into `a` — the session-lived
/// copy of the walk-arena list, so it survives the walk arena's teardown.
pub fn dupeExtras(a: std.mem.Allocator, src: []const run.Extra) std.mem.Allocator.Error![]const run.Extra {
    const out = try a.alloc(run.Extra, src.len);
    for (src, out) |s, *d| d.* = .{ .rel = try a.dupe(u8, s.rel), .kind = s.kind };
    return out;
}

/// Replace `extras` with a freshly-walked list, resetting the owning arena,
/// and clear the scoped-staleness latch. Writer-only (`full` and
/// `refreshExtras`).
fn setExtras(self: *ResidentSession, src: []const run.Extra) QueryError!void {
    _ = self.extras_arena.reset(.retain_capacity);
    self.extras = dupeExtras(self.extras_arena.allocator(), src) catch return QueryError.OutOfMemory;
    self.extras_stale = false;
}

/// Re-derive `extras` from one certified default walk (extras-only; the
/// mirror was already reconciled), replacing the prior list and clearing the
/// scoped-stale latch. A gapped walk declines (→ cold), like `full`.
/// Writer-only — the caller holds the exclusive lease.
fn refreshExtras(self: *ResidentSession) QueryError!bool {
    var walk_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer walk_arena.deinit();
    var sel_extras: []const run.Extra = &.{};
    const fs = try run.defaultFileSetExtras(walk_arena.allocator(), self.io, self.roots, &sel_extras);
    if (fs.path_error) return false;
    try setExtras(self, sel_extras);
    return true;
}

/// Does the mirror hold at least one path under every requested root? Naming a
/// root is naming intent: cold exempts an explicitly given PATH from the ignore
/// and hidden rules (`walk.zig::gather` → `Ignore.scopeToRoot`), matching rg, so
/// `gist pat ign/` searches a gitignored subtree that the whole-tree default
/// walk behind the mirror pruned entirely. Such a root leaves no `Extra` either
/// — the walk stops descending AT the pruned directory — so the extras guard
/// below cannot see it, and scoping the mirror to it would render a clean "no
/// match" where cold and rg both answer.
///
/// Coverage is the uniform test for that, needing no ignore machinery: a root
/// the mirror can serve has files in it. Zero coverage means either a pruned
/// root (cold answers, warm must not) or a genuinely empty one (cold answers
/// nothing, and so would warm) — declining both is fail-open, costing a covered
/// root only the scan up to its first hit and an uncovered one one pass.
fn rootsCovered(self: *const ResidentSession, roots: []const []const u8) bool {
    outer: for (roots) |r| {
        for (self.mir.paths) |p| if (scope.underRoot(p, r)) continue :outer;
        return false;
    }
    return true;
}

/// Fail-closed guard for the two ways a request can reach past the mirror: a
/// positional root the default walk pruned (`rootsCovered`), and the `Extra`
/// gap (`serial.zig`) — a `-t`/`-g` query un-hides/un-ignores files the mirror,
/// built from that same hidden/ignore-excluding walk, cannot hold. If either
/// holds, decline so the client answers on the certified cold path (which walks
/// them): the flagship "index changes speed, never results" claim, restored for
/// scoped and filtered queries. An unrooted request with no type/glob filter can
/// reach neither and returns at once (the common path pays only three length
/// checks). When a prior scoped reconcile left the extras list stale, upgrade
/// the held lease to exclusive, refresh with one walk, and downgrade back — the
/// double-checked dance `Ward.reconcileHeld` runs — so `*held` always ends
/// holding a valid read lease and the caller's `defer` release stays balanced on
/// every path, error included.
pub fn guardExtras(self: *ResidentSession, held: *ResidentSession.Held, req: request.Request) QueryError!answer.Answer(void) {
    if (req.filter.roots.len != 0 and !rootsCovered(self, req.filter.roots))
        return .{ .declined = .freshness_unprovable };
    if (req.filter.exts.len == 0 and req.filter.includes.len == 0) return .{ .got = {} };
    var declined = false;
    const Ctx = struct { session: *ResidentSession, declined: *bool };
    const res = self.ward.reconcileHeld(
        held.lease,
        Ctx{ .session = self, .declined = &declined },
        struct {
            fn fresh(ctx: Ctx) bool {
                return !ctx.session.extras_stale;
            }
        }.fresh,
        struct {
            fn refresh(ctx: Ctx) QueryError!void {
                if (!try refreshExtras(ctx.session)) ctx.declined.* = true;
            }
        }.refresh,
    );
    held.lease = res.lease; // always live — the caller's `defer` stays balanced
    if (res.err) |e| return e;
    if (declined) return .{ .declined = .freshness_unprovable };
    for (self.extras) |ex| if (req.filter.surfacesHidden(ex.rel, ex.kind == .ignored))
        return .{ .declined = .freshness_unprovable };
    return .{ .got = {} };
}
