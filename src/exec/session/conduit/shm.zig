//! shm — a portable, anonymous, one-shot shared buffer for fd-passed emit.
//!
//! The warm daemon renders a large `lines` answer into ONE of these, hands the
//! client its fd over the socket's SCM_RIGHTS control channel (`wire.zig`), and
//! the client mmaps it read-only straight to stdout — so a multi-MB answer never
//! traverses the socket (no user→kernel→user copy of the payload bytes, only the
//! fd rides the wire). It backs the same finished bytes the `chunk` frames would
//! carry; nothing about how they're computed changes.
//!
//! Anonymous + bounded to the exact rendered length on both platforms:
//!   * Linux — `memfd_create` then, once the daemon's writable view is gone,
//!     sealed immutable (`F_SEAL_WRITE|SHRINK|GROW|SEAL`) so the client's view
//!     can never be resized or rewritten under it.
//!   * macOS — `shm_open(O_CREAT|O_EXCL)` on a unique name, `shm_unlink`ed
//!     IMMEDIATELY (the fd stays valid after unlink) so no name lingers in the
//!     global namespace for another process to open.
//!
//! Fail-open, and typed as such: every fallible call **declines** rather than
//! erroring, and the caller turns the declinature back into the classic
//! `chunk`-frame path. This buffer is a pure accelerator, never a new source of
//! truth or a new failure mode — which is exactly why "the shared buffer could
//! not be stood up" belongs on `fault.Answer`'s success channel (ADR-373 law 1)
//! and not in an error set a caller could `try` past into an abort.

const std = @import("std");
const builtin = @import("builtin");
const fault = @import("../../../fault.zig");
const portal = @import("../../../portal.zig");

/// Only the two targets whose fd-passing + anonymous-shm story we implement and
/// measure. Everywhere else the caller stays on `chunk` frames — including
/// Windows, which hosts a resident session but cannot pass a descriptor over the
/// socket at all (`portal.fd_passing`), so a handle-based shm would be a second
/// protocol rather than a second spelling. It also gates the mapping calls, since
/// the whole module is POSIX shared memory: a target this is false on has neither
/// end of the handoff, and `resident_sessions` is now true on one such target.
pub const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

const page = std.heap.page_size_min;

/// The one declinature this module produces. An unsupported platform, a
/// refused `memfd_create`/`shm_open`, and a failed `mmap` were three names
/// (`Unsupported`/`ShmFailed`/`MapFailed`) that no caller ever told apart —
/// each means "no shared buffer here; stream chunk frames instead", which is
/// `capability_missing` in the declared vocabulary.
const declined: fault.Answer(Buffer) = .{ .declined = .capability_missing };

/// Test-only fault injection for the forced-fallback proof: when set, `create`
/// declines so `render.renderLinesShm` returns its `.chunk` variant
/// and the daemon streams the answer as chunk frames for an otherwise fd-eligible
/// answer — proving the fd→chunk fallback is byte-identical. Compiled out
/// entirely outside `zig build test`, so the production path pays nothing.
pub var force_fail_for_test: std.atomic.Value(bool) = .init(false);

// Not `pub` in this Zig's `std.c`; declared here at the C ABI it uses elsewhere.
extern "c" fn shm_open(name: [*:0]const u8, flag: c_int, mode: std.c.mode_t) c_int;

/// macOS shm names must be unique per object (O_EXCL) and short (PSHMNAMLEN=31);
/// pid + a monotonic counter keeps them unique across a daemon's lifetime.
/// Pointer-width like the other atomic counters here: an atomic may not exceed
/// the target's largest atomic (4 bytes on 32-bit), and `usize` is `u64` on every
/// 64-bit target. Only the low bits reach the name anyway.
var darwin_seq: std.atomic.Value(usize) = .init(0);

/// A writable shared buffer the daemon fills once, then freezes. After `freeze`
/// the bytes are immutable and `fd` is ready to hand to the client; `close`
/// releases the daemon's handle (the object lives until the client's fd closes).
pub const Buffer = struct {
    fd: std.posix.fd_t,
    /// The daemon's writable mapping — valid only until `freeze` (then empty).
    map: []align(page) u8,

    /// An anonymous shared object of exactly `len` bytes, mapped writable, or a
    /// declinature the caller answers with chunk frames.
    pub fn create(len: usize) fault.Answer(Buffer) {
        if (!supported or len == 0) return declined;
        if (comptime builtin.is_test) {
            if (force_fail_for_test.load(.monotonic)) return declined;
        }
        const fd = openAnon(len) orelse return declined;
        // Not `errdefer`: declining is a SUCCESS return now, so the fd has to be
        // shed explicitly on the one path that abandons it.
        const m = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
            _ = std.c.close(fd);
            return declined;
        };
        return .{ .got = .{ .fd = fd, .map = m } };
    }

    /// Drop the daemon's writable view and (Linux) seal the object immutable,
    /// leaving only `fd` to send. Call once, after filling `map`.
    pub fn freeze(self: *Buffer) void {
        std.posix.munmap(self.map);
        self.map = self.map[0..0];
        if (comptime builtin.os.tag == .linux) {
            const F = std.os.linux.F;
            // Best-effort: the client maps read-only regardless; sealing is
            // defense-in-depth against a resize/rewrite under its view.
            _ = std.os.linux.fcntl(self.fd, F.ADD_SEALS, F.SEAL_SEAL | F.SEAL_SHRINK | F.SEAL_GROW | F.SEAL_WRITE);
        }
    }

    /// Release the daemon's handle. Unmaps the writable view first if `freeze`
    /// was never called (the below-floor path reads `map` then closes without
    /// handing the fd off), so no mapping leaks either way. The shared object
    /// itself lives until the client's fd closes too.
    pub fn close(self: *Buffer) void {
        if (self.map.len != 0) {
            std.posix.munmap(self.map);
            self.map = self.map[0..0];
        }
        _ = std.c.close(self.fd);
    }
};

/// Map a received buffer fd read-only for the exact `len` the frame declared.
/// The daemon has already frozen it, so the view is a stable immutable snapshot.
/// Declines on the same terms as `create`; the client re-asks cold.
pub fn mapReadonly(fd: std.posix.fd_t, len: usize) fault.Answer([]align(page) const u8) {
    if (comptime !supported) return .{ .declined = .capability_missing };
    return mapReadonlyPosix(fd, len);
}

fn mapReadonlyPosix(fd: std.posix.fd_t, len: usize) fault.Answer([]align(page) const u8) {
    if (len == 0) return .{ .declined = .capability_missing };
    const m = std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0) catch
        return .{ .declined = .capability_missing };
    return .{ .got = m };
}

pub fn unmap(m: []align(page) const u8) void {
    if (comptime supported) std.posix.munmap(m);
}

/// An anonymous, `len`-sized fd, or `null` when this platform won't give one.
/// Optional rather than fallible for the same reason `create` is: there is no
/// failure here, only the absence of an accelerator. Each `null` path closes
/// whatever it already opened, since no `errdefer` can fire on a plain return.
fn openAnon(len: usize) ?std.posix.fd_t {
    if (comptime builtin.os.tag == .linux) {
        const fd = std.posix.memfd_create("gist-emit", std.os.linux.MFD.ALLOW_SEALING) catch return null;
        if (std.c.ftruncate(fd, @intCast(len)) != 0) {
            _ = std.c.close(fd);
            return null;
        }
        return fd;
    } else if (comptime builtin.os.tag.isDarwin()) {
        var namebuf: [32]u8 = undefined;
        const seq = darwin_seq.fetchAdd(1, .monotonic);
        const name = std.fmt.bufPrintZ(&namebuf, "/gist.{x}.{x}", .{ portal.processId(), seq }) catch return null;
        const oflag: c_int = @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
        const fd = shm_open(name.ptr, oflag, 0o600);
        if (fd < 0) return null;
        // Unlink at once: the fd stays valid, but no name survives for another
        // process to reach and the object is reclaimed when the last fd closes.
        _ = std.c.shm_unlink(name.ptr);
        if (std.c.ftruncate(fd, @intCast(len)) != 0) {
            _ = std.c.close(fd);
            return null;
        }
        return fd;
    } else return null;
}

test "round-trip: daemon writes, reader maps identical bytes" {
    if (!supported) return error.SkipZigTest;
    const payload = "path/to/file.zig:42:const x = 1;\n" ** 4096; // ~135 KB
    var buf = Buffer.create(payload.len).got;
    defer buf.close();
    @memcpy(buf.map[0..payload.len], payload);
    buf.freeze();
    const view = mapReadonly(buf.fd, payload.len).got;
    defer unmap(view);
    try std.testing.expectEqualSlices(u8, payload, view[0..payload.len]);
}

test "zero length declines (stays on chunk frames)" {
    try std.testing.expectEqual(fault.Decline.capability_missing, Buffer.create(0).declined);
    try std.testing.expectEqual(fault.Decline.capability_missing, mapReadonly(portal.invalid_handle, 0).declined);
}
