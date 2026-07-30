//! gist resident session — the freshness-barrier hardening suite (ADR-352 rung 2.5).
//!
//! `resident_test.zig` pins correctness against hand-authored oracles; this file
//! attacks the barrier itself along the three axes a warm, mutation-tracking
//! engine can silently corrupt:
//!
//!   1. Differential — over a pseudo-randomly generated tree and a spread of
//!      needles (both < 3 bytes, exercising the whole-corpus path, and ≥ 3,
//!      exercising the trigram-index path), the resident `files`/`count` answers
//!      must equal an INDEPENDENT on-disk oracle (a naive re-scan of the same
//!      bytes), before AND after an add/modify/delete round. The oracle never
//!      runs the engine, so a shared bug can't hide the drift (sins.mdc Sin #2).
//!   2. Concurrency — the one supported concurrency in the daemon is the watcher
//!      thread firing `markDirty` lock-free while a query reconciles under the
//!      mutex. A flood of events racing a query loop must never crash, leak, or
//!      return a wrong answer over a static tree (the seqlock recheck holds).
//!   3. Overflow / bound — an inotify queue overflow degrades to "everything may
//!      have changed" (a `markDirty` storm); the fail-closed reconcile must
//!      absorb it and stay correct, and the mutation overlay must stay BOUNDED
//!      (a re-touched path replaces its entry, never appends).

const std = @import("std");
const resident = @import("../warm/resident.zig");
const truth = @import("../warm/truth.zig");
const fault = @import("../../../fault.zig");
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

/// A throwaway on-disk tree plus the live-file bookkeeping the oracle needs.
const Corpus = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,
    live: std.ArrayList([]const u8) = .empty, // relative names currently on disk

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8, seed: usize) !Corpus {
        const root = try std.fmt.allocPrint(a, "/tmp/gist_fresh_{s}_{x}", .{ tag, seed });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Corpus) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
        self.live.deinit(self.a);
    }

    fn abs(self: *Corpus, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
    }

    fn write(self: *Corpus, rel: []const u8, data: []const u8) !void {
        try Dir.cwd().writeFile(self.io, .{ .sub_path = try self.abs(rel), .data = data });
        for (self.live.items) |n| if (std.mem.eql(u8, n, rel)) return;
        try self.live.append(self.a, try self.a.dupe(u8, rel));
    }

    fn remove(self: *Corpus, rel: []const u8) !void {
        try Dir.cwd().deleteFile(self.io, try self.abs(rel));
        for (self.live.items, 0..) |n, i| if (std.mem.eql(u8, n, rel)) {
            _ = self.live.orderedRemove(i);
            return;
        };
    }

    /// Independent oracle for `-c`: total lines (rg model — `\n` terminates, no
    /// phantom final line) containing `needle` across all live files.
    fn oracleCount(self: *Corpus, needle: []const u8) !u64 {
        var total: u64 = 0;
        for (self.live.items) |rel| {
            const bytes = Dir.cwd().readFileAlloc(self.io, try self.abs(rel), self.a, .limited(1 << 20)) catch continue;
            defer self.a.free(bytes);
            var rest: []const u8 = bytes;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const end = nl orelse rest.len;
                if (std.mem.indexOf(u8, rest[0..end], needle) != null) total += 1;
                if (nl == null) break;
                rest = rest[end + 1 ..];
            }
        }
        return total;
    }
};

/// A short sleep so a coarse filesystem clock records a strictly-newer mtime/ctime,
/// keeping `changedSince` from collapsing a write onto the prior reconcile tick.
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

/// Fill `buf` with pseudo-random lowercase lines, occasionally embedding one of
/// the needle tokens so matches are neither all-hit nor all-miss.
fn genContent(rng: std.Random, buf: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    const tokens = [_][]const u8{ "abc", "qwer", "xy", "z", "needle" };
    const lines = rng.intRangeAtMost(usize, 2, 8);
    for (0..lines) |_| {
        const len = rng.intRangeAtMost(usize, 3, 10);
        for (0..len) |_| try buf.append(a, 'a' + rng.uintLessThan(u8, 6));
        if (rng.uintLessThan(u8, 3) == 0) {
            try buf.append(a, ' ');
            try buf.appendSlice(a, tokens[rng.uintLessThan(usize, tokens.len)]);
        }
        try buf.append(a, '\n');
    }
}

fn assertMatchesOracle(session: *ResidentSession, corpus: *Corpus, gpa: std.mem.Allocator, needle: []const u8) !void {
    try truth.expectFiles(session, corpus, gpa, needle);
    var q = std.heap.ArenaAllocator.init(gpa);
    defer q.deinit();
    const qa = q.allocator();
    const want_count = try corpus.oracleCount(needle);
    const got_count = (try session.query(qa, .{ .pattern = needle, .mode = .count, .fixed = true })).got;
    try std.testing.expectEqual(want_count, got_count.count);
}

const needles = [_][]const u8{ "needle", "abc", "qwer", "xy", "z", "zzqxv" };

test "differential: resident == independent on-disk oracle, across add/modify/delete" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "diff", @intFromPtr(&threaded));
    defer corpus.deinit();

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    for (0..15) |i| {
        var buf: std.ArrayList(u8) = .empty;
        try genContent(rng, &buf, fa);
        try corpus.write(try std.fmt.allocPrint(fa, "f{d}.txt", .{i}), buf.items);
    }

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();

    // Baseline: every needle agrees with the oracle over the fresh corpus.
    for (needles) |n| try assertMatchesOracle(&session, &corpus, gpa, n);

    // Mutate the tree under the warm session, then re-verify all needles.
    try advanceClock(io);
    {
        var buf: std.ArrayList(u8) = .empty;
        try genContent(rng, &buf, fa);
        try corpus.write("late.txt", buf.items); // new file
    }
    {
        var buf: std.ArrayList(u8) = .empty;
        try genContent(rng, &buf, fa);
        try buf.appendSlice(fa, "a fresh needle line\n");
        try corpus.write("f3.txt", buf.items); // modify existing
    }
    try corpus.remove("f7.txt"); // delete existing

    for (needles) |n| try assertMatchesOracle(&session, &corpus, gpa, n);
}

/// Background thread: hammer `markDirty` (as the real inotify watcher would on a
/// storm of events) until told to stop, exercising the lock-free seqlock side.
const Flooder = struct {
    session: *ResidentSession,
    io: std.Io,
    run: std.atomic.Value(bool) = .init(true),

    fn loop(self: *Flooder) void {
        while (self.run.load(.acquire)) {
            self.session.markDirty();
            fault.spare("settle before the next stat", self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_us), .real));
        }
    }
};

test "concurrency: a watcher markDirty flood racing the query loop stays correct" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "conc", @intFromPtr(&threaded));
    defer corpus.deinit();
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rng = prng.random();
    for (0..10) |i| {
        var buf: std.ArrayList(u8) = .empty;
        try genContent(rng, &buf, fa);
        try corpus.write(try std.fmt.allocPrint(fa, "g{d}.txt", .{i}), buf.items);
    }

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();
    session.armWatcher(); // simulate a live watcher whose events the flood fires

    // Snapshot the oracle ONCE (the tree never changes here) so the hot loop is
    // pure query + compare — no disk re-scan — letting it race thousands of
    // events cheaply instead of being IO-bound.
    var want_count: [needles.len]u64 = undefined;
    var want_files: [needles.len]usize = undefined;
    for (needles, 0..) |n, i| {
        var fs: std.ArrayList([]const u8) = .empty;
        try truth.files(&corpus, &fs, n);
        want_files[i] = fs.items.len;
        want_count[i] = try corpus.oracleCount(n);
    }

    var flooder = Flooder{ .session = &session, .io = io };
    const t = try std.Thread.spawn(.{}, Flooder.loop, .{&flooder});

    // The tree is static, so every needle's answer is invariant no matter how
    // many spurious dirty events the flood injects: correctness must hold on
    // both the reconcile path and any clean window that briefly opens.
    for (0..400) |_| {
        var q = std.heap.ArenaAllocator.init(gpa);
        for (needles, 0..) |n, i| {
            const f = (try session.query(q.allocator(), .{ .pattern = n, .mode = .files, .fixed = true })).got;
            try std.testing.expectEqual(want_files[i], f.files.len);
            const c = (try session.query(q.allocator(), .{ .pattern = n, .mode = .count, .fixed = true })).got;
            try std.testing.expectEqual(want_count[i], c.count);
        }
        q.deinit();
    }

    flooder.run.store(false, .release);
    t.join();
}

test "overflow + bound: a markDirty storm is absorbed and the overlay stays bounded" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var corpus = try Corpus.init(fa, io, "ovf", @intFromPtr(&threaded));
    defer corpus.deinit();
    try corpus.write("keep.txt", "needle keeps\n");
    try corpus.write("churn.txt", "needle v0\n");

    var session = try ResidentSession.init(gpa, io, &.{corpus.root});
    defer session.deinit();

    // A queue-overflow degrades to "everything may have changed" — modeled as a
    // markDirty storm. The fail-closed reconcile must still answer correctly.
    for (0..10_000) |_| session.markDirty();
    try assertMatchesOracle(&session, &corpus, gpa, "needle");

    // Re-touch ONE file many times. The first modify establishes the overlay's
    // steady-state size; every subsequent modify of the SAME path must replace
    // its entry in place, never append — so the count stays pinned no matter how
    // many revisions land. This is the bound the engine's doc promises: a
    // long-lived daemon churning one hot file can't leak overlay entries.
    try advanceClock(io);
    try corpus.write("churn.txt", "needle v1\n");
    try assertMatchesOracle(&session, &corpus, gpa, "needle");
    const steady = session.overlay.count();
    for (2..10) |v| {
        try advanceClock(io);
        try corpus.write("churn.txt", try std.fmt.allocPrint(fa, "needle v{d}\n", .{v}));
        try assertMatchesOracle(&session, &corpus, gpa, "needle");
        try std.testing.expectEqual(steady, session.overlay.count());
    }
}
