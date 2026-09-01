//! Detached daemon auto-spawn, shared by the resident CLIs.
//!
//! The warm path only pays off if a daemon is running, but an agent's reflex is
//! a bare query with zero setup — nobody runs `<cli> serve` by hand. So when an
//! eligible query finds no daemon, the CLI fires one off detached and answers
//! this call cold/indexed as usual; every later eligible query within the warm
//! window is served from RAM. It is a pure accelerator: any failure (a spawn
//! error, an unsupported target, a peer that won the race) is swallowed and the
//! query still runs its certified fallback. Herd-safety is the daemon's job (its
//! exclusive lock admits exactly one racer), not the spawner's.
//!
//! Each CLI keeps its own eligibility policy and socket probe; only the
//! detach → launch mechanism lives here, once, for gist and relate.
//!
//! **The two platforms detach differently because they mean different things by
//! it.** POSIX has to build detachment out of parts: `fork`, then the child
//! leaves the CLI's session (`setsid`) and drops its stdio, then `execv`
//! replaces the image. Windows has no `fork` at all — a process is created from
//! an image, not cloned — so `CreateProcessW` *is* the launch, and there is no
//! session to leave: the child does not die with its parent, and asking for no
//! console window is the whole of what detaching means there. So this file has
//! two implementations of one sentence, and neither is a translation of the
//! other.
//!
//! Both leave the child inheriting this process's working directory, which is
//! load-bearing: a rootless daemon's served tree is exactly the tree this CLI
//! walks (the basis of warm==cold parity), and the CWD-relative socket path is
//! what keeps two scopes apart.

const std = @import("std");
const builtin = @import("builtin");
const fault = @import("irregex").fault;
const portal = @import("irregex").portal;

const windows = builtin.os.tag == .windows;

/// Only these targets have a resident tier to spawn a daemon *for*; everywhere
/// else the query just runs its fallback (no-op). Deliberately expressed as the
/// session capability rather than as a list of triples: a platform that cannot
/// host the session has nothing to launch, and one that can must be launchable,
/// so the two facts may not drift apart.
pub const can_spawn = portal.resident_sessions;

extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

/// Launch `<this-executable> verb` detached; return at once so the caller runs
/// its fallback while the daemon warms.
pub fn detach(gpa: std.mem.Allocator, io: std.Io, verb: [:0]const u8) !void {
    if (comptime !can_spawn) return;
    if (comptime windows) return detachWindows(gpa, io, verb);
    return detachPosix(gpa, io, verb);
}

/// Collect the intermediate, retrying only the one failure that means "not yet".
///
/// This is a reap, not a wait on the daemon: the intermediate is already on its
/// way out, so the call returns in microseconds. Its exit status is nothing we
/// can act on — a failed second fork means no daemon, the same swallowed
/// non-event every other spawn failure is — so the CLI runs cold either way and
/// only the process-table entry matters.
///
/// `EINTR` is the one answer worth retrying: a signal delivered mid-wait leaves
/// the child unreaped, which is the exact leak this function exists to prevent.
/// Every other failure (`ECHILD` — already reaped by a `SIGCHLD` handler or a
/// `SIG_IGN` disposition) means there is nothing left to collect, so retrying it
/// would spin. The retry is bounded anyway, because a reaper that can loop
/// forever is a worse bug than the zombie it was chasing.
fn reap(pid: std.c.pid_t) void {
    for (0..8) |_| {
        if (std.c.waitpid(pid, null, 0) >= 0) return;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

/// Double `fork` → grandchild fully detaches (new session, stdio → /dev/null)
/// and `execv`s the daemon; the parent reaps the intermediate and returns at
/// once. All argv/path memory is built BEFORE the fork, so neither forked
/// process touches anything but async-signal-safe syscalls between fork and exec
/// (no allocator, no std.Io) — safe even with a `std.Io.Threaded` pool present,
/// since `execv` replaces the whole image.
///
/// **Why two forks and a wait, when one fork already detaches.** `setsid` gives
/// the daemon its own session, but it does not change who its PARENT is: with a
/// single fork the daemon is this CLI's direct child, so the CLI owes it a
/// `wait` it can never afford to make (the daemon outlives it by design) and the
/// kernel holds a process-table entry until the CLI exits. That is invisible
/// when the spawn succeeds and ugly when it does not, which is the common case
/// here: ~10 coworker CLIs each fork a `serve`, the daemon's exclusive lock
/// admits one, and the nine losers `_exit` within microseconds — nine zombies
/// parked on nine CLIs that are still running their cold walk. A tool that leaks
/// process slots in proportion to how many agents are searching is a tool that
/// eventually cannot fork at all.
///
/// The second fork moves the daemon one generation away, so it is orphaned to
/// init/launchd the instant the intermediate leaves, and the intermediate is a
/// process whose whole life is `setsid` + `fork` + `_exit`. Waiting on THAT is
/// microseconds and cannot block on the daemon's lifetime, so the CLI reaps
/// everything it created and leaves nothing behind. One extra fork, paid only on
/// the rare invocation that actually starts a daemon.
fn detachPosix(gpa: std.mem.Allocator, io: std.Io, verb: [:0]const u8) !void {
    const exe_z = try std.process.executablePathAlloc(io, gpa); // NUL-terminated
    defer gpa.free(exe_z);
    const child_argv = [_:null]?[*:0]const u8{ exe_z.ptr, verb.ptr, null };

    const pid = fork();
    if (pid < 0) return fault.Resource.Exhausted;
    if (pid > 0) {
        reap(pid);
        return;
    }

    // ── intermediate ──: leave the CLI's session, then hand the daemon on so
    // nobody is left owing it a wait.
    _ = std.c.setsid();
    const daemon = fork();
    if (daemon != 0) _exit(if (daemon < 0) 127 else 0);

    // ── grandchild ──: drop the CLI's stdio and become the daemon.
    // No `/dev/null` → keep the CLI's stdio rather than not starting.
    if (std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0) catch null) |nul| {
        _ = std.c.dup2(nul, 0);
        _ = std.c.dup2(nul, 1);
        _ = std.c.dup2(nul, 2);
    }
    _ = execv(exe_z.ptr, &child_argv);
    _exit(127); // only reached if execv failed
}

/// `CreateProcessW` through std's spawner, with the three settings that make the
/// launch a detachment: no console window (`CREATE_NO_WINDOW` — a daemon must
/// not flash a window in front of whoever typed the query, and must not take
/// the CLI's console handles with it), all three streams on `NUL`, and the
/// inherited working directory the POSIX arm also relies on.
///
/// The parent then drops the process and thread handles WITHOUT waiting. That is
/// the detachment: a Windows child does not die with its parent and leaves no
/// zombie to reap, so a wait would only block this CLI behind the daemon's whole
/// lifetime. Releasing the handles is bookkeeping — the CLI exits moments later
/// either way — but a leak the OS cleans up is still a leak this seam can not
/// have.
fn detachWindows(gpa: std.mem.Allocator, io: std.Io, verb: [:0]const u8) !void {
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    var child = std.process.spawn(io, .{
        .argv = &.{ exe, verb },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return fault.Resource.Exhausted;
    std.os.windows.CloseHandle(child.id.?);
    std.os.windows.CloseHandle(child.thread_handle);
    child.id = null;
}
