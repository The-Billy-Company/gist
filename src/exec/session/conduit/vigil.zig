//! vigil — the daemon's wait, the pair it watches, and the bell that cuts it short.
//!
//! `loop.zig` is one wait over three kinds of handle: the listener, every
//! currently-idle client, and a bell a worker rings when it finishes a query. On
//! POSIX that wait is `poll(2)`, and this module is where that spelling stops
//! being assumed.
//!
//! **Why the wait and the bell live in one module.** They look like separate
//! primitives and are not: the bell's *shape is dictated by the wait*. Windows
//! asks its readiness question of the AFD driver, which is the transport under a
//! socket and knows nothing about pipes — so a pipe bell would be invisible to
//! the wait, and every finished query would sit out the idle timeout instead of
//! being collected at once. POSIX will watch either. So the bell is a connected
//! socket *pair* on both, which is the choice that removes a platform difference
//! rather than adding one: `Pair` opens it, `Bell` gives it a meaning, and
//! neither knows anything about the other's platform. Splitting them into two
//! files would put that coupling in a comment instead of in the type system.
//!
//! **The Win32 wait is the same question, not a different loop.** `poll(2)` says
//! *"of these handles, which can be served now, and wake me no later than T"*.
//! `IOCTL_AFD_POLL` says exactly that — a set of handles, an interest mask per
//! handle, and a timeout carried in the request itself — so the daemon's poll
//! set, its routing, its worker pool, and its two-stage idle policy all survive
//! the port unchanged. That mattered more than elegance: the alternative was a
//! second accept loop for Windows, which would have meant the warm tier's
//! concurrency and idle behavior were two implementations to keep honest instead
//! of one. (`std.posix.poll` is a hard `@compileError` on Windows, `WSAPoll` is
//! absent from std's ws2_32 bindings, and would not accept these handles anyway:
//! std creates sockets as raw AFD endpoints rather than through `WSASocketW`, so
//! there is no ws2_32 handle-table entry for it to find. `std.Io` grew `async`
//! and `Future` but no `select`, so there is no portable readiness primitive to
//! defer to yet.)
//!
//! Nothing here is required for correctness. A daemon that cannot open its AFD
//! device declines to serve and every query answers cold, which is the same
//! fallback a client already takes when it cannot reach a daemon at all.

const std = @import("std");
const builtin = @import("builtin");
const portal = @import("irregex").portal;
const rendezvous = @import("rendezvous.zig");

const windows = builtin.os.tag == .windows;
const w = std.os.windows;
const net = std.Io.net;

pub const Handle = portal.Handle;

/// Ceiling on one wait's set. The daemon presents `2 + crew.max_clients` (the
/// listener, the bell, and every idle client — 66 today), so this is roughly
/// double the real high-water mark.
///
/// It is a fixed ceiling rather than a growable list because the Win32 arm hands
/// the kernel ONE buffer whose length must be known before the call, and this
/// sits on the loop's hot path where an allocation per wakeup would be pure
/// overhead. `crew` deliberately isn't imported for the number: this seam must
/// not depend upward on the daemon that uses it.
pub const max_watched: usize = 128;

/// What one handle is reporting.
///
/// Three bits rather than one because the daemon reads them differently, and
/// collapsing them would quietly change POSIX behavior. A client is served on
/// ANY of them — a hangup is a frame's worth of news, since the read returns 0
/// and the slot frees — while the listener and the bell are acted on only for
/// `readable`, so a bare error on either must not be mistaken for an arriving
/// connection or a finished query.
pub const Ready = packed struct(u8) {
    /// Bytes to read, a connection to accept, or a peer that closed cleanly.
    readable: bool = false,
    /// The peer hung up.
    hangup: bool = false,
    /// The handle itself is in error.
    failed: bool = false,
    _unused: u5 = 0,

    pub fn any(r: Ready) bool {
        return r.readable or r.hangup or r.failed;
    }
};

/// One handle to wait on. `ready` is written by `Vigil.wait` and is meaningless
/// before it (and stale after the next call, exactly like `pollfd.revents`).
pub const Watch = struct {
    handle: Handle,
    ready: Ready = .{},
};

/// `TooManyWatched` is a caller bug (a set above `max_watched`) rather than a
/// platform condition; the other two are the same two `std.posix.poll` already
/// produces, so the POSIX arm passes them straight through and the Win32 arm
/// answers in the same vocabulary.
pub const WaitError = error{ TooManyWatched, SystemResources, Unexpected };

/// The wait itself. Stateless on POSIX; on Windows it holds the AFD device
/// handle every readiness question is asked through, plus the event that request
/// completes on, so neither is reopened per wakeup.
pub const Vigil = struct {
    keeper: if (windows) Afd else void,

    pub fn open() WaitError!Vigil {
        if (comptime !windows) return .{ .keeper = {} };
        return .{ .keeper = try Afd.open() };
    }

    pub fn close(self: *Vigil) void {
        if (comptime windows) self.keeper.close();
    }

    /// Wait until at least one of `watches` can be served or `timeout_ms`
    /// elapses (`-1` waits indefinitely), then stamp every entry's `ready` and
    /// return how many reported anything — `poll(2)`'s return, and `0` is what
    /// tells the caller its timeout fired rather than its handles moved.
    pub fn wait(self: *Vigil, watches: []Watch, timeout_ms: i32) WaitError!usize {
        if (watches.len > max_watched) return error.TooManyWatched;
        if (comptime !windows) return pollWait(watches, timeout_ms);
        return self.keeper.wait(watches, timeout_ms);
    }
};

/// The one-handle question, for a caller that asks it a handful of times per run
/// and holds no loop state: is `handle` readable within `timeout_ms`?
///
/// This is the client's deadline (`daemon/client/client.zig`), and it is the only
/// thing standing between a wedged daemon and a CLI that never returns — so it
/// must be a real wait on every platform, not an optimistic `true`. On POSIX it
/// is one `poll(2)`; on Windows it opens an AFD device for the single question and
/// closes it after, which costs two handle operations per wait and is why the
/// resident loop keeps its own `Vigil` instead of calling this per wakeup.
///
/// Only readability counts. A bare hangup or error must not read as "a frame
/// arrived" — that would skip the deadline and race a closing peer — and a peer
/// that closed having written nothing still reports readable (the read returns 0),
/// so EOF is not lost either way.
pub fn readable(handle: Handle, timeout_ms: i32) bool {
    var one = [_]Watch{.{ .handle = handle }};
    var vigil = Vigil.open() catch return false;
    defer vigil.close();
    const n = vigil.wait(&one, timeout_ms) catch return false;
    return n > 0 and one[0].ready.readable;
}

/// Hand `bytes` to a local socket handle; the count the kernel accepted, or null
/// if it refused. A short count is not an error — `wire.zig` loops on it.
///
/// Named for the vtable entries they wrap, because that is all they are: the
/// `std.Io` shape spelled out ONCE, in the module every local-socket handle here
/// already comes from. It is
/// a scatter/gather interface with a splat pattern in its tail, so "write these
/// bytes" is not the obvious call it looks like: `data` must be non-empty (its
/// last element is the pattern), which means the naive `&.{}` underflows inside
/// std rather than writing nothing. That is a fact worth learning at one call
/// site, not three.
pub fn netWrite(io: std.Io, handle: Handle, bytes: []const u8) ?usize {
    // Everything in the header, one empty pattern, splat zero: exactly one iovec
    // and no repetition.
    return io.vtable.netWrite(io.userdata, handle, bytes, &.{""}, 0) catch null;
}

/// Whatever has already arrived on `handle`, up to `buf.len`; `0` is a clean EOF
/// and null is a failed read.
pub fn netRead(io: std.Io, handle: Handle, buf: []u8) ?usize {
    var into: [1][]u8 = .{buf};
    return io.vtable.netRead(io.userdata, handle, &into) catch null;
}

fn pollWait(watches: []Watch, timeout_ms: i32) WaitError!usize {
    const P = std.posix.POLL;
    var pfds: [max_watched]std.posix.pollfd = undefined;
    const set = pfds[0..watches.len];
    for (watches, set) |watch, *pfd| pfd.* = .{ .fd = watch.handle, .events = P.IN, .revents = 0 };
    const n = std.posix.poll(set, timeout_ms) catch |e| return switch (e) {
        error.SystemResources => error.SystemResources,
        else => error.Unexpected,
    };
    for (watches, set) |*watch, pfd| watch.ready = .{
        .readable = pfd.revents & P.IN != 0,
        .hangup = pfd.revents & P.HUP != 0,
        .failed = pfd.revents & P.ERR != 0,
    };
    return n;
}

/// Not in `std.os.windows`; declared here at the ABI it has everywhere. The
/// event is reset before each request rather than after, so a previous wakeup
/// that completed synchronously — signaling the event without anyone waiting on
/// it — cannot satisfy the next wait before the driver has written an answer.
extern "ntdll" fn NtResetEvent(EventHandle: w.HANDLE, PreviousState: ?*w.LONG) callconv(.winapi) w.NTSTATUS;

/// The Win32 arm: one handle on `\Device\Afd` that every readiness question is
/// asked through, and one event those questions complete on.
///
/// The handles being asked ABOUT need no relationship to this one — that is what
/// makes a single device handle able to stand in for a whole poll set, and it is
/// the same arrangement wepoll and libuv use to give Windows an epoll. Ours is
/// simpler than theirs in one respect: they must first unwrap a ws2_32 socket
/// down to its base AFD handle (`SIO_BASE_HANDLE`) because a layered service
/// provider can sit in between, while std hands us AFD endpoints directly, so
/// there is no layer to peel.
const Afd = struct {
    device: w.HANDLE,
    /// Manual-reset: the reset is explicit (see `NtResetEvent`) precisely so a
    /// synchronous completion cannot leave a signal banked for the next wait.
    signal: w.HANDLE,

    // AFD's readiness bits. Not in std, and stable since NT — these are the
    // masks ws2_32 itself sets when it implements `select`/`WSAPoll`.
    const receive: w.ULONG = 0x0001;
    const receive_expedited: w.ULONG = 0x0002;
    const disconnect: w.ULONG = 0x0008;
    const abort: w.ULONG = 0x0010;
    const local_close: w.ULONG = 0x0020;
    const accept_ready: w.ULONG = 0x0080;
    const connect_fail: w.ULONG = 0x0100;

    /// Everything that maps onto a `POLL.IN`/`HUP`/`ERR` answer. `SEND` is
    /// deliberately absent: the daemon only ever asks "is there something to
    /// read here", and asking about writability would report every idle
    /// connection ready on every wakeup.
    const interest: w.ULONG =
        receive | receive_expedited | accept_ready | disconnect | abort | local_close | connect_fail;

    const HandleInfo = extern struct {
        handle: w.HANDLE,
        events: w.ULONG,
        status: w.NTSTATUS,
    };

    /// `AFD_POLL_INFO`. The trailing array is declared at full capacity but only
    /// ever SENT as `header + count * @sizeOf(HandleInfo)` bytes, which is why
    /// `@sizeOf(Info)` must never be used as the request length.
    const Info = extern struct {
        timeout: w.LARGE_INTEGER,
        count: w.ULONG,
        exclusive: w.ULONG,
        entries: [max_watched]HandleInfo,

        fn bytes(self: *const Info, n: usize) []const u8 {
            return @as([*]const u8, @ptrCast(self))[0 .. @offsetOf(Info, "entries") + n * @sizeOf(HandleInfo)];
        }
    };

    /// An absolute deadline this far out is how AFD spells "no timeout" — the
    /// field is one `LARGE_INTEGER` doing double duty, negative meaning a
    /// relative interval and positive an absolute instant.
    const forever: w.LARGE_INTEGER = std.math.maxInt(w.LARGE_INTEGER);

    fn open() WaitError!Afd {
        var device: w.HANDLE = undefined;
        var iosb: w.IO_STATUS_BLOCK = undefined;
        // Any trailing name is accepted; a distinctive one makes the handle
        // legible in Process Explorer next to a coworker's.
        const name = w.AFD.DEVICE_NAME ++ [_]u16{ '\\', 'V', 'i', 'g', 'i', 'l' };
        switch (w.ntdll.NtCreateFile(
            &device,
            .{ .STANDARD = .{ .SYNCHRONIZE = true } },
            &.{ .ObjectName = @constCast(&w.UNICODE_STRING.init(name)) },
            &iosb,
            null,
            .{},
            .{ .READ = true, .WRITE = true },
            .OPEN,
            // Asynchronous, so a request can report `PENDING` and be waited on
            // — which is the whole mechanism.
            .{ .IO = .ASYNCHRONOUS },
            null,
            0,
        )) {
            .SUCCESS => {},
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => return error.Unexpected,
        }
        errdefer w.CloseHandle(device);

        var signal: w.HANDLE = undefined;
        // SYNCHRONIZE to wait on it, EVENT_MODIFY_STATE to reset it. Nothing else.
        switch (w.ntdll.NtCreateEvent(
            &signal,
            .{ .STANDARD = .{ .SYNCHRONIZE = true }, .SPECIFIC = .{ .bits = 0x0002 } },
            null,
            .Notification,
            .FALSE,
        )) {
            .SUCCESS => {},
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => return error.Unexpected,
        }
        return .{ .device = device, .signal = signal };
    }

    fn close(self: *Afd) void {
        w.CloseHandle(self.signal);
        w.CloseHandle(self.device);
    }

    fn wait(self: *Afd, watches: []Watch, timeout_ms: i32) WaitError!usize {
        var request: Info = .{
            .timeout = if (timeout_ms < 0) forever else -@as(w.LARGE_INTEGER, timeout_ms) * 10_000,
            .count = @intCast(watches.len),
            // Non-exclusive: other waiters on the same handles keep their
            // registrations. Only ever relevant if a second thread polled the
            // same sockets, which the daemon's single-owner design forbids —
            // but claiming exclusivity we don't need would be a lie the kernel
            // enforces.
            .exclusive = 0,
            .entries = undefined,
        };
        for (watches, request.entries[0..watches.len]) |watch, *entry| entry.* = .{
            .handle = watch.handle,
            .events = interest,
            .status = .SUCCESS,
        };
        // The driver answers into a SEPARATE buffer, compacting the ready
        // handles to the front — so the request's own entries must not be
        // reused as the reply's, or a partially-written answer would be read
        // back as if every handle had reported.
        var reply: Info = undefined;
        var iosb: w.IO_STATUS_BLOCK = undefined;

        _ = NtResetEvent(self.signal, null);
        const issued = w.ntdll.NtDeviceIoControlFile(
            self.device,
            self.signal,
            null,
            null,
            &iosb,
            w.IOCTL.AFD.POLL,
            @ptrCast(&request),
            @intCast(request.bytes(watches.len).len),
            @ptrCast(&reply),
            @intCast(@offsetOf(Info, "entries") + watches.len * @sizeOf(HandleInfo)),
        );
        switch (issued) {
            .SUCCESS => {},
            // Parked until the deadline or a handle moves. The event, not the
            // status block, is what says the answer has landed.
            .PENDING => switch (w.ntdll.NtWaitForSingleObject(self.signal, .FALSE, null)) {
                .SUCCESS => {},
                else => return error.Unexpected,
            },
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => return error.Unexpected,
        }
        switch (iosb.u.Status) {
            .SUCCESS => {},
            // The deadline, spelled as a completion rather than an error: no
            // handle moved, which is `poll`'s zero return.
            .TIMEOUT => {
                for (watches) |*watch| watch.ready = .{};
                return 0;
            },
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            else => return error.Unexpected,
        }
        return harvest(watches, &reply);
    }

    /// Fold the driver's compacted reply back onto the caller's set. The reply
    /// names handles, not positions, so this is a lookup rather than a zip —
    /// and a handle the driver did not mention simply reports nothing, which is
    /// what leaves `poll`'s "untouched means not ready" contract intact.
    fn harvest(watches: []Watch, reply: *const Info) usize {
        for (watches) |*watch| watch.ready = .{};
        var woke: usize = 0;
        for (reply.entries[0..@min(reply.count, watches.len)]) |entry| {
            for (watches) |*watch| {
                if (watch.handle != entry.handle) continue;
                if (!watch.ready.any()) woke += 1;
                // A close/abort is BOTH readable and a hangup on purpose: the
                // POSIX side reports IN alongside HUP for a peer that closed
                // after writing, and the read that follows is what distinguishes
                // "a final frame" from "gone" — so the daemon must still be
                // sent to read, exactly as it is on POSIX.
                if (entry.events & (receive | receive_expedited | accept_ready) != 0) watch.ready.readable = true;
                if (entry.events & (disconnect | local_close) != 0) {
                    watch.ready.readable = true;
                    watch.ready.hangup = true;
                }
                if (entry.events & (abort | connect_fail) != 0) watch.ready.failed = true;
                break;
            }
        }
        return woke;
    }
};

/// Two connected local-socket handles, both watchable by a `Vigil` and both
/// readable/writable through `std.Io`'s socket vtable — so a caller that holds one
/// needs no platform branch of its own. That is the point of the type: the two
/// platforms build the pair differently and nothing downstream can tell.
///
/// Stream sockets rather than a pipe even on POSIX, where a pipe would be a
/// syscall cheaper. A pipe is unidirectional and is not a socket, so it would
/// bifurcate every caller: the AFD wait cannot see one at all, and `netRead` /
/// `netWrite` do not speak to one. Paying one syscall once at daemon startup to
/// delete that fork is not a trade worth thinking about twice.
///
/// The two `open` arms are not two spellings of one call. POSIX has
/// `socketpair(2)`; Windows has no such call and has to *build* the pair by
/// dialing a private name. That difference is the entire reason this type exists
/// — it is paid once, here, instead of at every site that wants two connected
/// handles.
pub const Pair = struct {
    /// Conventionally the end that is watched.
    ear: Handle,
    /// Conventionally the end that is written to.
    clapper: Handle,

    /// Names the Windows rendezvous uniquely within a process, so two pairs
    /// opened concurrently cannot collide on it. Pointer-width like the other
    /// counters here — an atomic may not exceed the target's widest.
    var seq: std.atomic.Value(usize) = .init(0);

    pub fn open(io: std.Io) WaitError!Pair {
        if (comptime !windows) return openPosix();
        return openWindows(io);
    }

    /// One `socketpair(2)`, spelled at the C ABI rather than through
    /// `net.Socket.createPair`: std's portable spelling only takes `.ip4`/`.ip6`
    /// for the family, so it cannot ask for the local domain at all, and an
    /// `AF_INET` socketpair is refused by every BSD kernel including Darwin's.
    fn openPosix() WaitError!Pair {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
        return .{ .ear = fds[0], .clapper = fds[1] };
    }

    /// A socketpair, the long way round: Windows has no `socketpair(2)` (std's
    /// `createPair` is `posix.system.socketpair` and declines there), so the pair
    /// is made by listening on a private name, dialing it, and accepting once. The
    /// name is deleted as soon as both ends exist — it was only ever a rendezvous,
    /// and leaving it on disk would let anything that could guess it write into
    /// this process's private channel.
    fn openWindows(io: std.Io) WaitError!Pair {
        var dir_buf: [portal.max_path]u8 = undefined;
        var path_buf: [portal.max_path]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/gist-pair.{x}.{x}", .{
            portal.scratchDir(&dir_buf),
            portal.processId(),
            seq.fetchAdd(1, .monotonic),
        }) catch return error.Unexpected;
        const ua = rendezvous.address(path) catch return error.Unexpected;
        var listener = ua.listen(io, .{}) catch return error.Unexpected;
        defer listener.deinit(io);
        defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const clapper = ua.connect(io) catch return error.Unexpected;
        errdefer clapper.close(io);
        const ear = listener.accept(io) catch return error.Unexpected;
        return .{ .ear = ear.socket.handle, .clapper = clapper.socket.handle };
    }

    /// By handle rather than through `net.Socket.close`: a `Socket` also carries
    /// the address it was bound to, and a rendezvous that has already been
    /// unlinked has nothing truthful to put there.
    pub fn close(self: *const Pair, io: std.Io) void {
        io.vtable.netClose(io.userdata, &.{ self.ear, self.clapper });
    }

    /// Write `bytes` to the far end, best-effort. Short writes are the caller's
    /// problem; every user here sends a single byte.
    pub fn write(self: *const Pair, io: std.Io, bytes: []const u8) void {
        _ = netWrite(io, self.clapper, bytes) orelse {};
    }

    /// Whatever has already arrived on the watched end, up to `buf.len`. Empty on
    /// error or a clean EOF — a caller that needs to tell those apart is using
    /// the wrong type.
    pub fn read(self: *const Pair, io: std.Io, buf: []u8) []u8 {
        return buf[0 .. netRead(io, self.ear, buf) orelse 0];
    }
};

/// The bell a worker rings to cut the wait short — one byte, no payload, no
/// ordering: its only job is to make the wait return so the loop drains the
/// completions a worker already published under the pool mutex.
///
/// A `Pair` with a meaning attached, and the meaning is the whole content: the
/// daemon watches `ear` beside its listener and its clients, a worker rings
/// `clapper`, and the bytes are never inspected by anyone.
pub const Bell = struct {
    channel: Pair,

    pub fn open(io: std.Io) WaitError!Bell {
        return .{ .channel = try Pair.open(io) };
    }

    pub fn close(self: *const Bell, io: std.Io) void {
        self.channel.close(io);
    }

    /// The handle the daemon's wait set watches.
    pub fn ear(self: *const Bell) Handle {
        return self.channel.ear;
    }

    /// One byte per completion. The channel holds at most `crew.max_clients`
    /// outstanding bytes — far under either platform's buffer — so this never
    /// blocks in practice, and a dropped byte costs only latency: the residue
    /// re-triggers the wait on the next pass.
    pub fn ring(self: *const Bell, io: std.Io) void {
        self.channel.write(io, &[_]u8{1});
    }

    /// Clear the accumulated rings after the wait reported the ear readable.
    /// One read is enough — anything left simply wakes the next wait, which
    /// then drains an already-empty completion queue and costs nothing.
    pub fn quiet(self: *const Bell, io: std.Io) void {
        var buf: [256]u8 = undefined;
        _ = self.channel.read(io, &buf);
    }
};

test "a bell rung is a bell heard, and the wait returns for it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var vigil = try Vigil.open();
    defer vigil.close();
    const bell = try Bell.open(io);
    defer bell.close(io);

    // Nothing rung yet: the wait must report its deadline, not its handles.
    var watches = [_]Watch{.{ .handle = bell.ear() }};
    try std.testing.expectEqual(@as(usize, 0), try vigil.wait(&watches, 0));
    try std.testing.expect(!watches[0].ready.any());

    bell.ring(io);
    // Indefinite on purpose: a bell that does not wake the wait must hang the
    // test rather than pass it on a generous timeout.
    try std.testing.expectEqual(@as(usize, 1), try vigil.wait(&watches, -1));
    try std.testing.expect(watches[0].ready.readable);

    bell.quiet(io);
    watches[0].ready = .{};
    try std.testing.expectEqual(@as(usize, 0), try vigil.wait(&watches, 0));
}

test "a pair carries bytes both ways, on whichever platform built it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pair = try Pair.open(io);
    defer pair.close(io);

    // The direction `Bell` uses, and the one the retirement tests read back.
    pair.write(io, "frame");
    try std.testing.expect(readable(pair.ear, -1));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("frame", pair.read(io, &buf));
    // And drained: a second read must not replay what was already taken.
    try std.testing.expect(!readable(pair.ear, 0));
}

test "a set above the ceiling is refused rather than truncated" {
    var vigil = try Vigil.open();
    defer vigil.close();
    var watches: [max_watched + 1]Watch = undefined;
    for (&watches) |*watch| watch.* = .{ .handle = portal.invalid_handle };
    try std.testing.expectError(error.TooManyWatched, vigil.wait(&watches, 0));
}
