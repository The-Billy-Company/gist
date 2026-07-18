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
const builtin = @import("builtin");
const request = @import("../../session/request.zig");
const run = @import("../ripgrep/run.zig");
const net = std.Io.net;

/// Only these targets have the fork+exec + `flock`/FSEvents/inotify machinery the
/// daemon relies on; everywhere else the query just runs cold (no-op).
const can_spawn = builtin.os.tag == .macos or builtin.os.tag == .linux;

extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

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
    if (comptime !can_spawn) return;
    // Opt-outs: an explicit disable, a parity-gate context (which must exercise
    // the raw engine, not a served answer), or a caller managing its own daemon.
    if (env.get("GIST_NO_AUTOSERVE") != null) return;
    if (env.get("GIST_NO_PARALLEL") != null) return;
    if (env.get("GIST_SESSION_SOCK") != null) return;
    // Only the shapes the daemon can actually accelerate are worth warming for.
    const req = request.classify(argv) catch return;
    // The client declines these shapes up front (`client.attempt`), so a daemon
    // would never serve them: `-c` stays cold (per-file layout), a TTY stdout
    // gets cold's interactive presentation, and a readable stdin is a stream
    // search. Don't burn a resident corpus warming for a shape that can't land.
    if (req.mode == .count) return;
    if (std.Io.File.stdout().isTty(io) catch false) return;
    if (run.readableStdin()) return;
    // A daemon may have come up since the client's dial (a coworker's spawn, or
    // one still binding). Probe once; if it answers, leave it be.
    if (net.UnixAddress.init(socket_path)) |ua| {
        if (ua.connect(io)) |stream| {
            stream.close(io);
            return;
        } else |_| {}
    } else |_| return;
    spawnDetached(gpa, io) catch {};
}

/// `fork` → child fully detaches (new session, stdio to /dev/null) and `execv`s
/// `gist serve`; the parent returns at once to run the cold query. All argv/path
/// memory is built BEFORE the fork, so the child touches only async-signal-safe
/// syscalls between fork and exec (no allocator, no std.Io) — safe even though a
/// `std.Io.Threaded` pool may exist, since `execv` replaces the whole image.
///
/// No root arg: bare `gist serve` serves the rootless CWD walk, and the child
/// inherits this CLI's working directory, so the daemon's served tree is exactly
/// the tree this rootless query walks cold — the basis of warm==cold parity. The
/// CWD-relative socket path (`.local/gist-verify/gistd.sock`) means a daemon
/// started from a different directory binds a different socket, never crossing
/// scopes.
fn spawnDetached(gpa: std.mem.Allocator, io: std.Io) !void {
    const exe_z = try std.process.executablePathAlloc(io, gpa); // NUL-terminated
    defer gpa.free(exe_z);
    const child_argv = [_:null]?[*:0]const u8{ exe_z.ptr, "serve", null };

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) return; // parent — the daemon warms while this query runs cold

    // ── child ──: detach from the CLI's session + stdio, then become the daemon.
    _ = std.c.setsid();
    if (std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0)) |nul| {
        _ = std.c.dup2(nul, 0);
        _ = std.c.dup2(nul, 1);
        _ = std.c.dup2(nul, 2);
    } else |_| {}
    _ = execv(exe_z.ptr, &child_argv);
    _exit(127); // only reached if execv failed
}
