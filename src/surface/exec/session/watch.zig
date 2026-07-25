// MONOLITHIC: freshness watcher — the inotify (Linux) and kqueue (macOS) backends plus the reconcile-always baseline are one dirty/clean/doubt/poison accelerator FSM feeding the exact dirty log; per-OS split fragments the arm-exactness / coverage-poison invariants (never a correctness dependency).
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
//! Backends: Linux `inotify` and macOS `kqueue` (`EVFILT_VNODE`). Both post
//! their event inside the syscall that caused it, which is what makes
//! drain-to-empty (`flushSync`) a genuine happens-before witness and lets each
//! arm `DirtyLog.exact` — the promise that unlocks the O(changed) scoped
//! reconcile. Every other target keeps the reconcile-always baseline. A rootless
//! session watches `.` — the same CWD tree its corpus walks.
//!
//! Both backends `note` every changed path into the session's `DirtyLog`, so
//! reconcile verifies only changed paths — O(changed) instead of O(tree). An
//! unattributable event becomes `noteDoubt`, forcing one full walk; coverage
//! that cannot be re-established calls `markDoubtForever`, retiring the fast
//! path for the session's life (fail-closed). Notes are keyed to absolute
//! realpaths, the canonical shape `delta.resolve` expects.
//!
//! The two differ in what they must refuse, because their event KEY SPACES
//! differ. inotify reports a parent watch descriptor plus a kernel-supplied
//! name, so a casefolded root (ext4/f2fs `+F`) would alias distinct
//! byte-spellings the exact key model cannot represent — such a session stays
//! coarse. kqueue reports a DESCRIPTOR this process opened itself, with the
//! walk's own canonical spelling, so a writer's choice of spelling never enters
//! the key space and exact arms even on a case-insensitive volume (ADR-372).
//! inotify must also watch for a queue overflow and for directories created
//! after arming, since its watches neither recurse nor coalesce; kqueue has no
//! queue to overflow (events fold into a knote's `fflags`) but must still extend
//! coverage into new entries, and must hold one descriptor per watched vnode.
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
//! And because a watch set only earns its keep while somebody is querying, it
//! is RELEASABLE: `shed` hands every descriptor back and returns the session to
//! the reconcile-always baseline, `start` re-registers it. That is what lets an
//! idle daemon stop taxing the commons its siblings share (`serve.zig`'s
//! two-stage idle policy) without ever risking a stale answer.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../../../corpus/tree/haystack.zig");
const ignore = @import("../../../corpus/tree/ignore.zig");
const Dir = std.Io.Dir;

const is_macos = builtin.os.tag == .macos;
const linux = std.os.linux;

/// The inotify event mask shared by root registration and the loop's on-the-fly
/// re-registration of directories created after arming.
const in_mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB |
    linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR;

/// `FS_IOC_GETFLAGS` (`_IOR('f', 1, long)`) + `FS_CASEFOLD_FL` from
/// `<linux/fs.h>`: read a directory's inode flags to detect a casefolded
/// (case-INsensitive) directory, which the byte-exact Linux key model can't
/// represent — such a root never arms exact (stays reconcile-always).
const FS_IOC_GETFLAGS: u32 = 0x8008_6601;
const FS_CASEFOLD_FL: c_long = 0x4000_0000;

// ── macOS kqueue backend ──
//
// Raw syscalls, no frameworks: the watcher costs the cold one-shot search
// nothing, where the FSEvents stream this replaced needed CoreServices +
// CoreFoundation (whose image initializers ran on every process launch, which is
// why they were `dlopen`'d rather than linked).
//
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
const vnode_notes: u32 = NOTE.DELETE | NOTE.WRITE | NOTE.EXTEND |
    NOTE.ATTRIB | NOTE.LINK | NOTE.RENAME | NOTE.REVOKE;

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

/// One registered vnode watch. `path` is the absolute path to `note` when the
/// descriptor fires; `is_dir` marks the events that mean "membership changed
/// here" rather than "these bytes changed". `key` is that directory's path in
/// the walk's own key space (empty for a file, which is never re-scanned), the
/// spelling the ignore policy judges entries by. Slots are addressed by the
/// `udata` each event carries, so an event resolves to its path without a hash
/// lookup.
const Watch = struct { fd: i32, path: []const u8, key: []const u8, is_dir: bool };

/// The per-directory files that DEFINE what the walk admits. They are hidden,
/// so the visibility rule would drop them from the watch set — but an edit to
/// one changes the admitted set without touching a single admitted file, and
/// `delta.classify` already calls such a path `.semantics` (full walk). They
/// are therefore the one hidden shape macOS watches, and a change to one
/// re-derives the policy AND the watch set (`Watcher.refreshCoverage`).
/// Why a tree is being covered — three questions a first registration and a
/// live extension answer differently: is a newly-watched path ANNOUNCED, may an
/// already-watched directory be trusted to report itself, and is a listing that
/// fails midway a coverage failure?
const Cover = enum {
    /// Boot. Nothing has changed, nothing is covered yet, and a directory that
    /// cannot be read contributes nothing to the corpus either.
    initial,
    /// A watched directory's membership moved. Announce the newcomers, and
    /// descend only into directories NOT already watched — an existing watch
    /// reports its own membership, which is the whole point of one descriptor
    /// per vnode, and re-walking its subtree would make every root-level event
    /// cost a full tree walk inside the drain.
    extend,
    /// An ignore source changed. The rules that SELECTED the set are different,
    /// so every directory is revisited however well-watched it already is.
    refresh,
};

fn isIgnoreSource(name: []const u8) bool {
    return std.mem.eql(u8, name, ".gitignore") or
        std.mem.eql(u8, name, ".ignore") or
        std.mem.eql(u8, name, ".rgignore");
}

test "ignore sources: exactly the three per-directory rule files" {
    const t = std.testing;
    try t.expect(isIgnoreSource(".gitignore"));
    try t.expect(isIgnoreSource(".ignore"));
    try t.expect(isIgnoreSource(".rgignore"));
    try t.expect(!isIgnoreSource("gitignore.md"));
    try t.expect(!isIgnoreSource(".gitignore.bak"));
    try t.expect(!isIgnoreSource(".gitattributes"));
}

/// Wall-clock nanoseconds off the raw libc clock — the watcher's OS thread has
/// no `std.Io` handle, and the annals compare against `base.ns` instants minted
/// from the SAME realtime clock. Null on failure (callers degrade to
/// doubt/uncovered, never to a guessed instant).
fn wallNowNs() ?i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

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
fn watchBudget() usize {
    var rl = std.posix.getrlimit(.NOFILE) catch return 0;
    if (rl.cur < rl.max) {
        rl.cur = rl.max;
        std.posix.setrlimit(.NOFILE, rl) catch {};
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
        /// must not return "drained" while the loop still holds unnoted events. An
        /// atomic spinlock — not an `Io.Mutex` — because the raw watcher OS thread
        /// has no `std.Io` handle (same reason `dirty.zig` spins); both critical
        /// sections are a bounded non-blocking drain, and the loop's idle `poll`
        /// sits outside it, so contention is brief and rare.
        read_lock: std.atomic.Value(bool) = .init(false),
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

        /// Does this session carry the annals ledger (the never-drained changed-path
        /// map a one-shot `gist index` queries)? Comptime-gated so the watcher stays
        /// generic over sessions that don't (relate's retrieval session).
        const has_annals = @hasField(Session, "annals");

        pub fn init(gpa: std.mem.Allocator, io: std.Io, session: *Session) @This() {
            return .{ .session = session, .io = io, .gpa = gpa };
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
            return false;
        }

        /// macOS barrier: drain the kqueue to empty under `read_lock` (serialized
        /// against the loop thread, which consumes from the same queue).
        fn flushKqueue(self: *@This()) bool {
            if (comptime !is_macos) return false;
            if (self.kq_fd < 0) return false;
            self.readLock();
            defer self.readUnlock();
            self.drainKqueueLocked();
            return true;
        }

        /// Linux barrier: drain every inotify record currently queued under
        /// `read_lock` (serialized against the loop thread's own drain so the fd
        /// and `wd_paths` stay single-consumer).
        fn flushInotify(self: *@This()) bool {
            if (comptime builtin.os.tag != .linux) return false;
            if (self.inotify_fd < 0) return false;
            self.readLock();
            defer self.readUnlock();
            self.drainInotifyLocked();
            return true;
        }

        /// Acquire/release the event-consumption spinlock (see `read_lock`).
        fn readLock(self: *@This()) void {
            while (self.read_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn readUnlock(self: *@This()) void {
            self.read_lock.store(false, .release);
        }

        /// Best-effort start. Arms the session (enabling the clean fast path) only
        /// when a watcher backend fully registers; otherwise leaves the session in
        /// the reconcile-always baseline and returns without error. Also the
        /// re-arm entry point after a `shed`: the backends register from an empty
        /// set, and `disarmWatcher` already spent the covering full pass, so the
        /// first reconcile under the new stream is a full walk exactly as at boot.
        pub fn start(self: *@This()) void {
            if (comptime builtin.os.tag == .linux) {
                self.startInotify();
            } else if (comptime is_macos) {
                self.startKqueue();
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
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            // The loop thread is joined — no consumer remains for the watch set.
            if (comptime is_macos) self.closeWatches();
            self.freeWdPaths();
            self.wd_paths.deinit(self.gpa);
            self.wd_paths = .empty;
        }

        /// The roots the watcher must cover: the session's roots, or the CWD walk
        /// (`.`) when the session is rootless — the same tree its corpus reads. A
        /// rootless daemon that watched nothing could never prove quiescence.
        fn watchRoots(self: *const @This()) []const []const u8 {
            return if (self.session.roots.len != 0) self.session.roots else &[_][]const u8{"."};
        }

        fn startInotify(self: *@This()) void {
            if (comptime builtin.os.tag != .linux) return;
            const fd: i32 = @intCast(linux.inotify_init1(linux.IN.NONBLOCK));
            if (fd < 0) return; // no inotify → stay in baseline

            // Recursively watch every directory under the roots, keyed ABSOLUTE
            // (realpath'd) so noted paths match the canonical shape
            // `delta.resolve` expects. If ANY watch fails to register we cannot
            // prove quiescence for that subtree, so we bail out unarmed
            // (fail-closed): the session keeps reconciling. `exact` arms only
            // when every root is case-sensitive (`rootsCaseSensitive`).
            var exact = true;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            for (self.watchRoots()) |root| {
                const rootz = std.posix.toPosixPath(root) catch return self.closeUnarmed(fd);
                const resolved = std.c.realpath(&rootz, &buf) orelse return self.closeUnarmed(fd);
                const abs = std.mem.span(resolved);
                if (self.casefolded(abs)) exact = false;
                if (!self.addWatchesRecursive(fd, abs)) return self.closeUnarmed(fd);
            }

            self.inotify_fd = fd;
            self.running.store(true, .release);
            // Promise exactness BEFORE arming the watcher, so the very first
            // event the loop notes is already covered by the exact contract.
            if (exact) self.session.dirty_log.armExact();
            self.session.armWatcher();
            self.thread = std.Thread.spawn(.{}, inotifyLoop, .{self}) catch {
                self.running.store(false, .release);
                self.inotify_fd = -1;
                return self.closeUnarmed(fd); // spawn failed — unarm by leaving watcher inactive
            };
        }

        /// Is directory `path` casefolded (case-INsensitive)? A confirmed
        /// `FS_CASEFOLD_FL` bit blocks exact mode; every other outcome — no bit,
        /// or an `ioctl` the filesystem doesn't implement (`ENOTTY`, the common
        /// case on non-casefold volumes) — means case-sensitive, so exact arms.
        fn casefolded(self: *@This(), path: []const u8) bool {
            if (comptime builtin.os.tag != .linux) return false;
            var dir = Dir.cwd().openDir(self.io, path, .{}) catch return false;
            defer dir.close(self.io);
            var flags: c_long = 0;
            const rc = linux.ioctl(dir.handle, FS_IOC_GETFLAGS, @intFromPtr(&flags));
            if (linux.errno(rc) != .SUCCESS) return false;
            return flags & FS_CASEFOLD_FL != 0;
        }

        /// Shared inotify bail-out: release the fd and every recorded watch path.
        fn closeUnarmed(self: *@This(), fd: i32) void {
            if (comptime builtin.os.tag != .linux) return;
            _ = linux.close(fd);
            self.freeWdPaths();
        }

        fn freeWdPaths(self: *@This()) void {
            var it = self.wd_paths.valueIterator();
            while (it.next()) |p| self.gpa.free(p.*);
            self.wd_paths.clearRetainingCapacity();
        }

        /// Register a watch on `path` and every non-skipped subdirectory, recording
        /// wd → path so the event loop can extend coverage into directories created
        /// later. Returns false on the first failure (caller bails unarmed, or —
        /// post-arm — poisons the session).
        fn addWatchesRecursive(self: *@This(), fd: i32, path: []const u8) bool {
            if (comptime builtin.os.tag != .linux) return false;
            const cpath = std.posix.toPosixPath(path) catch return false;
            const wd = linux.inotify_add_watch(fd, &cpath, in_mask);
            if (@as(isize, @bitCast(wd)) < 0) return false;
            const owned = self.gpa.dupe(u8, path) catch return false;
            const slot = self.wd_paths.getOrPut(self.gpa, @intCast(wd)) catch {
                self.gpa.free(owned);
                return false;
            };
            // A re-registered wd (same dir watched again) replaces its path.
            if (slot.found_existing) self.gpa.free(slot.value_ptr.*);
            slot.value_ptr.* = owned;

            var dir = Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return true;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |e| {
                if (e.kind != .directory) continue;
                if (haystack.isSkipDir(e.name)) continue;
                const child = haystack.joinPath(self.gpa, path, e.name) catch return false;
                defer self.gpa.free(child);
                if (!self.addWatchesRecursive(fd, child)) return false;
            }
            return true;
        }

        fn inotifyLoop(self: *@This()) void {
            if (comptime builtin.os.tag != .linux) return;
            var pfd = [_]std.posix.pollfd{.{ .fd = self.inotify_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            while (self.running.load(.acquire)) {
                const ready = std.posix.poll(&pfd, 500) catch break;
                if (ready == 0) continue;
                // Drain under `read_lock` so this loop and a concurrent
                // `flushInotify` barrier never both consume the single-reader fd —
                // nor both grow `wd_paths` via `coverNewDir` — at once. The `poll`
                // above sits OUTSIDE the lock, so the barrier contends only for the
                // brief drain, not the loop's idle wait.
                self.readLock();
                self.drainInotifyLocked();
                self.readUnlock();
            }
        }

        /// Read and process every inotify record currently queued (until the fd
        /// would block), noting each changed path and extending coverage into
        /// directories created after arming. Caller MUST hold `read_lock`. Every
        /// `note` precedes the single trailing `markDirty` — the dirty-log/seqlock
        /// ordering contract a scoped reconcile relies on. Linux only.
        fn drainInotifyLocked(self: *@This()) void {
            if (comptime builtin.os.tag != .linux) return;
            var buf: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
            var noted = false;
            while (true) {
                const n = std.posix.read(self.inotify_fd, &buf) catch break; // WouldBlock/err → drained
                if (n == 0) break;
                self.processRecords(buf[0..n]);
                noted = true;
            }
            if (noted) self.session.markDirty();
        }

        /// Walk one inotify read buffer's variable-length records, applying the two
        /// fail-closed conditions that would silently break the clean fast path — a
        /// queue overflow (events were LOST — quiescence can never be proven again
        /// on this fd) and a directory created/moved in after arming (inotify does
        /// not recurse; an unwatched subtree is a blind spot) — and noting the
        /// EXACT changed path of every other record. Caller holds `read_lock`.
        fn processRecords(self: *@This(), buf: []const u8) void {
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= buf.len) {
                // Cast-free record view (zig-safety): the fixed header is copied
                // out by value — 16 bytes on a cold path — instead of
                // reinterpreting the buffer pointer.
                const ev = std.mem.bytesToValue(linux.inotify_event, buf[off..][0..@sizeOf(linux.inotify_event)]);
                off += @sizeOf(linux.inotify_event) + ev.len;
                if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
                    self.session.markDoubtForever();
                    continue;
                }
                // An unmapped wd or malformed record can't be attributed, so
                // `noteEvent` declines to doubt (full walk); coverage extension
                // that cannot resolve poisons the session (fail-closed).
                self.noteEvent(&ev, buf, off);
                const grew_dir = ev.mask & linux.IN.ISDIR != 0 and
                    ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
                if (grew_dir) self.coverNewDir(&ev, buf, off);
            }
        }

        /// Extend watch coverage into a directory created/moved in after arming;
        /// any step that cannot be resolved poisons the session (fail-closed).
        fn coverNewDir(self: *@This(), ev: *const linux.inotify_event, buf: []const u8, rec_end: usize) void {
            const name = nameOf(ev, buf, rec_end) orelse return self.session.markDoubtForever();
            if (haystack.isSkipDir(name)) return;
            const parent = self.wd_paths.get(ev.wd) orelse return self.session.markDoubtForever();
            const child = haystack.joinPath(self.gpa, parent, name) catch return self.session.markDoubtForever();
            defer self.gpa.free(child);
            // Racing creations inside the new dir before its watch lands
            // are covered: the recursive registration below re-lists the
            // subtree AFTER each watch is added, and markDirty forces
            // the next query's reconcile to walk it regardless.
            if (!self.addWatchesRecursive(self.inotify_fd, child))
                self.session.markDoubtForever();
        }

        /// Note the exact path an inotify record attributes to, into the session's
        /// `DirtyLog`. A record with a name (`ev.len > 0`) is an entry inside the
        /// wd's directory (`parent/name`); a nameless record (`ev.len == 0`) is the
        /// watched directory itself. Either resolves to an absolute path (the wds
        /// were realpath'd at arm time). An unmapped wd (evicted/racing) or a
        /// malformed name field can't be attributed → `noteDoubt` (that drain
        /// takes the full walk).
        fn noteEvent(self: *@This(), ev: *const linux.inotify_event, buf: []const u8, rec_end: usize) void {
            const parent = self.wd_paths.get(ev.wd) orelse return self.session.dirty_log.noteDoubt();
            if (ev.len == 0) return self.session.dirty_log.note(parent);
            const name = nameOf(ev, buf, rec_end) orelse return self.session.dirty_log.noteDoubt();
            const child = haystack.joinPath(self.gpa, parent, name) catch return self.session.dirty_log.noteDoubt();
            defer self.gpa.free(child);
            self.session.dirty_log.note(child);
        }

        /// The NUL-terminated name trailing a variable-length inotify record, or
        /// null when the record is malformed (caller treats that as doubt).
        fn nameOf(ev: *const linux.inotify_event, buf: []const u8, rec_end: usize) ?[]const u8 {
            if (ev.len == 0 or rec_end > buf.len) return null;
            const raw = buf[rec_end - ev.len .. rec_end];
            const z = std.mem.indexOfScalar(u8, raw, 0) orelse return null;
            return if (z == 0) null else raw[0..z];
        }

        // ── macOS kqueue backend ──

        /// Register the whole watch set, then arm. Runs on the calling thread
        /// (daemon boot) and takes ~300 ms for 22k descriptors — it does not need
        /// to be instantaneous, because arming is not the same as claiming clean:
        /// `Seqlock.arm` only marks a watcher live, `clean` is published solely by
        /// a COMPLETED reconcile that no event raced, and `full_pass_done` forces
        /// the first pass after arming to be the full walk. So a change that races
        /// registration is caught by that walk (ADR-372).
        fn startKqueue(self: *@This()) void {
            if (comptime !is_macos) return;
            self.budget = watchBudget();
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
            if (!self.loadPolicy()) return self.closeWatches();
            if (!self.coverRoots(.initial)) return self.closeWatches();

            self.running.store(true, .release);
            self.thread = std.Thread.spawn(.{}, kqueueLoop, .{self}) catch {
                self.running.store(false, .release);
                return self.closeWatches();
            };
            // Annals coverage opens only now: an event that predated its own watch
            // was never observable, so the ledger must not claim the window
            // registration spanned (conservative by construction — uncovered, never
            // wrong). Then promise exactness, and arm LAST, so nothing can trust
            // quiescence before a consumer exists to prove it.
            if (comptime has_annals) if (wallNowNs()) |ns| self.session.annals.openCoverage(ns);
            self.session.dirty_log.armExact();
            self.session.armWatcher();
        }

        /// Build the admission policy the watch set is selected by — the same
        /// `Ignore` the corpus walk and `delta` use, over the same roots — into a
        /// fresh arena. False only when the arena itself cannot be created; the
        /// rules are then the walk's, not a private approximation of them.
        fn loadPolicy(self: *@This()) bool {
            if (comptime !is_macos) return false;
            self.dropPolicy();
            const arena = self.gpa.create(std.heap.ArenaAllocator) catch return false;
            arena.* = .init(self.gpa);
            self.ig_arena = arena;
            self.ig = ignore.Ignore.init(arena.allocator(), self.io, .{}, self.session.roots);
            return true;
        }

        fn dropPolicy(self: *@This()) void {
            if (comptime !is_macos) return;
            self.ig = null;
            if (self.ig_arena) |arena| {
                arena.deinit();
                self.gpa.destroy(arena);
                self.ig_arena = null;
            }
        }

        /// Cover every watched root from its realpath, in the walk's key space.
        /// Called at start, and again whenever an ignore source rewrites the
        /// policy — `addWatch` is idempotent, so a refresh adds exactly the
        /// entries the new rules admit and leaves the rest untouched.
        fn coverRoots(self: *@This(), comptime mode: Cover) bool {
            if (comptime !is_macos) return false;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const roots = self.watchRoots();
            for (roots) |root| {
                const rootz = std.posix.toPosixPath(root) catch return false;
                const resolved = std.c.realpath(&rootz, &buf) orelse return false;
                const abs = std.mem.span(resolved);
                // Annals deliveries are keyed absolute; arm the strip prefix before
                // any event can be noted. Only a single-root watch is
                // annals-addressable (one unambiguous prefix); a multi-root session
                // simply leaves the ledger unarmed (it declines).
                if (comptime has_annals) if (roots.len == 1) self.session.annals.arm(abs);
                // The key space is the corpus's: "" for the implicit CWD walk, the
                // root's own spelling otherwise — the shape ignore rules are
                // written against, and `scopeToRoot` exempts a named root from
                // rules that govern only its descendants.
                const key = if (std.mem.eql(u8, root, ".")) "" else root;
                if (self.ig) |*ig| ig.scopeToRoot(key);
                if (!self.coverTree(abs, key, mode)) return false;
            }
            return true;
        }

        /// Register `dir`, then recurse into exactly what the certified walk would
        /// descend and search: subdirectories it enters, files it admits, plus the
        /// hidden ignore SOURCES that decide both (`isIgnoreSource`). Matching the
        /// walk is what keeps the descriptor cost proportional to the corpus, and
        /// `delta` still makes the final admission call at reconcile time. False on
        /// the first genuine failure or budget exhaustion.
        ///
        /// `mode` says which caller this is (see `Cover`). Live extension announces
        /// every path that was not already watched, because such a path just
        /// APPEARED and this is the only place it can be named — a directory's
        /// event says its membership moved but not which entry, and a per-file
        /// reader (the annals) needs the entry. A listing that fails midway may
        /// have hidden exactly that newcomer, so live extension fails closed on it
        /// where boot shrugs.
        fn coverTree(self: *@This(), dir: []const u8, key: []const u8, comptime mode: Cover) bool {
            if (comptime !is_macos) return false;
            if (!self.addWatch(dir, key, true, mode)) return false;
            // An unreadable directory is not a watch failure: the reconcile walk
            // reports it and declines on its own terms (`fs.walk_error`).
            var d = Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return true;
            defer d.close(self.io);
            // This directory's own ignore files, in walk order: after its parent's
            // rules, before its entries are judged by them.
            if (self.ig) |*ig| ig.loadDir(if (key.len == 0) "." else key, key);
            var it = d.iterate();
            while (true) {
                const next = it.next(self.io) catch if (comptime mode == .initial) break else return false;
                const e = next orelse break;
                if (e.name.len == 0) continue;
                const child = haystack.joinPath(self.gpa, dir, e.name) catch return false;
                defer self.gpa.free(child);
                const child_key = self.joinKey(key, e.name) catch return false;
                defer self.gpa.free(child_key);
                const covered = switch (e.kind) {
                    .directory => !self.descends(e.name, child_key) or
                        (mode == .extend and self.watch_index.contains(child)) or
                        self.coverTree(child, child_key, mode),
                    .file => !self.admits(e.name, child_key) or
                        self.addWatch(child, "", false, mode),
                    else => true, // symlinks/specials: the default walk never reads them
                };
                if (!covered) return false;
            }
            return true;
        }

        /// `key/name`, with the implicit CWD walk's empty key contributing no
        /// separator — the corpus's own spelling for a path (`haystack.joinRoot`).
        fn joinKey(self: *const @This(), key: []const u8, name: []const u8) ![]const u8 {
            return if (key.len == 0) self.gpa.dupe(u8, name) else haystack.joinPath(self.gpa, key, name);
        }

        /// Would the walk descend into this subdirectory? Hidden and skip-policy
        /// directories are out of the walked set and can only enter it by a rename
        /// their parent reports; the rest answer to the same ignore rules.
        fn descends(self: *const @This(), name: []const u8, key: []const u8) bool {
            if (name[0] == '.' or haystack.isSkipDir(name)) return false;
            const ig = if (self.ig) |*p| p else return true;
            return !ig.shouldSkip(key, true, name, false, false);
        }

        /// Would the walk search this file — or does it DECIDE what the walk
        /// searches? An ignore source is watched though hidden (see
        /// `isIgnoreSource`); everything else hidden or ignored stays out.
        fn admits(self: *const @This(), name: []const u8, key: []const u8) bool {
            if (isIgnoreSource(name)) return true;
            if (name[0] == '.') return false;
            const ig = if (self.ig) |*p| p else return true;
            return !ig.shouldSkip(key, false, name, false, false);
        }

        /// Open an `O_EVTONLY` descriptor on `path` and register its vnode filter,
        /// recording the slot its events will address. Idempotent per path (a
        /// directory re-scan re-offers entries already watched). A path that
        /// vanished between listing and open is skipped rather than failed — there
        /// is nothing left to watch, and its parent reports any return. False only
        /// when the budget is spent or a registration genuinely fails. Every mode
        /// but `.initial` notes a genuinely-new watch as a changed path (see
        /// `coverTree`).
        fn addWatch(self: *@This(), path: []const u8, key: []const u8, is_dir: bool, comptime mode: Cover) bool {
            if (comptime !is_macos) return false;
            if (self.watch_index.contains(path)) return true;
            if (self.watches.items.len - self.free_slots.items.len >= self.budget) return false;
            const pathz = std.posix.toPosixPath(path) catch return false;
            const fd = std.c.open(&pathz, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true });
            if (fd < 0) return true;
            const owned = self.gpa.dupe(u8, path) catch {
                _ = std.c.close(fd);
                return false;
            };
            const owned_key = self.gpa.dupe(u8, key) catch {
                self.gpa.free(owned);
                _ = std.c.close(fd);
                return false;
            };
            const idx: u32 = self.free_slots.pop() orelse blk: {
                self.watches.append(self.gpa, undefined) catch {
                    self.gpa.free(owned_key);
                    self.gpa.free(owned);
                    _ = std.c.close(fd);
                    return false;
                };
                break :blk @intCast(self.watches.items.len - 1);
            };
            // Publish the slot before anything that can fail, so `retire` is the one
            // cleanup path for every failure below.
            self.watches.items[idx] = .{ .fd = fd, .path = owned, .key = owned_key, .is_dir = is_dir };
            self.watch_index.put(self.gpa, owned, idx) catch {
                self.retire(idx);
                return false;
            };
            var change = [_]std.c.Kevent{.{
                .ident = @intCast(fd),
                .filter = std.c.EVFILT.VNODE,
                // EV_CLEAR: each firing is delivered once, and further notes fold
                // into the knote instead of queuing — which is why kqueue has no
                // overflow to guard (contrast inotify's `Q_OVERFLOW`).
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = vnode_notes,
                .data = 0,
                .udata = idx,
            }};
            if (std.c.kevent(self.kq_fd, &change, 1, &change, 0, null) < 0) {
                self.retire(idx);
                return false;
            }
            // Noted only once the watch is live, so a path can never be announced
            // as changed while still uncovered for its next change.
            if (comptime mode != .initial) self.note(owned, is_dir);
            return true;
        }

        /// Wait for events OUTSIDE the consumption lock — a kqueue descriptor is
        /// itself pollable — then consume the whole batch under it, so a concurrent
        /// `flushSync` can never see an empty queue while this thread still holds
        /// events it has not noted.
        fn kqueueLoop(self: *@This()) void {
            if (comptime !is_macos) return;
            var pfd = [_]std.posix.pollfd{.{ .fd = self.kq_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            while (self.running.load(.acquire)) {
                const ready = std.posix.poll(&pfd, 500) catch break;
                if (ready == 0) continue;
                self.readLock();
                self.drainKqueueLocked();
                self.readUnlock();
            }
        }

        /// Consume queued vnode events until the queue is empty. Caller MUST hold
        /// `read_lock`. Every `note` precedes the single trailing `markDirty` — the
        /// dirty-log/seqlock ordering contract a scoped reconcile relies on. A
        /// failed consume leaves events we cannot account for, so it raises doubt
        /// (that reconcile walks fully) instead of reporting a clean drain.
        fn drainKqueueLocked(self: *@This()) void {
            if (comptime !is_macos) return;
            var evs: [256]std.c.Kevent = undefined;
            const immediately = std.c.timespec{ .sec = 0, .nsec = 0 };
            var noted = false;
            while (true) {
                const n = std.c.kevent(self.kq_fd, &evs, 0, &evs, evs.len, &immediately);
                if (n == 0) break;
                if (n < 0) {
                    self.session.dirty_log.noteDoubt();
                    noted = true;
                    break;
                }
                for (evs[0..@intCast(n)]) |ev| self.applyEvent(ev);
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
                if (!self.loadPolicy() or !self.coverRoots(.refresh)) self.session.markDoubtForever();
            }
            if (noted) self.session.markDirty();
        }

        /// Apply one vnode event: note the exact path that changed, extend coverage
        /// when a directory's membership moved, and retire a watch whose vnode left.
        fn applyEvent(self: *@This(), ev: std.c.Kevent) void {
            if (comptime !is_macos) return;
            if (ev.flags & std.c.EV.ERROR != 0) return self.session.dirty_log.noteDoubt();
            const idx = std.math.cast(u32, ev.udata) orelse return self.session.dirty_log.noteDoubt();
            if (idx >= self.watches.items.len) return self.session.dirty_log.noteDoubt();
            if (self.watches.items[idx].fd < 0) return; // retired earlier in this drain
            self.note(self.watches.items[idx].path, self.watches.items[idx].is_dir);
            if (self.watches.items[idx].is_dir) self.rescanDir(idx);
            // A vanished or renamed vnode's descriptor no longer names a member of
            // the walked set, so retire it and let the paired directory event
            // register the entry under its current spelling. This is about the
            // DESCRIPTOR, not the file: a case-only rename reports RENAME and DELETE
            // together while the file still very much exists.
            if (ev.fflags & (NOTE.DELETE | NOTE.RENAME | NOTE.REVOKE) != 0) self.retire(idx);
        }

        /// Note one changed absolute path into the dirty log — and, for a FILE, the
        /// annals ledger a one-shot `gist index` consults. A directory reaches only
        /// the dirty log: its event means "membership here moved", which the
        /// reconcile answers by diffing the subtree, while the ledger's reader
        /// amends per file and would stat a directory away — and its capacity is
        /// bounded, so an entry spent on shape is an entry evicted from content. A
        /// dead clock poisons the ledger rather than guessing an instant.
        fn note(self: *@This(), path: []const u8, is_dir: bool) void {
            self.session.dirty_log.note(path);
            if (is_dir) return;
            if (isIgnoreSource(std.fs.path.basename(path))) self.ig_stale = true;
            if (comptime has_annals) {
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
        fn rescanDir(self: *@This(), idx: u32) void {
            if (comptime !is_macos) return;
            // Heap-owned and stable across the watch-set growth below — only the
            // slot array can move, never a path's bytes. `coverTree` is the one
            // place the walk's admission policy lives, so a re-scan applies
            // exactly the rules the initial registration did; its own watch is
            // already indexed, making that first `addWatch` a no-op.
            const w = self.watches.items[idx];
            if (self.ig) |*ig| ig.scopeToRoot(self.rootKeyOf(w.key));
            if (!self.coverTree(w.path, w.key, .extend)) self.session.markDoubtForever();
        }

        /// The key-space root governing `key` — "" for the implicit CWD walk, and
        /// the reason a rule written for one named root cannot judge another's
        /// entries (`Ignore.scopeToRoot`).
        fn rootKeyOf(self: *const @This(), key: []const u8) []const u8 {
            for (self.session.roots) |r| {
                if (std.mem.eql(u8, key, r)) return r;
                if (key.len > r.len and std.mem.startsWith(u8, key, r) and key[r.len] == '/') return r;
            }
            return "";
        }

        /// Retire slot `idx`: close its descriptor (which removes the kevent with
        /// it), drop its index entry, and offer the slot for reuse. The path bytes
        /// are freed last — `watch_index` borrows them as its key.
        fn retire(self: *@This(), idx: u32) void {
            if (comptime !is_macos) return;
            const w = self.watches.items[idx];
            if (w.fd < 0) return;
            _ = std.c.close(w.fd);
            _ = self.watch_index.remove(w.path);
            self.watches.items[idx] = .{ .fd = -1, .path = &.{}, .key = &.{}, .is_dir = false };
            // A slot we cannot enqueue is simply never reused — never a coverage gap.
            self.free_slots.append(self.gpa, idx) catch {};
            self.gpa.free(w.key);
            self.gpa.free(w.path);
        }

        /// Close every watch descriptor and the queue itself, freeing their
        /// bookkeeping. Idempotent: `stop` calls it after a failed start too. A
        /// partial watch set is never armed, so this doubles as the bail-out path
        /// — and, after `shed`, the reset a later `start` re-registers from.
        fn closeWatches(self: *@This()) void {
            if (comptime !is_macos) return;
            self.ig_stale = false; // a pending refresh dies with the set it was about
            for (self.watches.items) |w| if (w.fd >= 0) {
                _ = std.c.close(w.fd);
                self.gpa.free(w.key);
                self.gpa.free(w.path);
            };
            self.dropPolicy();
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
    };
}
