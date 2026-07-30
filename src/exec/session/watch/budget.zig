//! gist resident session — the macOS watch-descriptor budget (ADR-352 rung 2.5,
//! ADR-372).
//!
//! One question: how many vnode watches may this session hold? The macOS kqueue
//! backend (`kqueue.zig`) pays one descriptor per watched vnode, so the answer
//! is a whole-machine resource decision, not a per-process one. `watchBudget`
//! clamps against the three ceilings the kernel actually enforces — only the
//! first of which `getrlimit` reports — and returns ZERO when nothing can be
//! spent, which leaves the session unarmed (reconcile-always) rather than
//! partially covered (fail-closed). The pure arithmetic (`budgetFrom`,
//! `commonsShare`, …) is split out here so those fail-closed edges are
//! unit-testable without mutating the real process limits. See the `watch.zig`
//! facade for how a zero budget keeps the session sound.

const std = @import("std");
const builtin = @import("builtin");
const fault = @import("../../../fault.zig");

const is_macos = builtin.os.tag == .macos;

/// Descriptors left for everything else the process needs — its listening
/// socket, per-request fds, index mmaps. A watch set that will not fit under
/// the ENFORCED per-process ceiling with this much headroom leaves the session
/// unarmed rather than partially covered (fail-closed).
const fd_reserve: usize = 512;

/// System-wide file-table entries no watch set may reach into, so a sibling
/// process — the next daemon's `pipe(2)`, an editor's save — can still open a
/// file after this session has armed.
const table_reserve: usize = 4096;

/// The largest fraction of the WHOLE system file table one session may hold as
/// watches (1/8). Several trees each keep their own auto-spawned daemon, so the
/// table is a commons: the fraction stops the first daemon claiming it, and the
/// live free-headroom term (`commonsShare`) stops the last one exhausting it.
const table_fraction: usize = 8;

/// How many vnode watches may be held. THREE ceilings bind, all enforced by the
/// kernel and only the first of them reported by `getrlimit`:
///
///   * `RLIMIT_NOFILE`, raised to the hard limit when it can be — a daemon
///     holding one descriptor per corpus file is exactly what the limit is for.
///   * macOS `kern.maxfilesperproc`, the per-process ceiling Darwin ACTUALLY
///     enforces. `getrlimit` never reports it, and the gap is not academic: a
///     soft limit of 1,048,575 against a `maxfilesperproc` of 245,760
///     over-states the room by 4.3×, and a stock macOS box ships 24,576 — under
///     the ~26k watches this repo alone admits. Unclamped, the fail-closed
///     check is not PREDICTIVE: the session accepts a set it cannot register
///     and meets `EMFILE` partway through instead of declining up front.
///   * a bounded share of the system-wide file table (`commonsShare`), because
///     one descriptor per vnode makes that table a commons several concurrent
///     daemons share (`table_fraction`).
///
/// Zero when the rlimit cannot be read, or when the commons has no room left —
/// the caller then stays unarmed (reconcile-always), which is the whole point.
pub fn watchBudget() usize {
    var rl = std.posix.getrlimit(.NOFILE) catch return 0;
    if (rl.cur < rl.max) {
        rl.cur = rl.max;
        fault.spare("raise the NOFILE soft limit", std.posix.setrlimit(.NOFILE, rl));
        rl = std.posix.getrlimit(.NOFILE) catch return 0;
    }
    return @min(budgetFrom(rl.cur), procCeiling(), commonsCeiling());
}

/// The budget arithmetic alone, split out so the fail-closed edges are testable
/// without mutating the process's real limits: a ceiling at or under the reserve
/// yields ZERO watches, which leaves the session unarmed (reconcile-always)
/// rather than partially covered.
fn budgetFrom(limit: std.posix.rlim_t) usize {
    if (limit == std.posix.RLIM.INFINITY) return std.math.maxInt(usize);
    const cur = std.math.cast(usize, limit) orelse return std.math.maxInt(usize);
    return lessReserve(cur);
}

/// A descriptor ceiling minus the headroom the rest of the process needs.
fn lessReserve(ceiling: usize) usize {
    return ceiling -| fd_reserve;
}

/// One integer `sysctl`, or null when the name is unknown or the kernel answers
/// with something other than the 32-bit int these are documented to be. Null is
/// "one fewer ceiling to respect", never "no watches" — an unreadable clamp must
/// not silently unarm a session that the reported limits already fit.
fn sysctlInt(name: [*:0]const u8) ?usize {
    if (comptime !is_macos) return null;
    var v: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (std.c.sysctlbyname(name, &v, &len, null, 0) != 0) return null;
    if (len != @sizeOf(c_int) or v <= 0) return null;
    return @intCast(v);
}

/// The per-process ceiling the kernel enforces behind `RLIMIT_NOFILE`'s back
/// (see `watchBudget`). Unbounded where no such second ceiling exists.
fn procCeiling() usize {
    return lessReserve(sysctlInt("kern.maxfilesperproc") orelse return std.math.maxInt(usize));
}

/// This session's share of the system-wide file table, priced against what is
/// actually free right now — so a daemon arming into a machine that already
/// runs four of them declines rather than starving the commons.
fn commonsCeiling() usize {
    const maxfiles = sysctlInt("kern.maxfiles") orelse return std.math.maxInt(usize);
    return commonsShare(maxfiles, sysctlInt("kern.num_files") orelse 0);
}

/// The commons arithmetic alone (testable without a kernel): a fixed fraction of
/// the whole table, never more than the free headroom above `table_reserve`.
/// Both terms carry weight — the fraction keeps one daemon from claiming the
/// table it shares with its siblings, the headroom keeps the LAST of them from
/// emptying it out from under everybody's `pipe(2)`.
fn commonsShare(maxfiles: usize, in_use: usize) usize {
    return @min(maxfiles / table_fraction, maxfiles -| in_use -| table_reserve);
}

test "budget: a ceiling at or under the reserve arms nothing (fail-closed)" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), budgetFrom(0));
    try t.expectEqual(@as(usize, 0), budgetFrom(fd_reserve));
    try t.expectEqual(@as(usize, 1), budgetFrom(fd_reserve + 1));
    try t.expectEqual(@as(usize, 262144 - fd_reserve), budgetFrom(262144));
    try t.expectEqual(std.math.maxInt(usize), budgetFrom(std.posix.RLIM.INFINITY));
}

test "budget: the reported rlimit is not the ceiling macOS enforces" {
    const t = std.testing;
    // The measured gap this clamp exists for, on the machine ADR-372 was built
    // on: a 1,048,575 soft `RLIMIT_NOFILE` against `kern.maxfilesperproc` of
    // 245,760 — the rlimit alone over-states the room by more than 4×.
    try t.expect(budgetFrom(1_048_575) > 4 * lessReserve(245_760));
    // A stock macOS box (`kern.maxfilesperproc` 24,576) cannot hold this repo's
    // ~26k-descriptor watch set at all, so the enforced clamp must decline it —
    // which is exactly what an unclamped rlimit would have let through.
    try t.expect(lessReserve(24_576) < 26_000);
    try t.expect(budgetFrom(1_048_575) > 26_000);
}

test "the enforced ceilings are actually readable on the platform that has them" {
    const t = std.testing;
    if (comptime !is_macos) return; // no second ceiling to read; the clamps are unbounded
    // The arithmetic above is only worth anything if the kernel answers, so pin
    // the plumbing itself: a typo'd `sysctl` name would silently widen the
    // budget back to the rlimit this whole clamp exists to distrust.
    try t.expect(sysctlInt("kern.maxfilesperproc") != null);
    try t.expect(sysctlInt("kern.maxfiles") != null);
    try t.expect(sysctlInt("kern.num_files") != null);
    try t.expectEqual(@as(?usize, null), sysctlInt("kern.no_such_knob_here"));
    // And the ceilings must actually bind: unbounded means the clamp is absent.
    try t.expect(procCeiling() < std.math.maxInt(usize));
    try t.expect(commonsCeiling() < std.math.maxInt(usize));
}

test "commons: a fraction of the table, never more than is actually free" {
    const t = std.testing;
    const table = 491_520; // kern.maxfiles as measured
    // Idle table: the fraction binds, so one daemon can never take the commons.
    try t.expectEqual(@as(usize, table / table_fraction), commonsShare(table, 44_461));
    // Siblings have filled it: the live free headroom binds instead, and it is
    // what leaves room for the next daemon's pipe(2).
    try t.expectEqual(@as(usize, table - 460_000 - table_reserve), commonsShare(table, 460_000));
    // Nothing left to spend → zero watches → the session stays unarmed.
    try t.expectEqual(@as(usize, 0), commonsShare(table, table - table_reserve));
    try t.expectEqual(@as(usize, 0), commonsShare(table, table * 2));
}
