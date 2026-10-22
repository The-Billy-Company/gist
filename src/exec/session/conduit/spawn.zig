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
//! session to leave: the child does not die with its parent, but must be given
//! its own stdio without inheriting the CLI's other handles. So this file has
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
const w = std.os.windows;

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

// std's Windows spawner assigns redirected stdio but still inherits EVERY
// inheritable handle. A captured CLI's original pipe writers then survive in
// the daemon even though its stdio points at NUL, so the shell waits for EOF
// until the daemon's idle TTL. This allowlist is the missing distinction.
const AttributeList = opaque {};
const StartupInfoEx = extern struct {
    startup: w.STARTUPINFOW,
    attributes: *AttributeList,
};

extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*AttributeList, count: w.DWORD, flags: w.DWORD, size: *usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: *AttributeList, flags: w.DWORD, attribute: usize, value: *anyopaque, size: usize, previous: ?*anyopaque, returned: ?*usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *AttributeList) callconv(.winapi) void;

/// Launch with no console window and exactly one inherited handle: `NUL`, used
/// for all three standard streams. In particular, a shell's capture pipes must
/// not survive in this long-lived daemon. The working directory and environment
/// are inherited just as they are in the POSIX arm.
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
    const exe_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, exe);
    defer gpa.free(exe_w);
    // An executable path cannot contain a quote, and the only verbs this seam
    // launches are the fixed words "serve" and "index". Quote argv[0] so an
    // installation under Program Files still starts the same executable.
    const command = try std.fmt.allocPrint(gpa, "\"{s}\" {s}", .{ exe, verb });
    defer gpa.free(command);
    const command_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, command);
    defer gpa.free(command_w);

    var nul: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtOpenFile(
        &nul,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_DATA = true, .WRITE_DATA = true } },
        },
        &.{
            .Attributes = .{ .INHERIT = true },
            .ObjectName = @constCast(&w.UNICODE_STRING.init(
                std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\Null"),
            )),
        },
        &iosb,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => {},
        else => return fault.Resource.Exhausted,
    }
    defer w.CloseHandle(nul);

    // The sizing call deliberately fails with INSUFFICIENT_BUFFER while
    // reporting the opaque list's required size.
    var attribute_bytes: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
    if (attribute_bytes == 0) return fault.Resource.Exhausted;
    const storage = try gpa.alignedAlloc(u8, .@"16", attribute_bytes);
    defer gpa.free(storage);
    const attributes: *AttributeList = @ptrCast(storage.ptr);
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes).toBool())
        return fault.Resource.Exhausted;
    defer DeleteProcThreadAttributeList(attributes);
    // ProcThreadAttributeValue(HandleList=2, thread=false, input=true,
    // additive=false), from the Windows SDK's winbase.h.
    const handle_list: usize = 0x00020002;
    if (!UpdateProcThreadAttribute(attributes, 0, handle_list, @ptrCast(&nul), @sizeOf(w.HANDLE), null, null).toBool())
        return fault.Resource.Exhausted;

    var startup: StartupInfoEx = .{
        .startup = std.mem.zeroes(w.STARTUPINFOW),
        .attributes = attributes,
    };
    startup.startup.cb = @sizeOf(StartupInfoEx);
    startup.startup.dwFlags = w.STARTF_USESTDHANDLES;
    startup.startup.hStdInput = nul;
    startup.startup.hStdOutput = nul;
    startup.startup.hStdError = nul;
    var process: w.PROCESS.INFORMATION = undefined;
    if (!w.kernel32.CreateProcessW(
        exe_w.ptr,
        command_w.ptr,
        null,
        null,
        .TRUE, // HANDLE_LIST restricts inheritance to NUL.
        .{ .create_no_window = true, .extended_startupinfo_present = true },
        null,
        null,
        &startup.startup,
        &process,
    ).toBool()) return fault.Resource.Exhausted;
    w.CloseHandle(process.hThread);
    w.CloseHandle(process.hProcess);
}
