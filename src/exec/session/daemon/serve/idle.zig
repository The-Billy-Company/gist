//! gist resident daemon — what an idle daemon gives back, and when.
//!
//! A warm daemon holds two very different resources. Its resident corpus +
//! trigram index are RAM, this process's own, reclaimed when it exits. Its
//! macOS watch set is one `O_EVTONLY` descriptor per watched vnode — ~26k on
//! this repo — drawn from the system-wide file table that every other process
//! shares, siblings included: ~10 coworker agents across several trees each
//! auto-spawn their own daemon, and a set that size is enough to fail the next
//! one's `pipe(2)`.
//!
//! So an idle daemon releases them in the order they cost the MACHINE, not the
//! order they cost itself: the watch set first, at `shed_ms`, and the session
//! only at `ttl_ms`. Shedding is free of correctness risk by construction — the
//! watcher is a pure accelerator (ADR-372), so a shed session simply reconciles
//! every query against the live filesystem, which is the pre-ADR behavior. What
//! it costs is speed, and only until the set is re-registered.
//!
//! Re-registration is the reason this is a policy and not an `if`. It walks the
//! tree and opens tens of thousands of descriptors (~300 ms of the poll thread),
//! so it must not run in front of a client's query — which would trade the
//! ~50 ms baseline walk it is trying to avoid for a 300 ms stall. It therefore
//! waits for the traffic that woke the daemon to go quiet again
//! (`rearm_quiet_ms`), and every query in the meantime answers on the baseline.
//! It runs on the poll thread with zero connections and nothing in flight — the
//! same quiescent window the boot arm ran in — which is what keeps the watcher
//! single-consumer without a lock.
//!
//! The whole policy is a pure function of two inputs (`nextStep`), so the
//! windows and their edges are testable without booting a daemon.

const std = @import("std");

/// Idle window with zero connections (and no query in flight) before a warm
/// daemon self-exits: the resident index/corpus stops earning its RAM once
/// nobody is querying, and a fresh query re-spawns one in the background anyway
/// (see `client/spawn.zig`).
pub const ttl_ms: i32 = 10 * 60 * 1000;

/// Idle window before the watch set goes back, well ahead of the session (see
/// the header). Short enough that an abandoned daemon stops taxing the file
/// table for most of its remaining life, long enough that an ordinary pause
/// between two `gist` invocations does not churn a re-registration.
pub const shed_ms: i32 = 2 * 60 * 1000;

/// How long returning traffic must settle before a shed watch set is rebuilt,
/// so the ~300 ms registration never lands in front of a query.
pub const rearm_quiet_ms: i32 = 2 * 1000;

/// Watch-set size below which shedding cannot pay for its own re-registration.
/// Linux's inotify backend holds ONE descriptor no matter how large the tree, so
/// this leaves it alone by construction; so is a macOS corpus far too small to
/// be what strains the table.
pub const shed_floor: usize = 1024;

/// Where the watch set stands in the policy: `holding` a set worth releasing,
/// `released` with nobody back yet, or a return `wanted` because a client dialed
/// in since. `inert` is everything the policy must not touch — an arm that never
/// succeeded (unsupported platform, a budget that would not fit), a re-arm that
/// declined, or a set too small to be worth rebuilding — so it neither retries a
/// refusal on a timer nor churns a cheap tree.
pub const WatchSet = enum { inert, holding, released, wanted };

/// What the daemon owes next, and how long until it is due.
pub const Step = struct { act: enum { shed, rearm, exit }, in_ms: i32 };

/// The idle plan. `idle_for_ms` is how long the daemon has had zero connections
/// and nothing in flight; it restarts at every connection, so the TTL measures
/// CONTINUOUS idleness exactly as it always has.
pub fn nextStep(set: WatchSet, idle_for_ms: i64) Step {
    return switch (set) {
        .holding => .{ .act = .shed, .in_ms = dueIn(shed_ms, idle_for_ms) },
        .wanted => .{ .act = .rearm, .in_ms = dueIn(rearm_quiet_ms, idle_for_ms) },
        .released, .inert => .{ .act = .exit, .in_ms = dueIn(ttl_ms, idle_for_ms) },
    };
}

/// The state a freshly (re-)registered watch set lands in: only a set big enough
/// to matter earns the policy's attention (see `shed_floor`).
pub fn settle(held: usize) WatchSet {
    return if (held >= shed_floor) .holding else .inert;
}

/// Milliseconds left until `deadline_ms` of idleness, floored at zero so an
/// already-overdue step fires on the next wakeup instead of blocking forever.
fn dueIn(deadline_ms: i32, idle_for_ms: i64) i32 {
    return @intCast(std.math.clamp(@as(i64, deadline_ms) - idle_for_ms, 0, deadline_ms));
}

test "the watch set goes back long before the session does" {
    const t = std.testing;
    // Freshly idle with a set worth holding: shed is due first, and the deadline
    // counts down rather than restarting on every wakeup.
    try t.expectEqual(Step{ .act = .shed, .in_ms = shed_ms }, nextStep(.holding, 0));
    try t.expectEqual(Step{ .act = .shed, .in_ms = 1000 }, nextStep(.holding, shed_ms - 1000));
    // Descriptors released: the session's own TTL is what remains, measured from
    // the SAME idle start — shedding must not buy the daemon extra life.
    try t.expectEqual(Step{ .act = .exit, .in_ms = ttl_ms - shed_ms }, nextStep(.released, shed_ms));
    try t.expect(shed_ms < ttl_ms);
}

test "a policy with nothing to act on only ever waits for the TTL" {
    const t = std.testing;
    // An arm that never succeeded must not be retried on a timer: the same
    // budget/platform that refused it will refuse it again.
    try t.expectEqual(Step{ .act = .exit, .in_ms = ttl_ms }, nextStep(.inert, 0));
    // A single inotify descriptor, or a corpus far too small to strain the file
    // table, is not worth a re-registration walk.
    try t.expectEqual(WatchSet.inert, settle(0));
    try t.expectEqual(WatchSet.inert, settle(1));
    try t.expectEqual(WatchSet.inert, settle(shed_floor - 1));
    try t.expectEqual(WatchSet.holding, settle(shed_floor));
    try t.expectEqual(WatchSet.holding, settle(26_000));
}

test "a returning client rebuilds the set only once its burst goes quiet" {
    const t = std.testing;
    try t.expectEqual(Step{ .act = .rearm, .in_ms = rearm_quiet_ms }, nextStep(.wanted, 0));
    // The quiet window is short next to the shed window — a returning user waits
    // seconds for warmth, not minutes — but long enough that back-to-back
    // invocations rebuild once rather than per connection.
    try t.expect(rearm_quiet_ms > 0 and rearm_quiet_ms < shed_ms);
}

test "an overdue deadline fires on the next wakeup, never blocks forever" {
    const t = std.testing;
    // A clock jump or a long-blocked poll must not hand `poll` a negative
    // timeout, which means "wait indefinitely" — the daemon would never exit.
    try t.expectEqual(@as(i32, 0), dueIn(ttl_ms, ttl_ms));
    try t.expectEqual(@as(i32, 0), dueIn(ttl_ms, std.math.maxInt(i64)));
    try t.expectEqual(@as(i32, 0), nextStep(.holding, shed_ms * 100).in_ms);
    // And never a timeout longer than the deadline itself.
    try t.expectEqual(@as(i32, ttl_ms), dueIn(ttl_ms, -1_000_000));
}
