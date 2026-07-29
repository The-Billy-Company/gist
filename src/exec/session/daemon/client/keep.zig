//! The caller's side of the answer keep — ask before computing, offer after.
//!
//! A verb that reads the whole corpus to answer one question has nothing left
//! to prune: the sweep IS the answer. `relate echoes --shape distinct` asks
//! "which of these twenty thousand files has no kin?", which is a claim about
//! every pair, and no index can make a claim about every pair cheap. What CAN
//! be cheap is not asking twice.
//!
//! So a memoizable verb runs a three-step errand around its own work:
//!
//! 1. **ask** — "daemon, do you still hold the answer to this exact question?"
//!    A hit is the rendered bytes and the exit code, and the verb is done
//!    before it has opened a single file.
//! 2. compute cold, exactly as it would with no daemon at all.
//! 3. **offer** — hand the rendered answer back, stamped with the epoch read in
//!    step 1. The daemon keeps it only if the corpus has not moved since, so an
//!    answer computed across someone else's edit is discarded rather than held.
//!
//! Every failure here is silence: no daemon, a stale protocol, a wedged peer,
//! an unvouchable epoch. The verb then behaves precisely as it did before this
//! module existed, which is the only property that makes an accelerator safe to
//! put in front of a correct program.

const std = @import("std");
const protocol = @import("../../conduit/protocol/protocol.zig");
const client = @import("client.zig");
const frame = @import("../../../../corpus/index/frame/frame.zig");
const fault = @import("../../../../fault.zig");
const net = std.Io.net;

/// Deadline for both errands. Tighter than a query's two seconds and for the
/// same reason the annals consult is: the whole point is to out-run the work
/// being skipped, so a daemon too busy to answer promptly is simply not used.
pub const timeout_ms: i32 = 500;

/// A held answer. `bytes` is caller-owned (allocated from the allocator passed
/// to `ask`) and outlives the connection it arrived on. `epoch` is the corpus
/// the answer describes — carried out so the recall can name it, the same way
/// a computed answer's summary names the tier that produced it.
pub const Held = struct { code: u8, epoch: u64, bytes: []u8 };

/// What the errand found.
pub const Ticket = union(enum) {
    /// The keep is unusable this run — no daemon, version skew, or a watcher
    /// that cannot vouch for an epoch. Do not offer an answer back either: an
    /// unvouchable epoch cannot invalidate anything later.
    unusable,
    hit: Held,
    /// Nothing held. The epoch to stamp `offer` with once the answer exists.
    miss: u64,
};

/// Ask the keep for `key`. Never errors; every uncertainty is `.unusable`.
pub fn ask(gpa: std.mem.Allocator, io: std.Io, socket_path: []const u8, key: []const u8) Ticket {
    if (!rendezvousIsOurs(socket_path)) return .unusable;
    const ua = net.UnixAddress.init(socket_path) catch return .unusable;
    const stream = ua.connect(io) catch return .unusable; // no daemon → cold, silently
    defer stream.close(io);
    return exchangeAsk(gpa, io, stream.socket.handle, key) catch .unusable;
}

fn exchangeAsk(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, key: []const u8) !Ticket {
    if (!try shakeHands(gpa, io, fd)) return .unusable;
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeRecall(&qbuf, gpa, key);
    if (!protocol.writeAll(io, fd, qbuf.items)) return .unusable;

    var resp = try client.recvFrameDeadline(gpa, io, fd, timeout_ms);
    defer resp.deinit();
    if (resp.op != .recalled) return .unusable;
    const r = protocol.decodeRecalled(resp.payload()) catch return .unusable;
    if (!r.ok) return .unusable;
    const h = r.hit orelse return .{ .miss = r.epoch };
    // Copy off the frame buffer: the answer outlives this connection, and the
    // caller writes it after every socket here is closed.
    return .{ .hit = .{ .code = h.code, .epoch = r.epoch, .bytes = try gpa.dupe(u8, h.answer) } };
}

/// Offer a computed answer to the keep, stamped with the epoch `ask` reported.
/// Fire-and-forget: the caller has already printed its answer and the keep is
/// free to refuse (corpus moved, no room, oversized). Never errors.
pub fn offer(
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    key: []const u8,
    epoch: u64,
    code: u8,
    answer: []const u8,
) void {
    const ua = net.UnixAddress.init(socket_path) catch return;
    const stream = ua.connect(io) catch return;
    defer stream.close(io);
    fault.spare(
        "keep offer (costs only this answer's reuse next run)",
        exchangeOffer(gpa, io, stream.socket.handle, key, epoch, code, answer),
    );
}

fn exchangeOffer(
    gpa: std.mem.Allocator,
    io: std.Io,
    fd: std.posix.fd_t,
    key: []const u8,
    epoch: u64,
    code: u8,
    answer: []const u8,
) !void {
    if (!try shakeHands(gpa, io, fd)) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeRetain(&buf, gpa, epoch, code, key, answer);
    _ = protocol.writeAll(io, fd, buf.items);
}

/// HELLO → READY, returning whether the peer speaks this exact protocol. No
/// transport capabilities are advertised: these frames are small by
/// construction (a key) or one-way (an answer), so neither wants an shm fd.
///
/// Deliberately NOT gated on READY's build stamp, unlike the query path. The
/// callers here are `relate` and `irregex` as often as `gist`, and three
/// binaries from one build are three different files — comparing them would
/// disable the keep for two products out of three. It is safe to skip because
/// the daemon never renders a kept answer: the CALLER computed it, and
/// `cli/reprise.zig` already folds the caller's own build into the key, so a
/// rebuilt binary asks a question its predecessor's answer cannot satisfy.
fn shakeHands(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t) !bool {
    try protocol.sendFrame(gpa, io, fd, .hello, &.{ protocol.protocol_version, 0 });
    var ready = try client.recvFrameDeadline(gpa, io, fd, timeout_ms);
    defer ready.deinit();
    if (ready.op != .ready) return false;
    const r = protocol.decodeReady(ready.payload()) catch return false;
    return r.proto == protocol.protocol_version;
}

/// Is the daemon at this rendezvous resident over the tree we are standing in?
/// An absolute `GIST_DIR` shared by two checkouts points both at one socket,
/// and a held answer names files by paths that resolve in either — so without
/// this proof the keep is the one warm tier that could serve a *different
/// repository's* answer. Fails closed.
fn rendezvousIsOurs(socket_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return frame.bindingHolds(frame.socketBindingPath(&buf, socket_path) orelse return false);
}
