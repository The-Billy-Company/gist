//! gist resident session — the Windows `ReadDirectoryChangesW` freshness backend
//! (ADR-352 rung 2.5, ADR-372).
//!
//! One recursive subscription per root, every completion landing on a single I/O
//! completion port. Structurally this is the Linux arm, not the macOS one: a
//! `WatchTree` subscription covers a whole subtree *including directories created
//! after arming*, so there is no `coverNewDir` to write, no descriptor-per-vnode
//! price to predict, and no admission walk to keep in step with the ignore rules.
//! The port is the `inotify_fd` of this backend — one waitable object, drained to
//! empty under `read_lock` by whichever of the two consumers gets there first.
//!
//! **Why a completion port and not an event or an APC.** All three can report a
//! finished notify, and only one of them can carry the freshness *barrier*. An
//! event in the `IO_STATUS_BLOCK` and an APC are both delivered by the issuing
//! thread — the status block is written and the event signalled inside a special
//! kernel APC queued to whoever issued the request — so a `flushSync` running on
//! the daemon's route thread could scan every status block, find them all
//! `PENDING`, and declare a tree quiescent that the kernel had already reported
//! moving. That is precisely the stale answer the barrier exists to prevent. A
//! completion port is queued by the I/O manager to the PORT, outliving even the
//! issuing thread, so a drain from any thread is a genuine witness — which is what
//! lets this backend keep the same `flushSync` contract the POSIX two have.
//!
//! **What the barrier does and does not promise here, honestly.** Windows updates
//! a file's directory entry lazily: bytes written through a handle that is still
//! open change no entry and therefore raise no notification, however long you
//! wait. That sounds fatal to a fast path and is not, because the reconcile this
//! watcher accelerates reads *that same directory entry* — `reconcile.one` gates a
//! re-read on the `mtime`/`ctime` the enumerating walk captured, and on Windows
//! that walk is `NtQueryDirectoryFile` over the very entries these notifications
//! are raised from. So a write this backend cannot see is a write a full reconcile
//! would also have missed. Skipping the walk loses nothing that walking would have
//! found, which is the only promise the clean fast path actually makes. The
//! obligation that follows is concrete and is the reason `filter` is spelled as
//! widely as it is: **every field the reconcile compares must be in the filter**,
//! or the walk would notice something the watcher slept through.
//!
//! **Exact keys, without a case-sensitivity refusal.** inotify has to decline
//! `exact` on a casefolded directory because it reports a parent watch plus a
//! writer-supplied name, so two byte-spellings can alias one file. A notify record
//! carries the name *as the directory entry stores it* — one spelling per file, no
//! matter how the writer opened it — so the key space is the walk's own, exactly as
//! it is for kqueue's descriptors (ADR-372). Case-insensitive volumes and
//! per-directory case-sensitive ones both arm.
//!
//! **The extended record class earns its floor.** `NotifyExtended` (Windows 10
//! 1709, under the `win10_rs4` floor the resident tier already declares) puts the
//! file's attributes AND its timestamps in the record itself. That buys two things
//! no POSIX backend gets: a directory is told from a file with no `stat` at all,
//! and the annals ledger is stamped with the file's own `max(mtime, ctime)` — the
//! exact quantity `Annals.seed` documents as canonical — rather than with the
//! drain-time clock the other two must approximate it by. A filesystem that
//! refuses the class falls back to the plain one, where an unattributable kind is
//! treated as a file: one ledger entry the reader stats away, never a lost change.
//!
//! Every function takes the generic `Watcher(Session)` as `self`; the shared
//! accelerator contract and lifecycle live in the `watch.zig` facade.

const std = @import("std");
const builtin = @import("builtin");
const haystack = @import("../../../corpus/tree/haystack.zig");
const portal = @import("../../../portal.zig");
const sheaf = @import("../../../corpus/tree/sheaf.zig");

const windows = builtin.os.tag == .windows;
const w = std.os.windows;

/// Not in `std.os.windows`; declared here at the ABI they have everywhere, the
/// same way `conduit/vigil.zig` declares `NtResetEvent`. std carried completion
/// ports while it had an event loop of its own and dropped them with it.
extern "ntdll" fn NtCreateIoCompletion(
    IoCompletionHandle: *w.HANDLE,
    DesiredAccess: w.ACCESS_MASK,
    ObjectAttributes: ?*const w.OBJECT.ATTRIBUTES,
    /// Concurrent threads the port will admit; `0` means one per processor.
    Count: w.ULONG,
) callconv(.winapi) w.NTSTATUS;

extern "ntdll" fn NtRemoveIoCompletion(
    IoCompletionHandle: w.HANDLE,
    KeyContext: *?*anyopaque,
    ApcContext: *?*anyopaque,
    IoStatusBlock: *w.IO_STATUS_BLOCK,
    /// Negative is a relative interval in 100ns ticks; a zero interval polls.
    Timeout: ?*const w.LARGE_INTEGER,
) callconv(.winapi) w.NTSTATUS;

/// std dropped its `kernel32` binding for this along with the old event loop;
/// `portal.zig` keeps its own for `wallSeconds`, and one `extern` is cheaper than
/// widening that module's surface for a second caller.
extern "kernel32" fn GetSystemTimeAsFileTime(*w.FILETIME) callconv(.winapi) void;

/// `FILE_COMPLETION_INFORMATION` — what binds a handle's completions to a port.
const Completion = extern struct { Port: w.HANDLE, Key: ?*anyopaque };

/// Every field `reconcile.one` compares, plus every cause of a `ChangeTime`
/// advance, and nothing else.
///
/// `LAST_WRITE` and `SIZE` are the two the walk reads directly. `CREATION`,
/// `ATTRIBUTES`, `SECURITY` and `EA` are in because each of them moves
/// `ChangeTime`, which the walk reads as `ctime` — a file whose metadata changed
/// under a fixed `mtime` is still a re-read. `FILE_NAME`/`DIR_NAME` carry
/// membership. `LAST_ACCESS` is deliberately out: nothing here compares atime, and
/// on a volume without `relatime`'s equivalent it would report every read in the
/// tree as a change.
const filter: w.FILE.NOTIFY.CHANGE = .{
    .FILE_NAME = true,
    .DIR_NAME = true,
    .ATTRIBUTES = true,
    .SIZE = true,
    .LAST_WRITE = true,
    .CREATION = true,
    .SECURITY = true,
    .EA = true,
};

/// Per-root notify buffer. The system fills this with as many records as fit and,
/// when they do not fit, discards the lot and completes with zero bytes — so this
/// number is the entire margin between a burst and permanent doubt
/// (`markDoubtForever`). 64 KiB is also the ceiling `ReadDirectoryChangesW`
/// documents for a handle on a network share, which is the largest size that is
/// portable across every volume a root might sit on.
const buffer_bytes = 64 * 1024;

/// Idle re-drain cadence. Nothing depends on it for correctness — `flushSync`
/// catches every event before any query is answered — but a daemon nobody is
/// querying still has to empty its buffers, or a `git checkout` during a quiet
/// spell would overflow one and cost the session its fast path for good.
const idle_ns: w.LARGE_INTEGER = -500 * std.time.ns_per_ms / 100;

/// Comptime-derived rather than the literal `0x10`, so a field reordering in std
/// cannot silently turn every directory into a file.
const directory_bit: u32 = @bitCast(w.FILE.ATTRIBUTE{ .DIRECTORY = true });

/// One root's recursive subscription. Pointer-stable for its whole life — the
/// kernel is holding `&iosb` and writing into `buffer` — which is why `watch.zig`
/// keeps these in a slice allocated once at arm time and never grows it.
pub const Root = struct {
    handle: portal.Handle = portal.invalid_handle,
    /// The root's canonical absolute path in gist's separator: the prefix every
    /// noted path is built on. `gpa`-owned.
    abs: []u8 = &.{},
    /// Written by the kernel; read only through the completion packet, never
    /// polled — see the module note on why polling it would not be a barrier.
    iosb: w.IO_STATUS_BLOCK = undefined,
    buffer: []align(4) u8 = &.{},
};

pub fn startNotify(self: anytype) void {
    if (comptime !windows) return;
    const roots = self.watchRoots();
    self.notify_roots = self.gpa.alloc(Root, roots.len) catch return;
    for (self.notify_roots) |*root| root.* = .{};
    errdefer closeNotify(self);

    var port: w.HANDLE = undefined;
    if (NtCreateIoCompletion(&port, w.ACCESS_MASK.Specific.IoCompletion.ALL_ACCESS, null, 0) != .SUCCESS)
        return closeNotify(self);
    self.notify_port = port;

    var stop: w.HANDLE = undefined;
    // Notification (manual-reset): once `stop` is set the loop must see it no
    // matter how many times it loops, so a wait may not consume the signal.
    if (w.ntdll.NtCreateEvent(&stop, .{ .STANDARD = .{ .SYNCHRONIZE = true } }, null, .Notification, .FALSE) != .SUCCESS)
        return closeNotify(self);
    self.notify_stop = stop;

    // Fail-closed: a root that will not subscribe leaves the whole session
    // unarmed, because a subtree nobody is watching cannot be proven quiescent.
    var lone_root: ?[]const u8 = null;
    for (roots, self.notify_roots, 0..) |path, *root, i| {
        if (!subscribe(self, root, path, i)) return closeNotify(self);
        if (roots.len == 1) lone_root = root.abs;
    }

    self.running.store(true, .release);
    armAnnals(self, lone_root);
    // Promise exactness BEFORE arming the watcher, so the very first event the
    // loop notes is already covered by the exact contract. Unconditional here:
    // a notify record carries the directory's own spelling, so there is no
    // casefold case to refuse (see the module note).
    self.session.dirty_log.armExact();
    self.session.armWatcher();
    self.thread = std.Thread.spawn(.{}, notifyLoop, .{self}) catch {
        self.running.store(false, .release);
        self.session.disarmWatcher();
        return closeNotify(self);
    };
}

/// Open one root asynchronously, bind it to the port under key `slot`, and post
/// its first request. False on any step, which unarms the session.
fn subscribe(self: anytype, root: *Root, path: []const u8, slot: usize) bool {
    if (comptime !windows) return false;

    var buf: [portal.max_path]u8 = undefined;
    const pathz = std.posix.toPosixPath(path) catch return false;
    // Canonical and absolute, exactly as the POSIX arms key their notes — this is
    // the prefix `Annals.relativize` and `Delta.keyFor` strip, and it is already
    // `/`-spelled by `portal.realpath`.
    const abs = portal.realpath(&pathz, &buf) orelse return false;
    root.abs = self.gpa.dupe(u8, abs) catch return false;
    root.buffer = self.gpa.alignedAlloc(u8, .@"4", buffer_bytes) catch return false;

    const wide = std.Io.Threaded.sliceToPrefixedFileW(portal.cwd(), path, .{}) catch return false;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    // Asynchronous is the load-bearing flag — std's own `openDir` pins
    // `SYNCHRONOUS_NONALERT`, which is why this is spelled out here rather than
    // borrowed. `OPEN_FOR_BACKUP_INTENT` is what lets a directory be opened for
    // listing without owning it.
    if (w.ntdll.NtCreateFile(
        &root.handle,
        .{ .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true } }, .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .ObjectName = @constCast(&wide.string()) },
        &iosb,
        null,
        .{},
        // Share everything: a watched tree must stay writable and deletable by
        // everyone else, or arming the watcher would change the tree's behavior.
        .VALID_FLAGS,
        .OPEN,
        .{ .DIRECTORY_FILE = true, .IO = .ASYNCHRONOUS, .OPEN_FOR_BACKUP_INTENT = true },
        null,
        0,
    ) != .SUCCESS) return false;

    // The key is the root's index, not a pointer, so a completion packet resolves
    // to its subscription without reinterpreting kernel-supplied memory. Offset by
    // one because a null key is indistinguishable from index zero.
    var binding: Completion = .{ .Port = self.notify_port, .Key = @ptrFromInt(slot + 1) };
    if (w.ntdll.NtSetInformationFile(root.handle, &iosb, &binding, @sizeOf(Completion), .Completion) != .SUCCESS)
        return false;
    return listen(self, root);
}

/// Post one notify request. The status block is stamped `PENDING` first: a request
/// that completes synchronously overwrites it, and one that does not has left it
/// meaning what it says.
fn listen(self: anytype, root: *Root) bool {
    if (comptime !windows) return false;
    root.iosb.u.Status = .PENDING;
    const class: w.DIRECTORY.NOTIFY_INFORMATION_CLASS = if (self.notify_extended) .NotifyExtended else .Notify;
    switch (w.ntdll.NtNotifyChangeDirectoryFileEx(
        root.handle,
        null, // no event and no APC: the port is the only reporter (module note)
        null,
        null,
        &root.iosb,
        root.buffer.ptr,
        @intCast(root.buffer.len),
        filter,
        .TRUE, // the whole subtree, new directories included — the Linux arm's `coverNewDir`, for free
        class,
    )) {
        .SUCCESS, .PENDING => return true,
        // The volume does not implement the extended record. Drop to the plain
        // one once and re-post; `notify_extended` keeps the drain's parser in step.
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_SUPPORTED => {
            if (!self.notify_extended) return false;
            self.notify_extended = false;
            return listen(self, root);
        },
        else => return false,
    }
}

fn notifyLoop(self: anytype) void {
    if (comptime !windows) return;
    while (self.running.load(.acquire)) {
        // Every dequeue in this backend happens under `read_lock`, including this
        // one — that is what makes the barrier exact. If the loop could block on
        // the port unlocked it would sometimes be holding a packet the barrier had
        // already concluded was not there, and a query would answer stale. So the
        // loop idles on its own stop event instead of on the port, and the port has
        // exactly one consumer discipline.
        self.read_lock.lock();
        drainNotifyLocked(self);
        self.read_lock.unlock();
        if (w.ntdll.NtWaitForSingleObject(self.notify_stop, .FALSE, &idle_ns) != .TIMEOUT) return;
    }
}

/// Take every completion packet the port already holds, note each record, and
/// re-post the subscriptions they came from. Caller MUST hold `read_lock`. Every
/// `note` precedes the single trailing `markDirty` — the dirty-log/seqlock
/// ordering contract a scoped reconcile relies on. Windows only.
pub fn drainNotifyLocked(self: anytype) void {
    if (comptime !windows) return;
    if (self.notify_port == portal.invalid_handle) return;
    const immediately: w.LARGE_INTEGER = 0;
    var noted = false;
    while (true) {
        var key: ?*anyopaque = null;
        var context: ?*anyopaque = null;
        var iosb: w.IO_STATUS_BLOCK = undefined;
        if (NtRemoveIoCompletion(self.notify_port, &key, &context, &iosb, &immediately) != .SUCCESS) break;
        noted = true;
        const slot = @intFromPtr(key);
        if (slot == 0 or slot > self.notify_roots.len) {
            // A packet naming no subscription: nothing to re-post and nothing to
            // attribute, but a change was still observed.
            self.noteUnattributable();
            continue;
        }
        const root = &self.notify_roots[slot - 1];
        // Zero bytes is how the system says "your buffer overflowed and I threw
        // the batch away" — events were LOST, so quiescence can never be proven
        // again on this subscription. Any non-success status (`NOTIFY_ENUM_DIR`
        // among them) means the same thing.
        if (iosb.u.Status != .SUCCESS or iosb.Information == 0) {
            self.session.markDoubtForever();
        } else {
            records(self, root, root.buffer[0..iosb.Information]);
        }
        if (!listen(self, root)) self.session.markDoubtForever();
    }
    if (noted) self.session.markDirty();
}

/// Walk one completed buffer's variable-length records. A malformed chain stops
/// the walk as doubt rather than being trusted for as far as it parsed.
fn records(self: anytype, root: *const Root, buf: []const u8) void {
    // The two layouts share their first two fields and differ only in where the
    // name and its length sit, so one walk serves both — `@offsetOf` rather than
    // literals so a std field reordering cannot desynchronise the parse.
    const Plain = w.FILE.NOTIFY.INFORMATION;
    const Extended = w.FILE.NOTIFY.EXTENDED_INFORMATION;
    const name_at: usize = if (self.notify_extended) @offsetOf(Extended, "FileName") else @offsetOf(Plain, "FileName");
    const len_at: usize = if (self.notify_extended) @offsetOf(Extended, "FileNameLength") else @offsetOf(Plain, "FileNameLength");

    var off: usize = 0;
    while (off + name_at <= buf.len) {
        const rec = buf[off..];
        const next = u32At(rec, @offsetOf(Plain, "NextEntryOffset"));
        const name_len = u32At(rec, len_at);
        if (name_at + name_len > rec.len) return self.noteUnattributable();
        noteRecord(self, root, rec, rec[name_at..][0..name_len]);
        if (next == 0) return;
        if (next < name_at or off + next > buf.len) return self.noteUnattributable();
        off += next;
    }
}

/// Note one record's path into the session's `DirtyLog` — and, for a FILE, the
/// annals ledger a one-shot `gist index` amend and the resident keep's epoch both
/// read. The absolute path is assembled straight into a stack buffer: this runs
/// once per changed path, and the two notes copy what they keep, so nothing here
/// needs to outlive the call.
fn noteRecord(self: anytype, root: *const Root, rec: []const u8, name: []const u8) void {
    var abs: [portal.max_path]u8 = undefined;
    const rel = render(root, name, &abs) orelse return self.noteUnattributable();
    // The subtrees the walk never enters, dropped whole. inotify gets this by
    // simply not watching them; a `WatchTree` subscription has no such choice, so
    // `.git`, `node_modules` and `zig-cache` churn is filtered here instead —
    // otherwise every object write in a `git` operation would dirty the session.
    if (haystack.underSkippedDir(rel)) return;
    const path = abs[0 .. root.abs.len + 1 + rel.len];
    self.session.dirty_log.note(path);
    if (!isDirectory(self, rec)) noteAnnals(self, path, rec);
}

/// `root.abs ++ "/" ++ name`, written into `out` with the record's `\` separators
/// rewritten to gist's. Returns the RELATIVE tail (a view into `out`), or null when
/// the name will not decode or the join will not fit.
fn render(root: *const Root, name: []const u8, out: []u8) ?[]const u8 {
    @memcpy(out[0..root.abs.len], root.abs);
    out[root.abs.len] = '/';
    const tail = out[root.abs.len + 1 ..];

    // Widened one element at a time rather than reinterpreted: a record's name is
    // 2-byte aligned within a 4-aligned buffer in practice, but nothing in the
    // contract says so, and `readInt` costs a move either way.
    var wide: [portal.max_path]u16 = undefined;
    const units = name.len / 2;
    if (units > wide.len or units * 3 > tail.len) return null;
    for (wide[0..units], 0..) |*unit, i| unit.* = std.mem.readInt(u16, name[i * 2 ..][0..2], .little);
    const n = std.unicode.wtf16LeToWtf8(tail, wide[0..units]);
    if (n == 0) return null;
    if (comptime std.fs.path.sep != '/') std.mem.replaceScalar(u8, tail[0..n], std.fs.path.sep, '/');
    return tail[0..n];
}

/// Is this record's entry a directory? The extended class says so in the record;
/// the plain one does not say at all, and an unknown kind is treated as a file —
/// at worst one ledger entry its reader stats away (see the module note).
fn isDirectory(self: anytype, rec: []const u8) bool {
    if (!self.notify_extended) return false;
    const attrs = u32At(rec, @offsetOf(w.FILE.NOTIFY.EXTENDED_INFORMATION, "FileAttributes"));
    return attrs & directory_bit != 0;
}

/// Record one exact FILE delivery into the annals ledger. A directory reaches only
/// the dirty log (`noteRecord`), matching both POSIX backends: its event means
/// "membership here moved", which the reconcile answers by diffing the subtree,
/// while the ledger's capacity is bounded and an entry spent on shape is an entry
/// evicted from content.
///
/// The instant comes from the record where the record can be trusted for it.
/// `max(LastModificationTime, LastChangeTime)` IS the quantity `Annals.seed`
/// documents as canonical — the same one the stat walk compares — so a `since`
/// filter over these notes reproduces the walk's own keep/drop exactly, where the
/// POSIX backends can only bound it from above with a drain-time clock. A REMOVED
/// or renamed-away entry is the exception: its timestamps describe the file as it
/// was, which would place the deletion before itself, so those take the clock.
fn noteAnnals(self: anytype, abs: []const u8, rec: []const u8) void {
    if (comptime !@TypeOf(self.*).has_annals) return;
    if (recordNs(self, rec)) |ns| self.session.annals.note(abs, ns) else self.session.annals.noteDoubt();
}

fn recordNs(self: anytype, rec: []const u8) ?i128 {
    const E = w.FILE.NOTIFY.EXTENDED_INFORMATION;
    const gone = switch (u32At(rec, @offsetOf(E, "Action"))) {
        // `FILE_ACTION_REMOVED` / `FILE_ACTION_RENAMED_OLD_NAME`. Not named in
        // std, and only these two need telling apart from the rest.
        2, 4 => true,
        else => false,
    };
    if (gone or !self.notify_extended) return wallNowNs();
    const modified = i64At(rec, @offsetOf(E, "LastModificationTime"));
    const changed = i64At(rec, @offsetOf(E, "LastChangeTime"));
    // A volume that keeps neither leaves both zero, which `filetimeNs` reads as
    // "not recorded"; the clock stands in rather than dating the change to 1601.
    return sheaf.filetimeNs(@max(modified, changed)) orelse wallNowNs();
}

/// The wall instant a delivery is stamped with when the record cannot supply one,
/// or null when the clock is unreadable — the caller poisons the ledger rather
/// than guessing. `inotify.zig` and `kqueue.zig` each keep the twin of this,
/// because the instant must be taken at DELIVERY and the ledger itself stays free
/// of any platform clock.
fn wallNowNs() ?i128 {
    if (comptime !windows) return null;
    var ft: w.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    return sheaf.filetimeNs(@bitCast((@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime));
}

/// Arm the annals ledger the resident keep reads its epoch from, and open its
/// coverage now that every root is subscribed — an event that predated its own
/// subscription was never observable, so the ledger must not claim the window
/// registration spanned. Deliveries are keyed absolute and byte-exact, so the
/// ledger arms only for a SINGLE root (one unambiguous strip prefix); a multi-root
/// session leaves it unarmed and every reader declines. This mirrors
/// `inotify.armAnnals` and `coverage.coverRoots`.
fn armAnnals(self: anytype, lone_root: ?[]const u8) void {
    if (comptime !@TypeOf(self.*).has_annals) return;
    const abs = lone_root orelse return;
    self.session.annals.arm(abs);
    if (wallNowNs()) |ns| self.session.annals.openCoverage(ns);
}

/// Hand back every handle, buffer and path this backend holds. Safe to call on a
/// half-built subscription set (the `startNotify` bail-out) and on a fully armed
/// one; `watch.zig` calls it only after the loop thread is joined, so nothing can
/// be writing into a buffer as it is freed.
pub fn closeNotify(self: anytype) void {
    if (comptime !windows) return;
    if (self.notify_stop != portal.invalid_handle) {
        _ = w.ntdll.NtClose(self.notify_stop);
        self.notify_stop = portal.invalid_handle;
    }
    for (self.notify_roots) |*root| {
        if (root.handle != portal.invalid_handle) {
            // Cancel before closing: a close alone would race the pending request
            // against the buffer being freed underneath it.
            var cancel: w.IO_STATUS_BLOCK = undefined;
            _ = w.ntdll.NtCancelIoFileEx(root.handle, &root.iosb, &cancel);
            _ = w.ntdll.NtClose(root.handle);
        }
        if (root.buffer.len != 0) self.gpa.free(root.buffer);
        if (root.abs.len != 0) self.gpa.free(root.abs);
    }
    if (self.notify_roots.len != 0) self.gpa.free(self.notify_roots);
    self.notify_roots = &.{};
    if (self.notify_port != portal.invalid_handle) {
        _ = w.ntdll.NtClose(self.notify_port);
        self.notify_port = portal.invalid_handle;
    }
    // A re-arm re-negotiates the record class: the roots it subscribes next time
    // may be on a different volume than the ones it just gave back.
    self.notify_extended = true;
}

/// Wake the loop thread so `watch.zig::stop` does not have to wait out the idle
/// interval. Setting the event is enough — `running` is already false by the time
/// this is called.
pub fn signalStop(self: anytype) void {
    if (comptime !windows) return;
    if (self.notify_stop != portal.invalid_handle) _ = w.ntdll.NtSetEvent(self.notify_stop, null);
}

/// Little-endian field reads at a known offset. Cast-free on purpose (the
/// `zig-safety` ratchet): a record is kernel-supplied bytes, and reinterpreting a
/// pointer into it would trade a bounds check for an alignment assumption the
/// notify contract never makes.
fn u32At(rec: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, rec[at..][0..4], .little);
}

fn i64At(rec: []const u8, at: usize) i64 {
    return std.mem.readInt(i64, rec[at..][0..8], .little);
}
