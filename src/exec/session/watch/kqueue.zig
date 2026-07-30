//! gist resident session — the macOS `kqueue` event backend (ADR-352 rung 2.5,
//! ADR-372).
//!
//! Raw syscalls, no frameworks: the watcher costs the cold one-shot search
//! nothing, where the FSEvents stream this replaced needed CoreServices +
//! CoreFoundation (whose image initializers ran on every process launch, which
//! is why they were `dlopen`'d rather than linked). One `EVFILT_VNODE`
//! descriptor per watched vnode (selected by `coverage.zig`, capped by
//! `budget.zig`); this module registers them (`startKqueue`), drains their
//! events under the shared consumption lock (`drainKqueueLocked`), extends
//! coverage when a directory's membership moves, and retires a descriptor whose
//! vnode left. Every function takes the generic `Watcher(Session)` as `self`;
//! the shared accelerator contract and lifecycle live in the `watch.zig`
//! facade.

const std = @import("std");
const builtin = @import("builtin");
const fault = @import("../../../fault.zig");
const budget = @import("budget.zig");
const coverage = @import("coverage.zig");

const is_macos = builtin.os.tag == .macos;

/// `EVFILT_VNODE` notes, from `<sys/event.h>`. Content (`WRITE`/`EXTEND`) is the
/// whole reason files are watched individually — a directory does not change when
/// a file's bytes do. Membership (`DELETE`/`RENAME`/`LINK`) plus a directory's own
/// `WRITE` cover the corpus's shape, and `ATTRIB` catches the mode/mtime edits the
/// freshness cursor reads.
const NOTE = struct {
    const DELETE: u32 = 0x0001;
    const WRITE: u32 = 0x0002;
    const EXTEND: u32 = 0x0004;
    const ATTRIB: u32 = 0x0008;
    const LINK: u32 = 0x0010;
    const RENAME: u32 = 0x0020;
    const REVOKE: u32 = 0x0040;
};

/// The note mask every watch requests (see `NOTE`).
pub const vnode_notes: u32 = NOTE.DELETE | NOTE.WRITE | NOTE.EXTEND |
    NOTE.ATTRIB | NOTE.LINK | NOTE.RENAME | NOTE.REVOKE;

/// Wall-clock nanoseconds off the raw libc clock — the watcher's OS thread has
/// no `std.Io` handle, and the annals compare against `base.ns` instants minted
/// from the SAME realtime clock. Null on failure (callers degrade to
/// doubt/uncovered, never to a guessed instant).
fn wallNowNs() ?i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Register the whole watch set, then arm. Runs on the calling thread
/// (daemon boot) and takes ~300 ms for 22k descriptors — it does not need
/// to be instantaneous, because arming is not the same as claiming clean:
/// `Seqlock.arm` only marks a watcher live, `clean` is published solely by
/// a COMPLETED reconcile that no event raced, and `full_pass_done` forces
/// the first pass after arming to be the full walk. So a change that races
/// registration is caught by that walk (ADR-372).
pub fn startKqueue(self: anytype) void {
    if (comptime !is_macos) return;
    self.budget = budget.watchBudget();
    if (self.budget == 0) return; // no descriptors to spend → stay in baseline
    const kq = std.c.kqueue();
    if (kq < 0) return;
    self.kq_fd = kq;

    // Watch every directory the default walk descends plus the files in
    // them, keyed ABSOLUTE (realpath'd) so noted paths match the canonical
    // shape `delta.resolve` expects — and so a writer's own spelling never
    // enters the key space. A registration we cannot complete leaves a
    // subtree whose quiescence is unprovable, so we bail out unarmed
    // (fail-closed): the session keeps reconciling.
    if (!coverage.loadPolicy(self)) return closeWatches(self);
    if (!coverage.coverRoots(self, .initial)) return closeWatches(self);

    self.running.store(true, .release);
    self.thread = std.Thread.spawn(.{}, kqueueLoop, .{self}) catch {
        self.running.store(false, .release);
        return closeWatches(self);
    };
    // Annals coverage opens only now: an event that predated its own watch
    // was never observable, so the ledger must not claim the window
    // registration spanned (conservative by construction — uncovered, never
    // wrong). Then promise exactness, and arm LAST, so nothing can trust
    // quiescence before a consumer exists to prove it.
    if (comptime @TypeOf(self.*).has_annals) if (wallNowNs()) |ns| self.session.annals.openCoverage(ns);
    self.session.dirty_log.armExact();
    self.session.armWatcher();
}

/// Wait for events OUTSIDE the consumption lock — a kqueue descriptor is
/// itself pollable — then consume the whole batch under it, so a concurrent
/// `flushSync` can never see an empty queue while this thread still holds
/// events it has not noted.
fn kqueueLoop(self: anytype) void {
    if (comptime !is_macos) return;
    var pfd = [_]std.posix.pollfd{.{ .fd = self.kq_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    while (self.running.load(.acquire)) {
        const ready = std.posix.poll(&pfd, 500) catch break;
        if (ready == 0) continue;
        self.read_lock.lock();
        drainKqueueLocked(self);
        self.read_lock.unlock();
    }
}

/// Consume queued vnode events until the queue is empty. Caller MUST hold
/// `read_lock`. Every `note` precedes the single trailing `markDirty` — the
/// dirty-log/seqlock ordering contract a scoped reconcile relies on. A
/// failed consume leaves events we cannot account for, so it degrades both
/// readers (`noteUnattributable`) instead of reporting a clean drain.
pub fn drainKqueueLocked(self: anytype) void {
    if (comptime !is_macos) return;
    var evs: [256]std.c.Kevent = undefined;
    const immediately = std.c.timespec{ .sec = 0, .nsec = 0 };
    var noted = false;
    while (true) {
        const n = std.c.kevent(self.kq_fd, &evs, 0, &evs, evs.len, &immediately);
        if (n == 0) break;
        if (n < 0) {
            self.noteUnattributable();
            noted = true;
            break;
        }
        for (evs[0..@intCast(n)]) |ev| applyEvent(self, ev);
        noted = true;
    }
    // An ignore source changed somewhere in this batch: the rules that
    // selected the watch set no longer describe the walked set, so both
    // are re-derived — once, after the batch, because the refresh grows
    // the set this loop was walking. Coverage we cannot rebuild is a blind
    // spot for every newly-admitted file, so it poisons (fail-closed);
    // the query itself is already safe (`delta.classify` sends an ignore
    // source to the full walk).
    if (self.ig_stale) {
        self.ig_stale = false;
        if (!coverage.loadPolicy(self) or !coverage.coverRoots(self, .refresh)) self.session.markDoubtForever();
    }
    if (noted) self.session.markDirty();
}

/// Apply one vnode event: note the exact path that changed, extend coverage
/// when a directory's membership moved, and retire a watch whose vnode left.
/// An event that names no watch of ours — an `EV_ERROR`, or a `udata` that
/// indexes nothing — is a change we cannot place, and degrades both readers.
fn applyEvent(self: anytype, ev: std.c.Kevent) void {
    if (comptime !is_macos) return;
    if (ev.flags & std.c.EV.ERROR != 0) return self.noteUnattributable();
    const idx = std.math.cast(u32, ev.udata) orelse return self.noteUnattributable();
    if (idx >= self.watches.items.len) return self.noteUnattributable();
    if (self.watches.items[idx].fd < 0) return; // retired earlier in this drain
    note(self, self.watches.items[idx].path, self.watches.items[idx].is_dir);
    if (self.watches.items[idx].is_dir) rescanDir(self, idx);
    // A vanished or renamed vnode's descriptor no longer names a member of
    // the walked set, so retire it and let the paired directory event
    // register the entry under its current spelling. This is about the
    // DESCRIPTOR, not the file: a case-only rename reports RENAME and DELETE
    // together while the file still very much exists.
    if (ev.fflags & (NOTE.DELETE | NOTE.RENAME | NOTE.REVOKE) != 0) retire(self, idx);
}

/// Note one changed absolute path into the dirty log — and, for a FILE, the
/// annals ledger a one-shot `gist index` consults. A directory reaches only
/// the dirty log: its event means "membership here moved", which the
/// reconcile answers by diffing the subtree, while the ledger's reader
/// amends per file and would stat a directory away — and its capacity is
/// bounded, so an entry spent on shape is an entry evicted from content. A
/// dead clock poisons the ledger rather than guessing an instant.
pub fn note(self: anytype, path: []const u8, is_dir: bool) void {
    self.session.dirty_log.note(path);
    if (is_dir) return;
    if (coverage.isIgnoreSource(std.fs.path.basename(path))) self.ig_stale = true;
    if (comptime @TypeOf(self.*).has_annals) {
        if (wallNowNs()) |ns| self.session.annals.note(path, ns) else self.session.annals.noteDoubt();
    }
}

/// A watched directory's membership changed: register whatever appeared, so
/// a later content edit to a new file cannot go unseen (a directory does not
/// fire when its files' bytes change — that is the whole reason files are
/// watched individually). Coverage we cannot re-establish is a blind spot,
/// so it poisons the session (fail-closed). Each newcomer is also NOTED
/// (`report`) — the directory's event proves something arrived but not what,
/// and the annals reader needs the file. What LEFT needs no work here: the
/// directory was already noted, and reconcile diffs its subtree.
fn rescanDir(self: anytype, idx: u32) void {
    if (comptime !is_macos) return;
    // Heap-owned and stable across the watch-set growth below — only the
    // slot array can move, never a path's bytes. `coverTree` is the one
    // place the walk's admission policy lives, so a re-scan applies
    // exactly the rules the initial registration did; its own watch is
    // already indexed, making that first `addWatch` a no-op.
    const w = self.watches.items[idx];
    if (self.ig) |*ig| ig.scopeToRoot(coverage.rootKeyOf(self, w.key));
    if (!coverage.coverTree(self, w.path, w.key, .extend)) self.session.markDoubtForever();
}

/// Retire slot `idx`: close its descriptor (which removes the kevent with
/// it), drop its index entry, and offer the slot for reuse. The path bytes
/// are freed last — `watch_index` borrows them as its key.
pub fn retire(self: anytype, idx: u32) void {
    if (comptime !is_macos) return;
    const w = self.watches.items[idx];
    if (w.fd < 0) return;
    _ = std.c.close(w.fd);
    _ = self.watch_index.remove(w.path);
    self.watches.items[idx] = .{ .fd = -1, .path = &.{}, .key = &.{}, .is_dir = false };
    // A slot we cannot enqueue is simply never reused — never a coverage gap.
    fault.spare("recycle a watch slot", self.free_slots.append(self.gpa, idx));
    self.gpa.free(w.key);
    self.gpa.free(w.path);
}

/// Close every watch descriptor and the queue itself, freeing their
/// bookkeeping. Idempotent: `stop` calls it after a failed start too. A
/// partial watch set is never armed, so this doubles as the bail-out path
/// — and, after `shed`, the reset a later `start` re-registers from.
pub fn closeWatches(self: anytype) void {
    if (comptime !is_macos) return;
    self.ig_stale = false; // a pending refresh dies with the set it was about
    for (self.watches.items) |w| if (w.fd >= 0) {
        _ = std.c.close(w.fd);
        self.gpa.free(w.key);
        self.gpa.free(w.path);
    };
    coverage.dropPolicy(self);
    self.watches.deinit(self.gpa);
    self.watches = .empty;
    self.watch_index.deinit(self.gpa);
    self.watch_index = .empty;
    self.free_slots.deinit(self.gpa);
    self.free_slots = .empty;
    if (self.kq_fd >= 0) {
        _ = std.c.close(self.kq_fd);
        self.kq_fd = -1;
    }
}
