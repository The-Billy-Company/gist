//! gist resident session — the epoch's vouch, driven on whichever exact backend
//! the platform actually ships.
//!
//! The answer keep rests on one borrowed premise: two runs reading the same
//! epoch saw the same corpus. Neither side of that sentence is tested by the
//! suites that own the two halves. `keep.zig` is handed an epoch and does
//! honest bookkeeping under it — offered 7 and 8 by hand, it cannot know
//! whether the tree moved between them. `annals.zig` arms its own ledger and
//! feeds itself synthetic `note` calls — it proves the arithmetic, never that
//! anything real drives it. The premise lives in the gap between: a backend
//! that must arm the ledger, deliver into it, and surrender it correctly.
//!
//! Three bugs lived in that gap, and all were invisible to every existing test.
//! `inotify` armed the seqlock and the dirty log and never armed the annals, so
//! `epoch()` answered null and the keep was silently dead on every Linux daemon
//! — unreachable by a suite that arms the ledger by hand, and unreachable by
//! `kqueue_test.zig`, which boots a real watcher but is macOS-only by
//! construction. And losing coverage poisoned only the seqlock: reconciling
//! kept protecting the QUERY while the stamp stood still under a moving tree,
//! so an answer already HELD read fresh indefinitely. The same shape hid once
//! more on the macOS side, where an event that named no watch of ours raised
//! doubt in the dirty log alone and left the ledger vouching an epoch it had
//! never counted that change into.
//!
//! So this file grades the premise itself, against a real watcher over a real
//! tree, on macOS and Linux alike:
//!
//!   1. LIVENESS — a backend that arms exact must vouch an epoch. Everything
//!      above this is correct without it; the warm tier is just quietly gone.
//!   2. SAFETY — across a randomized mutation sequence, two samples reading the
//!      same non-null epoch must have read the same bytes. Only that direction
//!      is asserted: an epoch that moves without a content change is merely
//!      conservative, and costs a recompute rather than correctness.
//!   3. SURRENDER — the two ways coverage ends. Lost coverage must make the
//!      epoch decline outright; a deliberate shed must move it past anything
//!      held under the retiring stream. Both are graded THROUGH the keep,
//!      because a bit on a struct is not the hazard — a served stale answer is.
//!   4. DOUBT — coverage survives, but one delivery could not be placed. The
//!      ledger must lose the WHICH and still count the WHETHER, because this is
//!      the one shape where neither protection holds alone: the reconcile's full
//!      walk saves the QUERY and does nothing for an answer already held.
//!
//! The oracle never runs the engine: it is a re-read of the fixture's own live
//! ledger, so a backend bug cannot grade its own homework (sins.mdc Sin #2).

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../warm/resident.zig");
const keepmod = @import("../answer/keep.zig");
const watch = @import("../watch/watch.zig");
const fault = @import("../../../fault.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// Platforms with a per-file-exact backend that can arm the ledger. Elsewhere
/// an unarmed session is the documented fail-closed posture, not a failure.
const exact_backend = switch (builtin.os.tag) {
    .macos, .linux => true,
    else => false,
};

/// A throwaway on-disk tree plus the live-file ledger the oracle re-reads.
/// Mutators keep the ledger in step, so the digest always describes the disk
/// rather than the engine's belief about it.
const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,
    live: std.ArrayList([]const u8) = .empty,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Tree {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_vouch_{s}_{x}", .{ tag, seed });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Tree) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
        self.live.deinit(self.a);
    }

    fn abs(self: *Tree, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }

    fn mkdir(self: *Tree, rel: []const u8) !void {
        try Dir.cwd().createDirPath(self.io, try self.abs(rel));
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        for (self.live.items) |n| if (std.mem.eql(u8, n, rel)) return;
        try self.live.append(self.a, try self.a.dupe(u8, rel));
    }

    fn remove(self: *Tree, rel: []const u8) !void {
        try Dir.cwd().deleteFile(self.io, try self.abs(rel));
        self.dropLive(rel);
    }

    /// A real `rename(2)`, so the kernel reports what it reports in production.
    fn move(self: *Tree, from: []const u8, to: []const u8) !void {
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

    /// Content digest of the walked corpus, computed WITHOUT the engine: every
    /// live path and its bytes, in a fixed order. Two instants sharing a digest
    /// held the same corpus, which is exactly the claim an epoch makes.
    fn digest(self: *Tree) !u64 {
        const order = try self.a.dupe([]const u8, self.live.items);
        defer self.a.free(order);
        std.mem.sort([]const u8, order, {}, lessPath);
        var h = std.hash.Wyhash.init(0);
        for (order) |rel| {
            h.update(rel);
            const bytes = Dir.cwd().readFileAlloc(self.io, try self.abs(rel), self.a, .limited(1 << 20)) catch continue;
            defer self.a.free(bytes);
            h.update(bytes);
        }
        return h.final();
    }
};

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// What the ledger vouched, paired with what was actually on disk when it did.
const Sample = struct { epoch: ?u64, digest: u64 };

/// A live session, its real watcher, and the tree beneath them.
const Rig = struct {
    session: *ResidentSession,
    watcher: *watch.Watcher(ResidentSession),
    tree: *Tree,

    /// Null when the backend legitimately declined to arm exact (descriptor
    /// budget, a `/tmp` shape it will not cover). The caller skips rather than
    /// grading an unarmed run as if it were a verdict.
    fn boot(
        session: *ResidentSession,
        watcher: *watch.Watcher(ResidentSession),
        tree: *Tree,
    ) ?Rig {
        watcher.start();
        if (!session.seqlock.armed() or !session.dirty_log.exact) return null;
        return .{ .session = session, .watcher = watcher, .tree = tree };
    }

    /// Cross the read-your-writes barrier where `serve.zig` crosses it, then
    /// read the ledger and the disk as one instant.
    fn sample(self: *Rig) !Sample {
        _ = self.watcher.flushSync();
        return .{ .epoch = self.session.annals.epoch(), .digest = try self.tree.digest() };
    }
};

/// A short sleep so a coarse filesystem clock records a strictly-newer
/// mtime/ctime — the discipline `kqueue_test.zig` and `scoped_test.zig` keep.
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

/// Mutations land under a subdirectory (a root entry is the documented
/// full-walk shape) and vary content so a digest actually moves.
fn seedTree(tree: *Tree) !void {
    try tree.mkdir("sub");
    try tree.write("sub/a.txt", "needle here\n");
    try tree.write("sub/b.txt", "quiet here\n");
}

/// One random filesystem mutation, chosen from the shapes a backend must
/// report differently: a newcomer, an in-place edit no directory event can
/// see, a deletion, and a rename that touches two entries at once.
fn mutate(rig: *Rig, rng: std.Random, step: usize) !void {
    const tree = rig.tree;
    try advanceClock(tree.io);
    const pick = rng.uintLessThan(u8, 100);
    const live = tree.live.items.len;

    if (pick < 35 or live == 0) {
        const rel = try std.fmt.allocPrint(tree.a, "sub/n{d}.txt", .{step});
        return tree.write(rel, if (rng.boolean()) "needle added\n" else "silent add\n");
    }
    const victim = tree.live.items[rng.uintLessThan(usize, live)];
    if (pick < 70) {
        const body = try std.fmt.allocPrint(tree.a, "needle rev {d}\n", .{step});
        return tree.write(victim, body); // in-place edit: only a file descriptor sees this
    }
    if (pick < 85) return tree.remove(victim);
    const to = try std.fmt.allocPrint(tree.a, "sub/m{d}.txt", .{step});
    return tree.move(victim, to);
}

/// Boilerplate every case shares. `body` receives a booted rig, or the case
/// skips visibly when the backend declined to arm.
fn withRig(tag: []const u8, body: *const fn (*Rig, std.mem.Allocator) anyerror!void) !void {
    if (comptime !exact_backend) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, tag, @intFromPtr(&threaded));
    defer tree.deinit();
    try seedTree(&tree);

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    defer watcher.stop();

    var rig = Rig.boot(&session, &watcher, &tree) orelse return error.SkipZigTest;
    try body(&rig, gpa);
}

test "vouch: a backend that arms exact must actually vouch an epoch" {
    try withRig("live", struct {
        fn run(rig: *Rig, _: std.mem.Allocator) !void {
            // Everything the older suites assert is already true here: the
            // seqlock armed, the dirty log promises exactness. Both held on
            // Linux while the annals sat unarmed behind them, so `epoch()`
            // answered null and the keep was never offered — a whole tier
            // gone, with no failing assertion anywhere in the tree.
            try std.testing.expect(rig.session.annals.epoch() != null);

            // And it must still vouch after real deliveries, not merely at rest.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/a.txt", "needle rewritten\n");
            const after = try rig.sample();
            try std.testing.expect(after.epoch != null);
        }
    }.run);
}

test "vouch: one epoch never spans two different corpora" {
    try withRig("safety", struct {
        fn run(rig: *Rig, gpa: std.mem.Allocator) !void {
            var prng = std.Random.DefaultPrng.init(0x5AFE7E);
            const rng = prng.random();

            var seen: std.ArrayList(Sample) = .empty;
            defer seen.deinit(gpa);
            try seen.append(gpa, try rig.sample());

            for (0..20) |step| {
                try mutate(rig, rng, step);
                const now = try rig.sample();
                // The unsound direction, and only it: an epoch that repeats
                // must describe the same bytes. An epoch that moves without a
                // content change is conservative and costs a recompute.
                for (seen.items) |prior| {
                    const a = prior.epoch orelse continue;
                    const b = now.epoch orelse continue;
                    if (a != b) continue;
                    try std.testing.expectEqual(prior.digest, now.digest);
                }
                try seen.append(gpa, now);
            }

            // A run whose epoch never moved satisfies the invariant vacuously —
            // and is precisely the dead-keep bug wearing a passing test. Require
            // the ledger to have actually counted the tree it watched.
            var moved: usize = 0;
            for (seen.items[1..], seen.items[0 .. seen.items.len - 1]) |now, prev| {
                const a = now.epoch orelse continue;
                const b = prev.epoch orelse continue;
                if (a != b) moved += 1;
            }
            try std.testing.expect(moved > 0);
        }
    }.run);
}

test "vouch: lost coverage stops the epoch being vouched at all" {
    try withRig("blind", struct {
        fn run(rig: *Rig, gpa: std.mem.Allocator) !void {
            var keep = keepmod.Keep.init(gpa);
            defer keep.deinit();

            const held = rig.session.annals.epoch() orelse return error.ExpectedVouch;
            keep.retain("q", held, 0, "answer as of the held epoch\n");

            // The backend loses coverage it cannot win back: an inotify queue
            // overflow, or a subtree that would not re-watch.
            rig.session.markDoubtForever();

            // Changes will now go unseen, so no later reading of the stamp
            // means anything — the one state where the epoch must decline
            // rather than stand still.
            try std.testing.expect(rig.session.annals.epoch() == null);

            // Why that has to be the ledger's job, stated as the keep sees it:
            // offered the pre-loss epoch the keep still hits, faithfully, having
            // no way to know the stamp stopped counting. The keep cannot protect
            // itself, so the epoch supply must refuse — which is the fix.
            try advanceClock(rig.tree.io);
            try rig.tree.write("sub/b.txt", "needle after the blinding\n");
            _ = rig.watcher.flushSync();
            try std.testing.expect(keep.recall("q", held) == .hit);
            try std.testing.expect(rig.session.annals.epoch() == null);
        }
    }.run);
}

test "vouch: a delivery nobody could place retires answers held before it" {
    try withRig("doubt", struct {
        fn run(rig: *Rig, gpa: std.mem.Allocator) !void {
            var keep = keepmod.Keep.init(gpa);
            defer keep.deinit();

            _ = rig.watcher.flushSync(); // settle, so the doubt is what moves the stamp
            const held = rig.session.annals.epoch() orelse return error.ExpectedVouch;
            keep.retain("q", held, 0, "answer as of the held epoch\n");
            // The ledger can still say WHICH files moved, which is the half the
            // doubt below takes away.
            const floor = rig.session.annals.floor_ns;
            var before = rig.session.annals.since(gpa, floor) orelse return error.ExpectedPathAnswer;
            before.deinit(gpa);

            // An event arrives that names no watch of ours: a kqueue `EV_ERROR`
            // or a stale `udata`, an inotify record whose wd is already gone.
            // Coverage is intact — this is doubt, not blindness — but a change
            // WAS observed, and this is the one shape where neither of the
            // session's two protections applies on its own.
            rig.watcher.noteUnattributable();

            // Coverage is intact, so the epoch is still vouchable …
            const after = rig.session.annals.epoch() orelse return error.DoubtMustNotBlind;
            // … and it must have counted the change it could not place. Without
            // that, the stamp stands still across a file the session never
            // re-examined, and the keep hands back a stale answer — reconciling
            // protects the QUERY, never an answer already held.
            try std.testing.expect(after > held);
            try std.testing.expect(keep.recall("q", after) == .stale);

            // The other half, in the other direction: WHICH is gone for good, so
            // a one-shot amend declines to the stat walk rather than trusting a
            // path set missing the delivery nobody could place.
            try std.testing.expect(rig.session.annals.since(gpa, floor) == null);
        }
    }.run);
}

test "vouch: a deliberate shed retires answers held under the retiring stream" {
    try withRig("shed", struct {
        fn run(rig: *Rig, gpa: std.mem.Allocator) !void {
            var keep = keepmod.Keep.init(gpa);
            defer keep.deinit();

            _ = rig.watcher.flushSync(); // settle, so the shed is what moves the stamp
            const held = rig.session.annals.epoch() orelse return error.ExpectedVouch;
            keep.retain("q", held, 0, "answer as of the held epoch\n");

            // An idle daemon hands its watches back. The window itself is
            // fail-closed — no descriptor, no vouch — but an answer held BEFORE
            // it would survive the re-arm against a stamp that never counted
            // whatever changed while nobody was looking.
            rig.session.disarmWatcher();

            // A shed is deliberate and reversible, so unlike lost coverage the
            // ledger keeps answering …
            const after = rig.session.annals.epoch() orelse return error.ShedMustNotBlind;
            // … but it must answer something new, or the held answer outlives
            // the stream that vouched for it.
            try std.testing.expect(after > held);
            try std.testing.expect(keep.recall("q", after) == .stale);
        }
    }.run);
}
