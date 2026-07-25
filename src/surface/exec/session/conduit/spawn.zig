//! Detached daemon auto-spawn, shared by the resident CLIs (ADR-352 rung 2.5).
//!
//! The warm path only pays off if a daemon is running, but an agent's reflex is
//! a bare query with zero setup — nobody runs `<cli> serve` by hand. So when an
//! eligible query finds no daemon, the CLI fires one off detached and answers
//! this call cold/indexed as usual; every later eligible query within the warm
//! window is served from RAM. It is a pure accelerator: any failure (fork/exec
//! error, unsupported target, a peer that won the race) is swallowed and the
//! query still runs its certified fallback. Herd-safety is the daemon's job
//! (its advisory `flock` admits exactly one racer), not the spawner's.
//!
//! Each CLI keeps its own eligibility policy and socket probe; only the
//! `fork` → detach → `execv` mechanism lives here, once, for gist and relate.

const std = @import("std");
const builtin = @import("builtin");

/// Only these targets have the fork+exec (+ `flock`/kqueue/inotify) machinery
/// the daemons rely on; everywhere else the query just runs its fallback (no-op).
pub const can_spawn = builtin.os.tag == .macos or builtin.os.tag == .linux;

extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;

/// `fork` → child fully detaches (new session, stdio → /dev/null) and `execv`s
/// `<this-executable> verb`; the parent returns at once to run its fallback. All
/// argv/path memory is built BEFORE the fork, so the child touches only
/// async-signal-safe syscalls between fork and exec (no allocator, no std.Io) —
/// safe even with a `std.Io.Threaded` pool present, since `execv` replaces the
/// whole image. The child inherits this process's working directory, so a
/// rootless daemon's served tree is exactly the tree this CLI walks (the basis
/// of warm==cold parity), and the CWD-relative socket path keeps scopes apart.
pub fn detach(gpa: std.mem.Allocator, io: std.Io, verb: [:0]const u8) !void {
    if (comptime !can_spawn) return;
    const exe_z = try std.process.executablePathAlloc(io, gpa); // NUL-terminated
    defer gpa.free(exe_z);
    const child_argv = [_:null]?[*:0]const u8{ exe_z.ptr, verb.ptr, null };

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
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
