//! `warden` — what the resident memory ceiling costs, decomposed.
//!
//! The ceiling in `exec/session/warden/` is a SAFETY feature, and a safety
//! feature that shows up in a throughput benchmark is not worth having. This
//! prices it against the allocator the daemon actually receives in ReleaseFast
//! (`std.heap.smp_allocator`, per-CPU sharded) and, crucially, decomposes the
//! cost so a regression can be attributed rather than merely noticed:
//!
//!   bare        the backing allocator, called directly
//!   passthru    a wrapper whose vtable forwards and accounts NOTHING — isolates
//!               the cost of interposing an `Allocator` at all (one extra
//!               indirect call per operation, and the inlining it forbids)
//!   warden      the real thing: passthru + the metered bound
//!
//! `warden - passthru` is the bound's own cost, which is the only part the
//! module's design controls. `passthru - bare` is the price of wrapping, which
//! no accounting scheme can remove — only a coarser seam can.
//!
//! The alloc/free loop does no work between operations on purpose: it is the
//! most adversarial shape possible for a per-allocation charge, so it bounds
//! what any real workload could lose. The daemon's real paths (a per-query
//! arena, whole-file mirror bodies) are far cheaper per metered byte.
const std = @import("std");
const Warden = @import("warden").Warden;

const threads = 8;

/// A wrapper that forwards every call and accounts nothing, so the difference
/// between it and `bare` is exactly what interposition costs.
const Passthru = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *Passthru) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Passthru = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Passthru = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Passthru = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Passthru = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(m, a, ra);
    }
};

const Arm = enum { bare, passthru, warden };

var clock: std.Io = undefined;

fn nowNs() u64 {
    return @intCast(std.Io.Clock.now(.awake, clock).nanoseconds);
}

fn churn(a: std.mem.Allocator, n: usize, sizes: []const usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = a.alloc(u8, sizes[i % sizes.len]) catch continue;
        p[0] = @truncate(i);
        std.mem.doNotOptimizeAway(p[0]);
        a.free(p);
    }
}

fn once(arm: Arm, par: bool, sizes: []const usize, n: usize) u64 {
    const raw = std.heap.smp_allocator;
    var pt = Passthru{ .backing = raw };
    var w = Warden.init(raw, std.math.maxInt(usize));
    const a = switch (arm) {
        .bare => raw,
        .passthru => pt.allocator(),
        .warden => w.allocator(),
    };
    if (!par) {
        const t0 = nowNs();
        churn(a, n, sizes);
        return nowNs() - t0;
    }
    // Every thread does the FULL count, not a share of it. Splitting the work made
    // each thread run for well under a millisecond, so spawn and join were a large
    // and variable fraction of the sample — enough to swamp the sub-nanosecond
    // signal being measured, and to produce a negative wrapper cost.
    var pool: [threads]std.Thread = undefined;
    const t0 = nowNs();
    for (&pool) |*h| h.* = std.Thread.spawn(.{}, churn, .{ a, n, sizes }) catch unreachable;
    for (pool) |h| h.join();
    return nowNs() - t0;
}

/// Best of `tries`, after a warmup pass, so first-touch page faults and a noisy
/// neighbor cannot be charged to whichever arm happened to run first.
fn best(arm: Arm, par: bool, sizes: []const usize, n: usize, tries: usize) f64 {
    _ = once(arm, par, sizes, n / 8);
    var lo: u64 = std.math.maxInt(u64);
    for (0..tries) |_| lo = @min(lo, once(arm, par, sizes, n));
    const ops = if (par) n * threads else n;
    return @as(f64, @floatFromInt(lo)) / @as(f64, @floatFromInt(ops));
}

/// What the bound's own cost may be, per operation, in each shape. Absolute
/// nanoseconds rather than a ratio: `bare` in the parallel column is
/// sub-nanosecond, so a ratio there measures noise, while nanoseconds per
/// allocation are what a workload actually pays.
///
/// The two budgets differ on purpose, because they police different failures:
///
///   `parallel` is the one that matters, and the one that nearly shipped broken.
///   A shared counter charged per allocation cost 213 ns/op here against an
///   allocator answering in 0.6 — the guard was 350× the work it guarded. Lane
///   sharding makes it free (measured 0.4 ns/op), and the budget is set above the
///   noise floor of a developer machine running other builds rather than at the
///   measurement, because a genuine regression here is not a fraction of a
///   nanosecond: putting the hot path back onto shared state costs 70–220, which
///   is 20–70× this budget. Policing noise would only teach people to ignore it.
///
///   `serial` is a floor, not a target. A hard ceiling must claim on alloc and
///   release on free, and two uncontended atomic read-modify-writes cost about
///   what they cost. This budget says "two, and no more" — a third atomic, or a
///   second cache line on the fast path, shows up here immediately.
const budget_parallel_ns: f64 = 3.0;
const budget_serial_ns: f64 = 4.5;

fn shape(label: []const u8, sizes: []const usize, n: usize, tries: usize) bool {
    var ok = true;
    for ([_]bool{ false, true }) |par| {
        const b = best(.bare, par, sizes, n, tries);
        const p = best(.passthru, par, sizes, n, tries);
        const w = best(.warden, par, sizes, n, tries);
        const bound = w - p;
        const wrap = p - b;
        const budget = if (par) budget_parallel_ns else budget_serial_ns;
        if (bound > budget) ok = false;
        std.debug.print(
            "  {s:<12} {s:<9} bare {d:>6.2}  passthru {d:>6.2}  warden {d:>6.2} ns/op   wrap {d:>5.2}  bound {d:>6.2} of {d:.1} ns  {s}\n",
            .{ label, if (par) "8-thread" else "serial", b, p, w, wrap, bound, budget, if (bound > budget) "OVER" else "ok" },
        );
    }
    return ok;
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    clock = threaded.io();

    const n: usize = 4_000_000;
    std.debug.print(
        "warden overhead vs smp_allocator — {d} alloc+free pairs; budget {d:.1} ns/op 8-thread, {d:.1} serial\n",
        .{ n, budget_parallel_ns, budget_serial_ns },
    );

    // Small allocations are adversarial: a fixed per-call charge is the largest
    // fraction of the smallest payload.
    const small = [_]usize{ 16, 32, 64, 48 };
    const mid = [_]usize{ 512, 1024, 2048, 768 };
    var ok = true;
    if (!shape("small 16-64B", &small, n, 5)) ok = false;
    if (!shape("mid .5-2KB", &mid, n, 5)) ok = false;

    if (!ok) {
        std.debug.print("\nwarden: the bound's own cost exceeded its budget\n", .{});
        return error.WardenOverheadRegressed;
    }
    std.debug.print("\nwarden: the bound stays inside its budget in every shape\n", .{});
}
