//! gist resident session — the freshness-watcher barrier suite (ADR-352 rung 2.5).
//!
//! The watcher is a pure *accelerator*: when it proves quiescence the session
//! takes the microsecond clean path; on any event it forces a reconcile. These
//! tests pin that barrier's two halves — an armed, event-free window flips
//! `clean` true (fast path) and a `markDirty` clears it (back to reconcile) —
//! and prove the real `Watcher` lifecycle (`start`/`stop`) is crash-free. All
//! three report-in-the-operation backends arm causal quiescence (Linux inotify ·
//! macOS kqueue, ADR-372 · Windows `ReadDirectoryChangesW`); a target without one
//! stays reconcile-always.
//!
//! It then pins THE PROMISE ITSELF, over the real `Watcher` and a real tree
//! (`rig.zig`). Arming `DirtyLog.exact` is one contract whatever backend arms it,
//! so these cases belong to the facade rather than to a platform: each is a hazard
//! the design had to answer, and each runs unchanged on every backend in
//! `rig.live`, which is the only way two implementations can be held to one
//! promise. A backend's own peculiarities — macOS's descriptor-per-vnode coverage
//! walk, Windows' record-class negotiation — stay in `kqueue_test.zig` and
//! `notify_test.zig` beside it.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../warm/resident.zig");
const rig = @import("rig.zig");
const truth = @import("../warm/truth.zig");
const watch = @import("watch.zig");
const fault = @import("../../../fault.zig");
const portal = @import("../../../portal.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;
const Rig = rig.Rig;

fn makeTree(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) ![]const u8 {
    // `portal.scratchDir` rather than `/tmp`: Windows has no such directory, and
    // this suite's whole point is that the barrier holds on every backend.
    var scratch: [portal.max_path]u8 = undefined;
    const root = try std.fmt.allocPrint(a, "{s}/gist_watch_{s}_{x}", .{ portal.scratchDir(&scratch), tag, seed });
    fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
    try Dir.cwd().createDirPath(io, root);
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.txt", .{root}), .data = "needle here\n" });
    return root;
}

test "barrier: an armed, event-free query flips clean; markDirty clears it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    const root = try makeTree(fixture.allocator(), io, "barrier", @intFromPtr(&threaded));
    defer fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));

    var session = try ResidentSession.init(gpa, io, &.{root});
    defer session.deinit();

    // Simulate a live watcher proving quiescence (no real backend needed to
    // exercise the seqlock the query path reads).
    session.armWatcher();
    try std.testing.expect(!session.seqlock.provenClean()); // nothing proven yet

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const r = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true })).got;
        try std.testing.expectEqual(@as(usize, 1), r.files.len);
    }
    // An armed reconcile with no racing event flips the clean fast path on.
    try std.testing.expect(session.seqlock.provenClean());

    // A filesystem event clears the proof; the next query must reconcile again.
    session.markDirty();
    try std.testing.expect(!session.seqlock.provenClean());

    {
        var q = std.heap.ArenaAllocator.init(gpa);
        defer q.deinit();
        const r = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true })).got;
        try std.testing.expectEqual(@as(usize, 1), r.files.len); // still correct
    }
    try std.testing.expect(session.seqlock.provenClean()); // re-proven clean
}

test "Watcher.start/stop arms only a causally complete backend" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    const root = try makeTree(fixture.allocator(), io, "lifecycle", @intFromPtr(&threaded));
    defer fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));

    var session = try ResidentSession.init(gpa, io, &.{root});
    defer session.deinit();

    var w = watch.Watcher(ResidentSession).init(gpa, io, &session);
    w.start();
    defer w.stop();

    // Arming is environment-dependent on every real backend (inotify watch
    // limits, kqueue descriptor budget, a volume whose driver won't subscribe),
    // so none is asserted to arm here — but arming without the exactness promise
    // would be the dangerous state: a session trusting quiescence from a backend
    // that cannot account for what changed. Windows is in the exact set for the
    // reason `notify.zig` argues: a notify record names the directory entry's own
    // spelling, so its key space is the walk's. A target with no causal backend
    // must stay unarmed.
    switch (builtin.os.tag) {
        .macos, .linux, .windows => if (session.seqlock.armed()) try std.testing.expect(session.dirty_log.exact),
        else => try std.testing.expect(!session.seqlock.armed()),
    }

    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const r = (try session.query(q.allocator(), .{ .pattern = "needle", .mode = .files, .fixed = true })).got;
    try std.testing.expectEqual(@as(usize, 1), r.files.len);
}

// ── the promise every exact backend makes, over a real tree (rig.zig) ──────

test "exact: an in-place content edit is seen — the blindness a dir-only watch has" {
    try rig.withRig("inplace", struct {
        fn run(r: *Rig) !void {
            // No entry is added or removed here, so the parent directory's own
            // metadata never changes. macOS needs the file's descriptor for this;
            // Windows sees it because `LAST_WRITE`/`SIZE` are in the filter and the
            // write closes its handle, flushing the directory entry.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("a.txt", "needle rewritten\n");
            try r.expectScopedOracle("needle");

            // And the reverse direction: the match must LEAVE when the bytes do.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("a.txt", "nothing to find\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: a file created after arming is covered for its LATER edits too" {
    try rig.withRig("newfile", struct {
        fn run(r: *Rig) !void {
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/c.txt", "needle newborn\n");
            try r.expectScopedOracle("needle");

            // The real assertion: edit the newcomer IN PLACE. On macOS this passes
            // only if the directory event registered the new file's own descriptor;
            // on Windows only if the recursive subscription re-posted after
            // delivering the create. A coverage gap answers the create right and
            // this edit stale.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/c.txt", "gone quiet\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: a directory created after arming is covered for in-place edits inside it" {
    try rig.withRig("newdir", struct {
        fn run(r: *Rig) !void {
            try rig.advanceClock(r.tree.io);
            try r.tree.mkdir("sub/fresh/deeper");
            try r.tree.write("sub/fresh/deeper/d.txt", "needle deep\n");
            try r.expectScopedOracle("needle");

            // Coverage must have recursed: an in-place edit two levels below a
            // directory that did not exist at arm time.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/fresh/deeper/d.txt", "silent now\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: a cross-directory move is reported at both ends" {
    try rig.withRig("crossmove", struct {
        fn run(r: *Rig) !void {
            // One rename, two watched directories: the source must stop matching
            // and the destination must start, in one batch.
            try rig.advanceClock(r.tree.io);
            try r.tree.move("sub/b.txt", "two/b.txt");
            try r.expectScopedOracle("needle");

            // The moved file keeps its coverage under the new parent.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("two/b.txt", "moved and muted\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: a case-only rename resolves to exactly one current spelling" {
    try rig.withRig("caserename", struct {
        fn run(r: *Rig) !void {
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/Mixed.txt", "needle cased\n");
            try r.expectScopedOracle("needle");

            // On a case-INSENSITIVE volume (APFS and NTFS both, by default) the two
            // spellings name one file, so a writer-keyed watcher would alias them.
            // This is the case inotify must refuse `exact` for; kqueue keys by
            // descriptor and notify by directory entry, so both represent it. The
            // oracle's ledger holds only the new spelling, so a surviving twin
            // fails the count.
            try rig.advanceClock(r.tree.io);
            try r.tree.move("sub/Mixed.txt", "sub/mixed.txt");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: a deletion leaves the corpus and stays gone" {
    try rig.withRig("delete", struct {
        fn run(r: *Rig) !void {
            try rig.advanceClock(r.tree.io);
            try r.tree.remove("sub/b.txt");
            try r.expectScopedOracle("needle");

            // A retired watch must not resurrect the file, and re-creating the
            // same path must be picked up again.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/b.txt", "needle reborn\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: an entry added to a served root declines to scope, and is still right" {
    try rig.withRig("rootentry", struct {
        fn run(r: *Rig) !void {
            // `delta.resolve` refuses a root-scoped verdict on purpose, so this is
            // the full walk — and the answer must be correct anyway. Pinned because
            // the alternative (enumerating a root subtree serially) would look
            // scoped while costing more than the walk it replaced.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("root_born.txt", "needle at root\n");
            try r.expectFullOracle("needle");

            // The newcomer is covered all the same: an in-place edit of it is
            // scopeable even though its birth was not.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("root_born.txt", "hushed\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: a shed watch set answers from the baseline, and re-arming re-covers the gap" {
    try rig.withRig("shed", struct {
        fn run(r: *Rig) !void {
            try std.testing.expect(r.watcher.held() > 0);

            // Shedding gives every handle back and withdraws all three scoped-path
            // preconditions with the stream that justified them.
            r.watcher.shed();
            try std.testing.expectEqual(@as(usize, 0), r.watcher.held());
            try std.testing.expect(!r.session.seqlock.armed());
            try std.testing.expect(!r.session.dirty_log.exact);
            try std.testing.expect(!r.session.full_pass_done);
            // No backend, so no barrier to cross — a `flushSync` that claimed to
            // have drained one would be a licence to trust a dead stream.
            try std.testing.expect(!r.watcher.flushSync());

            // The adverse case: an IN-PLACE content edit with nothing watching.
            // Only the reconcile-always baseline can catch it — which is exactly
            // what shedding falls back to.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/b.txt", "needle rewritten while shed\n");
            try r.expectOracle("needle");

            // And one more change inside the shed window that NOTHING has observed
            // by the time the watcher comes back.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/b.txt", "quiet while shed\n");

            r.watcher.start();
            try std.testing.expect(r.session.seqlock.armed());
            try std.testing.expect(r.watcher.held() > 0);
            // The first pass under the new stream must be the FULL one. A scoped
            // pass here would drain an empty note set — nothing was noted while
            // shed — and answer the disk staler than it is, which is precisely what
            // a `full_pass_done` surviving the shed would allow.
            try r.expectFullOracle("needle");
            try std.testing.expect(r.session.full_pass_done);

            // The rebuilt set is a real one, not a husk: an in-place edit scopes
            // again, so re-arming restored coverage rather than just the flag.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/b.txt", "needle back\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "exact: stop() releases the watch set and the session survives it" {
    if (comptime !rig.live) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try rig.Tree.init(fixture.allocator(), io, "teardown", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle here\n");

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    watcher.start();
    watcher.stop();
    // A stopped watcher must not leave a barrier that claims to have drained
    // anything, and the session must still answer (reconcile-always).
    try std.testing.expect(!watcher.flushSync());
    try truth.expectFiles(&session, &tree, gpa, "needle");
    watcher.stop(); // idempotent — the deinit path runs twice in fail-fast callers
}
