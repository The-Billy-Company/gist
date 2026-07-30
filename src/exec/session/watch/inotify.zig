//! gist resident session — the Linux `inotify` freshness backend (ADR-352 rung
//! 2.5, ADR-372).
//!
//! Recursively watches every directory under the session's roots, keyed to
//! absolute realpaths so noted paths match the canonical shape `delta.resolve`
//! expects. inotify reports a parent watch descriptor plus a kernel-supplied
//! name, so a casefolded root (ext4/f2fs `+F`) would alias distinct
//! byte-spellings the exact key model cannot represent — such a root stays
//! coarse (`casefolded`). Because inotify watches neither recurse nor coalesce,
//! the loop must extend coverage into directories created after arming
//! (`coverNewDir`) and treat a queue overflow as permanent doubt. Every function
//! takes the generic `Watcher(Session)` as `self`; the shared accelerator
//! contract and lifecycle live in the `watch.zig` facade.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../../../corpus/tree/haystack.zig");

const linux = std.os.linux;
const Dir = std.Io.Dir;

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

pub fn startInotify(self: anytype) void {
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
    var lone_root: ?[]const u8 = null;
    const roots = self.watchRoots();
    for (roots) |root| {
        const rootz = std.posix.toPosixPath(root) catch return closeUnarmed(self, fd);
        const resolved = std.c.realpath(&rootz, &buf) orelse return closeUnarmed(self, fd);
        const abs = std.mem.span(resolved);
        if (casefolded(self, abs)) exact = false;
        if (roots.len == 1) lone_root = abs;
        if (!addWatchesRecursive(self, fd, abs)) return closeUnarmed(self, fd);
    }

    self.inotify_fd = fd;
    self.running.store(true, .release);
    armAnnals(self, lone_root, exact);
    // Promise exactness BEFORE arming the watcher, so the very first
    // event the loop notes is already covered by the exact contract.
    if (exact) self.session.dirty_log.armExact();
    self.session.armWatcher();
    self.thread = std.Thread.spawn(.{}, inotifyLoop, .{self}) catch {
        self.running.store(false, .release);
        self.inotify_fd = -1;
        return closeUnarmed(self, fd); // spawn failed — unarm by leaving watcher inactive
    };
}

/// Is directory `path` casefolded (case-INsensitive)? A confirmed
/// `FS_CASEFOLD_FL` bit blocks exact mode; every other outcome — no bit,
/// or an `ioctl` the filesystem doesn't implement (`ENOTTY`, the common
/// case on non-casefold volumes) — means case-sensitive, so exact arms.
fn casefolded(self: anytype, path: []const u8) bool {
    if (comptime builtin.os.tag != .linux) return false;
    var dir = Dir.cwd().openDir(self.io, path, .{}) catch return false;
    defer dir.close(self.io);
    var flags: c_long = 0;
    const rc = linux.ioctl(dir.handle, FS_IOC_GETFLAGS, @intFromPtr(&flags));
    if (linux.errno(rc) != .SUCCESS) return false;
    return flags & FS_CASEFOLD_FL != 0;
}

/// Shared inotify bail-out: release the fd and every recorded watch path.
fn closeUnarmed(self: anytype, fd: i32) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = linux.close(fd);
    freeWdPaths(self);
}

pub fn freeWdPaths(self: anytype) void {
    var it = self.wd_paths.valueIterator();
    while (it.next()) |p| self.gpa.free(p.*);
    self.wd_paths.clearRetainingCapacity();
}

/// Register a watch on `path` and every non-skipped subdirectory, recording
/// wd → path so the event loop can extend coverage into directories created
/// later. Returns false on the first failure (caller bails unarmed, or —
/// post-arm — poisons the session).
fn addWatchesRecursive(self: anytype, fd: i32, path: []const u8) bool {
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
        if (!addWatchesRecursive(self, fd, child)) return false;
    }
    return true;
}

fn inotifyLoop(self: anytype) void {
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
        self.read_lock.lock();
        drainInotifyLocked(self);
        self.read_lock.unlock();
    }
}

/// Read and process every inotify record currently queued (until the fd
/// would block), noting each changed path and extending coverage into
/// directories created after arming. Caller MUST hold `read_lock`. Every
/// `note` precedes the single trailing `markDirty` — the dirty-log/seqlock
/// ordering contract a scoped reconcile relies on. Linux only.
pub fn drainInotifyLocked(self: anytype) void {
    if (comptime builtin.os.tag != .linux) return;
    var buf: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
    var noted = false;
    while (true) {
        const n = std.posix.read(self.inotify_fd, &buf) catch break; // WouldBlock/err → drained
        if (n == 0) break;
        processRecords(self, buf[0..n]);
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
fn processRecords(self: anytype, buf: []const u8) void {
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
        noteEvent(self, &ev, buf, off);
        const grew_dir = ev.mask & linux.IN.ISDIR != 0 and
            ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
        if (grew_dir) coverNewDir(self, &ev, buf, off);
    }
}

/// Extend watch coverage into a directory created/moved in after arming;
/// any step that cannot be resolved poisons the session (fail-closed).
fn coverNewDir(self: anytype, ev: *const linux.inotify_event, buf: []const u8, rec_end: usize) void {
    const name = nameOf(ev, buf, rec_end) orelse return self.session.markDoubtForever();
    if (haystack.isSkipDir(name)) return;
    const parent = self.wd_paths.get(ev.wd) orelse return self.session.markDoubtForever();
    const child = haystack.joinPath(self.gpa, parent, name) catch return self.session.markDoubtForever();
    defer self.gpa.free(child);
    // Racing creations inside the new dir before its watch lands
    // are covered: the recursive registration below re-lists the
    // subtree AFTER each watch is added, and markDirty forces
    // the next query's reconcile to walk it regardless.
    if (!addWatchesRecursive(self, self.inotify_fd, child))
        self.session.markDoubtForever();
}

/// The wall instant a delivery is stamped with, or null when the clock is
/// unreadable — the caller poisons the ledger rather than guessing one. Each
/// backend reads the clock beside its own event loop (`kqueue.zig` keeps the
/// twin of this) because the instant must be taken at DELIVERY, not at drain;
/// the ledger itself stays free of any platform clock.
fn wallNowNs() ?i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Arm the annals ledger the resident keep reads its epoch from, and open its
/// coverage now that every watch is registered — an event that predated its
/// own watch was never observable, so the ledger must not claim the window
/// registration spanned (conservative by construction: uncovered, never
/// wrong). Deliveries are keyed absolute and byte-exact, so the ledger arms
/// only for a SINGLE root (one unambiguous strip prefix) whose spelling that
/// key model can represent; a multi-root or casefolded session leaves it
/// unarmed and every reader — `since` and the keep's `epoch` alike — declines.
/// This mirrors `coverage.coverRoots` on the macOS side, which is where the
/// kqueue backend arms the same ledger.
fn armAnnals(self: anytype, lone_root: ?[]const u8, exact: bool) void {
    if (comptime !@TypeOf(self.*).has_annals) return;
    if (!exact) return;
    const abs = lone_root orelse return;
    self.session.annals.arm(abs);
    if (wallNowNs()) |ns| self.session.annals.openCoverage(ns);
}

/// Record one exact FILE delivery into the annals ledger. A directory reaches
/// only the dirty log: its event means "membership here moved", which the
/// reconcile answers by diffing the subtree, while the ledger's reader amends
/// per file and would stat a directory away — and its capacity is bounded, so
/// an entry spent on shape is an entry evicted from content. A dead clock
/// poisons the ledger rather than guessing an instant. The same split
/// `kqueue.note` applies, so both backends describe one corpus surface.
fn noteAnnals(self: anytype, abs: []const u8) void {
    if (comptime !@TypeOf(self.*).has_annals) return;
    if (wallNowNs()) |ns| self.session.annals.note(abs, ns) else self.session.annals.noteDoubt();
}

/// Note the exact path an inotify record attributes to, into the session's
/// `DirtyLog` — and, for a FILE, the annals ledger a one-shot `gist index`
/// amend and the resident keep's epoch both read. A record with a name
/// (`ev.len > 0`) is an entry inside the wd's directory (`parent/name`); a
/// nameless record (`ev.len == 0`) is the watched directory itself. Either
/// resolves to an absolute path (the wds were realpath'd at arm time). An
/// unmapped wd (evicted/racing) or a malformed name field can't be attributed
/// → `noteUnattributable` (that drain takes the full walk, and the ledger keeps
/// counting a change it cannot place).
fn noteEvent(self: anytype, ev: *const linux.inotify_event, buf: []const u8, rec_end: usize) void {
    const parent = self.wd_paths.get(ev.wd) orelse return self.noteUnattributable();
    if (ev.len == 0) return self.session.dirty_log.note(parent); // the watched dir itself
    const name = nameOf(ev, buf, rec_end) orelse return self.noteUnattributable();
    const child = haystack.joinPath(self.gpa, parent, name) catch return self.noteUnattributable();
    defer self.gpa.free(child);
    self.session.dirty_log.note(child);
    if (ev.mask & linux.IN.ISDIR == 0) noteAnnals(self, child);
}

/// The NUL-terminated name trailing a variable-length inotify record, or
/// null when the record is malformed (caller treats that as doubt).
fn nameOf(ev: *const linux.inotify_event, buf: []const u8, rec_end: usize) ?[]const u8 {
    if (ev.len == 0 or rec_end > buf.len) return null;
    const raw = buf[rec_end - ev.len .. rec_end];
    const z = std.mem.indexOfScalar(u8, raw, 0) orelse return null;
    return if (z == 0) null else raw[0..z];
}
