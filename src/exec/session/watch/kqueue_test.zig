//! gist resident session — what is macOS's alone about the kqueue barrier (ADR-372).
//!
//! The promises every exact backend makes — an in-place edit is seen, a newcomer
//! is covered for its later edits, a cross-directory move lands on both ends, a
//! case-only rename resolves to one spelling, a deletion stays gone, a served root
//! declines to scope and is right anyway, a shed set falls back to the baseline —
//! live in `watch_test.zig` and run over `rig.zig` on every backend that arms
//! exact. Duplicating them here would let one platform's copy drift.
//!
//! What is left is what only this backend has, and each case is a hazard the
//! design had to answer rather than a paraphrase of the code:
//!
//!   - the WATCH SET is selected by the walk's own ignore policy, because macOS
//!     pays one descriptor per file (25k admitted here against 193k with
//!     gitignored output kept). So an ignore-rule edit has to re-derive the
//!     policy AND the set — a fresh policy alone leaves a newly-admitted file
//!     unwatched, which answers staler than the disk while claiming clean.
//!   - a vnode it cannot OPEN is a delivery it cannot place, and one of those is
//!     enough to refuse the whole session. No other backend has this shape:
//!     inotify and `ReadDirectoryChangesW` both register against a directory and
//!     never open the entries.
//!
//! macOS-only by construction; every case returns immediately elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../warm/resident.zig");
const rig = @import("rig.zig");
const truth = @import("../warm/truth.zig");
const watch = @import("watch.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;
const Rig = rig.Rig;
const Tree = rig.Tree;
const is_macos = builtin.os.tag == .macos;

test "kqueue: an ignore-rule edit re-derives the admitted set AND the watch set" {
    if (comptime !is_macos) return;
    try rig.withSeededRig("kq_ignorerule", struct {
        fn seed(tree: *Tree) !void {
            try rig.seedTree(tree);
            // The rule file is hidden, so the visibility rule alone would leave
            // it unwatched — and an edit to it would change what the walk admits
            // with nothing to report it.
            try tree.write(".gitignore", "shy.txt\n");
            try tree.writeIgnored("sub/shy.txt", "needle unseen\n");
        }
    }.seed, struct {
        fn run(r: *Rig) !void {
            // On disk, matching, and correctly absent: an ignored file is not a
            // member of the walked set, so it is not watched either.
            try r.expectOracle("needle");

            // Rewrite the rule. The path is `.semantics` to `delta.classify`, so
            // the answer comes from the full walk — the cheap half of the fix.
            try rig.advanceClock(r.tree.io);
            try r.tree.write(".gitignore", "nothing.txt\n");
            try r.tree.admit("sub/shy.txt");
            try r.expectFullOracle("needle");

            // The half that a fresh policy alone would not buy: the newly-admitted
            // file must now be WATCHED. Its bytes change without its directory
            // changing, so a watch set still selected by the OLD rules answers
            // this staler than the disk while claiming the session is clean.
            try rig.advanceClock(r.tree.io);
            try r.tree.write("sub/shy.txt", "quiet at last\n");
            try r.expectScopedOracle("needle");
        }
    }.run);
}

test "kqueue: a delivery that cannot be placed leaves the session unarmed" {
    if (comptime !is_macos) return;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "kq_unplaceable", @intFromPtr(&threaded));
    defer tree.deinit();
    try tree.write("a.txt", "needle here\n");
    // On disk, hidden by no rule, searched by the walk — and impossible to
    // open. It stands in for a spent descriptor table, which refuses at the
    // same call and cannot be provoked on demand. Kept out of the oracle's
    // ledger because nothing can read it, engine or oracle.
    try tree.writeIgnored("locked.txt", "nothing to find\n");
    const lockedz = try std.posix.toPosixPath(try tree.abs("locked.txt"));
    if (std.c.chmod(&lockedz, 0) != 0) return; // cannot stage the hazard here
    defer _ = std.c.chmod(&lockedz, 0o644);
    const probe = std.c.open(&lockedz, .{ .ACCMODE = .RDONLY });
    if (probe >= 0) { // running as root — the hazard does not exist
        _ = std.c.close(probe);
        return;
    }

    // Control first: the same shape WITHOUT the hazard has to arm on this
    // machine, or the assertion below is vacuous — a box whose descriptor
    // budget refuses coverage never arms for reasons of its own.
    {
        var clean = try Tree.init(fixture.allocator(), io, "kq_unplaceable_ctl", @intFromPtr(&fixture));
        defer clean.deinit();
        try clean.write("a.txt", "needle here\n");
        var cs = try ResidentSession.init(gpa, io, &.{clean.root});
        defer cs.deinit();
        var cw = watch.Watcher(ResidentSession).init(gpa, io, &cs);
        defer cw.stop();
        cw.start();
        if (!cs.seqlock.armed()) return;
    }

    var session = try ResidentSession.init(gpa, io, &.{tree.root});
    defer session.deinit();
    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    defer watcher.stop();
    watcher.start();

    // One admitted file it could not place a delivery on is enough: claiming
    // quiescence for the REST is how an edit to a watched file goes
    // undelivered behind an epoch that never moves, and a held answer outlives
    // the bytes it describes.
    try std.testing.expect(!session.seqlock.armed());
    try std.testing.expect(!session.dirty_log.exact);
    try std.testing.expectEqual(@as(usize, 0), watcher.held());
    try std.testing.expect(!watcher.flushSync());

    // The cost of failing closed is speed, never truth: the reconcile-always
    // baseline still answers the disk, including an in-place edit that no
    // watcher is there to report.
    try truth.expectFiles(&session, &tree, gpa, "needle");
    try rig.advanceClock(io);
    try tree.write("a.txt", "needle rewritten\n");
    try truth.expectFiles(&session, &tree, gpa, "needle");
}
