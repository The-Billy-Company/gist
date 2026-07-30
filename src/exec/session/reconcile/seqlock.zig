//! The freshness seqlock every resident session shares (ADR-352 rung 2.5).
//!
//! Both warm engines — gist's `ResidentSession` (mirrors corpus bytes) and
//! relate's `RetrievalSession` (caches an anchor overlay) — face the identical
//! concurrency problem: a watch thread reports filesystem events while a query
//! thread, under the session mutex, decides whether it may skip the reconcile
//! walk. The decision is a lock-free seqlock over three atomics + one plain
//! bool, and the memory ordering is subtle enough that it must live in ONE
//! place, not be re-derived per session. This is that place: it owns every
//! `.acquire`/`.release`/`.monotonic`, so no session ever touches a raw atomic.
//!
//! The payload — what "reconcile" actually recomputes — stays per session; the
//! barrier only tracks *whether* a recompute is owed. The protocol:
//!
//!   - watch thread: `markDirty` on every event, `markDoubtForever` when it
//!     loses coverage it cannot recover (fail-closed — the fast path is then
//!     permanently off), `arm` once a backend is proven live, and `disarm` when
//!     it gives live coverage back on purpose (an idle daemon releasing its
//!     descriptors) — reversible, unlike doubt, but every query in the gap
//!     reconciles and the session owes a fresh covering pass before the scoped
//!     path can reopen.
//!   - query thread (holding the session mutex): `skip` short-circuits the walk
//!     when a live watcher has proven quiescence; otherwise snapshot `enter`,
//!     recompute, then `commit` — which republishes "clean" ONLY if no event
//!     raced the recompute (the seqlock re-read). Without a watcher, `clean` is
//!     never set, so every query reconciles: correct, just not microsecond-fast.
//!
//! `clean` is set true only under `eligible`, and any event (`markDirty`, and
//! `markDoubtForever` calls it) clears it, so `provenClean` — the raw bit the
//! answer paths read to decide whether a hit still needs an existence stat —
//! is a sound "no untracked change since the last reconcile" witness on its own.

const std = @import("std");

/// Lock-free freshness barrier. Embed one per session; drive it from the
/// watcher (event thread) and the reconcile (query thread, under the mutex).
pub const Seqlock = struct {
    /// A watcher backend is live and proving quiescence. Atomic because a
    /// backend may hand its coverage back and take it up again (`disarm`/`arm`
    /// — an idle daemon shedding its descriptors), so this is not a
    /// write-once-before-any-reader flag; read it through `armed`.
    active: std.atomic.Value(bool) = .init(false),
    /// Event counter, bumped on every filesystem event — the seqlock sequence.
    ///
    /// Pointer-width, not `u64`, because that is what an atomic sequence counter
    /// is: `std.atomic.Value(T)` is only instantiable for `@sizeOf(T) <=` the
    /// target's largest atomic, which is 4 bytes on every 32-bit target Zig
    /// supports (i686 `cmpxchg8b` and ARMv7 `ldrexd` give CAS but not the full
    /// RMW set, so the compiler caps the width). On all 64-bit targets `usize`
    /// *is* `u64`, so this is bit-identical to what shipped before.
    ///
    /// The width bounds one hazard: `commit` republishes clean only if `seq` is
    /// unchanged since `enter`, so it can be fooled only by exactly 2^bits events
    /// landing inside a single reconcile window. That is the same envelope the
    /// Linux kernel accepts for every `seqcount_t`, which is a 32-bit `unsigned`
    /// on 32-bit and 64-bit hosts alike.
    seq: std.atomic.Value(usize) = .init(0),
    /// True only when a watcher has proven no event since the last reconcile.
    clean: std.atomic.Value(bool) = .init(false),
    /// Latched by a watcher that lost coverage it cannot recover (queue
    /// overflow, an unwatchable new directory): the clean fast path is disabled
    /// for the session's life and every query reconciles (fail-closed).
    poison: std.atomic.Value(bool) = .init(false),

    // ── watch thread (lock-free) ──

    /// An event arrived: the next query must reconcile. A path-reporting backend
    /// `note`s the exact paths into its `DirtyLog` BEFORE calling this, so any
    /// event counted by a reconcile's pre-drain `enter` is visible to that drain.
    pub fn markDirty(self: *Seqlock) void {
        _ = self.seq.fetchAdd(1, .monotonic);
        self.clean.store(false, .release);
    }

    /// Coverage is lost for good: permanently disable the clean fast path, then
    /// force a reconcile. Every later query reconciles — slower, never stale.
    pub fn markDoubtForever(self: *Seqlock) void {
        self.poison.store(true, .release);
        self.markDirty();
    }

    /// Declare a watcher live and proving quiescence (see `active`). The clean
    /// witness is dropped first: a NEW stream has proven nothing yet, so a
    /// re-arm must never inherit the quiescence its predecessor published.
    pub fn arm(self: *Seqlock) void {
        self.clean.store(false, .release);
        self.active.store(true, .release);
    }

    /// The watcher handed its coverage back on purpose (an idle daemon shedding
    /// one descriptor per watched vnode): close the fast path until something
    /// arms again. Deliberately NOT `poison` — that latch is for coverage LOST,
    /// which can never be trusted again; this release is reversible, and every
    /// query in between simply reconciles.
    pub fn disarm(self: *Seqlock) void {
        self.active.store(false, .release);
        self.clean.store(false, .release);
    }

    // ── query thread (holds the session mutex) ──

    /// Is a watcher backend live at all? (`eligible` is this AND unpoisoned.)
    pub fn armed(self: *const Seqlock) bool {
        return self.active.load(.acquire);
    }

    /// A live, unpoisoned watcher — the precondition for ever trusting `clean`.
    pub fn eligible(self: *const Seqlock) bool {
        return self.armed() and !self.poison.load(.acquire);
    }

    /// The reconcile fast path: a live watcher has proven no event since the
    /// last reconcile, so the cached overlay/mirror is already current.
    pub fn skip(self: *const Seqlock) bool {
        return self.eligible() and self.clean.load(.acquire);
    }

    /// Snapshot the event counter before recomputing; hand it back to `commit`.
    pub fn enter(self: *const Seqlock) usize {
        return self.seq.load(.acquire);
    }

    /// Republish "clean" iff a watcher is live, unpoisoned, and no event raced
    /// the recompute since `enter` returned `seq0`. Otherwise stay dirty.
    pub fn commit(self: *Seqlock, seq0: usize) void {
        if (self.eligible() and self.seq.load(.acquire) == seq0)
            self.clean.store(true, .release);
    }

    /// The raw clean witness the answer paths read to gate per-hit existence
    /// checks: true ⇒ nothing changed since the last reconcile, so a hit need
    /// not be re-stated for existence. Sound on its own (see the module header).
    pub fn provenClean(self: *const Seqlock) bool {
        return self.clean.load(.acquire);
    }
};

test "a fresh barrier is dirty and skips nothing" {
    var s: Seqlock = .{};
    try std.testing.expect(!s.skip());
    try std.testing.expect(!s.provenClean());
    try std.testing.expect(!s.eligible());
}

test "clean is trusted only under a live, unpoisoned watcher" {
    var s: Seqlock = .{};
    // No watcher: a completed reconcile never publishes clean.
    const seq0 = s.enter();
    s.commit(seq0);
    try std.testing.expect(!s.skip());

    // Armed + quiescent: commit publishes clean, the fast path opens.
    s.arm();
    const seq1 = s.enter();
    s.commit(seq1);
    try std.testing.expect(s.skip());
    try std.testing.expect(s.provenClean());

    // An event during the next reconcile window forbids re-publishing clean.
    const seq2 = s.enter();
    s.markDirty();
    try std.testing.expect(!s.skip());
    s.commit(seq2);
    try std.testing.expect(!s.skip());
}

test "a shed watcher closes the fast path, and re-arming never inherits it" {
    var s: Seqlock = .{};
    s.arm();
    const seq0 = s.enter();
    s.commit(seq0);
    try std.testing.expect(s.skip());

    // Coverage handed back: every query reconciles again — but this is a
    // release, not doubt, so nothing is latched.
    s.disarm();
    try std.testing.expect(!s.armed());
    try std.testing.expect(!s.skip());
    try std.testing.expect(!s.provenClean());
    try std.testing.expect(!s.poison.load(.acquire));

    // Re-arming must not resurrect the stale clean witness: the new stream has
    // proven nothing until a reconcile completes under it.
    s.arm();
    try std.testing.expect(s.armed());
    try std.testing.expect(!s.skip());
    const seq1 = s.enter();
    s.commit(seq1);
    try std.testing.expect(s.skip());
}

test "doubt is permanent: the fast path never reopens" {
    var s: Seqlock = .{};
    s.arm();
    s.markDoubtForever();
    const seq0 = s.enter();
    s.commit(seq0);
    try std.testing.expect(!s.skip());
    try std.testing.expect(!s.eligible());
}
