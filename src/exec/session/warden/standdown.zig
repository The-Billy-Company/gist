//! gist resident session — the durable "do not spawn me again" note a daemon
//! leaves when it will not fit its memory ration.
//!
//! A ceiling alone is not a memory protection. A daemon that meets the ration
//! while loading its mirror exits, the next query finds no rendezvous and
//! auto-spawns a replacement, that one loads the same too-large corpus and exits
//! too — and the tree now pays a fork, an exec, and a partial mirror load per
//! query, forever. That is worse than the unbounded daemon it replaced: the
//! ceiling would have converted a memory leak into a spawn storm. It is also the
//! churn actually observed beside the 1904 MB daemon.
//!
//! So a refusal has to be **remembered somewhere both processes can see**, and
//! the only thing they share is the filesystem beside the rendezvous. A daemon
//! that stands down writes one next to its socket; `client/spawn.zig` reads it
//! and declines to spawn, answering cold immediately instead of paying for a
//! daemon that is going to die.
//!
//! ## Why it expires
//!
//! The note is a fact about a MOMENT — this corpus, this machine, this much free
//! memory — and every term can change without anyone thinking to delete a file.
//! A permanent marker would make one bad afternoon a permanent loss of the warm
//! tier, and the failure would be invisible (a fast tool that quietly stopped
//! being fast). So it decays: after `lull_ns` the next client ignores it and
//! spawns, paying one more failed load to re-ask a question whose answer may
//! have changed. The cost of being wrong in that direction is one spawn per
//! interval; the cost of being wrong in the other is silence.
//!
//! Absence, an unreadable note, a malformed one, and an expired one are all the
//! same answer — **spawn** — because the warm tier is an optimization and this
//! module must never be the reason a machine that could go resident does not.
//! It fails OPEN, which is the opposite of `ration.zig`'s edge, and deliberately
//! so: there the risk was taking memory that isn't there, here it is refusing
//! speed that is.

const std = @import("std");
const fault = @import("irregex").fault;
const Dir = std.Io.Dir;

/// How long a refusal is believed. Ten minutes, matching the daemon's own idle
/// TTL (`daemon/serve/idle.zig`) — long enough that a burst of queries from ~10
/// coworker agents costs one failed spawn rather than one per query, short
/// enough that closing a browser is enough to get the warm tier back.
const lull_ns: i128 = 10 * 60 * std.time.ns_per_s;

/// Suffix for the note, beside the socket and its `.tree` binding so all three
/// share the rendezvous's lifetime and its `GIST_DIR` relocation.
const suffix = ".standdown";

/// Where the note for `socket_path` lives, or null when the composed path will
/// not fit. Null costs the brake, never correctness.
pub fn notePath(buf: []u8, socket_path: []const u8) ?[]const u8 {
    if (socket_path.len + suffix.len > buf.len) return null;
    return std.fmt.bufPrint(buf, "{s}" ++ suffix, .{socket_path}) catch null;
}

/// Record that this tree does not fit, so successors answer cold instead of
/// re-staging a daemon that will die the same way. Best-effort throughout: a
/// note that cannot be written costs the brake and nothing else, which is why
/// nothing here propagates a fault.
///
/// The first line is machine-read and states **which ration was refused**; the
/// prose after it is for the human who finds the file. Recording the budget is
/// what keeps the brake from outliving its own cause: a later client that may
/// spend more than this daemon could is not making the same attempt, so it is
/// not covered by this refusal (`standing`).
pub fn mark(io: std.Io, socket_path: []const u8, held: u64, allowance: u64) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = notePath(&buf, socket_path) orelse return;
    var body: [320]u8 = undefined;
    const text = std.fmt.bufPrint(&body,
        \\{s}{d}
        \\gist serve stood down: the resident mirror does not fit its memory ration.
        \\held at refusal: {d} MB
        \\ration:          {d} MB
        \\Raise it with GIST_MEMORY_MB=<megabytes> (effective immediately), or let
        \\this note expire (10 min).
        \\
    , .{ ration_key, allowance, held >> 20, allowance >> 20 }) catch return;
    fault.spare("record the resident stand-down", Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }));
}

/// Leading key of the note's machine-read first line.
const ration_key = "ration_bytes=";

/// The ration a note was written under, or null when the note does not say.
/// Null means the brake falls back to "believe it", since an unparsable note
/// still proves SOME daemon refused this tree recently.
fn refusedAt(text: []const u8) ?u64 {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    if (!std.mem.startsWith(u8, line, ration_key)) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, line[ration_key.len..], " \r"), 10) catch null;
}

/// Withdraw the note. Called by a daemon that DID fit, so one refusal cannot
/// outlive the condition that caused it — a corpus that shrank, a machine that
/// freed memory, or an operator who raised the ration all clear it on the first
/// successful load rather than waiting out the lull.
pub fn lift(io: std.Io, socket_path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = notePath(&buf, socket_path) orelse return;
    Dir.cwd().deleteFile(io, path) catch {}; // absence is the desired state
}

/// Is a live refusal on file that covers an attempt with `allowance` bytes to
/// spend? True means **do not spawn**. Every uncertainty answers false (see the
/// module header): the brake exists to stop a storm, not to gate the warm tier.
///
/// `allowance` is the caller's OWN ration, and it is what keeps the brake from
/// latching. A note is only evidence about the budget it was written under: the
/// note stops the spawn, and only a successful spawn lifts the note, so if a
/// bigger allowance were still covered by a smaller refusal there would be no
/// way back except the expiry — a raised `GIST_MEMORY_MB` would sit dead for ten
/// minutes with nothing to say it had been read. A client that can spend more
/// than the refused daemon could is making a different attempt, and gets to try.
pub fn standing(io: std.Io, socket_path: []const u8, allowance: u64) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = notePath(&buf, socket_path) orelse return false;
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    if (!fresh(st.mtime.nanoseconds, std.Io.Clock.now(.real, io).nanoseconds)) return false;

    // Read the budget it refused. A short read, an absent header, or a malformed
    // number leaves the note believed on its mtime alone — it still proves some
    // daemon refused this tree moments ago.
    var body: [512]u8 = undefined;
    const text = Dir.cwd().readFile(io, path, &body) catch return true;
    const refused = refusedAt(text) orelse return true;
    return allowance <= refused;
}

/// The decay arithmetic alone, so both edges are testable without a clock: a
/// note is believed until `lull_ns` has passed. A note stamped in the FUTURE
/// (a clock step, a copied tree, a filesystem with a coarse or skewed clock) is
/// treated as expired rather than as believed forever — the same fail-open
/// direction, and the only direction in which a bad timestamp cannot strand the
/// warm tier permanently.
fn fresh(stamped_ns: i128, now_ns: i128) bool {
    if (stamped_ns > now_ns) return false;
    return now_ns - stamped_ns < lull_ns;
}

test "standdown: a note is believed for the lull and then ignored" {
    const t = std.testing;
    const now: i128 = 1_000 * std.time.ns_per_s;
    try t.expect(fresh(now, now)); // just written
    try t.expect(fresh(now - lull_ns + 1, now)); // inside the lull
    try t.expect(!fresh(now - lull_ns, now)); // exactly expired
    try t.expect(!fresh(now - 10 * lull_ns, now)); // long stale
}

test "standdown: a future stamp expires rather than sticking forever" {
    const t = std.testing;
    const now: i128 = 1_000 * std.time.ns_per_s;
    // A clock step or a copied tree must not be able to disable the warm tier
    // permanently — the failure would be a tool that silently stopped being
    // fast, which is the one outcome this module must never cause.
    try t.expect(!fresh(now + 1, now));
    try t.expect(!fresh(now + 100 * lull_ns, now));
}

test "standdown: the note sits beside the rendezvous it refuses" {
    const t = std.testing;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try t.expectEqualStrings(
        "/tmp/gistd.sock" ++ suffix,
        notePath(&buf, "/tmp/gistd.sock").?,
    );
    // A path with no room for the suffix yields null (no brake), never a
    // truncated path that would refuse some OTHER rendezvous.
    var tight: [8]u8 = undefined;
    try t.expect(notePath(&tight, "/tmp/gistd.sock") == null);
}

test "standdown: mark, read, and lift round-trip through a real rendezvous" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A stand-in rendezvous keyed to this shard, so the sibling test shards can
    // run this concurrently without marking each other's socket.
    var sock_buf: [64]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "/tmp/gist_standdown_{x}.sock", .{@intFromPtr(&threaded)});
    defer lift(io, sock);

    const refused: u64 = 2048 << 20;

    // No note ⇒ spawn (the common case, and the fail-open default).
    try t.expect(!standing(io, sock, refused));

    mark(io, sock, 1904 << 20, refused);
    try t.expect(standing(io, sock, refused)); // same budget ⇒ same outcome
    try t.expect(standing(io, sock, refused - 1)); // less to spend ⇒ still covered

    // THE ANTI-LATCH: a client that may spend more than the refused daemon could
    // is not covered, so a raised `GIST_MEMORY_MB` takes effect immediately.
    // Without this the note blocks the spawn and only a spawn lifts the note, so
    // the warm tier would stay dark for the full expiry with no way to say the
    // operator had already fixed it.
    try t.expect(!standing(io, sock, refused + 1));
    try t.expect(!standing(io, sock, 8 << 30));

    lift(io, sock);
    try t.expect(!standing(io, sock, refused)); // and a daemon that fits clears it

    lift(io, sock); // idempotent: absence is the desired state
    try t.expect(!standing(io, sock, refused));
}

test "standdown: the note states the budget it refused, machine-readably" {
    const t = std.testing;
    // The first line is a contract between two processes, so pin it rather than
    // trusting the prose beneath it to keep its shape.
    try t.expectEqual(@as(?u64, 209715200), refusedAt("ration_bytes=209715200\nprose\n"));
    try t.expectEqual(@as(?u64, 4294967296), refusedAt("ration_bytes=4294967296"));

    // Anything unparsable leaves the note believed on its mtime alone (null ⇒
    // the caller's `orelse true`), because a note nobody can read is still proof
    // that some daemon refused this tree moments ago.
    try t.expectEqual(@as(?u64, null), refusedAt(""));
    try t.expectEqual(@as(?u64, null), refusedAt("gist serve stood down\n"));
    try t.expectEqual(@as(?u64, null), refusedAt("ration_bytes=\n"));
    try t.expectEqual(@as(?u64, null), refusedAt("ration_bytes=not-a-number\n"));
}
