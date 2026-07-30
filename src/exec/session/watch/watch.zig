//! gist resident session — the freshness watcher (ADR-352 rung 2.5).
//!
//! The watcher is a pure *accelerator* for the freshness barrier, never a
//! correctness dependency. Its only job is to keep a session honest about when
//! it may skip the reconcile walk: on any filesystem event under the watched
//! roots it calls `session.markDirty()`, forcing the next query to reconcile;
//! when it has proven no event since the last reconcile the session takes the
//! microsecond fast path. If a watcher cannot be started (unsupported platform,
//! a watch that won't register, a descriptor budget that won't fit), the session
//! is simply **never armed** — `watcher_active` stays false and every query
//! reconciles the changed set against the live filesystem. Correctness rests on
//! that reconcile (`resident.zig`), so a missing or degraded watcher only costs
//! speed, never soundness (fail-closed).
//!
//! Backends: Linux `inotify`, macOS `kqueue` (`EVFILT_VNODE`), and Windows
//! `ReadDirectoryChangesW` over an I/O completion port. All three report their
//! event inside the operation that caused it, which is what makes drain-to-empty
//! (`flushSync`) a genuine happens-before witness and lets each arm
//! `DirtyLog.exact` — the promise that unlocks the O(changed) scoped reconcile.
//! Every other target keeps the reconcile-always baseline. A rootless session
//! watches `.` — the same CWD tree its corpus walks.
//!
//! On Windows that witness rests on the *completion port* specifically, and the
//! event a delivery is keyed to is the directory entry rather than the write: both
//! are load-bearing and both are argued in `notify.zig`'s module note.
//!
//! Every backend `note`s each changed path into the session's `DirtyLog`, so
//! reconcile verifies only changed paths — O(changed) instead of O(tree). An
//! unattributable event becomes `noteUnattributable`, forcing one full walk;
//! coverage that cannot be re-established calls `markDoubtForever`, retiring the
//! fast path for the session's life (fail-closed). Notes are keyed to absolute
//! realpaths, the canonical shape `delta.resolve` expects.
//!
//! Each of those degradations has to reach TWO readers, because the session
//! protects them differently. A QUERY re-derives its answer from the tree, so
//! forcing the full walk is enough for it. A HELD answer is never re-derived at
//! all — it is trusted purely on the annals' change epoch standing still, which
//! a forced walk does nothing for. So an event a backend cannot place must also
//! reach the ledger, and coverage a backend cannot keep must stop the epoch
//! being vouched at all. Both translations therefore live on this facade
//! (`noteUnattributable`, and `resident.zig`'s doubt/disarm hooks) rather than
//! once per backend, where the two could drift apart.
//!
//! They differ in what they must refuse, because their event KEY SPACES differ.
//! inotify reports a parent watch descriptor plus a kernel-supplied name, so a
//! casefolded root (ext4/f2fs `+F`) would alias distinct byte-spellings the
//! exact key model cannot represent — such a session stays coarse. kqueue
//! reports a DESCRIPTOR this process opened itself, with the walk's own
//! canonical spelling, so a writer's choice of spelling never enters the key
//! space and exact arms even on a case-insensitive volume (ADR-372).
//! `ReadDirectoryChangesW` reports the name as the DIRECTORY ENTRY stores it —
//! one spelling per file whatever the writer typed — so it too arms exact,
//! including on a case-insensitive volume.
//!
//! And they differ in what each must therefore guard. inotify must watch for a
//! queue overflow and for directories created after arming, since its watches
//! neither recurse nor coalesce; kqueue has no queue to overflow (events fold
//! into a knote's `fflags`) but must still extend coverage into new entries, and
//! must hold one descriptor per watched vnode. Windows is the Linux shape without
//! the second half: a `WatchTree` subscription covers directories created after
//! arming for free, so there is no coverage to extend and no per-vnode price to
//! predict — but its per-root buffer can overflow exactly as inotify's queue can,
//! and overflow there is `markDoubtForever` for the same reason.
//!
//! That descriptor-per-vnode price is why the macOS set is selected by the
//! WALK'S OWN admission policy (`corpus/tree/ignore.zig`), not by the raw tree:
//! inotify watches directories and gets their entries named for free, while
//! keeping gitignored files on macOS cost 193k descriptors against 25k admitted
//! ones here. The set therefore also carries the hidden per-directory ignore
//! SOURCES that decide admission, and a change to one re-derives both the rules
//! and the set (`refreshCoverage` via `Cover.refresh`) — otherwise a rule edit
//! could admit a file that nothing was watching.
//!
//! The same price makes the budget a question about the WHOLE MACHINE, not just
//! this process: `watchBudget` clamps against the ceiling Darwin actually
//! enforces (`kern.maxfilesperproc`, which `getrlimit` never reports) and
//! against a bounded share of the live system file table, so declining is
//! predictive rather than an `EMFILE` discovered halfway through registration.
//! A prediction over a commons is not a promise, though — a sibling arming in
//! between spends the room it counted — so the registration itself also refuses
//! to call an unopenable path covered: only a path that VANISHED may be skipped,
//! and every other errno leaves the session unarmed (`coverage.vanished`).
//! And because a watch set only earns its keep while somebody is querying, it
//! is RELEASABLE: `shed` hands every descriptor back and returns the session to
//! the reconcile-always baseline, `start` re-registers it. That is what lets an
//! idle daemon stop taxing the commons its siblings share (`serve.zig`'s
//! two-stage idle policy) without ever risking a stale answer.
//!
//! The backends live beside this facade under `watch/`: `inotify.zig` (Linux),
//! `kqueue.zig` (macOS events) + `coverage.zig` (the macOS admission walk) +
//! `budget.zig` (the descriptor ceiling), `notify.zig` (Windows). Each is a set of free functions over
//! the generic `Watcher(Session)` below; this file owns the shared state, the
//! comptime backend selection, and the cross-backend invariants documented here.

const std = @import("std");
const builtin = @import("builtin");
const ignore = @import("../../../corpus/tree/ignore.zig");
const portal = @import("../../../portal.zig");
const Latch = @import("../../../kernel/math/lease.zig").Latch;
const inotify = @import("inotify.zig");
const kqueue = @import("kqueue.zig");
const notify = @import("notify.zig");

const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;
const linux = std.os.linux;

/// One registered vnode watch. `path` is the absolute path to `note` when the
/// descriptor fires; `is_dir` marks the events that mean "membership changed
/// here" rather than "these bytes changed". `key` is that directory's path in
/// the walk's own key space (empty for a file, which is never re-scanned), the
/// spelling the ignore policy judges entries by. Slots are addressed by the
/// `udata` each event carries, so an event resolves to its path without a hash
/// lookup.
const Watch = struct { fd: i32, path: []const u8, key: []const u8, is_dir: bool };

/// The freshness watcher, generic over any resident `Session` that exposes the
/// change-tracking surface it drives: `roots: []const []const u8`,
/// `armWatcher()`, `markDirty()`, `markDoubtForever()`, and a `dirty_log`
/// (`.armExact()` / `.note()` / `.noteDoubt()`). Gist's `ResidentSession` and
/// relate's retrieval session both satisfy it, so one watcher backs both —
/// the accelerator is written once, the corpus/index model stays per-session.
pub fn Watcher(comptime Session: type) type {
    return struct {
        session: *Session,
        io: std.Io,
        gpa: std.mem.Allocator,
        thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = .init(false),
        inotify_fd: i32 = -1,
        /// Linux: watch descriptor → the directory it covers (gpa-owned), so a
        /// dir-create event can be resolved to a path and its subtree watched
        /// before the next reconcile walks it. Built on the main thread before the
        /// loop thread spawns; grown only under `read_lock` afterward.
        wd_paths: std.AutoHashMapUnmanaged(i32, []u8) = .empty,
        /// Serializes consumption of the event queue (and the watch-set growth a
        /// new directory triggers) between the loop thread and a `flushSync`
        /// barrier, so a batch is never split between two consumers — the barrier
        /// must not return "drained" while the loop still holds unnoted events. The
        /// shared `Latch` — not an `Io.Mutex` — because the raw watcher OS thread
        /// has no `std.Io` handle (same reason `dirty.zig` latches); both critical
        /// sections are a bounded non-blocking drain, and the loop's idle `poll`
        /// sits outside it, so contention is brief and rare.
        read_lock: Latch = .{},
        /// macOS: the kqueue descriptor. -1 until the whole watch set registers.
        kq_fd: i32 = -1,
        /// macOS: one entry per watched vnode, addressed by the `udata` its events
        /// carry. Retired slots (a vanished file's) are recycled via `free_slots`,
        /// so an index stays stable for the life of its watch. Built on the calling
        /// thread before the loop spawns; grown only under `read_lock` after.
        watches: std.ArrayListUnmanaged(Watch) = .empty,
        /// macOS: path → `watches` index, so a directory re-scan can tell an
        /// already-watched entry from a newly-appeared one. Keys borrow the
        /// corresponding `Watch.path`.
        watch_index: std.StringHashMapUnmanaged(u32) = .empty,
        /// macOS: `watches` slots whose vnode is gone, free for reuse.
        free_slots: std.ArrayListUnmanaged(u32) = .empty,
        /// macOS: the descriptor ceiling this session may spend on watches,
        /// resolved once at start (see `watchBudget`).
        budget: usize = 0,
        /// macOS: the walk's own admission policy, so the watch set is the set
        /// the corpus admits rather than the whole tree. Linux pays one inotify
        /// watch per DIRECTORY and gets its entries named for free, so it can
        /// afford to watch everything; macOS pays one DESCRIPTOR per watched
        /// file, where the difference is 8× on this repo (25k admitted files
        /// against 193k when gitignored output is kept) — enough for a single
        /// daemon to hold 40% of the system-wide file table. Rules and their
        /// arena are rebuilt wholesale whenever an ignore source changes.
        ig: ?ignore.Ignore = null,
        ig_arena: ?*std.heap.ArenaAllocator = null,
        /// macOS: an ignore source changed during this drain, so the policy and
        /// the watch set it selected are both stale. Refreshed once at the end
        /// of the drain rather than mid-iteration (the refresh grows the very
        /// set the drain is walking).
        ig_stale: bool = false,
        /// Windows: the I/O completion port every root's notify request lands
        /// on — this backend's `inotify_fd`, and the reason its `flushSync` is a
        /// real barrier rather than a poll of somebody else's thread
        /// (`notify.zig`'s module note).
        notify_port: portal.Handle = portal.invalid_handle,
        /// Windows: one recursive subscription per root. Allocated once at arm
        /// time and never grown, because the kernel holds a pointer into each
        /// entry's status block and buffer for as long as its request is live.
        notify_roots: []notify.Root = &.{},
        /// Windows: how the loop is retired without waiting out its idle
        /// interval. Set by `stop`, never cleared while a loop is running.
        notify_stop: portal.Handle = portal.invalid_handle,
        /// Windows: false once a volume has refused the extended record class,
        /// which is also what keeps the drain's parser in step with the layout
        /// the kernel is actually writing.
        notify_extended: bool = true,

        /// Does this session carry the annals ledger (the never-drained changed-path
        /// map a one-shot `gist index` queries)? Comptime-gated so the watcher stays
        /// generic over sessions that don't (relate's retrieval session).
        pub const has_annals = @hasField(Session, "annals");

        pub fn init(gpa: std.mem.Allocator, io: std.Io, session: *Session) @This() {
            return .{ .session = session, .io = io, .gpa = gpa };
        }

        /// An event arrived that resolves to no path at all — a kqueue
        /// `EV_ERROR` or a `udata` that indexes nothing, an inotify record whose
        /// watch descriptor is already gone, a join that would not allocate.
        /// Coverage is intact, so this is DOUBT, not blindness; both of the
        /// session's readers must degrade for it, and they degrade differently:
        ///
        ///   - the dirty log loses its exactness for one drain, so that
        ///     reconcile takes the full walk and the QUERY stays correct;
        ///   - the annals lose the WHICH for good (no walk exists there to
        ///     re-derive a lost path) and keep counting the WHETHER, so an
        ///     answer already HELD retires on this event instead of surviving
        ///     it. Reconciling never protected a held answer — that one is
        ///     trusted purely on the epoch standing still, and an unplaceable
        ///     delivery is still an observed change.
        ///
        /// It lives on the facade because it is a cross-backend invariant, not a
        /// backend detail: if the two spell an unplaceable delivery differently
        /// they stop describing one corpus surface.
        pub fn noteUnattributable(self: *@This()) void {
            self.session.dirty_log.noteDoubt();
            if (comptime has_annals) self.session.annals.noteDoubt();
        }

        /// Establish the backend's causal freshness barrier: drain every event the
        /// kernel has already queued, so anything that happened-before this call is
        /// noted by the time it returns. Sound on both backends because each posts
        /// its event inside the syscall that caused it — once a writer's
        /// `write`/`close`/`rename` has returned, the event is already here
        /// (ADR-372). False on an unarmed session, which reconciles every query
        /// anyway.
        pub fn flushSync(self: *@This()) bool {
            if (comptime is_macos) return self.flushKqueue();
            if (comptime builtin.os.tag == .linux) return self.flushInotify();
            if (comptime is_windows) return self.flushNotify();
            return false;
        }

        /// Windows barrier: take every completion packet the port already holds,
        /// under `read_lock` (serialized against the loop thread, which consumes
        /// from the same port under the same lock — the single-consumer discipline
        /// that makes this a witness rather than a guess).
        fn flushNotify(self: *@This()) bool {
            if (comptime !is_windows) return false;
            if (self.notify_port == portal.invalid_handle) return false;
            self.read_lock.lock();
            defer self.read_lock.unlock();
            notify.drainNotifyLocked(self);
            return true;
        }

        /// macOS barrier: drain the kqueue to empty under `read_lock` (serialized
        /// against the loop thread, which consumes from the same queue).
        fn flushKqueue(self: *@This()) bool {
            if (comptime !is_macos) return false;
            if (self.kq_fd < 0) return false;
            self.read_lock.lock();
            defer self.read_lock.unlock();
            kqueue.drainKqueueLocked(self);
            return true;
        }

        /// Linux barrier: drain every inotify record currently queued under
        /// `read_lock` (serialized against the loop thread's own drain so the fd
        /// and `wd_paths` stay single-consumer).
        fn flushInotify(self: *@This()) bool {
            if (comptime builtin.os.tag != .linux) return false;
            if (self.inotify_fd < 0) return false;
            self.read_lock.lock();
            defer self.read_lock.unlock();
            inotify.drainInotifyLocked(self);
            return true;
        }

        /// Best-effort start. Arms the session (enabling the clean fast path) only
        /// when a watcher backend fully registers; otherwise leaves the session in
        /// the reconcile-always baseline and returns without error. Also the
        /// re-arm entry point after a `shed`: the backends register from an empty
        /// set, and `disarmWatcher` already spent the covering full pass, so the
        /// first reconcile under the new stream is a full walk exactly as at boot.
        pub fn start(self: *@This()) void {
            if (comptime builtin.os.tag == .linux) {
                inotify.startInotify(self);
            } else if (comptime is_macos) {
                kqueue.startKqueue(self);
            } else if (comptime is_windows) {
                notify.startNotify(self);
            }
            // Other targets: no watcher → reconcile-always baseline (already the
            // session's default; nothing to arm).
        }

        /// Descriptors this watcher is holding right now: the live vnode set plus
        /// the queue itself on macOS, a single `inotify` fd on Linux however large
        /// the tree, zero when nothing armed or after `shed`. It is the price the
        /// rest of the machine pays for this session, which is why the daemon's
        /// idle policy reads it rather than guessing from the corpus size.
        pub fn held(self: *const @This()) usize {
            if (comptime is_macos) {
                if (self.kq_fd < 0) return 0;
                return self.watches.items.len - self.free_slots.items.len + 1;
            }
            // Windows pays one handle per ROOT however deep the tree — a recursive
            // subscription, not a per-vnode registration — plus the port and the
            // stop event. So it reads like Linux's single fd rather than macOS's
            // per-vnode set, and the idle policy's shed is about the port, not a
            // commons anyone else is competing for.
            if (comptime is_windows) {
                if (self.notify_port == portal.invalid_handle) return 0;
                return self.notify_roots.len + 2;
            }
            return if (self.inotify_fd >= 0) 1 else 0;
        }

        /// Hand the whole watch set back while nobody is querying. The session is
        /// disarmed FIRST, so no answer can trust a quiescence that is about to
        /// stop being proven; then the loop thread is retired and every descriptor
        /// closed. The session falls back to the reconcile-always baseline — the
        /// pre-ADR-372 behavior, slower but never stale — and `start` re-registers
        /// from scratch. Caller must guarantee no query is in flight: `serve.zig`
        /// sheds only with zero connections, the same quiescent window the initial
        /// arm ran in.
        pub fn shed(self: *@This()) void {
            if (self.held() == 0) return;
            self.session.disarmWatcher();
            self.stop();
        }

        pub fn stop(self: *@This()) void {
            self.running.store(false, .release);
            if (comptime builtin.os.tag == .linux) {
                if (self.inotify_fd >= 0) {
                    _ = linux.close(self.inotify_fd);
                    self.inotify_fd = -1;
                }
            }
            // The macOS loop waits in a `poll` with a timeout, so clearing
            // `running` is enough to retire it — no cross-thread wake needed.
            // Windows idles on an event it can be woken through, so it retires at
            // once instead of after the interval.
            if (comptime is_windows) notify.signalStop(self);
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            // The loop thread is joined — no consumer remains for the watch set.
            if (comptime is_macos) kqueue.closeWatches(self);
            if (comptime is_windows) notify.closeNotify(self);
            inotify.freeWdPaths(self);
            self.wd_paths.deinit(self.gpa);
            self.wd_paths = .empty;
        }

        /// The roots the watcher must cover: the session's roots, or the CWD walk
        /// (`.`) when the session is rootless — the same tree its corpus reads. A
        /// rootless daemon that watched nothing could never prove quiescence.
        pub fn watchRoots(self: *const @This()) []const []const u8 {
            return if (self.session.roots.len != 0) self.session.roots else &[_][]const u8{"."};
        }
    };
}
