//! gist resident session — the metered allocator a daemon's memory must pass
//! through.
//!
//! `ration.zig` decides how many bytes a resident session may hold. This decides
//! that it CANNOT hold more, which is a different and much stronger claim: not a
//! number reported after the fact, but a ceiling no allocation can cross.
//!
//! ## Why a wrapper and not a check
//!
//! The obvious shape — sample RSS on a timer, log or exit when it looks bad — is
//! the shape that fails. It is advisory (the process is already over budget by
//! the time anyone looks), it is racy (the interesting growth happens between
//! two samples), and it is opt-in at every call site that has to remember to
//! ask. A daemon holding 1904 MB was not missing a warning; it was missing a
//! refusal.
//!
//! So the bound is imposed where allocation happens, by handing the session an
//! `std.mem.Allocator` that is the meter. Every resident byte — mirror docs, the
//! trigram CSR, overlay entries, the answer keep, path tables, per-query arenas
//! built on it — is charged, because there is no second allocator to reach for.
//! `serve.run` receives one `gpa` and threads it into everything it constructs,
//! so wrapping that ONE value at that ONE seam covers the whole resident set:
//! the chokepoint already existed, and this gives it a ceiling.
//!
//! What it does not cover is honest and bounded: `content.shard` bytes reached
//! through an mmap are page-cache pages the kernel evicts under pressure, not
//! heap this process must account for, and `conduit/shm.zig`'s per-answer
//! handoff buffers are unmapped when the answer ends. Both are already bounded
//! by something other than this daemon's appetite.
//!
//! ## Refusal is a routing fact, not a crash
//!
//! Crossing the ceiling returns `null` from the vtable, which Zig surfaces as
//! `error.OutOfMemory` at the call site. In a general program that is a fatal
//! surprise. Here it is the ordinary warm→cold declinature this whole tier is
//! built around (`fault.Decline.freshness_unprovable` and its siblings): the
//! resident path is an accelerator, the cold walk answers every query
//! correctly, and no resident allocation is on a path that panics on OOM. A
//! session that cannot fit hands its work back to the tier that never needed to
//! fit, which is the same fail-closed edge `watchBudget` takes to zero watches.
//!
//! ## Relief before refusal
//!
//! Refusing outright would make the ceiling correct but wasteful, because some
//! of what a session holds is pure cache. The answer keep is 64 MiB of RENDERED
//! bytes whose entries are by construction recomputable — that is what makes
//! them cacheable. So the warden takes a `Relief` hand: on first contact with
//! the ceiling it asks the session to surrender what it can rebuild, and only
//! refuses if the allocation still will not fit. Reclaimable memory is spent
//! before a query is declined, and the ceiling still holds absolutely.

const std = @import("std");
const Alignment = std.mem.Alignment;

/// What a session can give back when the ceiling binds, and how to ask for it.
/// `hand` returns the bytes it released — zero is a legitimate answer, meaning
/// "nothing left to surrender", and the warden then refuses rather than asking
/// again in a loop. It must free through the warden's own allocator (that is how
/// the bytes come off the meter) and must not allocate.
pub const Relief = struct {
    ctx: *anyopaque,
    hand: *const fn (*anyopaque) usize,

    fn call(self: Relief) usize {
        return self.hand(self.ctx);
    }
};

/// A ration and the live accounting against it.
///
/// Not copyable once handed out: `allocator()` closes over `self`, so the
/// `Warden` must outlive every allocation it meters — in practice it lives on
/// `serve.run`'s stack, which outlives the session, the keep, and the workers by
/// construction.
/// How many bytes a lane claims from the shared counter in one go. Sized so a
/// lane refills rarely (a whole batch of small allocations per shared write),
/// while the credit parked across every lane stays a rounding error against a
/// ration measured in gigabytes: 32 lanes × 256 KiB is 8 MiB at worst, and
/// `sweep` reclaims all of it before anything is refused.
const batch: usize = 256 << 10;

/// Credit a lane may accumulate from frees before it hands the excess back, so
/// one lane cannot end up hoarding the entire ration.
const lane_cap: usize = batch * 2;

/// Lanes are process-lifetime slots, not thread-owned ones. A thread borrows an
/// index and never gives it back, which is what makes a dead thread harmless:
/// its parked credit stays in the warden's array, reachable by `sweep` and
/// re-spendable by whoever borrows the lane next. Nothing is stranded, so no
/// thread-exit hook is needed — Zig does not offer one.
const lanes = 32;

/// One counter per cache line, carrying its own copy of the backing allocator.
///
/// The padding IS the optimization: two lanes on one line would trade a
/// shared-counter round trip for a shared-line round trip and win nothing. The
/// duplicated `backing` is the second half of the same idea — an allocation reads
/// the credit and the allocator to forward to, and reading them from one line
/// costs one cache line instead of two. Sixteen immutable bytes per lane buys
/// that; it measured 1.5 ns/op on small serial allocations, which on an allocator
/// that answers in 4.3 is not a rounding error.
const Lane = struct {
    credit: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    backing: std.mem.Allocator = undefined,
};

/// This thread's lane, borrowed once on first use and thereafter read with no
/// atomic at all — a thread-local load and one predictable branch.
///
/// Round-robin rather than a thread-id hash: ids collide in clusters, and on
/// macOS reading one is a libc call, which is exactly the cost being avoided. The
/// sentinel exists because a `threadlocal` initializer must be comptime-known, so
/// the first touch on each thread does the assigning.
threadlocal var lane_of: usize = unborrowed;
const unborrowed = std.math.maxInt(usize);
var lane_rr: std.atomic.Value(usize) = .init(0);

fn myLane() usize {
    if (lane_of == unborrowed) lane_of = lane_rr.fetchAdd(1, .monotonic) % lanes;
    return lane_of;
}

pub const Warden = struct {
    /// The allocator underneath. Every lane carries its own copy for the hot path,
    /// so this one is read only where a lane is not already in hand.
    backing: std.mem.Allocator,
    /// Bytes this session may hold at once. Never mutated after `init`, so the
    /// ceiling cannot be raised by anything that gets hold of the warden.
    ration: usize,
    /// `held` and `crest` deliberately share ONE cache line, and everything below
    /// is pushed off it.
    ///
    /// They are the two words a successful charge touches — a write then a read —
    /// so once a core owns the line for the write, the read is free. Giving them
    /// separate lines made an uncontended allocation touch two lines instead of
    /// one and cost 1.3 ns/op on small allocations. What genuinely must not share
    /// with them is the diagnostics: a `refusals` or `relieved` write is rare, but
    /// on this line it would invalidate the very counter every worker contends
    /// for, making a diagnostic a tax on the bound.
    held: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    /// The most it ever held at one instant — the number that says whether the
    /// ration is generous, snug, or fiction. Reported by `gist status`.
    crest: std.atomic.Value(usize) = .init(0),
    /// Allocations the ceiling turned away, and bytes relief clawed back. Both
    /// are diagnostics; neither participates in the bound. Aligned onto a line of
    /// their own so writing them cannot slow a charge down.
    ///
    /// One machine word each, like `held` and `crest`, because that is the width a
    /// 32-bit target can load and add atomically at all — a 64-bit atomic has no
    /// lock-free instruction on i386 or ARM32, so declaring one there is a compile
    /// error rather than a slow path. `turnedAway`/`reclaimed` still report `u64`,
    /// which costs nothing (the widening is implicit, and identity on a 64-bit
    /// host) and keeps the reported shape independent of the word size it was
    /// counted in.
    refusals: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    relieved: std.atomic.Value(usize) = .init(0),
    relief: ?Relief = null,
    /// Guards against re-entering relief from inside relief (a hand that frees
    /// through this allocator re-enters `release`, which is safe, but a hand
    /// that allocated would re-enter `reserve`, which must not recurse).
    relieving: std.atomic.Value(bool) = .init(false),
    /// Wholesale claims, retailed per thread. Last so the hot counter above stays
    /// near the front of the struct.
    lanes: [lanes]Lane = @splat(.{}),

    pub fn init(backing: std.mem.Allocator, ration: usize) Warden {
        return .{
            .backing = backing,
            .ration = ration,
            .lanes = @splat(.{ .backing = backing }),
        };
    }

    /// Register what to surrender under pressure. Set once the session exists,
    /// since the thing worth giving back is owned by the session.
    pub fn attend(self: *Warden, r: Relief) void {
        self.relief = r;
    }

    pub fn allocator(self: *Warden) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    /// Bytes live right now: claimed from the shared counter, less what lanes hold
    /// but have not handed out.
    ///
    /// The subtraction is what makes the lane scheme honest to a reader. `held`
    /// alone is the *reserved* total, which overstates live usage by whatever is
    /// parked, and a status line that drifts high by a few megabytes for
    /// bookkeeping reasons is a status line nobody can use to judge a ration.
    /// Sampled rather than locked, so a concurrent free can land mid-walk; that
    /// costs a byte-exact instant, not correctness, and the ceiling never consults
    /// this — it reads `held` directly.
    pub fn holding(self: *const Warden) usize {
        var parked: usize = 0;
        for (&self.lanes) |*l| parked += l.credit.load(.monotonic);
        return self.held.load(.monotonic) -| parked;
    }

    /// The high-water mark.
    pub fn peak(self: *const Warden) usize {
        return self.crest.load(.monotonic);
    }

    /// How much of the ration is spent, in hundredths — for a status line, not
    /// for a decision. Zero when unrationed, so an unarmed session reports 0%
    /// rather than dividing by zero.
    pub fn tension(self: *const Warden) u8 {
        if (self.ration == 0) return 0;
        const pct = self.holding() * 100 / self.ration;
        return @intCast(@min(pct, 100));
    }

    pub fn turnedAway(self: *const Warden) u64 {
        return self.refusals.load(.monotonic);
    }

    pub fn reclaimed(self: *const Warden) u64 {
        return self.relieved.load(.monotonic);
    }

    /// Charge `n` bytes against this thread's lane, refilling from the shared
    /// counter only when the lane runs dry.
    ///
    /// This is the whole reason the ceiling is affordable. A bound is a shared
    /// fact, and touching a shared fact on every allocation costs a cache line
    /// round trip per operation — measured at ~78 ns/op with eight workers, where
    /// the allocator underneath answers in 0.6. So the shared counter is charged
    /// in `batch`-sized wholesale claims and retailed out from a lane the thread
    /// mostly has to itself, which turns a cross-core transfer into a hit on a
    /// line already in L1.
    ///
    /// The bound survives intact because the shared counter tracks *reserved*
    /// bytes, not live ones: lane credit has already been charged. Live usage is
    /// therefore always `held` minus the credit parked in lanes — never more than
    /// `held`, and so never more than the ration. Parked credit only ever makes
    /// the warden stricter than necessary, and `sweep` reclaims it before anything
    /// is actually refused, so strictness never becomes a false refusal.
    fn reserve(self: *Warden, lane: *Lane, n: usize) bool {
        // Spend first, restore if the lane could not cover it. One
        // read-modify-write on the common path, where a load-then-CAS would cost
        // two — and unlike the shared counter, an overdraft here is invisible to
        // the bound: these bytes are already charged, so a lane briefly reading
        // low only sends this thread to `refill`.
        const prior = lane.credit.fetchSub(n, .monotonic);
        if (prior >= n) return true;
        _ = lane.credit.fetchAdd(n, .monotonic);
        return self.refill(lane, n);
    }

    /// The lane is dry (or too thin for `n`). Claim wholesale from the shared
    /// counter, and only then start giving ground: take exactly what is needed,
    /// reclaim credit parked in other lanes, and finally ask the session to
    /// surrender reclaimable state.
    ///
    /// Relief is asked at most once: a hand that gave back nothing will not give
    /// back more on a second ask, and looping here would spend the pressure
    /// episode spinning instead of handing the query to cold.
    fn refill(self: *Warden, lane: *Lane, n: usize) bool {
        const bulk = std.math.add(usize, n, batch) catch n;
        if (self.charge(bulk)) {
            _ = lane.credit.fetchAdd(bulk - n, .monotonic);
            return true;
        }
        if (self.charge(n)) return true; // no room for a batch, but room for this
        // Before refusing, pull back what other lanes are merely holding: a
        // refusal has to mean the ration is spent, not parked.
        if (self.sweep() > 0 and self.charge(n)) return true;
        if (self.beg() > 0) {
            _ = self.sweep(); // relief frees through this allocator, so it lands in lanes
            if (self.charge(n)) return true;
        }
        _ = self.refusals.fetchAdd(1, .monotonic);
        return false;
    }

    /// Pull every lane's parked credit back to the shared counter, returning the
    /// bytes moved. Rare by construction — only on the approach to the ceiling and
    /// when a caller asks what is truly held.
    fn sweep(self: *Warden) usize {
        var moved: usize = 0;
        for (&self.lanes) |*l| moved += l.credit.swap(0, .monotonic);
        if (moved > 0) self.give(moved);
        return moved;
    }

    /// The whole bound, in one function: claim, judge, and give back a claim that
    /// was not allowed.
    ///
    /// A single `fetchAdd` rather than a CAS loop. The loop was correct but it
    /// *spun*: with eight workers on one counter every loser re-read and
    /// re-decided, so the bound's cost grew with contention instead of staying
    /// flat (213 ns/op at eight threads, against 2 ns serial — see
    /// `bench/rungs/warden/`). `fetchAdd` never retries.
    ///
    /// The difference is that this can briefly *publish* a total above the
    /// ration, where the loop never could. That is safe in the only direction
    /// that matters: a concurrent charge which sees the inflated total refuses,
    /// and refusing early is this module's whole posture. What no thread can do
    /// is keep memory it was not allowed — the claim is rolled back before the
    /// allocation is ever attempted, so real usage still never exceeds the
    /// ceiling. The pre-check and the wrap test make a nonsensical length a
    /// refusal rather than an overflow.
    fn charge(self: *Warden, n: usize) bool {
        if (n > self.ration) return false; // cannot fit even alone; never publish it
        const prior = self.held.fetchAdd(n, .monotonic);
        const next = prior + n;
        if (next > self.ration or next < prior) { // over budget, or a wrapped length
            _ = self.held.fetchSub(n, .monotonic);
            return false;
        }
        // The crest is a diagnostic, so it must not cost a second
        // read-modify-write on the hot line. Past the first few allocations
        // almost nothing sets a new high-water mark, and a plain load only
        // *shares* the line where `fetchMax` would invalidate every other core's
        // copy of it. The `fetchMax` still performs the update, so two threads
        // that both clear the bar still resolve to the larger.
        if (next > self.crest.load(.monotonic)) _ = self.crest.fetchMax(next, .monotonic);
        return true;
    }

    /// Ask the session to surrender reclaimable state. Returns bytes freed, or
    /// zero when there is no hand registered, another thread is already asking,
    /// or the session had nothing left to give.
    fn beg(self: *Warden) usize {
        const r = self.relief orelse return 0;
        if (self.relieving.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return 0;
        defer self.relieving.store(false, .release);
        const freed = r.call();
        _ = self.relieved.fetchAdd(freed, .monotonic);
        return freed;
    }

    /// Return `n` bytes — to this thread's lane, so the next allocation on this
    /// thread can spend them without touching the shared counter at all. A free
    /// is as hot as an alloc, so it gets the same treatment.
    fn release(self: *Warden, lane: *Lane, n: usize) void {
        const now = lane.credit.fetchAdd(n, .monotonic) + n;
        if (now <= lane_cap) return;
        // This lane is hoarding. Hand the excess back so other lanes — and the
        // ceiling's own arithmetic — can see it.
        const give_back = now - batch;
        var cur = now;
        while (cur >= give_back) {
            if (lane.credit.cmpxchgWeak(cur, cur - give_back, .monotonic, .monotonic)) |actual| {
                cur = actual;
                continue;
            }
            self.give(give_back);
            return;
        }
    }

    /// Return `n` bytes to the shared counter, in one non-retrying step for the
    /// same reason `charge` claims in one.
    ///
    /// Guarded against underflow, because a double-free or a length the caller
    /// mis-remembers must not wrap the counter into a huge number that reads as an
    /// exhausted ration and refuses every later allocation. The clamp is a repair,
    /// so it costs a second atomic only on the broken path.
    fn give(self: *Warden, n: usize) void {
        const prior = self.held.fetchSub(n, .monotonic);
        if (prior >= n) return;
        _ = self.held.fetchAdd(n - prior, .monotonic);
    }

    // Each entry point resolves its lane ONCE and then uses that lane for both the
    // charge and the forward, so the whole fast path lives on a single cache line.

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Warden = @ptrCast(@alignCast(ctx));
        const lane = &self.lanes[myLane()];
        if (!self.reserve(lane, len)) return null;
        return lane.backing.rawAlloc(len, alignment, ra) orelse {
            self.release(lane, len);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *Warden = @ptrCast(@alignCast(ctx));
        const lane = &self.lanes[myLane()];
        if (new_len > memory.len) {
            const grow = new_len - memory.len;
            if (!self.reserve(lane, grow)) return false;
            if (!lane.backing.rawResize(memory, alignment, new_len, ra)) {
                self.release(lane, grow);
                return false;
            }
            return true;
        }
        if (!lane.backing.rawResize(memory, alignment, new_len, ra)) return false;
        self.release(lane, memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Warden = @ptrCast(@alignCast(ctx));
        const lane = &self.lanes[myLane()];
        if (new_len > memory.len) {
            const grow = new_len - memory.len;
            if (!self.reserve(lane, grow)) return null;
            return lane.backing.rawRemap(memory, alignment, new_len, ra) orelse {
                self.release(lane, grow);
                return null;
            };
        }
        const p = lane.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.release(lane, memory.len - new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *Warden = @ptrCast(@alignCast(ctx));
        const lane = &self.lanes[myLane()];
        self.release(lane, memory.len);
        lane.backing.rawFree(memory, alignment, ra);
    }
};

test "warden: the ceiling is a refusal, not a report" {
    const t = std.testing;
    var w = Warden.init(t.allocator, 4096);
    const a = w.allocator();

    const fits = try a.alloc(u8, 4000);
    defer a.free(fits);
    // The allocation that would cross the ceiling FAILS. This is the whole
    // module: an advisory design would have returned the bytes and logged.
    try t.expectError(error.OutOfMemory, a.alloc(u8, 4000));
    try t.expectEqual(@as(u64, 1), w.turnedAway());
    try t.expect(w.holding() <= w.ration);
}

test "warden: freeing returns the bytes to the ration" {
    const t = std.testing;
    var w = Warden.init(t.allocator, 4096);
    const a = w.allocator();

    const first = try a.alloc(u8, 4000);
    try t.expectError(error.OutOfMemory, a.alloc(u8, 4000));
    a.free(first);
    try t.expectEqual(@as(usize, 0), w.holding());
    // Room again, so the ceiling throttles a session rather than poisoning it.
    const second = try a.alloc(u8, 4000);
    a.free(second);
    // The crest remembers the pressure after the memory is gone — that is what
    // makes it worth reporting.
    try t.expect(w.peak() >= 4000);
}

test "warden: relief is spent before a query is declined" {
    const t = std.testing;
    const Cache = struct {
        a: std.mem.Allocator,
        buf: ?[]u8 = null,
        asked: usize = 0,
        fn hand(ctx: *anyopaque) usize {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.asked += 1;
            const b = s.buf orelse return 0;
            s.buf = null;
            s.a.free(b); // frees through the warden — this is how it comes off the meter
            return b.len;
        }
    };

    var w = Warden.init(t.allocator, 8192);
    const a = w.allocator();
    var cache = Cache{ .a = a };
    w.attend(.{ .ctx = &cache, .hand = Cache.hand });

    cache.buf = try a.alloc(u8, 5000); // recomputable bytes, holding the ration
    // Would not fit beside the cache — but the cache is exactly what a session
    // is allowed to lose, so the allocation SUCCEEDS after relief.
    const wanted = try a.alloc(u8, 5000);
    defer a.free(wanted);
    try t.expectEqual(@as(usize, 1), cache.asked);
    try t.expectEqual(@as(u64, 5000), w.reclaimed());
    try t.expectEqual(@as(u64, 0), w.turnedAway());
    try t.expect(cache.buf == null);

    // With nothing left to surrender, the next one is refused — and relief is
    // asked exactly once more, not in a loop.
    try t.expectError(error.OutOfMemory, a.alloc(u8, 5000));
    try t.expectEqual(@as(usize, 2), cache.asked);
    try t.expectEqual(@as(u64, 1), w.turnedAway());
}

test "warden: growth is charged and shrinkage refunded" {
    const t = std.testing;
    var w = Warden.init(t.allocator, 1 << 20);
    const a = w.allocator();

    // An ArrayList's amortized growth is the realistic shape here: many
    // resize/remap steps rather than one alloc, and each has to be charged or
    // the ceiling leaks through the most common allocation pattern there is.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    try list.appendNTimes(a, 0xab, 100_000);
    try t.expect(w.holding() >= 100_000);

    const grown = w.holding();
    list.clearAndFree(a);
    try t.expect(w.holding() < grown);
    try t.expectEqual(@as(usize, 0), w.holding());
}

test "warden: a ration of zero admits nothing at all" {
    const t = std.testing;
    // `ration.arms` returns zero for a machine that should not go resident, so
    // zero has to mean it: not "unbounded", which is the direction this mistake
    // would fail in.
    var w = Warden.init(t.allocator, 0);
    const a = w.allocator();
    try t.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try t.expectEqual(@as(u8, 0), w.tension());
}

test "warden: a lane cannot hoard what the ceiling needs" {
    const t = std.testing;
    // The failure this forbids is created by the lane scheme itself: credit is
    // charged wholesale, so bytes can sit unspent in one lane while another lane
    // asks for room. If a refusal could be provoked by *parked* credit, the
    // ceiling would refuse work the ration could plainly afford — and the bigger
    // the batch, the worse it would get. `sweep` is why that cannot happen, and
    // deleting it must fail here rather than merely make the daemon mean.
    var w = Warden.init(t.allocator, 512 << 10);
    const a = w.allocator();

    // A tiny allocation on one lane drags in a whole batch, then gives it back —
    // parked, not spent.
    const crumb = try a.alloc(u8, 1);
    a.free(crumb);
    try t.expect(w.held.load(.monotonic) > 0); // reserved…
    try t.expectEqual(@as(usize, 0), w.holding()); // …but nothing is live

    // Another lane now wants most of the ration. It only fits if the parked batch
    // is reclaimed first.
    const other = try std.Thread.spawn(.{}, struct {
        fn take(al: std.mem.Allocator, out: *?[]u8) void {
            out.* = al.alloc(u8, 400 << 10) catch null;
        }
    }.take, .{ a, &held_by_other });
    other.join();
    try t.expect(held_by_other != null);
    try t.expectEqual(@as(u64, 0), w.turnedAway());
    a.free(held_by_other.?);
    held_by_other = null;
}
var held_by_other: ?[]u8 = null;

test "warden: batched lanes still cannot cross the ceiling" {
    const t = std.testing;
    // The concurrency test below runs with a ration too small for a batch, so it
    // exercises the un-batched path. This one gives the ration room for many
    // batches, which is the daemon's real shape: every worker holding lane credit
    // at once is exactly when a bound kept per-lane could drift above the ceiling.
    var w = Warden.init(t.allocator, 8 << 20);
    const a = w.allocator();

    const Worker = struct {
        fn churn(al: std.mem.Allocator, warden: *Warden) void {
            for (0..500) |i| {
                const b = al.alloc(u8, 4096 + i % 512) catch continue;
                // `held` is the reserved total and is what the ceiling tests, so
                // it — not the live figure — is what must never exceed the ration.
                std.debug.assert(warden.held.load(.monotonic) <= warden.ration);
                al.free(b);
            }
        }
    };
    var pool: [8]std.Thread = undefined;
    for (&pool) |*h| h.* = try std.Thread.spawn(.{}, Worker.churn, .{ a, &w });
    for (pool) |h| h.join();

    try t.expect(w.peak() <= w.ration);
    // Every byte accounted for once the lanes are read alongside the counter.
    try t.expectEqual(@as(usize, 0), w.holding());
}

test "warden: accounting survives concurrent workers" {
    const t = std.testing;
    // The daemon runs up to 8 workers against one allocator. If the test-and-add
    // were not one step, the ceiling would be crossed under exactly this shape
    // and the bound would hold only single-threaded.
    var w = Warden.init(t.allocator, 64 * 1024);
    const a = w.allocator();

    const Worker = struct {
        fn churn(al: std.mem.Allocator, warden: *Warden) void {
            for (0..200) |_| {
                const b = al.alloc(u8, 1024) catch continue;
                std.debug.assert(warden.holding() <= warden.ration);
                al.free(b);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.churn, .{ a, &w });
    for (threads) |th| th.join();

    try t.expectEqual(@as(usize, 0), w.holding());
    try t.expect(w.peak() <= w.ration);
}
