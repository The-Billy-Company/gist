//! Detached daemon auto-spawn, shared by the resident CLIs (ADR-352 rung 2.5).
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
const fault = @import("../../../fault.zig");
const portal = @import("../../../portal.zig");

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

/// `fork` → child fully detaches (new session, stdio → /dev/null) and `execv`s
/// the daemon; the parent returns at once. All argv/path memory is built BEFORE
/// the fork, so the child touches only async-signal-safe syscalls between fork
/// and exec (no allocator, no std.Io) — safe even with a `std.Io.Threaded` pool
/// present, since `execv` replaces the whole image.
fn detachPosix(gpa: std.mem.Allocator, io: std.Io, verb: [:0]const u8) !void {
    const exe_z = try std.process.executablePathAlloc(io, gpa); // NUL-terminated
    defer gpa.free(exe_z);
    const child_argv = [_:null]?[*:0]const u8{ exe_z.ptr, verb.ptr, null };

    const pid = fork();
    if (pid < 0) return fault.Resource.Exhausted;
    if (pid > 0) return; // parent — the daemon warms while this query runs cold

    // ── child ──: detach from the CLI's session + stdio, then become the daemon.
    _ = std.c.setsid();
    // No `/dev/null` → the child keeps the CLI's stdio rather than not starting.
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
