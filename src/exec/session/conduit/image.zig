//! Which BUILD is answering — the half of the daemon handshake
//! `protocol_version` cannot express.
//!
//! The wire version proves two peers FRAME alike. It cannot prove they ANSWER
//! alike. A correctness fix that changes what a warm answer IS — a freshness
//! barrier that stops vouching an epoch it never counted (ADR-372) — moves no
//! frame, so it earns no version bump, and a daemon started before the fix goes
//! on serving freshly-rebuilt clients for as long as it stays resident. The
//! failure that motivated this was exactly that: a fix landed, the binary was
//! rebuilt two minutes later, and a daemon from hours earlier kept answering
//! from the pre-fix engine. "Restart the daemon" is an operator habit, not a
//! contract, and quietly returning bytes that no longer exist on disk is the
//! one answer shape a search tool may never have.
//!
//! So READY also carries the daemon's `stamp`, latched at ITS boot — before any
//! later rebuild can replace the file underneath it — and reported for the rest
//! of its life. The stamping instant and the reporting instant being hours
//! apart is the entire point, which is why the daemon holds it in
//! `ResidentSession.image` rather than re-asking here.
//!
//! **The stamp is the executable's mtime, which is an identity and NOT an
//! order.** Zig's install step copies the cache artifact with its timestamp
//! preserved, so the stamp is really a build-hash proxy — reinstalling the same
//! build reproduces the same stamp (no spurious skew), and switching between
//! two cached builds moves the mtime *backwards*. Measured here: a daemon
//! latched 15:43:17 while the binary that later replaced it read 15:38:45. So
//! comparing two stamps can only ever answer "same build?" — anything that
//! reads them as newer/older is wrong, and a client that waits to be the newer
//! one before retiring a daemon waits forever.
//!
//! **What breaks the tie is the file on disk, and only the daemon can ask.**
//! `replaced` re-stats the path THIS process was exec'd from and compares it to
//! the stamp latched at boot. A daemon whose own executable has been rewritten
//! underneath it is superseded as a matter of fact, with no clock and no
//! ordering: the bytes it is running no longer exist. It stands down, and the
//! next query spawns a daemon from whatever is on disk now. Two live builds at
//! one rendezvous therefore never fight — each one's own file is intact, so
//! neither is `replaced`, and the loser simply stays cold.
//!
//! **Scope: gist-to-gist only.** This identifies a FILE, and the three product
//! binaries are three files from one build. Only the gist face serves and
//! auto-spawns the daemon, so its query path compares like with like. The
//! answer keep is deliberately outside: `relate` and `irregex` dial gist's
//! socket by design, and they are already build-partitioned where it counts —
//! `cli/reprise.zig` folds the CALLER's own build into the keep key, so a
//! rebuilt binary cannot recall an answer its predecessor rendered.
//!
//! Fail-open by construction. A target with no self-exe path, or a stat that
//! will not answer, stamps `unknown`, and `unknown` on either side means
//! "cannot judge" — exactly the pre-existing behavior, never a refusal to
//! serve and never a retirement.

const std = @import("std");
const builtin = @import("builtin");
const inode = @import("irregex").inner.corpus.inode;

/// No answer available. A real stamp is a wall-clock nanosecond count, so zero
/// is unambiguously "this side could not identify itself".
pub const unknown: u64 = 0;

/// This process's build stamp, computed once and remembered. The daemon calls
/// it at boot so its answer predates any later rebuild; a client calls it at
/// dial, where the file on disk still IS the image it was exec'd from.
///
/// Racing callers may both compute — the inputs are one file, so the answer is
/// too, and a duplicated stat is cheaper than a lock on a path taken once per
/// process.
pub fn stamp(io: std.Io) u64 {
    if (latched.load(.acquire)) return memo;
    const v = compute(io);
    if (v == unknown) return v; // a non-answer is never latched; keep re-asking
    memo = v;
    latched.store(true, .release);
    return v;
}

/// May a peer at `theirs` answer for a caller at `mine`? Equal builds may; an
/// `unknown` on either side abstains, because a check that cannot be made must
/// not be made.
pub fn agrees(mine: u64, theirs: u64) bool {
    return mine == unknown or theirs == unknown or mine == theirs;
}

/// On build skew, which of the two should HOST the rendezvous? A strict total
/// order over the two stamps — and it is a **tiebreak, not a recency claim**.
/// Everything above about mtime being an identity rather than an order still
/// holds: `hosts` does not assert the larger stamp is the newer build, only
/// that both sides compute the same winner from the same pair.
///
/// That is the property `replaced` alone cannot deliver. `replaced` retires a
/// daemon whose own file was rewritten, which silently assumes every daemon's
/// executable is one a rebuild eventually overwrites. A daemon exec'd from a
/// content-addressed build artifact breaks the assumption outright: the path
/// embeds a hash of its own bytes, so it can never be rewritten, `replaced` is
/// false for the whole of its life, and it holds the socket while every
/// rebuilt client declines and runs cold. The idle TTL is no escape either —
/// it wants ten *continuous* quiet minutes, which a tree ~10 coworker agents
/// query never gets. Measured: 10 such orphans resident at once, the warm tier
/// stranded, every eligible query 6-13x slower than the daemon beside it.
///
/// Symmetry is the trap to avoid, so this is deliberately not "we disagree".
/// A symmetric rule has two live builds taking turns evicting each other all
/// afternoon; `>` converges after one cold query, to the same winner from
/// either side, no matter which dialed first. The loser stays cold exactly as
/// it does today — so the worst case is the current behavior, and the common
/// case (a fresh install against a stale orphan) hands the rendezvous back.
///
/// `unknown` abstains on either side: a side that cannot identify itself must
/// not evict one that can.
pub fn hosts(mine: u64, theirs: u64) bool {
    return mine != unknown and theirs != unknown and mine > theirs;
}

/// Has the executable this process is running been rewritten since `stamp`
/// latched it? For a resident daemon that is the whole retirement question,
/// answered against the filesystem rather than against a peer: the bytes it
/// serves from are gone, so it is superseded no matter what any client claims
/// to be. False whenever the question cannot be answered — an unstampable
/// process, a deleted path — because an accelerator must never stop itself on
/// a doubt.
pub fn replaced(io: std.Io) bool {
    if (!latched.load(.acquire)) return false; // never identified itself; nothing to compare
    const now = compute(io);
    return now != unknown and now != memo;
}

/// The latched stamp, and the flag that publishes it.
///
/// Two words rather than one wide atomic because an atomic may not exceed the
/// target's largest — four bytes on a 32-bit target, where a stamp is eight by
/// definition. The alternative, sizing the memo to the target, would quietly
/// narrow the very identity the daemon and its clients compare, on exactly the
/// target least able to afford a collision. So the width stays honest and the
/// *flag* carries the ordering: `release` on the write, `acquire` on the read,
/// so a reader that sees the latch sees the whole value behind it.
///
/// Racing writers are still benign, which is what lets the value itself stay
/// plain: the input is one file, so every winner writes identical bytes, and a
/// duplicated stat is cheaper than a lock on a path taken once per process. A
/// target that genuinely cannot identify itself never latches at all and
/// recomputes per call — a couple of failed stats over a process's life, on the
/// platform where the check does nothing anyway.
var memo: u64 = unknown;
var latched: std.atomic.Value(bool) = .init(false);

/// The file this process is running, into `buf` — no allocation, because this
/// runs on the daemon's per-connection path. Symlinks are already resolved by
/// the platform call, so a client invoked through `~/.local/bin/gist` and the
/// daemon it spawned at `zig-out/bin/gist` stamp the same file.
///
/// The stand-in is for tests only: a test can neither replace the binary it is
/// executing nor touch it — sibling shards are running the same file — so
/// exercising `replaced` means pointing the question at a throwaway instead.
fn selfPath(io: std.Io, buf: []u8) ?[]const u8 {
    if (builtin.is_test) if (exe_override) |p| return p;
    const n = std.process.executablePath(io, buf) catch return null;
    return buf[0..n];
}

var exe_override: ?[]const u8 = null;

pub const test_api = if (builtin.is_test) struct {
    /// Answer as if this process were exec'd from `path` (null restores the
    /// truth), and drop the latch so the next `stamp` re-reads. The caller owns
    /// `path` and must outlive the override.
    pub fn standIn(path: ?[]const u8) void {
        exe_override = path;
        latched.store(false, .release);
        memo = unknown;
    }
} else struct {};

fn compute(io: std.Io) u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = selfPath(io, &buf) orelse return unknown;
    // `statPath` follows the final link deliberately: the installed `gist` is a
    // symlink onto `zig-out/bin/gist`, and it is the TARGET a rebuild rewrites.
    // `lstat` here would stamp the link's own mtime — which `make install-gist`
    // also rewrites, on its own schedule, making two peers on ONE binary
    // disagree.
    const st = inode.statPath(exe) orelse return unknown;
    const mtime = st.mtime_ns orelse return unknown;
    // Pre-epoch or absurd clocks are not an identity worth trusting; a stat
    // that answers nonsense is the same as one that will not answer.
    return std.math.cast(u64, mtime) orelse unknown;
}

test "agrees: equal builds serve, differing builds decline, unknown abstains" {
    const t = std.testing;
    try t.expect(agrees(7, 7));
    try t.expect(!agrees(7, 8));
    try t.expect(agrees(unknown, 8)); // we cannot identify ourselves
    try t.expect(agrees(7, unknown)); // the daemon cannot identify itself
    try t.expect(agrees(unknown, unknown));
}

test "replaced: an intact executable is never reported as superseded" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Latch, then ask again with nothing touched. A false positive here would
    // have every daemon stand down on its first client, forever.
    try t.expect(stamp(io) != unknown);
    try t.expect(!replaced(io));
    // Idempotent: asking does not itself move the latch.
    try t.expect(!replaced(io));
}

test "replaced: rewriting the file under a latched process is what supersedes it" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Dir = std.Io.Dir;

    // A stand-in for "the binary I am running", so this test can do the one
    // thing a live install does — rewrite it — without touching the file the
    // sibling shards are executing.
    var name_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buf, "/tmp/gist_image_{x}", .{@intFromPtr(&threaded)});
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "v1" });
    defer Dir.cwd().deleteFile(io, path) catch {};
    test_api.standIn(path);
    defer test_api.standIn(null); // and the memo re-latches on the real exe

    try t.expect(stamp(io) != unknown);
    try t.expect(!replaced(io));

    // mtime has a coarse floor on some filesystems; a rewrite a nanosecond
    // later must still register, so wait out the granularity rather than
    // assert on a clock this test does not own.
    try io.sleep(.fromNanoseconds(20 * std.time.ns_per_ms), .real);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "v2" });
    try t.expect(replaced(io));

    // The latch itself never moves: a superseded process stays superseded
    // rather than quietly adopting the new build's identity mid-life.
    try t.expectEqual(stamp(io), stamp(io));
    try t.expect(replaced(io));
}

test "stamp: this test binary identifies itself, stably, and never as unknown" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const first = stamp(threaded.io());
    // A running test binary always has a self-exe path, so this is a real
    // stamp — and the memo must hand back the same one.
    try t.expect(first != unknown);
    try t.expectEqual(first, stamp(threaded.io()));
    try t.expect(agrees(first, first));
}
