//! gist resident session — the exact dirty-path log (O(changed) freshness).
//!
//! A `DirtyLog` is the hand-off between a path-reporting watcher backend and
//! the session's reconcile: the backend `note`s every changed path (and
//! `noteDoubt`s whenever it cannot vouch for completeness — dropped events,
//! flag it can't classify), the reconcile `drain`s the accumulated set and
//! decides whether it may reconcile *scoped* (verify only the drained paths)
//! instead of re-walking the whole tree.
//!
//! Fail-closed by construction, in three independent ways:
//!
//!   1. `exact` is armed only by a backend that promises every `markDirty` is
//!      preceded by a `note`/`noteDoubt` for the same event — macOS kqueue (one
//!      watched descriptor per vnode) and Linux inotify over case-sensitive
//!      roots both do. A backend that can't make that promise (a casefolded
//!      Linux root, an unsupported target) never arms it, so its drains always
//!      force the full walk — the fail-closed baseline.
//!   2. The set is BOUNDED (`cap` distinct paths). Overflow, or any allocation
//!      failure while noting, raises `doubt` — the drain then reports an
//!      incomplete set and the reconcile falls back to the full walk.
//!   3. `doubt` is sticky until the next drain: once a drain saw doubt, that
//!      reconcile walks fully, which re-derives the truth for every path the
//!      log may have lost.
//!
//! Threading: `note`/`noteDoubt` are called from the watcher thread,
//! `drain` from the query thread under the session mutex; the shared
//! `kernel/math/lease.zig::Latch` guards the set (the critical sections are tiny
//! and bounded, and the watcher's OS thread has no `std.Io` handle for an
//! `Io.Mutex`). The ordering contract with the seqlock
//! is: the backend notes the path BEFORE it bumps `dirty_seq` (`markDirty`),
//! and the reconcile reads `dirty_seq` BEFORE it drains — so any event counted
//! by the pre-drain seq read is visible to that drain, and any event that
//! raced past it keeps the session dirty for the next reconcile (its path is
//! already queued).

const std = @import("std");
const Latch = @import("../../../kernel/math/lease.zig").Latch;

/// Distinct-path bound. A drain larger than this means a tree-wide storm (a
/// build, a checkout) — the full walk is the right tool there anyway, so the
/// log degrades to `doubt` rather than growing without bound.
pub const default_cap = 4096;

/// One drained batch: the noted paths (each gpa-owned, as is the slice) plus
/// the two soundness bits the reconcile gates on.
pub const Drained = struct {
    paths: []const []const u8 = &.{},
    doubt: bool = false,
    exact: bool = false,

    pub fn deinit(self: *Drained, gpa: std.mem.Allocator) void {
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
        self.* = .{};
    }
};

pub const DirtyLog = struct {
    gpa: std.mem.Allocator,
    mu: Latch = .{},
    /// Distinct noted paths (owned keys). Deduped so a hot file rewritten a
    /// thousand times in one window costs one slot, not the whole budget.
    set: std.StringHashMapUnmanaged(void) = .empty,
    doubt: bool = false,
    exact: bool = false,
    cap: usize = default_cap,

    pub fn init(gpa: std.mem.Allocator) DirtyLog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DirtyLog) void {
        var it = self.set.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.set.deinit(self.gpa);
    }

    /// The backend's completeness promise: from now on every `markDirty` is
    /// preceded by a `note`/`noteDoubt` for the same event. Withdrawn only by
    /// `disarmExact`, when the backend that made it is gone.
    pub fn armExact(self: *DirtyLog) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.exact = true;
    }

    /// The promising backend released its coverage (a shed watch set): nothing
    /// is noting paths any more, so the promise it made must not outlive it.
    /// Every drain from here reports `exact = false` — full walks only — until
    /// a new backend arms.
    pub fn disarmExact(self: *DirtyLog) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.exact = false;
    }

    /// Record one changed path (deduped). Overflow or OOM degrades to `doubt`
    /// — never a silent drop.
    pub fn note(self: *DirtyLog, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.doubt) return; // already forcing a full walk; don't grow
        if (self.set.contains(path)) return;
        if (self.set.count() >= self.cap) {
            self.doubt = true;
            return;
        }
        const owned = self.gpa.dupe(u8, path) catch {
            self.doubt = true;
            return;
        };
        self.set.put(self.gpa, owned, {}) catch {
            self.gpa.free(owned);
            self.doubt = true;
        };
    }

    /// The backend saw an event it cannot attribute to an exact path set
    /// (kernel drop, subdir-scan flag, mount churn): the next drain must walk.
    pub fn noteDoubt(self: *DirtyLog) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.doubt = true;
    }

    /// Move the accumulated batch out (resetting the log). The caller owns the
    /// result (`Drained.deinit`). Paths come out in arbitrary order.
    pub fn drain(self: *DirtyLog, gpa: std.mem.Allocator) Drained {
        self.mu.lock();
        defer self.mu.unlock();
        var out = Drained{ .doubt = self.doubt, .exact = self.exact };
        self.doubt = false;
        const n = self.set.count();
        if (n != 0) blk: {
            const paths = gpa.alloc([]const u8, n) catch {
                // Can't even carry the batch out: drop it and force the walk.
                var it = self.set.keyIterator();
                while (it.next()) |k| self.gpa.free(k.*);
                self.set.clearRetainingCapacity();
                out.doubt = true;
                break :blk;
            };
            var it = self.set.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) paths[i] = k.*;
            self.set.clearRetainingCapacity();
            out.paths = paths;
        }
        return out;
    }
};

test "note dedupes, drain moves out and resets" {
    const t = std.testing;
    var log = DirtyLog.init(t.allocator);
    defer log.deinit();
    log.note("a");
    log.note("b");
    log.note("a");
    var d = log.drain(t.allocator);
    defer d.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), d.paths.len);
    try t.expect(!d.doubt);
    try t.expect(!d.exact);
    var d2 = log.drain(t.allocator);
    defer d2.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), d2.paths.len);
}

test "overflow degrades to doubt, doubt resets on drain" {
    const t = std.testing;
    var log = DirtyLog.init(t.allocator);
    defer log.deinit();
    log.cap = 2;
    log.note("a");
    log.note("b");
    log.note("c"); // over the bound → doubt, path dropped
    var d = log.drain(t.allocator);
    defer d.deinit(t.allocator);
    try t.expect(d.doubt);
    try t.expectEqual(@as(usize, 2), d.paths.len);
    log.note("x");
    var d2 = log.drain(t.allocator);
    defer d2.deinit(t.allocator);
    try t.expect(!d2.doubt);
    try t.expectEqual(@as(usize, 1), d2.paths.len);
}

test "armExact is sticky and echoed on every drain" {
    const t = std.testing;
    var log = DirtyLog.init(t.allocator);
    defer log.deinit();
    var d0 = log.drain(t.allocator);
    defer d0.deinit(t.allocator);
    try t.expect(!d0.exact);
    log.armExact();
    var d1 = log.drain(t.allocator);
    defer d1.deinit(t.allocator);
    try t.expect(d1.exact);
}

test "the exact promise does not outlive the backend that made it" {
    const t = std.testing;
    var log = DirtyLog.init(t.allocator);
    defer log.deinit();
    log.armExact();
    log.disarmExact();
    var d = log.drain(t.allocator);
    defer d.deinit(t.allocator);
    try t.expect(!d.exact); // nothing is noting → no drain may claim completeness
    log.armExact();
    var d2 = log.drain(t.allocator);
    defer d2.deinit(t.allocator);
    try t.expect(d2.exact);
}

test "noteDoubt forces the next drain only" {
    const t = std.testing;
    var log = DirtyLog.init(t.allocator);
    defer log.deinit();
    log.noteDoubt();
    var d = log.drain(t.allocator);
    defer d.deinit(t.allocator);
    try t.expect(d.doubt);
    var d2 = log.drain(t.allocator);
    defer d2.deinit(t.allocator);
    try t.expect(!d2.doubt);
}
