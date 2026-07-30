//! The harness every exact-backend barrier suite drives (ADR-372).
//!
//! `scoped_test.zig` attacks the scoped reconcile by SIMULATING a backend's
//! three-call contract (`armExact` → `note` → `markDirty`). This module removes
//! the simulation: it boots the real `Watcher` over a real tree, crosses the real
//! `flushSync` barrier exactly where `serve.zig` crosses it (before dispatch), and
//! grades every answer against an independent on-disk oracle (`warm/truth.zig` — a
//! naive re-read that never runs the engine, so a backend bug cannot grade its own
//! homework).
//!
//! It lives apart from the suites because the CONTRACT is one contract. A backend
//! that arms `DirtyLog.exact` has promised the same six things on every platform —
//! an in-place edit is seen, a newcomer is covered for its later edits too, a
//! cross-directory move lands on both ends, a case-only rename resolves to one
//! spelling, a deletion stays gone, a served root declines to scope and is right
//! anyway — and the only honest way to hold two backends to one promise is to make
//! them run the same cases. A per-backend copy of this rig would let the promises
//! drift apart silently, which is exactly the fork `relate echoes --as copies`
//! exists to find.
//!
//! What stays in a per-backend suite is what is genuinely per-backend: macOS's
//! descriptor-per-vnode coverage walk and its ignore-rule re-derivation
//! (`kqueue_test.zig`), Windows' record-class negotiation and buffer-overflow
//! doubt (`notify_test.zig`).
//!
//! Every scopeable case also asserts the reconcile was SCOPED, because an answer
//! that is merely correct proves nothing here — a silent fall back to the full walk
//! would be correct too, and would make the whole barrier vacuous. Mutations
//! therefore land under a subdirectory: the root itself is the documented full-walk
//! shape, pinned by its own case rather than dodged.

const std = @import("std");
const builtin = @import("builtin");
const fault = @import("../../../fault.zig");
const portal = @import("../../../portal.zig");
const resident = @import("../warm/resident.zig");
const truth = @import("../warm/truth.zig");
const watch = @import("watch.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// Where this rig runs, and why each member is here rather than a blanket
/// "wherever a watcher exists".
///
///   * macOS — `kqueue.zig`, exact by descriptor keying, proven by these cases
///     since ADR-372.
///   * Windows — `notify.zig`, exact by directory-entry keying; proven by these
///     same cases on the native CI lane, which is the only place a Windows kernel
///     exists to answer them.
///
/// Linux is deliberately NOT in the set yet, and saying so is the point: nobody
/// has run this rig against `inotify.zig`, whose watches neither recurse nor
/// coalesce, so adding it here would either pass vacuously or fail for reasons
/// that have nothing to do with the backend under review. Widening it is its own
/// pass with its own evidence, not a line changed in passing.
pub const live = switch (builtin.os.tag) {
    .macos, .windows => true,
    else => false,
};

/// A throwaway on-disk tree plus the live-file ledger the oracle re-reads. Only
/// the fields `truth.zig` names are public surface; the mutators keep the ledger
/// in step so the oracle always describes the disk, never the engine's belief.
pub const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,
    live: std.ArrayList([]const u8) = .empty,

    pub fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Tree {
        // `portal.scratchDir`, not `/tmp`: Windows has no such directory. Slashed
        // because every path in this rig is compared as a STRING against the
        // session's answers, and those are `/`-spelled on every platform by
        // declared design — a `C:\…\Temp` prefix would make the oracle and the
        // engine disagree about spelling rather than about content. Win32
        // normalizes `/` itself, so the tree still opens.
        var buf: [portal.max_path]u8 = undefined;
        const scratch = try a.dupe(u8, portal.scratchDir(&buf));
        if (comptime std.fs.path.sep != '/') std.mem.replaceScalar(u8, scratch, std.fs.path.sep, '/');
        const root = try std.fmt.allocPrint(a, "{s}/gist_watch_{s}_{x}", .{ scratch, tag, seed });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    pub fn deinit(self: *Tree) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
        self.live.deinit(self.a);
    }

    pub fn abs(self: *Tree, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }

    pub fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        try self.admit(rel);
    }

    /// Write a file an ignore rule keeps OUT of the walked set: it exists on
    /// disk, so a watcher that ignores the rules would find it, and the oracle
    /// must not expect it until a rule change admits it.
    pub fn writeIgnored(self: *Tree, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        self.dropLive(rel);
    }

    /// Record that `rel` is (now) part of the walked set.
    pub fn admit(self: *Tree, rel: []const u8) !void {
        for (self.live.items) |n| if (std.mem.eql(u8, n, rel)) return;
        try self.live.append(self.a, try self.a.dupe(u8, rel));
    }

    pub fn mkdir(self: *Tree, rel: []const u8) !void {
        try Dir.cwd().createDirPath(self.io, try self.abs(rel));
    }

    pub fn remove(self: *Tree, rel: []const u8) !void {
        try Dir.cwd().deleteFile(self.io, try self.abs(rel));
        self.dropLive(rel);
    }

    /// A real rename, so the kernel reports exactly what it reports in production
    /// (on macOS both directories plus the moved vnode; on Windows a
    /// `RENAMED_OLD_NAME`/`RENAMED_NEW_NAME` pair).
    pub fn move(self: *Tree, from: []const u8, to: []const u8) !void {
        try Dir.renameAbsolute(try self.abs(from), try self.abs(to), self.io);
        self.dropLive(from);
        try self.live.append(self.a, try self.a.dupe(u8, to));
    }

    fn dropLive(self: *Tree, rel: []const u8) void {
        for (self.live.items, 0..) |n, i| if (std.mem.eql(u8, n, rel)) {
            _ = self.live.orderedRemove(i);
            return;
        };
    }
};

/// One live session + its real watcher over `tree`, already through the covering
/// full pass a scoped reconcile is only sound downstream of. `boot` returns null
/// when the watcher did not arm exact — a machine whose descriptor budget or whose
/// volume driver refuses coverage is a legitimate fail-closed outcome, not a test
/// failure, and the caller skips rather than asserting against the baseline.
pub const Rig = struct {
    session: *ResidentSession,
    watcher: *watch.Watcher(ResidentSession),
    tree: *Tree,
    gpa: std.mem.Allocator,

    pub fn boot(
        gpa: std.mem.Allocator,
        session: *ResidentSession,
        watcher: *watch.Watcher(ResidentSession),
        tree: *Tree,
    ) !?Rig {
        watcher.start();
        if (!session.seqlock.armed() or !session.dirty_log.exact) return null;
        var rig = Rig{ .session = session, .watcher = watcher, .tree = tree, .gpa = gpa };
        // The covering first pass: full by construction (`full_pass_done` is
        // false until it completes), which is exactly why arming
        // mid-registration is sound.
        try rig.expectOracle("needle");
        try std.testing.expect(session.full_pass_done);
        return rig;
    }

    /// Cross the read-your-writes barrier the way `serve.zig` does — drain the
    /// queue, then answer — and assert the answer matched the disk AND that the
    /// reconcile behind it was scoped, not a full walk.
    pub fn expectScopedOracle(self: *Rig, needle: []const u8) !void {
        const before = self.session.scoped_reconciles.load(.monotonic);
        try std.testing.expect(self.watcher.flushSync());
        try self.expectOracle(needle);
        try std.testing.expect(self.session.scoped_reconciles.load(.monotonic) > before);
    }

    /// The same barrier crossing for a mutation the resolver declines to scope:
    /// the answer must still match the disk, via the full walk.
    pub fn expectFullOracle(self: *Rig, needle: []const u8) !void {
        const before = self.session.scoped_reconciles.load(.monotonic);
        try std.testing.expect(self.watcher.flushSync());
        try self.expectOracle(needle);
        try std.testing.expectEqual(before, self.session.scoped_reconciles.load(.monotonic));
    }

    pub fn expectOracle(self: *Rig, needle: []const u8) !void {
        try truth.expectFiles(self.session, self.tree, self.gpa, needle);
    }
};

/// A short sleep so a coarse filesystem clock records a strictly-newer
/// mtime/ctime past the session's freshness cursor (the same discipline
/// `scoped_test.zig` keeps). Comfortably past both granularities in play: HFS+/
/// APFS at 1 ns but with a coarser update cadence, and Windows' ~15.6 ms system
/// clock tick.
pub fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

/// The tree every case starts from: one matching file at the root, one in a
/// subdirectory, and a second watched directory that exists BEFORE arming, so a
/// cross-directory move has two scopeable endpoints (a root entry would decline
/// to scope).
pub fn seedTree(tree: *Tree) !void {
    try tree.write("a.txt", "needle here\n");
    try tree.mkdir("sub");
    try tree.write("sub/b.txt", "needle in sub\n");
    try tree.mkdir("two");
    try tree.write("two/z.txt", "quiet here\n");
}

pub fn withRig(tag: []const u8, body: *const fn (*Rig) anyerror!void) !void {
    return withSeededRig(tag, seedTree, body);
}

/// Boilerplate every case shares: a threaded `Io`, a fixture arena, a `seed`ed
/// tree, a session, and a watcher. `body` receives a booted rig, or is skipped
/// when the watcher legitimately declined to arm.
pub fn withSeededRig(
    tag: []const u8,
    seed: *const fn (*Tree) anyerror!void,
    body: *const fn (*Rig) anyerror!void,
) !void {
    if (comptime !live) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, tag, @intFromPtr(&threaded));
    defer tree.deinit();
    try seed(&tree);

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    defer watcher.stop();

    var rig = (try Rig.boot(gpa, &session, &watcher, &tree)) orelse return;
    try body(&rig);
}
