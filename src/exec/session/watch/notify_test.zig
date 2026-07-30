//! gist resident session — what is Windows' alone about the notify barrier
//! (ADR-352 rung 2.5, ADR-372).
//!
//! The promises every exact backend makes run over `rig.zig` from
//! `watch_test.zig`, unchanged on this platform — that is the point of extracting
//! them, and it is what actually holds this backend to the bar macOS already
//! cleared. What is left here is what only `ReadDirectoryChangesW` has:
//!
//!   - a RECURSIVE subscription, so `held()` must not scale with tree depth. The
//!     macOS backend's per-vnode price is the reason its budget logic exists; if
//!     this one silently grew a handle per directory it would inherit a problem it
//!     was supposed not to have, and the shared cases above would still pass.
//!   - a per-root BUFFER that overflows where inotify has a queue and kqueue has
//!     nothing. Overflow means events were discarded by the system, which is
//!     permanent doubt — and the fail-closed direction has to be provable, not
//!     asserted in a comment.
//!   - a record class NEGOTIATED at arm time (`NotifyExtended`, else `Notify`).
//!     Both parses must produce a working session, because which one a volume
//!     grants is not the caller's choice.
//!   - the annals ledger stamped from the RECORD's own timestamps rather than the
//!     drain clock, which is the one thing this backend does better than both
//!     POSIX arms and therefore the one most worth pinning.
//!
//! Windows-only by construction; every case returns immediately elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../warm/resident.zig");
const rig = @import("rig.zig");
const truth = @import("../warm/truth.zig");
const watch = @import("watch.zig");

const ResidentSession = resident.ResidentSession;
const Rig = rig.Rig;
const Tree = rig.Tree;
const is_windows = builtin.os.tag == .windows;

test "notify: a recursive subscription costs one handle per root, not per directory" {
    if (comptime !is_windows) return;
    try rig.withSeededRig("nt_recursive", struct {
        fn seed(tree: *Tree) !void {
            try rig.seedTree(tree);
            // Depth the macOS backend would pay a descriptor per level for.
            try tree.mkdir("sub/a/b/c/d/e");
            try tree.write("sub/a/b/c/d/e/deep.txt", "needle at depth\n");
        }
    }.seed, struct {
        fn run(r: *Rig) !void {
            // One root: its directory handle, the completion port, the stop event.
            // A backend that had quietly become per-directory would report far more
            // and still answer every shared case correctly, which is exactly why
            // this is asserted as a number rather than inferred from behavior.
            try std.testing.expectEqual(@as(usize, 3), r.watcher.held());

            // And the cheap set really does cover the deep leaf: an in-place edit
            // six levels down, with no per-directory registration behind it.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/a/b/c/d/e/deep.txt", "hushed at depth\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "notify: the annals epoch advances from a delivery, and a held answer retires with it" {
    if (comptime !is_windows) return;
    try rig.withRig("nt_annals", struct {
        fn run(r: *Rig) !void {
            // A single-root session arms the ledger (one unambiguous strip
            // prefix); null is unarmed-or-blind, and there is nothing to observe
            // in either state.
            const before = r.session.annals.epoch() orelse return;

            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/b.txt", "needle stamped\n");
            try std.testing.expect(r.watcher.flushSync());

            // The epoch is what a HELD answer is trusted on — it is never
            // re-derived — so a delivery that moved bytes and not the epoch is the
            // shape that outlives its own truth.
            const after = r.session.annals.epoch() orelse return;
            try std.testing.expect(after != before);
            try r.expectOracle("needle");
        }
    }.run);
}

test "notify: a skipped subtree's churn does not dirty the session" {
    if (comptime !is_windows) return;
    try rig.withSeededRig("nt_skipped", struct {
        fn seed(tree: *Tree) !void {
            try rig.seedTree(tree);
            // A `WatchTree` subscription has no way to decline a subtree, so the
            // filtering is `notify.zig`'s own. Without it every object write in a
            // `git` operation would dirty the session and cost it the fast path,
            // which is the difference between an accelerator and a tax.
            try tree.mkdir("node_modules/pkg");
            try tree.writeIgnored("node_modules/pkg/index.js", "needle vendored\n");
        }
    }.seed, struct {
        fn run(r: *Rig) !void {
            // Correctly absent to begin with: the walk never admitted it.
            try r.expectOracle("needle");

            try rig.advanceClock(r.tree.io);
            try r.tree.writeIgnored("node_modules/pkg/index.js", "needle churned\n");
            try std.testing.expect(r.watcher.flushSync());

            // Churn inside a skipped subtree is not a corpus change, so the session
            // must still be able to prove itself clean. A note here would be
            // harmless to correctness and fatal to the point of the fast path.
            try std.testing.expect(r.session.seqlock.provenClean());
            try r.expectOracle("needle");
        }
    }.run);
}

test "notify: an overflowed buffer retires the fast path for good, and still answers" {
    if (comptime !is_windows) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "nt_overflow", @intFromPtr(&threaded));
    defer tree.deinit();
    try rig.seedTree(&tree);

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    defer watcher.stop();
    watcher.start();
    if (!session.seqlock.armed()) return;

    // Provoked rather than mocked: enough entries in one un-drained window that
    // their records cannot fit the 64 KiB buffer, which is how the system reports
    // a lost batch in production. Names are long on purpose — a record's cost is
    // its name — so this needs hundreds of files rather than tens of thousands.
    // `flushSync` is deliberately NOT crossed inside the loop; draining is what
    // would prevent the overflow.
    var name: [200]u8 = undefined;
    for (0..600) |i| {
        const rel = try std.fmt.bufPrint(&name, "sub/overflow_{d:0>4}_{s}.txt", .{ i, "p" ** 150 });
        try tree.write(rel, "needle in the flood\n");
    }
    try std.testing.expect(watcher.flushSync());

    // The contract is one-way: a session that has lost events can never prove
    // quiescence again, however quiet the tree goes afterwards. If the flood did
    // NOT overflow on this machine the session is simply still clean, which is not
    // a failure — so the doubt is asserted only once it has actually been declared.
    const doubted = !session.seqlock.armed();

    // Either way the answer must match the disk, which is the only promise that
    // was ever unconditional. Including for a change made after the flood, with
    // the fast path gone.
    try truth.expectFiles(&session, &tree, gpa, "needle");
    try rig.advanceClock(io);
    try tree.write("sub/b.txt", "needle after the flood\n");
    _ = watcher.flushSync();
    try truth.expectFiles(&session, &tree, gpa, "needle");

    if (doubted) {
        // And it stays gone — a later quiet reconcile must not re-arm it.
        try std.testing.expect(!session.seqlock.provenClean());
    }
}

test "notify: the plain record class arms and answers exactly like the extended one" {
    if (comptime !is_windows) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "nt_plain", @intFromPtr(&threaded));
    defer tree.deinit();
    try rig.seedTree(&tree);

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    defer watcher.stop();

    // Which class a volume grants is not the caller's choice, so the fallback is
    // reached here the way a refusing filesystem would reach it: the flag is
    // cleared before arming, and every parse offset, the file/directory decision,
    // and the timestamp source follow it. A test that only ever ran the extended
    // parse would leave the other half of `records` unexecuted everywhere.
    watcher.notify_extended = false;
    watcher.start();
    if (!session.seqlock.armed()) return;
    try std.testing.expect(!watcher.notify_extended);
    try std.testing.expect(session.dirty_log.exact); // exactness is not the class's to grant

    var r = Rig{ .session = &session, .watcher = &watcher, .tree = &tree, .gpa = gpa };
    try r.expectOracle("needle");
    try std.testing.expect(session.full_pass_done);

    // An in-place edit is the case the plain class is weakest at — no attributes
    // in the record, so every entry is treated as a file and stamped with the
    // drain clock — and it must still scope and still match the disk.
    try rig.advanceClock(io);
    try tree.write("sub/b.txt", "needle without attributes\n");
    try r.expectScopedOracle("needle");

    try rig.advanceClock(io);
    try tree.mkdir("sub/born");
    try tree.write("sub/born/x.txt", "needle newborn plain\n");
    try r.expectScopedOracle("needle");
}
