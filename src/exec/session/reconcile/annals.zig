//! gist resident session — the annals (the never-drained changed-path ledger).
//!
//! `DirtyLog` (dirty.zig) hands the watcher's changed set to the session's own
//! reconcile and is CONSUMED by every drain. The annals are the sibling ledger
//! for a different reader: a one-shot `gist index` amend, which dials the
//! daemon and asks "which corpus files changed since instant S?" — the answer
//! that replaces the ~100 ms stat walk (and the ~10 ms FSEvents historical
//! replay, whose fseventsd IPC floor a one-shot process can never dodge) with
//! one warm map lookup. Where the dirty log drains, the annals ACCRETE: every
//! exact file event is recorded as `path → last delivery instant`, so any
//! later query can be answered by filtering entries at/after its `since`.
//!
//! Fail-closed, in the journal replay's exact posture — every uncertainty
//! reads as "the annals cannot vouch" and the caller runs its proven fallback:
//!
//!   1. Answerable only when ARMED by a per-file-exact backend (macOS kqueue ·
//!      Linux inotify), and only for `since_ns >= floor_ns` — the coverage
//!      floor, set once every watch is registered (nothing before a vnode was
//!      watched is knowable) and advanced by every eviction.
//!   2. `doubt` is STICKY FOREVER (unlike the dirty log's per-drain doubt):
//!      an inexact event (rescan hint, kernel/user drop, id wrap, mount
//!      churn), an unmappable delivery, or an OOM while noting poisons the
//!      whole ledger — there is no full walk here to re-derive lost truth.
//!      It poisons the WHICH, though, not the WHETHER: every doubt is still an
//!      observed change, so it advances the epoch stamp too rather than
//!      silencing it (see `epoch`). Losing COVERAGE is the stronger failure
//!      and gets its own state (`goBlind`): once events stop arriving the
//!      stamp stops counting, so the epoch must decline instead of standing
//!      still under a moving tree.
//!   3. The ledger is BOUNDED (`cap` distinct paths). Overflow evicts the
//!      oldest half by delivery instant and advances `floor_ns` past them,
//!      so old queries decline instead of reading an amputated answer.
//!
//! Entries are stored REPO-RELATIVE: `note` strips the armed absolute root
//! prefix (accepting the `/System/Volumes/Data` firmlink alias a macOS path may
//! resolve under) and drops paths under walk-skipped directories —
//! the same shaping `journal.zig`'s replay applies, so an annals answer and a
//! journal answer describe the same corpus surface.
//!
//! Threading: `note`/`noteDoubt` run on the watcher (or FlushSync caller)
//! thread, `since` on the serve thread; the same shared `Latch` the dirty log
//! takes guards the map (the watcher thread has no `std.Io` handle for an
//! `Io.Mutex`).

const std = @import("std");
const haystack = @import("../../../corpus/tree/haystack.zig");
const Latch = @import("../../../kernel/math/lease.zig").Latch;

/// Distinct-path bound. Half again the journal replay's 8192-change answer
/// cap: a ledger this full means tree-wide churn where the amend's own drift
/// threshold forces a compaction anyway, so precision past it buys nothing.
pub const default_cap = 16384;

/// The Data-volume firmlink prefix fseventsd may key user paths under
/// (journal.zig documents the same alias for historical replay).
const data_volume_prefix = "/System/Volumes/Data";

/// One answered query: the armed absolute watch prefix (so the reader can
/// verify the ledger covers ITS tree) + the repo-relative paths noted at/after
/// `since`. Strings and slice are owned by the caller's allocator.
pub const Snapshot = struct {
    prefix: []const u8 = &.{},
    paths: []const []const u8 = &.{},

    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.prefix);
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
        self.* = .{};
    }
};

pub const Annals = struct {
    gpa: std.mem.Allocator,
    mu: Latch = .{},
    /// Repo-relative path (gpa-owned key) → wall instant of its LAST noted
    /// delivery. Delivery is at/after occurrence, so filtering deliveries
    /// `>= since` keeps every path that OCCURRED at/after `since` (a sound
    /// superset; the caller's stat confirm prunes the extras).
    map: std.StringHashMapUnmanaged(i128) = .empty,
    /// Coverage floor: a query is answerable only for `since_ns >= floor_ns`.
    /// Starts unarmed at +∞; arm sets it to the stream-live instant; each
    /// eviction advances it past the evicted deliveries.
    floor_ns: i128 = std.math.maxInt(i128),
    /// The armed absolute root prefix deliveries are stripped against
    /// (gpa-owned). Null until `arm` — notes before arming are dropped
    /// (nothing before the floor is answerable anyway).
    prefix: ?[]u8 = null,
    doubt: bool = false,
    /// Coverage is GONE, not merely unattributable — the backend has stopped
    /// delivering (an inotify queue overflow, a subtree that could not be
    /// re-watched). The distinction from `doubt` is the whole reason `epoch`
    /// can answer at all: doubt means "a change arrived that I could not
    /// place", so the WHETHER is still counted and every held answer still
    /// retires on the next event. Blindness means changes will stop arriving,
    /// so the stamp would stand still while the tree moved and a held answer
    /// would read fresh forever. This is the one state that makes `epoch`
    /// decline outright.
    blind: bool = false,
    cap: usize = default_cap,
    /// Monotone count of observed corpus changes — the ledger's other reading.
    /// `since` answers WHICH files moved; this answers WHETHER anything did,
    /// as one comparable number. That is all a cached whole-corpus answer needs
    /// to know it is still the answer, and it survives the eviction that makes
    /// the path map itself lossy.
    stamp: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Annals {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Annals) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.map.deinit(self.gpa);
        if (self.prefix) |p| self.gpa.free(p);
    }

    /// Arm the delivery prefix — called BEFORE the watcher stream starts, so no
    /// delivery is ever dropped for want of a prefix (a note before coverage
    /// opens is harmless: the floor still gates every query). OOM on the copy
    /// leaves the ledger unarmed — never answerable, still sound.
    pub fn arm(self: *Annals, abs_root: []const u8) void {
        const owned = self.gpa.dupe(u8, abs_root) catch return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.prefix) |p| self.gpa.free(p); // a re-armed watcher replaces it
        self.prefix = owned;
    }

    /// Coverage begins: the per-file-exact stream is live as of
    /// `coverage_start_ns` (captured AFTER the stream started, so every event
    /// at/after it is delivered — and, `arm` having run first, noted).
    pub fn openCoverage(self: *Annals, coverage_start_ns: i128) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.floor_ns = coverage_start_ns;
    }

    /// Extend coverage BACKWARD to `older_ns` — the boot-seed hook: after a
    /// journal replay has deposited every change in (older_ns, now) via `seed`,
    /// queries older than the stream-live instant become answerable too.
    pub fn extendCoverage(self: *Annals, older_ns: i128) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.floor_ns = @min(self.floor_ns, older_ns);
    }

    /// Deposit one ALREADY-RELATIVE path (a boot-time journal-replay entry)
    /// carrying its own instant — for a seeded path that is the file's live
    /// max(mtime, ctime), the exact quantity the stat walk compares, so a
    /// `since` filter over it reproduces the walk's own keep/drop. Skip-dir
    /// shaping matches `note`. Returns false on OOM (caller aborts the seed
    /// WITHOUT extending coverage — the ledger stays sound, just younger).
    pub fn seed(self: *Annals, rel: []const u8, ts_ns: i128) bool {
        if (rel.len == 0 or haystack.underSkippedDir(rel)) return true;
        self.mu.lock();
        defer self.mu.unlock();
        self.stamp += 1;
        if (self.map.getPtr(rel)) |ts| {
            ts.* = @max(ts.*, ts_ns); // a live delivery already outran the seed
            return true;
        }
        if (self.map.count() >= self.cap) return false; // seeding must never evict live coverage
        const owned = self.gpa.dupe(u8, rel) catch return false;
        self.map.put(self.gpa, owned, ts_ns) catch {
            self.gpa.free(owned);
            return false;
        };
        return true;
    }

    /// Record one exact FILE delivery (absolute path, wall instant). Relative
    /// shaping happens here so the hot callback stays a single call: strip the
    /// armed prefix (firmlink alias accepted), drop the root itself and
    /// anything under a walk-skipped directory, and store `rel → now_ns`
    /// (a re-noted path replaces its instant). A delivery OUTSIDE the armed
    /// prefix is the OS disagreeing with the stream's scope — sticky doubt,
    /// exactly like the journal replay. OOM while noting is doubt too.
    pub fn note(self: *Annals, abs: []const u8, now_ns: i128) void {
        self.mu.lock();
        defer self.mu.unlock();
        const pfx = self.prefix orelse return; // unarmed: unanswerable anyway
        const rel = relativize(pfx, abs) orelse return self.poison();
        if (rel.len == 0 or haystack.underSkippedDir(rel)) return; // the root itself / never-walked subtree
        self.stamp += 1;
        // Past this line the ledger records WHICH file moved, and a poisoned
        // ledger has stopped doing that. The stamp above is the WHETHER, and it
        // must keep advancing after a poison or a held answer would look fresh
        // forever while the tree moved under it.
        if (self.doubt) return;
        if (self.map.getPtr(rel)) |ts| {
            ts.* = now_ns;
            return;
        }
        if (self.map.count() >= self.cap) self.evictOldest();
        const owned = self.gpa.dupe(u8, rel) catch return self.poison();
        self.map.put(self.gpa, owned, now_ns) catch {
            self.gpa.free(owned);
            self.poison();
        };
    }

    /// An event the backend cannot attribute to exact paths: poison the
    /// ledger for the daemon's lifetime (no walk exists here to recover).
    pub fn noteDoubt(self: *Annals) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.poison();
    }

    /// The backend lost coverage it cannot win back. Retire every held answer
    /// (the stamp moves once more) and then stop vouching for the corpus
    /// entirely: unlike `noteDoubt`, this says future changes will go UNSEEN,
    /// so no later reading of the stamp can be trusted either. Permanent, in
    /// the posture of the seqlock poison it rides beside — the session keeps
    /// reconciling, and the keep simply stops being offered.
    pub fn goBlind(self: *Annals) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.blind = true;
        self.poison();
    }

    /// Coverage handed back ON PURPOSE — an idle daemon shedding its watches.
    /// Recoverable, unlike `goBlind`: a re-arm reopens coverage and raises the
    /// floor past the unwatched window, so `since` declines across it. What
    /// re-arming cannot repair is an answer held under the retiring stream —
    /// the shed window observes nothing, so that answer would match an epoch
    /// which never counted the edits made while nobody was watching. Moving
    /// the stamp here retires it at shed time instead.
    pub fn lapse(self: *Annals) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.stamp += 1;
    }

    /// Lose the WHICH, keep the WHETHER. Every poisoning is itself an observed
    /// change the ledger could not place, so it advances the epoch as well —
    /// the conservative reading, since a bumped stamp retires every held
    /// answer. Skipping the bump would be the unsound direction: an
    /// unattributable event that left the epoch alone would let a stale answer
    /// look fresh. Called under `mu`.
    fn poison(self: *Annals) void {
        self.doubt = true;
        self.stamp += 1;
    }

    /// Evict the oldest half of the ledger by delivery instant and advance
    /// the floor past every evicted entry, so a query that would have needed
    /// them declines instead of silently missing paths. Called under `lock`.
    fn evictOldest(self: *Annals) void {
        const n = self.map.count();
        const stamps = self.gpa.alloc(i128, n) catch return self.poison();
        defer self.gpa.free(stamps);
        var it = self.map.valueIterator();
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) stamps[i] = v.*;
        std.mem.sort(i128, stamps, {}, comptime std.sort.asc(i128));
        const cut = stamps[n / 2]; // median delivery instant

        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.gpa);
        var kit = self.map.iterator();
        while (kit.next()) |e| {
            if (e.value_ptr.* > cut) continue;
            doomed.append(self.gpa, e.key_ptr.*) catch return self.poison();
        }
        for (doomed.items) |k| {
            _ = self.map.remove(k);
            self.gpa.free(k);
        }
        // Every remaining entry is > cut; queries at/before cut lost coverage.
        self.floor_ns = @max(self.floor_ns, cut + 1);
    }

    /// The corpus's current change epoch, or null when the ledger cannot vouch
    /// for it (unarmed, or poisoned by an unattributable event).
    ///
    /// Two runs that read the same epoch saw the same corpus, so an answer
    /// computed under one is still exact under the other.
    ///
    /// Neither `doubt` nor the coverage floor gates this, and both omissions
    /// are the point: they mark the ledger's inability to say WHICH files
    /// moved, while this reading only claims WHETHER any did. Every eviction
    /// rides a `note` that already advanced the stamp, and every poisoning
    /// advances it directly — so the two failures that make `since` decline
    /// leave this answer conservative rather than wrong. Under ten concurrent
    /// editors that distinction is the whole difference between a keep that
    /// works and one poisoned within minutes of daemon start.
    ///
    /// Two states DO return null, and both are the same claim — nobody is
    /// counting: an UNARMED ledger has observed nothing, and a BLIND one has
    /// stopped observing. Those are exactly the cases where a standing stamp
    /// would mean "the corpus held still" when it means "no one was looking".
    pub fn epoch(self: *Annals) ?u64 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.prefix == null or self.blind) return null;
        return self.stamp;
    }

    /// Answer "which paths changed since `since_ns`?" — or null when the
    /// ledger cannot vouch (unarmed, poisoned, or `since_ns` predates the
    /// floor). The caller owns the snapshot (`Snapshot.deinit`).
    pub fn since(self: *Annals, gpa: std.mem.Allocator, since_ns: i128) ?Snapshot {
        self.mu.lock();
        defer self.mu.unlock();
        const pfx = self.prefix orelse return null;
        if (self.doubt or since_ns < self.floor_ns) return null;
        return self.collect(gpa, pfx, since_ns) catch null; // OOM = cannot vouch
    }

    /// The allocating body of `since`, error-unioned so `errdefer` actually
    /// releases partial output on OOM (a plain `return null` from an optional-
    /// returning fn never runs errdefer). Called under `lock`.
    fn collect(self: *Annals, gpa: std.mem.Allocator, pfx: []const u8, since_ns: i128) !Snapshot {
        const prefix = try gpa.dupe(u8, pfx);
        errdefer gpa.free(prefix);
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |p| gpa.free(p);
            out.deinit(gpa);
        }
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < since_ns) continue;
            const dup = try gpa.dupe(u8, e.key_ptr.*);
            errdefer gpa.free(dup);
            try out.append(gpa, dup);
        }
        return .{ .prefix = prefix, .paths = try out.toOwnedSlice(gpa) };
    }
};

/// Strip `abs` down to prefix-relative form, accepting the realpath spelling
/// and its `/System/Volumes/Data` firmlink alias. Null ⇒ not under the prefix.
/// Zero-copy: the result aliases `abs`.
fn relativize(prefix: []const u8, abs: []const u8) ?[]const u8 {
    var rest: ?[]const u8 = null;
    if (std.mem.startsWith(u8, abs, prefix)) {
        rest = abs[prefix.len..];
    } else if (std.mem.startsWith(u8, abs, data_volume_prefix) and
        std.mem.startsWith(u8, abs[data_volume_prefix.len..], prefix))
    {
        rest = abs[data_volume_prefix.len + prefix.len ..];
    }
    const r = rest orelse return null;
    if (r.len == 0) return r; // the root itself
    if (r[0] != '/') return null; // prefix ended mid-component (/repo2 vs /repo)
    return r[1..];
}

/// Test shorthand: prefix + coverage in one call (production splits them
/// around the stream start; see `arm`/`openCoverage`).
fn armFor(an: *Annals, root: []const u8, floor: i128) void {
    an.arm(root);
    an.openCoverage(floor);
}

test "unarmed annals never answers" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    try t.expect(an.since(t.allocator, 0) == null);
    // A prefix without coverage still declines (floor is +∞).
    an.arm("/repo");
    try t.expect(an.since(t.allocator, std.math.maxInt(i64)) == null);
}

test "arm + note + since filters by delivery instant" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/repo", 100);
    an.note("/repo/a.zig", 150);
    an.note("/repo/b.zig", 250);
    an.note("/repo/a.zig", 300); // re-note replaces the instant

    var s1 = an.since(t.allocator, 200) orelse return error.TestUnexpectedResult;
    defer s1.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), s1.paths.len); // a (300) + b (250)

    var s2 = an.since(t.allocator, 260) orelse return error.TestUnexpectedResult;
    defer s2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), s2.paths.len);
    try t.expectEqualStrings("a.zig", s2.paths[0]);

    // Before the floor: unanswerable, never a partial answer.
    try t.expect(an.since(t.allocator, 99) == null);
}

test "firmlink alias resolves; foreign prefix poisons" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/repo", 0);
    an.note("/System/Volumes/Data/repo/x.zig", 10);
    var s = an.since(t.allocator, 0) orelse return error.TestUnexpectedResult;
    defer s.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), s.paths.len);
    try t.expectEqualStrings("x.zig", s.paths[0]);

    an.note("/elsewhere/y.zig", 20); // outside the armed scope → sticky doubt
    try t.expect(an.since(t.allocator, 0) == null);
}

test "skip-dir subtrees and the root itself are dropped, files named like skip dirs kept" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/repo", 0);
    an.note("/repo", 5); // the root: a dir event spelling, never a corpus file
    an.note("/repo/.git/HEAD", 10);
    an.note("/repo/node_modules/pkg/i.js", 10);
    an.note("/repo/zig-out", 10); // basename only — admissible as a FILE
    var s = an.since(t.allocator, 0) orelse return error.TestUnexpectedResult;
    defer s.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), s.paths.len);
    try t.expectEqualStrings("zig-out", s.paths[0]);
}

test "eviction advances the floor past evicted deliveries" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    an.cap = 4;
    armFor(&an, "/r", 0);
    an.note("/r/a", 10);
    an.note("/r/b", 20);
    an.note("/r/c", 30);
    an.note("/r/d", 40);
    an.note("/r/e", 50); // over cap → evict deliveries ≤ median, floor advances

    try t.expect(an.since(t.allocator, 0) == null); // pre-eviction coverage is gone
    var s = an.since(t.allocator, an.floor_ns) orelse return error.TestUnexpectedResult;
    defer s.deinit(t.allocator);
    try t.expect(s.paths.len >= 2); // the newer half + the new entry survive
    try t.expect(an.floor_ns > 0);
}

test "boot seed extends coverage backward with per-path instants" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/r", 1000); // stream live at 1000
    // Journal replay found two pre-boot changes; seed carries each file's own
    // metadata instant, then coverage extends back to the token mint.
    try t.expect(an.seed("old.zig", 400));
    try t.expect(an.seed(".git/HEAD", 500)); // skip-dir subtree: dropped, still ok
    an.extendCoverage(300);

    var s = an.since(t.allocator, 300) orelse return error.TestUnexpectedResult;
    defer s.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), s.paths.len);
    try t.expectEqualStrings("old.zig", s.paths[0]);
    // A query strictly between the seed instant and the stream floor filters it.
    var s2 = an.since(t.allocator, 450) orelse return error.TestUnexpectedResult;
    defer s2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), s2.paths.len);
    // Older than the extended floor: still unanswerable.
    try t.expect(an.since(t.allocator, 299) == null);
}

test "doubt is sticky forever" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/r", 0);
    an.noteDoubt();
    an.note("/r/a", 10);
    try t.expect(an.since(t.allocator, 0) == null);
    try t.expect(an.since(t.allocator, 10_000) == null);
}

test "an unarmed ledger has no epoch; an armed still one is a stable epoch" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    try t.expect(an.epoch() == null); // never observed anything
    armFor(&an, "/r", 0);
    const at_rest = an.epoch() orelse return error.TestUnexpectedResult;
    try t.expectEqual(at_rest, an.epoch().?); // reading it does not move it
    an.note("/r/a.zig", 10);
    try t.expectEqual(at_rest + 1, an.epoch().?);
    an.note("/r/.git/HEAD", 11); // skip-dir subtree is not corpus change
    try t.expectEqual(at_rest + 1, an.epoch().?);
}

test "blindness retires held answers and then declines the epoch forever" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/r", 0);
    const before = an.epoch() orelse return error.TestUnexpectedResult;

    an.goBlind(); // coverage lost: the backend has stopped delivering
    // The bump is not decoration — it is what retires an answer already held
    // at `before`, in the same drain that discovered the loss.
    try t.expect(an.stamp > before);
    // And from here nothing may be vouched: a standing stamp would now mean
    // "nobody is looking", not "the corpus held still".
    try t.expect(an.epoch() == null);
    an.note("/r/a.zig", 10);
    try t.expect(an.epoch() == null); // permanent, unlike a lapse
    try t.expect(an.since(t.allocator, 0) == null);
}

test "a lapse retires held answers without blinding or poisoning the ledger" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/r", 0);
    an.note("/r/a.zig", 10);
    const held_at = an.epoch() orelse return error.TestUnexpectedResult;

    an.lapse(); // the idle daemon hands its watches back
    const after = an.epoch() orelse return error.TestUnexpectedResult;
    try t.expect(after > held_at); // an answer held at `held_at` no longer matches

    // A shed is reversible: the ledger still answers, and a re-arm raises the
    // floor past the unwatched window so `since` declines across it while the
    // epoch keeps counting.
    an.note("/r/b.zig", 20);
    try t.expectEqual(after + 1, an.epoch().?);
    an.openCoverage(30);
    try t.expect(an.since(t.allocator, 20) == null); // pre-re-arm window: unanswerable
    var s = an.since(t.allocator, 30) orelse return error.TestUnexpectedResult;
    defer s.deinit(t.allocator);
}

test "doubt keeps the epoch answerable and advances it" {
    const t = std.testing;
    var an = Annals.init(t.allocator);
    defer an.deinit();
    armFor(&an, "/r", 0);
    const before = an.epoch() orelse return error.TestUnexpectedResult;

    an.note("/elsewhere/x.zig", 10); // unmappable delivery → poison
    try t.expect(an.since(t.allocator, 0) == null); // WHICH is gone …
    const after = an.epoch() orelse return error.TestUnexpectedResult; // … WHETHER is not
    try t.expect(after > before); // and it counted the change it could not place

    // The load-bearing half: a poisoned ledger records no more PATHS, but it
    // must keep counting CHANGES, or a held answer would look epoch-fresh
    // forever while the tree moved under it.
    an.note("/r/b.zig", 20);
    try t.expect(an.epoch().? > after);
    try t.expect(an.since(t.allocator, 0) == null); // still no WHICH, as before
}
