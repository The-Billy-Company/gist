//! Adverse allocation-failure suite for the C-ABI seam (OOM returns a value, never aborts).
//!
//! irregex is a library: the host process owns the heap. So the question this
//! file answers is not "does the walk work" but "what happens to the HOST when
//! the walk cannot allocate". Every entry that stands up or reconciles a corpus
//! reaches the cold walkers — the ignore matcher, the serial file-set walk, the
//! fused parallel loader — and each of those used to answer allocation failure
//! with `process.exit(2)`, killing the embedding process from inside a call it
//! made. There is no status code a caller can read from a dead process, and the
//! FFI installs the `dark` sink, so it did not even get the notice.
//!
//! The proof therefore has to be adverse, and it has to be taken from inside a
//! live process: inject a failure at allocation N, and require the outcome be a
//! RETURNED `error.OutOfMemory` (or a clean success, when the walk needed fewer
//! than N allocations) — never a process that stops existing. A test that
//! asserts a status on a path where the allocation cannot fail proves nothing
//! here; the assertion is only worth anything because the test is still running
//! to make it.
//!
//! The sweep walks every failure index rather than one hand-picked site, so a
//! single un-converted `catch oom()` anywhere in a walker is not a subtle
//! wrong answer — it takes the test binary down with it.

const std = @import("std");
const contract = @import("contract.zig");
const session = @import("session.zig");
const api = @import("irregex").api;
const fault = @import("irregex").fault;
const ignore = @import("irregex").inner.corpus.ignore;
const loadpar = @import("irregex").inner.corpus.loadpar;
const cold = @import("irregex").commands.search;
const assay = @import("irregex").assay;

const Dir = std.Io.Dir;
const t = std.testing;

/// How many distinct allocation failures each sweep injects. Comfortably past
/// the allocation count of any single walk over the fixture, so the tail of the
/// sweep also proves the *success* path is untouched by the conversion.
const sweep_width = 96;

/// Byte granularity of the parallel leg's budget ladder (see `Budget`). A fixed
/// buffer cannot reuse freed bytes, so the top rung has to clear a whole fused
/// load's high-water mark — not its live set — for the sweep to span starvation
/// through sufficiency. Asserted by that test's two-sided expectation.
const budget_step = 8 << 10;

/// A small tree that exercises the allocating legs of every walker under test:
/// nested directories (per-dir ignore chains), a `.gitignore` with an anchored
/// rule and a negation (rule compilation + slot maps), a hidden file, a skip
/// dir, and enough plain files to fill the candidate lists.
fn buildFixture(io: std.Io, a: std.mem.Allocator, root: []const u8) !void {
    fault.spare("clear leftover oom fixture", Dir.cwd().deleteTree(io, root));
    try Dir.cwd().createDirPath(io, try join(a, root, "sub/nested"));
    try Dir.cwd().createDirPath(io, try join(a, root, "node_modules"));
    try write(io, try join(a, root, ".gitignore"), "*.log\n!keep.log\nsub/anchored.txt\n");
    try write(io, try join(a, root, "sub/.gitignore"), "local.tmp\n");
    try write(io, try join(a, root, "a.txt"), "alpha\n");
    try write(io, try join(a, root, "keep.log"), "re-included\n");
    try write(io, try join(a, root, "drop.log"), "ignored\n");
    try write(io, try join(a, root, ".hidden"), "hidden\n");
    try write(io, try join(a, root, "sub/b.zig"), "const b = 1;\n");
    try write(io, try join(a, root, "sub/local.tmp"), "ignored by the nested rule\n");
    try write(io, try join(a, root, "sub/anchored.txt"), "ignored by the anchored rule\n");
    try write(io, try join(a, root, "sub/nested/c.py"), "c = 2\n");
    try write(io, try join(a, root, "node_modules/dep.js"), "skip dir\n");
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// One sweep iteration's heap: a failing allocator over an arena, so the walk
/// under test sees a hard `error.OutOfMemory` at allocation `fail_at` while the
/// arena still reclaims whatever the aborted walk had already taken. (The walk
/// is allowed to abandon memory on its error path — that is the caller's arena
/// discipline, not this lane's subject — and backing the sweep with the testing
/// allocator directly would report those abandoned bytes as leaks and hide the
/// property under test.)
const Heap = struct {
    arena: std.heap.ArenaAllocator,
    failing: std.testing.FailingAllocator,

    fn init(self: *Heap, fail_at: usize) void {
        self.arena = std.heap.ArenaAllocator.init(t.allocator);
        self.failing = std.testing.FailingAllocator.init(self.arena.allocator(), .{ .fail_index = fail_at });
    }

    fn deinit(self: *Heap) void {
        self.arena.deinit();
    }
};

/// The parallel leg's sweep unit. `FailingAllocator` counts allocations in
/// plain (non-atomic) fields, and `loadpar.load` allocates from several worker
/// threads at once — so instead of serializing a counter behind a hand-rolled
/// allocator, the parallel sweep starves the walk of a *byte budget*: a fixed
/// buffer whose thread-safe interface (std's own atomics) refuses every request
/// past the budget, from whichever worker asks first. Which worker draws the
/// failure stays nondeterministic, which is precisely the case that must not be
/// able to kill the process, and starvation is if anything the harsher probe:
/// past exhaustion *every* subsequent allocation fails, so an unconverted
/// `catch oom()` downstream of the first failure is caught too.
const Budget = struct {
    buf: []u8,
    fba: std.heap.FixedBufferAllocator,

    fn init(self: *Budget, bytes: usize) !void {
        self.buf = try t.allocator.alloc(u8, bytes);
        self.fba = std.heap.FixedBufferAllocator.init(self.buf);
    }

    fn deinit(self: *Budget) void {
        t.allocator.free(self.buf);
    }

    /// `threadSafeAllocator`, not `allocator`: the walk's workers are raw OS
    /// threads with no `std.Io` handle at the point they allocate.
    fn allocator(self: *Budget) std.mem.Allocator {
        return self.fba.threadSafeAllocator();
    }
};

test "the ignore matcher returns OutOfMemory rather than exiting the host" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/gist_oom_ignore_fixture";
    var setup = std.heap.ArenaAllocator.init(t.allocator);
    defer setup.deinit();
    try buildFixture(io, setup.allocator(), root);
    defer fault.spare("remove oom fixture", Dir.cwd().deleteTree(io, root));
    const roots: []const []const u8 = &.{root};

    var ooms: usize = 0;
    for (0..sweep_width) |fail_at| {
        var heap: Heap = undefined;
        heap.init(fail_at);
        defer heap.deinit();
        const a = heap.failing.allocator();
        // Root/ancestor tiers, then the per-directory chain and a membership
        // question — the three allocating legs `gist_open` drives.
        if (ignore.Ignore.init(a, io, .{}, roots)) |init_ok| {
            var ig = init_ok;
            ig.loadDir(root, root) catch |e| {
                try t.expectEqual(error.OutOfMemory, e);
                ooms += 1;
                continue;
            };
            _ = ig.admitsPath(root, "sub/nested/c.py") catch |e| {
                try t.expectEqual(error.OutOfMemory, e);
                ooms += 1;
            };
        } else |e| {
            try t.expectEqual(error.OutOfMemory, e);
            ooms += 1;
        }
    }
    // If the walkers still exited on OOM this line is unreachable — the process
    // would be gone. Reaching it with failures observed is the whole claim.
    try t.expect(ooms > 0);
}

test "the cold file-set walk returns OutOfMemory rather than exiting the host" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/gist_oom_serial_fixture";
    var setup = std.heap.ArenaAllocator.init(t.allocator);
    defer setup.deinit();
    try buildFixture(io, setup.allocator(), root);
    defer fault.spare("remove oom fixture", Dir.cwd().deleteTree(io, root));
    const roots: []const []const u8 = &.{root};

    // Control: with no failure injected the walk still answers, so the
    // conversion changed no verdict — only what happens when memory runs out.
    {
        var control = std.heap.ArenaAllocator.init(t.allocator);
        defer control.deinit();
        var extras: []const cold.Extra = &.{};
        const set = try cold.defaultFileSetExtras(control.allocator(), io, roots, &extras);
        try t.expect(set.paths.len > 0);
    }

    var ooms: usize = 0;
    for (0..sweep_width) |fail_at| {
        var heap: Heap = undefined;
        heap.init(fail_at);
        defer heap.deinit();
        var extras: []const cold.Extra = &.{};
        // `defaultFileSetExtras` is the exact walk behind `gist_open` and
        // behind every reconcile `gist_search` performs.
        if (cold.defaultFileSetExtras(heap.failing.allocator(), io, roots, &extras)) |set| {
            try t.expect(set.paths.len > 0);
        } else |e| {
            try t.expectEqual(error.OutOfMemory, e);
            ooms += 1;
        }
    }
    try t.expect(ooms > 0);
}

test "the fused parallel loader returns OutOfMemory rather than exiting the host" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/gist_oom_loadpar_fixture";
    var setup = std.heap.ArenaAllocator.init(t.allocator);
    defer setup.deinit();
    try buildFixture(io, setup.allocator(), root);
    defer fault.spare("remove oom fixture", Dir.cwd().deleteTree(io, root));
    const roots: []const []const u8 = &.{root};

    var ooms: usize = 0;
    var loads: usize = 0;
    for (0..sweep_width) |step| {
        var budget: Budget = undefined;
        try budget.init(step * budget_step);
        defer budget.deinit();
        if (loadpar.load(budget.allocator(), io, roots)) |loaded| {
            var c = loaded;
            c.deinit();
            loads += 1;
        } else |e| {
            try t.expectEqual(error.OutOfMemory, e);
            ooms += 1;
        }
    }
    // Both legs, as in the serial sweeps: the starved budgets prove failure is
    // RETURNED, and the generous tail proves the conversion left the success
    // path intact rather than making the loader always fail.
    try t.expect(ooms > 0);
    try t.expect(loads > 0);
}

test "gist_open answers a walk-time OOM with IRREGEX_OOM and a named fault" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/gist_oom_open_fixture";
    var setup = std.heap.ArenaAllocator.init(t.allocator);
    defer setup.deinit();
    try buildFixture(io, setup.allocator(), root);
    defer fault.spare("remove oom fixture", Dir.cwd().deleteTree(io, root));
    // `openWith` installs the dark sink process-wide, as the C entry does;
    // restore the default so a later test's diagnostics are not swallowed.
    defer assay.install(.{});

    const paths = [_][*:0]const u8{root};
    var ooms: usize = 0;
    for (0..sweep_width) |fail_at| {
        var heap: Heap = undefined;
        heap.init(fail_at);
        defer heap.deinit();
        var handle: *session.Session = undefined;
        const st = session.openWith(heap.failing.allocator(), &paths, 1, &handle);
        switch (st) {
            .ok => session.close(handle),
            .out_of_memory => {
                ooms += 1;
                // The status a C host reads: IRREGEX_OOM, a fault (not a
                // declinature), carrying the taxonomy's own name for it.
                try t.expectEqual(@as(i32, -2), @intFromEnum(st));
                try t.expectEqual(contract.Disposition.fault, st.disposition());
                var detail: contract.FaultDetail = undefined;
                detail.struct_size = @sizeOf(contract.FaultDetail);
                try t.expectEqual(contract.Status.match, contract.lastFault(&detail));
                try t.expectEqualStrings("OutOfMemory", std.mem.span(detail.name));
                try t.expectEqual(@as(i32, -2), detail.status);
            },
            // `open_failed` is the seam's honest "an error the taxonomy does not
            // name" — `reportAny` installs no detail for it. An out-of-memory
            // can never arrive here (`Status.ofFault` maps it), so the empty
            // slot is exactly what proves this iteration failed for some other
            // reason rather than an OOM landing in the wrong channel.
            .open_failed => {
                var detail: contract.FaultDetail = undefined;
                detail.struct_size = @sizeOf(contract.FaultDetail);
                try t.expectEqual(contract.Status.ok, contract.lastFault(&detail));
            },
            else => {
                std.debug.print("gist_open returned {t} at fail_index {d}\n", .{ st, fail_at });
                return error.WrongStatusForOom;
            },
        }
    }
    try t.expect(ooms > 0);
}

test "the cursor ABI's engine open reports a walk-time OOM through the same seam" {
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();

    const root = "/tmp/gist_oom_engine_fixture";
    var setup = std.heap.ArenaAllocator.init(t.allocator);
    defer setup.deinit();
    try buildFixture(threaded.io(), setup.allocator(), root);
    defer fault.spare("remove oom fixture", Dir.cwd().deleteTree(threaded.io(), root));
    const roots: []const []const u8 = &.{root};

    var ooms: usize = 0;
    for (0..sweep_width) |fail_at| {
        var heap: Heap = undefined;
        heap.init(fail_at);
        defer heap.deinit();
        if (api.Engine.open(heap.failing.allocator(), roots)) |engine| {
            engine.close();
        } else |e| {
            if (e != error.OutOfMemory) continue; // some other tier declining
            contract.beginCall();
            // `libirregex`'s `corpus.open` translates that error exactly so.
            const st = contract.reportAny(e, .open_failed);
            try t.expectEqual(contract.Status.out_of_memory, st);
            var detail: contract.FaultDetail = undefined;
            detail.struct_size = @sizeOf(contract.FaultDetail);
            try t.expectEqual(contract.Status.match, contract.lastFault(&detail));
            try t.expectEqualStrings("OutOfMemory", std.mem.span(detail.name));
            ooms += 1;
        }
    }
    try t.expect(ooms > 0);
}

test "the exported entry reports a real allocation failure without exiting" {
    // No injected allocator: an impossible root count makes the C heap itself
    // refuse, so this covers the literal `gist_open` body on `c_allocator`.
    defer assay.install(.{});
    var handle: *session.Session = undefined;
    const st = session.open(null, std.math.maxInt(usize) / 2, &handle);
    try t.expectEqual(contract.Status.out_of_memory, st);
    try t.expectEqual(@as(i32, -2), @intFromEnum(st));
    var detail: contract.FaultDetail = undefined;
    detail.struct_size = @sizeOf(contract.FaultDetail);
    try t.expectEqual(contract.Status.match, contract.lastFault(&detail));
    try t.expectEqualStrings("OutOfMemory", std.mem.span(detail.name));
}
