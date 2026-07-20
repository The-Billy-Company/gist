//! gist resident client — best-effort daemon auto-spawn (ADR-352 rung 2.5).
//!
//! The warm path only pays off if a daemon is actually running, but an agent's
//! reflex is a bare `gist <pattern> -l` with zero setup — nobody runs `gist
//! serve` by hand. So when an *eligible* query finds no daemon listening, the
//! cold CLI fires one off detached and then answers this query cold as usual:
//! the current call pays the cold walk, every subsequent eligible query within
//! the daemon's warm window is served from RAM (~in-memory latency, no per-query
//! tree walk — on macOS the FSEvents watcher even elides the reconcile).
//!
//! It is a pure accelerator, exactly like the watcher: any failure (fork/exec
//! error, unsupported target, a peer that won the race) is swallowed and the
//! query still runs cold. Correctness never depends on the spawn succeeding.
//!
//! Herd-safety is the daemon's job, not ours: ~10 coworker CLIs can each fork a
//! `gist serve` at once, but `serve.run`'s advisory `flock` admits exactly one —
//! the losers exit immediately without touching the socket (see `serve.zig`).
//! We only avoid the obviously-wasteful spawn when a daemon is already up.

const std = @import("std");
const request = @import("../../../../exec/session/request.zig");
const run = @import("../../../../exec/cold/engine/serial.zig");
const session_spawn = @import("../../../../exec/session/spawn.zig");
const net = std.Io.net;

/// Fire off a detached `gist serve` iff this query would benefit from a warm
/// daemon and none is listening yet. Never blocks on the daemon (it warms in the
/// background); never errors (the caller runs cold regardless).
pub fn maybeSpawn(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
    socket_path: []const u8,
) void {
    if (comptime !session_spawn.can_spawn) return;
    // Opt-outs: an explicit disable, a parity-gate context (which must exercise
    // the raw engine, not a served answer), or a caller managing its own daemon.
    for ([_][]const u8{ "GIST_NO_AUTOSERVE", "GIST_NO_PARALLEL", "GIST_SESSION_SOCK" }) |k|
        if (env.get(k) != null) return;
    // Only the shapes the daemon can actually accelerate are worth warming for.
    const req = request.classify(argv) catch return;
    // The client declines these shapes up front (`client.attempt`), so a daemon
    // would never serve them: `-c` stays cold (per-file layout), a TTY stdout
    // gets cold's interactive presentation, and a readable stdin is a stream
    // search. Don't burn a resident corpus warming for a shape that can't land.
    if (req.mode == .count or (std.Io.File.stdout().isTty(io) catch false) or run.readableStdin()) return;
    // A daemon may have come up since the client's dial (a coworker's spawn, or
    // one still binding). Probe once; if it answers, leave it be.
    if (net.UnixAddress.init(socket_path)) |ua| {
        if (ua.connect(io)) |stream| {
            stream.close(io);
            return;
        } else |_| {}
    } else |_| return;
    // No root arg: bare `gist serve` serves the rootless CWD walk the child
    // inherits — exactly the tree this rootless query walks cold (warm==cold
    // parity), and the CWD-relative socket keeps scopes from a differently-rooted
    // daemon apart.
    session_spawn.detach(gpa, io, "serve") catch {};
}
