//! gist resident session — the freshness watcher (ADR-352 rung 2.5).
//!
//! The watcher is a pure *accelerator* for the freshness barrier, never a
//! correctness dependency. Its only job is to keep a session honest about when
//! it may skip the reconcile walk: on any filesystem event under the watched
//! roots it calls `session.markDirty()`, forcing the next query to reconcile;
//! when it has proven no event since the last reconcile the session takes the
//! microsecond fast path. If a watcher cannot be started (unsupported platform,
//! a watch that won't register, a queue that could overflow), the session is
//! simply **never armed** — `watcher_active` stays false and every query
//! reconciles the changed set against the live filesystem. Correctness rests on
//! that reconcile (`resident.zig`), so a missing or degraded watcher only costs
//! speed, never soundness (fail-closed).
//!
//! Backends: Linux `inotify` (recursive watches, arm-only-on-full-success) and
//! macOS `FSEvents` (one recursive stream over the roots, driven on a private
//! CFRunLoop thread — the OS's native subtree watcher, coalesced at the kernel);
//! every other target uses the reconcile-always baseline. A rootless session
//! (the common auto-spawned daemon) watches `.` — the same CWD tree its
//! corpus walks.
//!
//! BOTH backends request PER-FILE events and `note` every delivered path into
//! the session's `DirtyLog` (arming its `exact` promise), which is what lets the
//! reconcile verify only the changed paths — O(changed) instead of O(tree). Any
//! event a backend cannot attribute to an exact path — macOS's inexact flags
//! (`MustScanSubDirs`, kernel/user drops, id wrap, mount churn), or Linux's
//! unmapped watch descriptor / malformed record / queue overflow — becomes
//! `noteDoubt`, forcing that drain onto the full walk. Linux keys its notes to
//! absolute paths (the roots are realpath'd at arm time) so they match the
//! canonical shape `delta.resolve` expects, exactly like FSEvents' delivery.
//!
//! The Linux backend also parses its stream for the two conditions that would
//! silently BREAK the clean fast path itself: a queue overflow, and a directory
//! created/moved in after arming (inotify watches don't recurse on their own).
//! It re-registers new subtrees on the fly and, if it cannot, calls
//! `markDoubtForever` — the session then reconciles every query instead of ever
//! trusting a blind quiescence claim (fail-closed). Exact mode arms only when
//! every root is on a case-SENSITIVE directory: a casefolded root (ext4/f2fs
//! `+F`) would alias distinct byte-spellings, which the byte-exact Linux key
//! model does not represent, so such a session stays coarse (reconcile-always).

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../../../corpus/tree/haystack.zig");
const cs = @import("coreservices.zig");
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

// ── macOS FSEvents backend ──
//
// The CoreServices (FSEvents) + CoreFoundation (CFRunLoop) surface the macOS
// watcher drives is bound at RUNTIME (`dlopen`, never link-time) in `cs`
// (`coreservices.zig`) — that module owns the ABI types + symbol table and the
// fail-closed load; this file owns the event loop + drop/flood policy that use
// them. The two policy knobs below stay here, next to the loop they govern.
//
// Event flags meaning "these paths are NOT an exact account of what changed":
// subtree-rescan hints, kernel/user queue drops, id wrap, history replay
// boundary, root moves, mount churn. Any → the batch is a doubt (full walk).
const inexact_flags: u32 = 0x0000_00FF;
// Coalescing window (s): small keeps the read-your-writes stale window tight
// while still folding a build's event storm into a handful of markDirty calls.
const fsevents_latency: f64 = 0.05;

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
        /// macOS: the dlopen'd CoreFoundation/CoreServices entry points, bound by
        /// `startFsevents` before the loop thread spawns and closed by `stop`.
        /// Null on every non-macOS target and whenever the frameworks fail to
        /// load (→ unarmed, reconcile-always).
        syms: ?cs.Syms = null,
        /// Linux: watch descriptor → the directory it covers (gpa-owned), so a
        /// dir-create event can be resolved to a path and its subtree watched
        /// before the next reconcile walks it. Built on the main thread before the
        /// loop thread spawns; grown only under `read_lock` afterward.
        wd_paths: std.AutoHashMapUnmanaged(i32, []u8) = .empty,
        /// Linux: serializes reads of `inotify_fd` (and the `wd_paths` growth a
        /// dir-create drain triggers) between the loop thread and a `flushSync`
        /// barrier, keeping the single-consumer fd and the watch map race-free. An
        /// atomic spinlock — not an `Io.Mutex` — because the raw watcher OS thread
        /// has no `std.Io` handle (same reason `dirty.zig` spins); both critical
        /// sections are a bounded non-blocking drain, and the loop's idle `poll`
        /// sits outside it, so contention is brief and rare. Unused off Linux.
        read_lock: std.atomic.Value(bool) = .init(false),
        /// macOS: the watch thread's CFRunLoop, published so `stop` can wake it. Null
        /// until the loop thread stores it (before it signals `ready`).
        run_loop: std.atomic.Value(?*anyopaque) = .init(null),
        /// macOS: the live FSEvents stream ref, published by the loop thread once
        /// `FSEventStreamStart` succeeds so the serve thread can `flushSync` it —
        /// the annals query's causal barrier. Cleared by the loop thread before
        /// the stream is torn down; readers only ever run while the daemon's
        /// single serve thread is live (i.e. before `stop`).
        fs_stream: std.atomic.Value(?*anyopaque) = .init(null),
        /// macOS start handshake: 0 pending, 1 stream armed, 2 failed. The loop
        /// thread publishes it once; `startFsevents` polls it to decide whether to
        /// arm the session (kept on the main thread so the plain `watcher_active`
        /// bool the query path reads is never written concurrently).
        start_result: std.atomic.Value(u8) = .init(0),

        /// Does this session carry the annals ledger (the never-drained changed-path
        /// map a one-shot `gist index` queries)? Comptime-gated so the watcher stays
        /// generic over sessions that don't (relate's retrieval session).
        const has_annals = @hasField(Session, "annals");

        pub fn init(gpa: std.mem.Allocator, io: std.Io, session: *Session) @This() {
            return .{ .session = session, .io = io, .gpa = gpa };
        }

        /// Force synchronous delivery of every watcher event already queued — the
        /// causal barrier a freshness-sensitive query runs behind: after this
        /// returns, every change that OCCURRED before the call has been `note`d, so
        /// the reconcile that follows cannot answer over pre-edit bytes. macOS
        /// flushes the live FSEvents stream; Linux drains the inotify fd (whose
        /// events are queued synchronously inside the causing syscall, so every
        /// write that happened-before is already readable). Returns false when no
        /// backend is armed — the caller treats that as unvouched, but the unarmed
        /// session already reconciles every query, so correctness is unaffected.
        pub fn flushSync(self: *@This()) bool {
            if (comptime is_macos) {
                const s = if (self.syms) |*p| p else return false;
                const stream = self.fs_stream.load(.acquire) orelse return false;
                s.FSEventStreamFlushSync(stream);
                return true;
            }
            if (comptime builtin.os.tag == .linux) return self.flushInotify();
            return false;
        }

        /// Linux causal barrier: drain every inotify record currently queued under
        /// `read_lock` (serialized against the loop thread's own drain so the fd
        /// and `wd_paths` stay single-consumer). Sound because inotify queues an
        /// event within the syscall that produces it — once the writer's
        /// `write`/`close` has returned, its record is already readable here — so a
        /// drain-to-empty captures everything that happened-before. False when
        /// unarmed (no fd), where the session reconciles every query anyway.
        fn flushInotify(self: *@This()) bool {
            if (comptime builtin.os.tag != .linux) return false;
            if (self.inotify_fd < 0) return false;
            self.readLock();
            defer self.readUnlock();
            self.drainInotifyLocked();
            return true;
        }

        /// Acquire/release the inotify-read spinlock (see `read_lock`).
        fn readLock(self: *@This()) void {
            while (self.read_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn readUnlock(self: *@This()) void {
            self.read_lock.store(false, .release);
        }

        /// Best-effort start. Arms the session (enabling the clean fast path) only
        /// when a watcher backend fully registers; otherwise leaves the session in
        /// the reconcile-always baseline and returns without error.
        pub fn start(self: *@This()) void {
            if (comptime builtin.os.tag == .linux) {
                self.startInotify();
            } else if (comptime is_macos) {
                self.startFsevents();
            }
            // Other targets: no watcher → reconcile-always baseline (already the
            // session's default; nothing to arm).
        }

        pub fn stop(self: *@This()) void {
            self.running.store(false, .release);
            if (comptime builtin.os.tag == .linux) {
                if (self.inotify_fd >= 0) {
                    _ = linux.close(self.inotify_fd);
                    self.inotify_fd = -1;
                }
            } else if (comptime is_macos) {
                // Wake the CFRunLoop out of its wait so the loop re-checks `running`
                // and exits promptly instead of idling out its timeout slice.
                if (self.syms) |*s| if (self.run_loop.load(.acquire)) |rl| s.CFRunLoopStop(rl);
            }
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            // The loop thread is joined — no reader remains for the framework
            // handles; drop them (a no-op on non-macOS, where `syms` is null).
            if (self.syms) |*s| {
                s.close();
                self.syms = null;
            }
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

        // ── macOS FSEvents backend ──

        /// Spawn the CFRunLoop thread and arm the session iff the stream started —
        /// same fail-closed contract as inotify: an unstarted watcher leaves the
        /// session in the reconcile-always baseline (correct, just not fast). The
        /// handshake keeps `armWatcher` on THIS thread so the plain `watcher_active`
        /// bool the query path reads is never written concurrently.
        fn startFsevents(self: *@This()) void {
            if (comptime !is_macos) return;
            // Bind the frameworks on THIS thread before the loop spawns; a miss
            // (unavailable framework / symbol) leaves the session unarmed —
            // reconcile-always, still correct.
            self.syms = cs.Syms.load() orelse return;
            self.thread = std.Thread.spawn(.{}, fseventsLoop, .{self}) catch {
                if (self.syms) |*s| {
                    s.close();
                    self.syms = null;
                }
                return;
            };
            // Wait for the loop thread to publish its start result — FSEventStreamStart
            // returns in microseconds, so this bounded spin (a one-time daemon-boot
            // cost) resolves near-instantly; the 2 s deadline only guards a wedged
            // launch, after which we stay unarmed (reconcile-always, still correct).
            const deadline = std.Io.Clock.now(.real, self.io).nanoseconds + 2 * std.time.ns_per_s;
            while (self.start_result.load(.acquire) == 0 and std.Io.Clock.now(.real, self.io).nanoseconds < deadline)
                std.atomic.spinLoopHint();
            if (self.start_result.load(.acquire) == 1) {
                // Per-file events are live from stream start, so every markDirty is
                // now preceded by a note/noteDoubt: promise exactness, then arm.
                self.session.dirty_log.armExact();
                self.session.armWatcher();
            }
        }

        /// Build one recursive FSEvents stream over the roots, run its CFRunLoop
        /// until `stop`, then tear the stream down. Any setup failure publishes
        /// `start_result = 2` and returns unarmed.
        fn fseventsLoop(self: *@This()) void {
            if (comptime !is_macos) return;
            const s = &self.syms.?; // load() proved non-null before this spawned
            const paths = self.buildPathsArray() orelse return self.start_result.store(2, .release);
            defer s.CFRelease(paths);

            var ctx = cs.CFContext{ .info = @ptrCast(self.session) };
            // Annals coverage instant: captured BEFORE the stream exists. `SinceNow`
            // resolves at creation and fseventsd's journal replays anything between
            // create and start, so every event at/after this instant is delivered —
            // the floor is conservative by construction. A clock failure leaves the
            // annals uncovered (never answerable), not wrong.
            const coverage_ns: ?i128 = if (comptime has_annals) cs.wallNowNs() else null;
            const stream = s.FSEventStreamCreate(
                null,
                fseventsCallback,
                &ctx,
                paths,
                cs.kFSEventStreamEventIdSinceNow,
                fsevents_latency,
                cs.kFSEventStreamCreateFlagNoDefer | cs.kFSEventStreamCreateFlagFileEvents,
            ) orelse return self.start_result.store(2, .release);
            defer {
                self.fs_stream.store(null, .release);
                s.FSEventStreamStop(stream);
                s.FSEventStreamInvalidate(stream);
                s.FSEventStreamRelease(stream);
            }

            const rl = s.CFRunLoopGetCurrent();
            self.run_loop.store(rl, .release);
            s.FSEventStreamScheduleWithRunLoop(stream, rl, s.run_loop_default_mode);
            if (s.FSEventStreamStart(stream) == 0) return self.start_result.store(2, .release);

            self.fs_stream.store(stream, .release);
            if (comptime has_annals) if (coverage_ns) |ns| self.session.annals.openCoverage(ns);
            self.running.store(true, .release);
            self.start_result.store(1, .release);

            // Run in bounded slices so `stop` (which also calls CFRunLoopStop to
            // wake us immediately) is observed even if it raced the loop entry —
            // no unstoppable CFRunLoopRun, no CFRunLoopStop/entry ordering hazard.
            while (self.running.load(.acquire))
                _ = s.CFRunLoopRunInMode(s.run_loop_default_mode, 1.0, 0);
        }

        /// Realpath each root into a retaining CFArray of CFStrings (FSEvents wants
        /// absolute paths; the daemon's cwd is the repo root — a rootless session
        /// watches `.`, its whole CWD walk). Returns null on any allocation/CF
        /// failure so the caller stays unarmed. The array retains the strings, so
        /// we release our own references before returning it.
        fn buildPathsArray(self: *@This()) ?cs.Ref {
            if (comptime !is_macos) return null;
            const s = &self.syms.?;
            const roots = self.watchRoots();
            const refs = self.gpa.alloc(cs.Ref, roots.len) catch return null;
            defer self.gpa.free(refs);

            var made: usize = 0;
            defer for (refs[0..made]) |r| s.CFRelease(r);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            for (roots) |root| {
                const rootz = self.gpa.dupeZ(u8, root) catch return null;
                defer self.gpa.free(rootz);
                const resolved = std.c.realpath(rootz, &buf) orelse return null;
                const abs = std.mem.span(resolved);
                const cfstr = s.CFStringCreateWithBytes(null, abs.ptr, @intCast(abs.len), cs.kCFStringEncodingUTF8, 0) orelse return null;
                refs[made] = cfstr;
                made += 1;
                // Annals deliveries are keyed absolute; arm the strip prefix now —
                // BEFORE the stream exists — so no delivery can outrun it. Only a
                // single-root watch is annals-addressable (one unambiguous prefix);
                // a multi-root session simply leaves the ledger unarmed (declines).
                if (comptime has_annals) if (roots.len == 1) self.session.annals.arm(abs);
            }
            return s.CFArrayCreate(null, refs.ptr, @intCast(made), s.array_callbacks);
        }

        /// FSEvents delivers here on any change under the roots. With per-file
        /// events on (and no `UseCFTypes`), `event_paths` is a `char**` of the
        /// changed items' own absolute paths. Every path is `note`d into the
        /// session's dirty log BEFORE `markDirty` bumps the seqlock (the ordering
        /// the log's drain contract relies on); any flag that means the paths are
        /// not an exact account of what changed (rescan hints, drops, id wrap,
        /// mounts) becomes `noteDoubt`, so that batch's reconcile walks fully.
        fn fseventsCallback(_: cs.Ref, info: ?*anyopaque, num_events: usize, event_paths: ?[*]const [*:0]const u8, event_flags: [*]const u32, _: [*]const u64) callconv(.c) void {
            const session: *Session = @ptrCast(@alignCast(info orelse return));
            // One delivery instant for the whole batch — coalesced events share a
            // callback anyway, and delivery-at-or-after-occurrence is what the
            // annals' `since` filter relies on. A dead clock poisons the ledger
            // (never guesses); the dirty log is untouched either way.
            const now_ns: ?i128 = if (comptime has_annals) cs.wallNowNs() else null;
            if (event_paths) |paths| {
                for (0..num_events) |i| {
                    if (event_flags[i] & inexact_flags != 0) {
                        session.dirty_log.noteDoubt();
                        if (comptime has_annals) session.annals.noteDoubt();
                    } else {
                        const p = std.mem.span(paths[i]);
                        session.dirty_log.note(p);
                        if (comptime has_annals) {
                            if (now_ns) |ns| session.annals.note(p, ns) else session.annals.noteDoubt();
                        }
                    }
                }
            } else {
                session.dirty_log.noteDoubt();
                if (comptime has_annals) session.annals.noteDoubt();
            }
            session.markDirty();
        }
    };
}
