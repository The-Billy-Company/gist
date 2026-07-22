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
//! The macOS backend additionally requests PER-FILE events and `note`s every
//! delivered path into the session's `DirtyLog` (arming its `exact` promise),
//! which is what lets the reconcile verify only the changed paths — O(changed)
//! instead of O(tree). Any event flag it cannot attribute to exact paths
//! (`MustScanSubDirs`, kernel/user drops, id wrap, mount churn) becomes
//! `noteDoubt`, forcing that drain onto the full walk. The Linux backend stays
//! coarse (never arms `exact` — its drains always walk), but it now parses its
//! event stream for the two conditions that would silently BREAK the clean
//! fast path itself: a queue overflow, and a directory created/moved in after
//! arming (inotify watches don't recurse on their own). It re-registers new
//! subtrees on the fly and, if it cannot, calls `markDoubtForever` — the
//! session then reconciles every query instead of ever trusting a blind
//! quiescence claim (fail-closed).

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../../../corpus/tree/haystack.zig");
const Dir = std.Io.Dir;

const is_macos = builtin.os.tag == .macos;
const linux = std.os.linux;

/// The inotify event mask shared by root registration and the loop's on-the-fly
/// re-registration of directories created after arming.
const in_mask: u32 = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB |
    linux.IN.CLOSE_WRITE | linux.IN.ONLYDIR;

// ── macOS FSEvents backend — lazily `dlopen`'d, never link-time bound ──
//
// The CoreServices (FSEvents) + CoreFoundation (CFRunLoop) surface the macOS
// watcher drives, resolved at RUNTIME through `std.DynLib` instead of linked
// into the binary. Link-time framework loading runs the CoreFoundation + ObjC
// image initializers on EVERY process launch (~0.9 ms measured, ~1.8× a bare
// exe's startup) — a tax the cold one-shot search (`gist <pat>`, the product's
// whole reason to out-run ripgrep) would pay for an accelerator only the
// resident daemon ever arms. Loading on demand keeps the frameworks out of the
// cold binary's load commands entirely, so a search pays zero for the watcher.
// Fail-closed by construction: a `dlopen`/`dlsym` miss (or any non-macOS
// target) leaves `syms` null → the session is never armed → every query
// reconciles (correct, just not fast), the exact contract a missing backend
// already carried.
const Ref = ?*anyopaque;
const CFIndex = isize;
const kCFStringEncodingUTF8: u32 = 0x0800_0100;
const kFSEventStreamEventIdSinceNow: u64 = 0xFFFF_FFFF_FFFF_FFFF;
// NoDefer: deliver the first event immediately, then coalesce at `fsevents_latency`.
const kFSEventStreamCreateFlagNoDefer: u32 = 0x0000_0002;
// FileEvents: report the changed ITEM's own path (file or dir) instead of its
// parent directory — the exact dirty set the scoped reconcile needs.
const kFSEventStreamCreateFlagFileEvents: u32 = 0x0000_0010;
// Event flags meaning "these paths are NOT an exact account of what changed":
// subtree-rescan hints, kernel/user queue drops, id wrap, history replay
// boundary, root moves, mount churn. Any → the batch is a doubt (full walk).
const inexact_flags: u32 = 0x0000_00FF;
// Coalescing window (s): small keeps the read-your-writes stale window tight
// while still folding a build's event storm into a handful of markDirty calls.
const fsevents_latency: f64 = 0.05;

// FSEvents delivers `info` as an opaque pointer (the session, type-erased so the
// symbol table stays generic-free); `fseventsCallback` casts it back to its
// concrete `*Session`. The retaining `kCFTypeArrayCallBacks` lets the paths
// array own the CFString roots, so the loop drops its own references at once and
// the stream copies the list on create.
const FsCallback = *const fn (Ref, ?*anyopaque, usize, ?[*]const [*:0]const u8, [*]const u32, [*]const u64) callconv(.c) void;

const CFContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copy_description: ?*const anyopaque = null,
};

/// The dlopen'd CoreFoundation + CoreServices entry points, bound once when a
/// macOS session arms its watcher. Session-independent (the callback's `info` is
/// `?*anyopaque`), so it lives at module scope and off-macOS is simply never
/// populated — the field type stays valid on every target.
const Syms = struct {
    cf: std.DynLib,
    cs: std.DynLib,
    CFStringCreateWithBytes: *const fn (Ref, [*]const u8, CFIndex, u32, u8) callconv(.c) Ref,
    CFArrayCreate: *const fn (Ref, [*]const Ref, CFIndex, ?*const anyopaque) callconv(.c) Ref,
    CFRelease: *const fn (Ref) callconv(.c) void,
    CFRunLoopGetCurrent: *const fn () callconv(.c) Ref,
    CFRunLoopRunInMode: *const fn (Ref, f64, u8) callconv(.c) i32,
    CFRunLoopStop: *const fn (Ref) callconv(.c) void,
    FSEventStreamCreate: *const fn (Ref, FsCallback, ?*const CFContext, Ref, u64, f64, u32) callconv(.c) Ref,
    FSEventStreamScheduleWithRunLoop: *const fn (Ref, Ref, Ref) callconv(.c) void,
    FSEventStreamStart: *const fn (Ref) callconv(.c) u8,
    FSEventStreamStop: *const fn (Ref) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (Ref) callconv(.c) void,
    FSEventStreamRelease: *const fn (Ref) callconv(.c) void,
    run_loop_default_mode: Ref,
    array_callbacks: ?*const anyopaque,

    const cf_path = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    const cs_path = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

    /// Open both frameworks and bind every symbol, or null on the first miss
    /// (closing whatever opened). CoreFoundation carries the CF functions + the
    /// two data symbols; CoreServices carries FSEvents.
    fn load() ?Syms {
        if (comptime !is_macos) return null;
        var cf = std.DynLib.open(cf_path) catch return null;
        var cs = std.DynLib.open(cs_path) catch {
            cf.close();
            return null;
        };
        var s: Syms = undefined;
        s.cf = cf;
        s.cs = cs;
        s.CFStringCreateWithBytes = cf.lookup(@TypeOf(s.CFStringCreateWithBytes), "CFStringCreateWithBytes") orelse return s.fail();
        s.CFArrayCreate = cf.lookup(@TypeOf(s.CFArrayCreate), "CFArrayCreate") orelse return s.fail();
        s.CFRelease = cf.lookup(@TypeOf(s.CFRelease), "CFRelease") orelse return s.fail();
        s.CFRunLoopGetCurrent = cf.lookup(@TypeOf(s.CFRunLoopGetCurrent), "CFRunLoopGetCurrent") orelse return s.fail();
        s.CFRunLoopRunInMode = cf.lookup(@TypeOf(s.CFRunLoopRunInMode), "CFRunLoopRunInMode") orelse return s.fail();
        s.CFRunLoopStop = cf.lookup(@TypeOf(s.CFRunLoopStop), "CFRunLoopStop") orelse return s.fail();
        // Data symbols: `lookup` returns the symbol's address. `kCFRunLoopDefaultMode`
        // is a CFStringRef *variable* → deref to the value; `kCFTypeArrayCallBacks`
        // is the callbacks struct → its address is what CFArrayCreate wants.
        s.run_loop_default_mode = (cf.lookup(*Ref, "kCFRunLoopDefaultMode") orelse return s.fail()).*;
        s.array_callbacks = cf.lookup(*const anyopaque, "kCFTypeArrayCallBacks") orelse return s.fail();
        s.FSEventStreamCreate = cs.lookup(@TypeOf(s.FSEventStreamCreate), "FSEventStreamCreate") orelse return s.fail();
        s.FSEventStreamScheduleWithRunLoop = cs.lookup(@TypeOf(s.FSEventStreamScheduleWithRunLoop), "FSEventStreamScheduleWithRunLoop") orelse return s.fail();
        s.FSEventStreamStart = cs.lookup(@TypeOf(s.FSEventStreamStart), "FSEventStreamStart") orelse return s.fail();
        s.FSEventStreamStop = cs.lookup(@TypeOf(s.FSEventStreamStop), "FSEventStreamStop") orelse return s.fail();
        s.FSEventStreamInvalidate = cs.lookup(@TypeOf(s.FSEventStreamInvalidate), "FSEventStreamInvalidate") orelse return s.fail();
        s.FSEventStreamRelease = cs.lookup(@TypeOf(s.FSEventStreamRelease), "FSEventStreamRelease") orelse return s.fail();
        return s;
    }

    /// A partial resolve must never half-arm the watcher: close both handles and
    /// report the miss as null so the session stays in the reconcile-always base.
    fn fail(s: *Syms) ?Syms {
        s.close();
        return null;
    }

    fn close(s: *Syms) void {
        s.cf.close();
        s.cs.close();
    }
};

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
        syms: ?Syms = null,
        /// Linux: watch descriptor → the directory it covers (gpa-owned), so a
        /// dir-create event can be resolved to a path and its subtree watched
        /// before the next reconcile walks it. Built on the main thread before the
        /// loop thread spawns; grown only by the loop thread afterward.
        wd_paths: std.AutoHashMapUnmanaged(i32, []u8) = .empty,
        /// macOS: the watch thread's CFRunLoop, published so `stop` can wake it. Null
        /// until the loop thread stores it (before it signals `ready`).
        run_loop: std.atomic.Value(?*anyopaque) = .init(null),
        /// macOS start handshake: 0 pending, 1 stream armed, 2 failed. The loop
        /// thread publishes it once; `startFsevents` polls it to decide whether to
        /// arm the session (kept on the main thread so the plain `watcher_active`
        /// bool the query path reads is never written concurrently).
        start_result: std.atomic.Value(u8) = .init(0),

        pub fn init(gpa: std.mem.Allocator, io: std.Io, session: *Session) @This() {
            return .{ .session = session, .io = io, .gpa = gpa };
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

            // Recursively watch every directory under the roots. If ANY watch
            // fails to register we cannot prove quiescence for that subtree, so
            // we bail out unarmed (fail-closed): the session keeps reconciling.
            for (self.watchRoots()) |root| {
                if (!self.addWatchesRecursive(fd, root)) return self.closeUnarmed(fd);
            }

            self.inotify_fd = fd;
            self.running.store(true, .release);
            self.session.armWatcher();
            self.thread = std.Thread.spawn(.{}, inotifyLoop, .{self}) catch {
                self.running.store(false, .release);
                self.inotify_fd = -1;
                return self.closeUnarmed(fd); // spawn failed — unarm by leaving watcher inactive
            };
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
            var buf: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
            var pfd = [_]std.posix.pollfd{.{ .fd = self.inotify_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            while (self.running.load(.acquire)) {
                const ready = std.posix.poll(&pfd, 500) catch break;
                if (ready == 0) continue;
                const n = std.posix.read(self.inotify_fd, &buf) catch |e| switch (e) {
                    error.WouldBlock => continue,
                    else => break,
                };
                if (n == 0) continue;
                // Walk the event records for the two conditions that would
                // silently break the clean fast path: a queue overflow (events
                // were LOST — quiescence can never be proven again on this fd)
                // and a directory created/moved in after arming (inotify does
                // not recurse; an unwatched subtree is a blind spot). Extend
                // coverage inline; if that fails, poison the session so it
                // reconciles every query (fail-closed).
                var off: usize = 0;
                while (off + @sizeOf(linux.inotify_event) <= n) {
                    // Cast-free record view (zig-safety): the fixed header is
                    // copied out by value — 16 bytes on a cold path — instead
                    // of reinterpreting the buffer pointer.
                    const ev = std.mem.bytesToValue(linux.inotify_event, buf[off..][0..@sizeOf(linux.inotify_event)]);
                    off += @sizeOf(linux.inotify_event) + ev.len;
                    if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
                        self.session.markDoubtForever();
                        continue;
                    }
                    const grew_dir = ev.mask & linux.IN.ISDIR != 0 and
                        ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
                    if (grew_dir) self.coverNewDir(&ev, &buf, off);
                }
                self.session.markDirty();
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
            self.syms = Syms.load() orelse return;
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

            var ctx = CFContext{ .info = @ptrCast(self.session) };
            const stream = s.FSEventStreamCreate(
                null,
                fseventsCallback,
                &ctx,
                paths,
                kFSEventStreamEventIdSinceNow,
                fsevents_latency,
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents,
            ) orelse return self.start_result.store(2, .release);
            defer {
                s.FSEventStreamStop(stream);
                s.FSEventStreamInvalidate(stream);
                s.FSEventStreamRelease(stream);
            }

            const rl = s.CFRunLoopGetCurrent();
            self.run_loop.store(rl, .release);
            s.FSEventStreamScheduleWithRunLoop(stream, rl, s.run_loop_default_mode);
            if (s.FSEventStreamStart(stream) == 0) return self.start_result.store(2, .release);

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
        fn buildPathsArray(self: *@This()) ?Ref {
            if (comptime !is_macos) return null;
            const s = &self.syms.?;
            const roots = self.watchRoots();
            const refs = self.gpa.alloc(Ref, roots.len) catch return null;
            defer self.gpa.free(refs);

            var made: usize = 0;
            defer for (refs[0..made]) |r| s.CFRelease(r);
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            for (roots) |root| {
                const rootz = self.gpa.dupeZ(u8, root) catch return null;
                defer self.gpa.free(rootz);
                const resolved = std.c.realpath(rootz, &buf) orelse return null;
                const abs = std.mem.span(resolved);
                const cfstr = s.CFStringCreateWithBytes(null, abs.ptr, @intCast(abs.len), kCFStringEncodingUTF8, 0) orelse return null;
                refs[made] = cfstr;
                made += 1;
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
        fn fseventsCallback(_: Ref, info: ?*anyopaque, num_events: usize, event_paths: ?[*]const [*:0]const u8, event_flags: [*]const u32, _: [*]const u64) callconv(.c) void {
            const session: *Session = @ptrCast(@alignCast(info orelse return));
            if (event_paths) |paths| {
                for (0..num_events) |i| {
                    if (event_flags[i] & inexact_flags != 0) {
                        session.dirty_log.noteDoubt();
                    } else {
                        session.dirty_log.note(std.mem.span(paths[i]));
                    }
                }
            } else session.dirty_log.noteDoubt();
            session.markDirty();
        }
    };
}
