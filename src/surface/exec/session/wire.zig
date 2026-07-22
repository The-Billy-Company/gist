//! Length-prefixed frame plumbing for the resident daemons (ADR-352).
//!
//! One grammar, `[u32 LE len][u8 opcode][payload…]` where `len` counts the
//! opcode + payload, shared verbatim by every resident session's socket
//! (gist's regex protocol and relate's retrieval protocol both frame over
//! this). It knows nothing about opcodes' meaning — the opcode is a raw `u8`
//! each protocol maps to its own typed enum — so the byte-level transport,
//! its SIGPIPE guard, and its fail-closed truncation/oversize handling live
//! exactly once instead of once per protocol.
//!
//! Fail-closed: an oversized (`> max_frame`) or zero-length frame is a hard
//! error; a truncated peer read is `ConnClosed`. Opcode validity is the
//! caller's concern (it owns the enum), so this layer never rejects a byte.

const std = @import("std");
const builtin = @import("builtin");

/// Refused before allocation — dwarfs any real response, caps a hostile peer.
pub const max_frame: u32 = 16 << 20;

pub const WireError = error{ FrameTooLarge, Truncated, BadOpcode, BadFrame, ConnClosed, Io, OutOfMemory };

/// Append `v` little-endian to `buf` — the shared width-generic int writer
/// every frame body composes headers/counts with.
pub fn appendInt(comptime T: type, buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: T) !void {
    var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

/// Append a `[len][opcode][payload]` frame to `buf`.
pub fn writeFrame(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, op: u8, payload: []const u8) !void {
    try appendInt(u32, buf, gpa, @intCast(1 + payload.len));
    try buf.append(gpa, op);
    try buf.appendSlice(gpa, payload);
}

pub const Parsed = struct { op: u8, payload: []const u8, consumed: usize };

/// Parse one frame from the front of `bytes`, or `null` when incomplete.
/// `FrameTooLarge` is the only hard error (a raw opcode is always valid here).
pub fn parseFrame(bytes: []const u8) WireError!?Parsed {
    if (bytes.len < 4) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0 or len > max_frame) return WireError.FrameTooLarge;
    const total = 4 + @as(usize, len);
    if (bytes.len < total) return null;
    return .{ .op = bytes[4], .payload = bytes[5..total], .consumed = total };
}

/// Write all of `bytes` to `fd`, retrying short writes; false on a dead peer.
/// Never raises SIGPIPE: Linux uses MSG_NOSIGNAL; Darwin/BSD arms SO_NOSIGPIPE
/// here (idempotent) so server/client/tests inherit the guard. CLI stdout
/// SIGPIPE (`gist | head`) is left intact.
pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    if (comptime builtin.os.tag.isDarwin()) {
        const on: c_int = 1;
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, std.mem.asBytes(&on)) catch {};
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const sent = sendNoSigpipe(fd, bytes.ptr + off, bytes.len - off);
        if (sent <= 0) return false;
        off += @intCast(sent);
    }
    return true;
}

/// One SIGPIPE-safe `send` (see `writeAll`); byte count, ≤ 0 on dead peer/error.
fn sendNoSigpipe(fd: std.posix.fd_t, ptr: [*]const u8, len: usize) isize {
    const flags: u32 = if (comptime builtin.os.tag == .linux) std.posix.MSG.NOSIGNAL else 0;
    return @bitCast(std.posix.system.sendto(fd, ptr, len, flags, null, 0));
}

/// Send one framed message on `fd`.
pub fn sendFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t, op: u8, payload: []const u8) WireError!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    writeFrame(&buf, gpa, op, payload) catch return WireError.OutOfMemory;
    if (!writeAll(fd, buf.items)) return WireError.ConnClosed;
}

/// A framed message read off `fd`, owning its bytes (payload aliases into it).
/// `op` is the raw opcode byte; the caller maps it to its protocol enum.
pub const Frame = struct {
    op: u8,
    bytes: []u8, // whole frame; payload is bytes[5..]
    gpa: std.mem.Allocator,

    pub fn payload(self: *const Frame) []const u8 {
        return self.bytes[5..];
    }
    pub fn deinit(self: *Frame) void {
        self.gpa.free(self.bytes);
    }
};

/// Read exactly `n` bytes into `dst`; false on EOF/short read.
fn readExact(fd: std.posix.fd_t, dst: []u8) bool {
    var off: usize = 0;
    while (off < dst.len) {
        const n = std.posix.system.read(fd, dst.ptr + off, dst.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Receive one whole frame from `fd`. `ConnClosed` on truncated peer;
/// `FrameTooLarge` fails closed.
pub fn recvFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!Frame {
    var hdr: [4]u8 = undefined;
    if (!readExact(fd, &hdr)) return WireError.ConnClosed;
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len == 0 or len > max_frame) return WireError.FrameTooLarge;
    const total = 4 + @as(usize, len);
    const bytes = gpa.alloc(u8, total) catch return WireError.OutOfMemory;
    errdefer gpa.free(bytes);
    @memcpy(bytes[0..4], &hdr);
    if (!readExact(fd, bytes[4..])) return WireError.ConnClosed;
    return .{ .op = bytes[4], .bytes = bytes, .gpa = gpa };
}

// ── SCM_RIGHTS fd passing ────────────────────────────────────────────────────
//
// A single fd rides one frame's `sendmsg` in an ancillary control message; the
// zero-copy emit path (`shm.zig`) uses it to hand the client a shared-memory fd
// instead of streaming the payload bytes. The control-buffer geometry is the
// libc CMSG_* macros computed from the target's `cmsghdr` (its own alignment is
// the CMSG_ALIGN unit — `size_t` on Linux, `u32` on macOS), so it is correct on
// both without hardcoding either layout.

// `recvmsg`/`shm_open` are not `pub` in this Zig's `std.c`; `sendmsg`/`close`
// are, so only the receiver is redeclared here at the same C ABI.
extern "c" fn recvmsg(sockfd: std.posix.fd_t, msg: *std.c.msghdr, flags: u32) isize;

const cmsghdr = std.c.cmsghdr;
const fd_size = @sizeOf(std.posix.fd_t);
const cmsg_align = @alignOf(cmsghdr);
const cmsg_data_off = std.mem.alignForward(usize, @sizeOf(cmsghdr), cmsg_align); // CMSG_DATA offset
const cmsg_len = cmsg_data_off + fd_size; // CMSG_LEN(fd)
const cmsg_space = cmsg_data_off + std.mem.alignForward(usize, fd_size, cmsg_align); // CMSG_SPACE(fd)

/// Overlay a `cmsghdr` on a CMSG_SPACE-sized control buffer. The buffer is
/// sized and aligned for the target's `cmsghdr`; bytesAsValue preserves that
/// provenance without manufacturing a pointer from its address.
fn cmsgHdr(ctrl: *align(cmsg_align) [cmsg_space]u8) *cmsghdr {
    return std.mem.bytesAsValue(cmsghdr, ctrl[0..@sizeOf(cmsghdr)]);
}
fn cmsgHdrConst(ctrl: *align(cmsg_align) const [cmsg_space]u8) *const cmsghdr {
    return std.mem.bytesAsValue(cmsghdr, ctrl[0..@sizeOf(cmsghdr)]);
}

/// Send `bytes` as one message carrying `pass_fd` in an SCM_RIGHTS control
/// message. The fd is delivered with the message's first byte, so a partial
/// first send finishes plain (`writeAll`) with the fd already across. Same
/// SIGPIPE guard as `writeAll`. `false` on a dead peer.
pub fn sendWithFd(fd: std.posix.fd_t, bytes: []const u8, pass_fd: std.posix.fd_t) bool {
    if (comptime builtin.os.tag.isDarwin()) {
        const on: c_int = 1;
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, std.mem.asBytes(&on)) catch {};
    }
    var iov = [_]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var ctrl: [cmsg_space]u8 align(cmsg_align) = undefined;
    @memset(&ctrl, 0);
    const chdr = cmsgHdr(&ctrl);
    chdr.len = @intCast(cmsg_len);
    chdr.level = @intCast(std.c.SOL.SOCKET);
    chdr.type = @intCast(std.c.SCM.RIGHTS);
    var passed = pass_fd;
    @memcpy(ctrl[cmsg_data_off..][0..fd_size], std.mem.asBytes(&passed));
    var msg = std.c.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &ctrl,
        .controllen = @intCast(ctrl.len),
        .flags = 0,
    };
    const flags: u32 = if (comptime builtin.os.tag == .linux) std.posix.MSG.NOSIGNAL else 0;
    const n = std.c.sendmsg(fd, &msg, flags);
    if (n <= 0) return false;
    const sent: usize = @intCast(n);
    return sent >= bytes.len or writeAll(fd, bytes[sent..]);
}

/// A frame received alongside an optional passed fd (null unless the peer sent
/// an SCM_RIGHTS control message with this message). The caller owns `passed_fd`
/// and must close it (or `munmap`+close for an shm fd).
pub const FdFrame = struct { frame: Frame, passed_fd: ?std.posix.fd_t };

/// Like `recvFrame`, but over `recvmsg` so a passed fd is captured rather than
/// silently dropped. Used by a client that advertised fd-transport support; a
/// plain frame simply arrives with `passed_fd == null`.
pub fn recvFrameWithFd(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!FdFrame {
    var passed: ?std.posix.fd_t = null;
    // A captured fd on any later failure would leak the shm handle — close it.
    errdefer if (passed) |p| {
        _ = std.c.close(p);
    };
    var hdr: [4]u8 = undefined;
    if (!recvExactMsg(fd, &hdr, &passed)) return WireError.ConnClosed;
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len == 0 or len > max_frame) return WireError.FrameTooLarge;
    const total = 4 + @as(usize, len);
    const bytes = gpa.alloc(u8, total) catch return WireError.OutOfMemory;
    errdefer gpa.free(bytes);
    @memcpy(bytes[0..4], &hdr);
    if (!recvExactMsg(fd, bytes[4..], &passed)) return WireError.ConnClosed;
    return .{ .frame = .{ .op = bytes[4], .bytes = bytes, .gpa = gpa }, .passed_fd = passed };
}

/// Read exactly `dst.len` bytes via `recvmsg`, capturing the first SCM_RIGHTS fd
/// seen into `out_fd`. False on EOF/short read.
fn recvExactMsg(fd: std.posix.fd_t, dst: []u8, out_fd: *?std.posix.fd_t) bool {
    var off: usize = 0;
    while (off < dst.len) {
        var iov = [_]std.posix.iovec{.{ .base = dst.ptr + off, .len = dst.len - off }};
        var ctrl: [cmsg_space]u8 align(cmsg_align) = undefined;
        var msg = std.c.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &ctrl,
            .controllen = @intCast(ctrl.len),
            .flags = 0,
        };
        const n = recvmsg(fd, &msg, 0);
        if (n <= 0) return false;
        if (out_fd.* == null and @as(usize, @intCast(msg.controllen)) >= cmsg_len) {
            const chdr = cmsgHdrConst(&ctrl);
            if (chdr.level == @as(i32, @intCast(std.c.SOL.SOCKET)) and chdr.type == @as(i32, @intCast(std.c.SCM.RIGHTS))) {
                var got: std.posix.fd_t = undefined;
                @memcpy(std.mem.asBytes(&got), ctrl[cmsg_data_off..][0..fd_size]);
                out_fd.* = got;
            }
        }
        off += @intCast(n);
    }
    return true;
}
