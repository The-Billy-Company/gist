//! gist resident session — the macOS kqueue coverage walk (ADR-352 rung 2.5,
//! ADR-372).
//!
//! macOS pays one DESCRIPTOR per watched file, so — unlike Linux, which watches
//! whole directories and gets their entries named for free — the watch set must
//! be exactly the set the corpus admits, or a single daemon holds 40% of the
//! system file table. This module selects that set from the SAME `Ignore`
//! policy the corpus walk and `delta` use, over the same roots: `coverTree`
//! descends precisely what the certified walk would descend and searches, plus
//! the hidden ignore SOURCES that decide both. It owns the arena the policy
//! lives in (`loadPolicy`/`dropPolicy`) and the key-space arithmetic
//! (`joinKey`/`rootKeyOf`). Registration itself and the event loop live in
//! `kqueue.zig`; the shared accelerator contract lives in the `watch.zig`
//! facade.

const std = @import("std");
const builtin = @import("builtin");
const ignore = @import("../../../corpus/tree/ignore.zig");
const haystack = @import("../../../corpus/tree/haystack.zig");
const kqueue = @import("kqueue.zig");
const portal = @import("../../../portal.zig");

const is_macos = builtin.os.tag == .macos;
const Dir = std.Io.Dir;

/// Why a tree is being covered — three questions a first registration and a
/// live extension answer differently: is a newly-watched path ANNOUNCED, may an
/// already-watched directory be trusted to report itself, and is a listing that
/// fails midway a coverage failure?
pub const Cover = enum {
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

/// The per-directory files that DEFINE what the walk admits. They are hidden,
/// so the visibility rule would drop them from the watch set — but an edit to
/// one changes the admitted set without touching a single admitted file, and
/// `delta.classify` already calls such a path `.semantics` (full walk). They
/// are therefore the one hidden shape macOS watches, and a change to one
/// re-derives the policy AND the watch set (`drainKqueueLocked`).
pub fn isIgnoreSource(name: []const u8) bool {
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

/// Build the admission policy the watch set is selected by — the same
/// `Ignore` the corpus walk and `delta` use, over the same roots — into a
/// fresh arena. False only when the arena itself cannot be created; the
/// rules are then the walk's, not a private approximation of them.
pub fn loadPolicy(self: anytype) bool {
    if (comptime !is_macos) return false;
    dropPolicy(self);
    const arena = self.gpa.create(std.heap.ArenaAllocator) catch return false;
    arena.* = .init(self.gpa);
    self.ig_arena = arena;
    // OOM lands on this function's existing failure signal: no policy, so
    // the watch set over-covers and `delta` still makes every admission
    // call. The fault itself resurfaces on the reconcile that needs it.
    self.ig = ignore.Ignore.init(arena.allocator(), self.io, .{}, self.session.roots) catch return false;
    return true;
}

pub fn dropPolicy(self: anytype) void {
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
pub fn coverRoots(self: anytype, comptime mode: Cover) bool {
    if (comptime !is_macos) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const roots = self.watchRoots();
    for (roots) |root| {
        const rootz = std.posix.toPosixPath(root) catch return false;
        const resolved = portal.realpath(&rootz, &buf) orelse return false;
        const abs = resolved;
        // Annals deliveries are keyed absolute; arm the strip prefix before
        // any event can be noted. Only a single-root watch is
        // annals-addressable (one unambiguous prefix); a multi-root session
        // simply leaves the ledger unarmed (it declines).
        if (comptime @TypeOf(self.*).has_annals) if (roots.len == 1) self.session.annals.arm(abs);
        // The key space is the corpus's: "" for the implicit CWD walk, the
        // root's own spelling otherwise — the shape ignore rules are
        // written against, and `scopeToRoot` exempts a named root from
        // rules that govern only its descendants.
        const key = if (std.mem.eql(u8, root, ".")) "" else root;
        if (self.ig) |*ig| ig.scopeToRoot(key);
        if (!coverTree(self, abs, key, mode)) return false;
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
pub fn coverTree(self: anytype, dir: []const u8, key: []const u8, comptime mode: Cover) bool {
    if (comptime !is_macos) return false;
    if (!addWatch(self, dir, key, true, mode)) return false;
    // An unreadable directory is not a watch failure: the reconcile walk
    // reports it and declines on its own terms (`fs.walk_error`).
    var d = Dir.cwd().openDir(self.io, dir, .{ .iterate = true }) catch return true;
    defer d.close(self.io);
    // This directory's own ignore files, in walk order: after its parent's
    // rules, before its entries are judged by them.
    if (self.ig) |*ig| ig.loadDir(if (key.len == 0) "." else key, key) catch return false;
    var it = d.iterate();
    while (true) {
        const next = it.next(self.io) catch if (comptime mode == .initial) break else return false;
        const e = next orelse break;
        if (e.name.len == 0) continue;
        const child = haystack.joinPath(self.gpa, dir, e.name) catch return false;
        defer self.gpa.free(child);
        const child_key = joinKey(self, key, e.name) catch return false;
        defer self.gpa.free(child_key);
        const covered = switch (e.kind) {
            .directory => !descends(self, e.name, child_key) or
                (mode == .extend and self.watch_index.contains(child)) or
                coverTree(self, child, child_key, mode),
            .file => !admits(self, e.name, child_key) or
                addWatch(self, child, "", false, mode),
            else => true, // symlinks/specials: the default walk never reads them
        };
        if (!covered) return false;
    }
    return true;
}

/// `key/name`, with the implicit CWD walk's empty key contributing no
/// separator — the corpus's own spelling for a path (`haystack.joinRoot`).
fn joinKey(self: anytype, key: []const u8, name: []const u8) ![]const u8 {
    return if (key.len == 0) self.gpa.dupe(u8, name) else haystack.joinPath(self.gpa, key, name);
}

/// Would the walk descend into this subdirectory? Hidden and skip-policy
/// directories are out of the walked set and can only enter it by a rename
/// their parent reports; the rest answer to the same ignore rules.
fn descends(self: anytype, name: []const u8, key: []const u8) bool {
    if (name[0] == '.' or haystack.isSkipDir(name)) return false;
    const ig = if (self.ig) |*p| p else return true;
    return !ig.shouldSkip(key, true, name, false, false);
}

/// Would the walk search this file — or does it DECIDE what the walk
/// searches? An ignore source is watched though hidden (see
/// `isIgnoreSource`); everything else hidden or ignored stays out.
fn admits(self: anytype, name: []const u8, key: []const u8) bool {
    if (isIgnoreSource(name)) return true;
    if (name[0] == '.') return false;
    const ig = if (self.ig) |*p| p else return true;
    return !ig.shouldSkip(key, false, name, false, false);
}

/// Which `open(2)` failure leaves nothing to watch, and which leaves a live
/// file with no delivery on it?
///
/// Only the first may be skipped. A path that vanished between listing and
/// open has no vnode to watch at all, and its parent's membership event names
/// it again if it returns. Every other errno — above all a spent descriptor
/// table (`MFILE`/`NFILE`), which `budget.zig` predicts but cannot promise
/// against a machine that moved underneath it — is a path the walk still
/// admits and still searches, now silently uncovered.
///
/// That posture is the one this module may never take. An uncovered file's
/// edits are never delivered, so the annals go on vouching an epoch that never
/// counted them, and a HELD answer — never re-derived, trusted purely on that
/// epoch standing still — outlives the bytes it describes. `noteUnattributable`
/// closes that gap for a delivery that arrived unplaceable; this closes it for
/// one that was never placed.
fn vanished(e: std.posix.E) bool {
    return e == .NOENT or e == .NOTDIR;
}

/// Open an `O_EVTONLY` descriptor on `path` and register its vnode filter,
/// recording the slot its events will address. Idempotent per path (a
/// directory re-scan re-offers entries already watched). A path that
/// vanished between listing and open is skipped rather than failed — there
/// is nothing left to watch, and its parent reports any return; any OTHER
/// open failure is a delivery this session could not place and fails closed
/// (`vanished`). False when the budget is spent or a registration genuinely
/// fails. Every mode but `.initial` notes a genuinely-new watch as a changed
/// path (see `coverTree`).
fn addWatch(self: anytype, path: []const u8, key: []const u8, is_dir: bool, comptime mode: Cover) bool {
    if (comptime !is_macos) return false;
    if (self.watch_index.contains(path)) return true;
    if (self.watches.items.len - self.free_slots.items.len >= self.budget) return false;
    const pathz = std.posix.toPosixPath(path) catch return false;
    const fd = std.c.open(&pathz, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .CLOEXEC = true });
    if (fd < 0) return vanished(std.posix.errno(fd));
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
        kqueue.retire(self, idx);
        return false;
    };
    var change = [_]std.c.Kevent{.{
        .ident = @intCast(fd),
        .filter = std.c.EVFILT.VNODE,
        // EV_CLEAR: each firing is delivered once, and further notes fold
        // into the knote instead of queuing — which is why kqueue has no
        // overflow to guard (contrast inotify's `Q_OVERFLOW`).
        .flags = std.c.EV.ADD | std.c.EV.CLEAR,
        .fflags = kqueue.vnode_notes,
        .data = 0,
        .udata = idx,
    }};
    if (std.c.kevent(self.kq_fd, &change, 1, &change, 0, null) < 0) {
        kqueue.retire(self, idx);
        return false;
    }
    // Noted only once the watch is live, so a path can never be announced
    // as changed while still uncovered for its next change.
    if (comptime mode != .initial) kqueue.note(self, owned, is_dir);
    return true;
}

test "coverage: only a vanished path may be skipped — everything else fails closed" {
    const t = std.testing;
    // The two that mean "this path, as spelled, is not there": nothing to
    // watch, and the parent names it again if it comes back.
    try t.expect(vanished(.NOENT));
    try t.expect(vanished(.NOTDIR));
    // The one this predicate exists for. `budget.zig` clamps against the
    // ceiling Darwin enforces so registration DECLINES up front rather than
    // meeting EMFILE partway through — but the clamp is a prediction over a
    // commons several daemons share, and a sibling arming in between spends
    // the room it counted. Treating that as "covered" is how a live file goes
    // unwatched while the session vouches for it.
    try t.expect(!vanished(.MFILE));
    try t.expect(!vanished(.NFILE));
    // Present, admitted, searched by the walk — and unreadable to us. Its
    // mode can change back without a single delivery, so a held answer that
    // omitted it would never learn otherwise.
    try t.expect(!vanished(.ACCES));
    try t.expect(!vanished(.PERM));
    try t.expect(!vanished(.NOMEM));
    try t.expect(!vanished(.INTR));
}

/// The key-space root governing `key` — "" for the implicit CWD walk, and
/// the reason a rule written for one named root cannot judge another's
/// entries (`Ignore.scopeToRoot`).
pub fn rootKeyOf(self: anytype, key: []const u8) []const u8 {
    for (self.session.roots) |r| {
        if (std.mem.eql(u8, key, r)) return r;
        if (key.len > r.len and std.mem.startsWith(u8, key, r) and key[r.len] == '/') return r;
    }
    return "";
}
