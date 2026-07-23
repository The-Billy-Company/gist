// MONOLITHIC: resident-session UDS wire protocol — framing, opcodes, HELLO/READY capabilities, and the additive query_ext/annals codecs are one versioned contract (ADR-352 rung 2.5)
//! gist resident session — the Unix-domain-socket wire protocol (ADR-352 rung 2.5).
//!
//! Length-prefixed framing over a stream socket: `[u32 len][u8 opcode][payload…]`,
//! where `len` counts the opcode + payload. One request per query, one response
//! back; a persistent client keeps the connection open across many queries.
//! The codec is pure (encode/decode byte slices) with thin `sendFrame`/
//! `recvFrame` helpers over a POSIX fd, so the frame grammar is unit-tested
//! without opening a socket.
//!
//! Fail-closed: oversized/truncated frames and unknown opcodes are hard errors.
//! Anything the server cannot serve warm comes back as `decline` (client → cold).

const std = @import("std");
const request = @import("request.zig");
const wire = @import("wire.zig");
const shm = @import("shm.zig");

/// Wire version. Unknown flag bits outside `known_flags` fail closed (BadFrame
/// → decline → cold); a version-mismatched READY handshake also falls open cold.
///
/// fd-transport is negotiated as an ADDITIVE capability (see `cap_fd_transport`),
/// not a version bump: an old client sends a 1-byte HELLO and an old daemon
/// ignores the extra byte, so no peer is forced cold by the change.
///
/// v5 grew the `query_ext` `[u8 pcre]` engine trailer (`-P`/`--pcre2` served
/// warm). The bump makes the handshake fail-open: a v5 client meeting a stale
/// v4 daemon (or vice versa) sees the version mismatch in READY and runs cold,
/// so no peer ever reads the new trailer without agreeing to it.
///
/// v6 grew the `changed`/`annals` opcode pair (the `gist index` amend consult).
/// An old daemon receiving `changed` would BadOpcode-drop the whole connection
/// mid-session; the bump lets a v6 client see the stale daemon in READY and
/// skip the consult entirely (fallback: journal replay → stat walk).
pub const protocol_version: u8 = 6;

/// Session/transport capabilities the peers agree on in the HELLO frame. NOT
/// query flags — the flags byte is fully assigned; this is a separate handshake
/// byte the daemon reads once per connection. Additive and fail-open: a peer
/// that advertises nothing (or an old peer sending no caps byte) gets exactly
/// the classic `chunk`-frame path.
pub const cap_fd_transport: u8 = 1 << 0; // client can receive a shm fd for a large `lines` answer

/// The capability set this build advertises (client) and honors (daemon). Zero
/// on a target without the anonymous-shm + SCM_RIGHTS path, so those peers stay
/// on `chunk` frames automatically.
pub const caps_supported: u8 = if (shm.supported) cap_fd_transport else 0;

/// Frame ceiling + error set are the shared `wire` plumbing's; re-exported so
/// existing `protocol.max_frame` / `protocol.WireError` call sites are stable.
pub const max_frame = wire.max_frame;
pub const WireError = wire.WireError;

pub const Opcode = enum(u8) {
    hello = 1, // C→S: [u8 proto_version]
    ready = 2, // S→C: [u8 proto][u64 daemon_gen][u64 session_gen][u32 n][gen bytes]
    query = 3, // C→S: [u8 mode][u8 flags][if flags&max_count_present: u64 LE][pattern bytes]
    result = 4, // S→C: [u8 mode] then files/count/lines body
    decline = 5, // S→C: (no payload) — answer this request cold
    err = 6, // S→C: [message bytes]
    shutdown = 7, // C→S: (no payload)
    status = 8, // C→S: (no payload) → S replies `ready`
    ping = 9, // C→S: (no payload)
    pong = 10, // S→C: (no payload)
    // `lines` streams as zero+ `chunk` frames then a terminal `result`
    // `[mode=lines][u8 matched]`. Keeps every frame under `max_frame`.
    chunk = 11, // S→C: [raw output bytes]
    // Zero-copy terminal `lines` answer: `[u64 LE length][u8 matched]` while the
    // rendered bytes ride a shared-memory fd in the same sendmsg's SCM_RIGHTS
    // control message (see `shm.zig` + `wire.sendWithFd`). REPLACES the `chunk`
    // stream + terminal `result` for this answer. Sent only when the client
    // advertised `cap_fd_transport` AND the answer exceeds `fd_transport_floor`.
    chunk_fd = 12, // S→C: [u64 length][u8 matched] (+ fd via SCM_RIGHTS)
    // The scoped query: the classic `query` body (mode/flags/opt max_count) but
    // with a LENGTH-PREFIXED pattern so a `PathFilter` trailer can follow — four
    // string lists in a fixed order: positional roots, `-g` includes, `-g '!…'`
    // excludes, and `-t <type>` extension globs. ADDITIVE — a daemon that
    // predates this opcode hits the `else` decline / `BadOpcode` drop and the
    // client fails open to cold, exactly like an unknown flag bit. The classic
    // `query` opcode still carries every unscoped request, so an old daemon
    // keeps serving those warm.
    query_ext = 13, // C→S: [u8 mode][u8 flags][opt u64 max_count][u32 plen][pattern] then 4×([u8 n]{[u32 len][bytes]}) = roots,includes,excludes,exts, then [u8 rank_present][opt u64 rank_k], then [u8 ctx_present][opt u64 before][opt u64 after], then [u8 pcre] (`-P`/`--pcre2`; self-describing, absent tail ⇒ 0)
    // The annals consult (`gist index` amend fast path): "which corpus files
    // changed at/after instant S?" — answered from the daemon's never-drained
    // watcher ledger (`annals.zig`) behind an FSEventStreamFlushSync barrier.
    // ADDITIVE like `query_ext`: an old daemon's `BadOpcode` drop / `decline`
    // sends the client to its proven fallback (journal replay → stat walk).
    changed = 14, // C→S: [i64 since_ns]
    // The answer: ok=0 ⇒ the ledger cannot vouch (unarmed, poisoned, floor,
    // flush failure) — never a partial list. ok=1 ⇒ the daemon's armed absolute
    // watch prefix (the client verifies it matches its own repo root) + every
    // REPO-RELATIVE path noted at/after S (a sound superset; the client's stat
    // confirm prunes the extras).
    annals = 15, // S→C: [u8 ok][if ok: [u32 plen][prefix][u32 n]{[u32 len][path]}]
};

// Query flags byte. Reserved bits join `known_flags` only with their engine semantics.
const flag_fixed: u8 = 1 << 0;
const flag_ignore_case: u8 = 1 << 1;
const flag_line_num: u8 = 1 << 2; // `-n` (lines mode)
const flag_word: u8 = 1 << 3; // `-w`
const flag_invert: u8 = 1 << 4; // `-v` (set-complement: non-matching lines)
const flag_smart_case: u8 = 1 << 5; // `-S` (raw; session resolves — see request.zig)
const flag_quiet: u8 = 1 << 6; // `-q` (existence-only; server answers a bare matched flag)
const flag_max_count_present: u8 = 1 << 7; // `-m` (a u64 LE cap follows the flags byte)

/// Flag bits this daemon implements. Any other set bit → `BadFrame` → decline → cold.
pub const known_flags: u8 = flag_fixed | flag_ignore_case | flag_line_num | flag_word | flag_invert | flag_smart_case | flag_quiet | flag_max_count_present;

/// Chunk payload budget for a streamed `lines` answer — under `max_frame`.
pub const chunk_bytes: usize = 4 << 20;

/// Answer-size floor for the fd path. Below it the shm map + client mmap
/// page-fault fixed cost isn't earned back (measured on macOS: a sub-1-MiB
/// answer's chunk stream is well under a millisecond), so small emits stay on
/// `chunk` frames — the daemon already has the bytes mapped, so it streams them
/// with no extra render. At/above it the eliminated socket copy + client
/// accumulation dominate and the fd path wins (measured ~1.2× at 32 MB).
pub const fd_transport_floor: usize = 1 << 20;

/// Append a `[len][opcode][payload]` frame to `buf` (gist opcode → raw byte).
pub fn writeFrame(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, op: Opcode, payload: []const u8) !void {
    return wire.writeFrame(buf, gpa, @intFromEnum(op), payload);
}

pub const Parsed = struct { op: Opcode, payload: []const u8, consumed: usize };

/// Parse one frame from the front of `bytes`, or `null` when incomplete.
/// `FrameTooLarge`/`BadOpcode` are hard errors (an unknown opcode byte the
/// shared layer accepts fails closed here, where the enum is known).
pub fn parseFrame(bytes: []const u8) WireError!?Parsed {
    const p = (try wire.parseFrame(bytes)) orelse return null;
    const op = std.enums.fromInt(Opcode, p.op) orelse return WireError.BadOpcode;
    return .{ .op = op, .payload = p.payload, .consumed = p.consumed };
}

/// The query flags byte — ONE derivation shared by `query` and `query_ext` so
/// the two opcodes can never disagree on what a set bit means.
fn packFlags(req: request.Request) u8 {
    var flags: u8 = 0;
    if (req.fixed) flags |= flag_fixed;
    if (req.ignore_case) flags |= flag_ignore_case;
    if (req.line_num) flags |= flag_line_num;
    if (req.word) flags |= flag_word;
    if (req.invert) flags |= flag_invert;
    if (req.smart_case) flags |= flag_smart_case;
    if (req.quiet) flags |= flag_quiet;
    if (req.max_count != null) flags |= flag_max_count_present;
    return flags;
}

pub fn encodeQuery(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, req: request.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(req.mode));
    try body.append(gpa, packFlags(req));
    // The optional `-m N` cap rides between the flags byte and the pattern (bit
    // 7 gates its presence) — the only variable-width field ahead of the pattern.
    if (req.max_count) |m| try wire.appendInt(u64, &body, gpa, m);
    try body.appendSlice(gpa, req.pattern);
    try writeFrame(buf, gpa, .query, body.items);
}

/// Encode a scoped request (`query_ext`): the classic body, but the pattern is
/// length-prefixed so the four-list `PathFilter` trailer can follow (roots,
/// includes, excludes, exts). Each list's count is a u8 (`request.max_scope`
/// ≤ 255 keeps it there), so an empty filter is four `0` bytes.
pub fn encodeQueryExt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, req: request.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(req.mode));
    try body.append(gpa, packFlags(req));
    if (req.max_count) |m| try wire.appendInt(u64, &body, gpa, m);
    try wire.appendInt(u32, &body, gpa, @intCast(req.pattern.len));
    try body.appendSlice(gpa, req.pattern);
    try appendStrList(&body, gpa, req.filter.roots);
    try appendStrList(&body, gpa, req.filter.includes);
    try appendStrList(&body, gpa, req.filter.excludes);
    try appendStrList(&body, gpa, req.filter.exts);
    // The `--rank[=N]` trailer: a presence byte, then the u64 top-k only when set
    // (`0` = cold's default 20). Self-describing, so a non-rank scoped query costs
    // one extra `0` byte and a rank query rides the same opcode as any scoped one.
    try body.append(gpa, @intFromBool(req.rank_k != null));
    if (req.rank_k) |k| try wire.appendInt(u64, &body, gpa, k);
    // The `-A`/`-B`/`-C` context trailer: a presence byte, then two u64 (before,
    // after) only when a window is set. Self-describing like the rank trailer, so
    // a windowless scoped query costs one extra `0` byte.
    const has_ctx = req.before != 0 or req.after != 0;
    try body.append(gpa, @intFromBool(has_ctx));
    if (has_ctx) {
        try wire.appendInt(u64, &body, gpa, req.before);
        try wire.appendInt(u64, &body, gpa, req.after);
    }
    // The `-P`/`--pcre2` engine trailer: one self-describing byte (there is no
    // free bit in the flags byte — it is fully assigned). A `-P` query rides
    // `query_ext` even when rootless (the client routes it here), so an old
    // daemon — which never negotiates this protocol version — is not reached.
    try body.append(gpa, @intFromBool(req.pcre));
    try writeFrame(buf, gpa, .query_ext, body.items);
}

/// Append a `[u8 count]{[u32 len][bytes]}` string list (count ≤ `max_scope`).
fn appendStrList(body: *std.ArrayList(u8), gpa: std.mem.Allocator, list: []const []const u8) !void {
    try body.append(gpa, @intCast(list.len));
    for (list) |s| {
        try wire.appendInt(u32, body, gpa, @intCast(s.len));
        try body.appendSlice(gpa, s);
    }
}

/// Build a `Request` from the decoded scalar fields + `pattern`/`filter` (both
/// alias the frame buffer / caller arena). Shared by `decodeQuery` and
/// `decodeQueryExt` so the two opcodes lower a set flag bit to the same field.
fn requestFrom(mode: request.Mode, flags: u8, max_count: ?u64, pattern: []const u8, filter: request.PathFilter, rank_k: ?usize, before: u64, after: u64, pcre: bool) request.Request {
    return .{
        .pattern = pattern,
        .mode = mode,
        .fixed = flags & flag_fixed != 0,
        .ignore_case = flags & flag_ignore_case != 0,
        .line_num = flags & flag_line_num != 0,
        .word = flags & flag_word != 0,
        .pcre = pcre,
        .invert = flags & flag_invert != 0,
        .smart_case = flags & flag_smart_case != 0,
        .quiet = flags & flag_quiet != 0,
        .max_count = max_count,
        .before = before,
        .after = after,
        .filter = filter,
        .rank_k = rank_k,
    };
}

/// Decode a `query` payload. `pattern` aliases into `payload` (caller keeps the
/// frame buffer alive). Any flag bit outside `known_flags` → `BadFrame`.
pub fn decodeQuery(payload: []const u8) WireError!request.Request {
    if (payload.len < 2) return WireError.BadFrame;
    const mode = std.enums.fromInt(request.Mode, payload[0]) orelse return WireError.BadFrame;
    const flags = payload[1];
    if (flags & ~known_flags != 0) return WireError.BadFrame;
    // Bit 7 gates the u64 cap between the flags byte and the pattern; a payload
    // too short to hold it is a truncated frame, not an empty-pattern one.
    var rest = payload[2..];
    var max_count: ?u64 = null;
    if (flags & flag_max_count_present != 0) {
        if (rest.len < 8) return WireError.BadFrame;
        max_count = std.mem.readInt(u64, rest[0..8], .little);
        rest = rest[8..];
    }
    if (rest.len == 0) return WireError.BadFrame;
    // The classic `query` opcode carries no engine trailer — it is only ever
    // emitted for a rootless, non-`-P` request (the client routes `-P` through
    // `query_ext`), so `pcre` is always false here.
    return requestFrom(mode, flags, max_count, rest, .{}, null, 0, 0, false);
}

/// Decode a `query_ext` payload — the scoped query. Same head as `decodeQuery`
/// but the pattern is length-prefixed and a four-list `PathFilter` trailer
/// follows (roots, includes, excludes, exts). `pattern` and every token alias
/// `payload`; each list's SLICE (the headers) is allocated from `a` (the
/// caller's per-query arena). Truncation / an over-cap count fails closed
/// (→ decline → cold). A flag bit outside `known_flags` → BadFrame.
pub fn decodeQueryExt(a: std.mem.Allocator, payload: []const u8) WireError!request.Request {
    if (payload.len < 2) return WireError.BadFrame;
    const mode = std.enums.fromInt(request.Mode, payload[0]) orelse return WireError.BadFrame;
    const flags = payload[1];
    if (flags & ~known_flags != 0) return WireError.BadFrame;
    var rest = payload[2..];
    var max_count: ?u64 = null;
    if (flags & flag_max_count_present != 0) {
        if (rest.len < 8) return WireError.BadFrame;
        max_count = std.mem.readInt(u64, rest[0..8], .little);
        rest = rest[8..];
    }
    const pattern = try takeLenPrefixed(&rest);
    if (pattern.len == 0) return WireError.BadFrame;
    const filter: request.PathFilter = .{
        .roots = try takeStrList(a, &rest),
        .includes = try takeStrList(a, &rest),
        .excludes = try takeStrList(a, &rest),
        .exts = try takeStrList(a, &rest),
    };
    const rank_k = try takeRank(&rest);
    const ctx = try takeContext(&rest);
    const pcre = takePcre(&rest);
    return requestFrom(mode, flags, max_count, pattern, filter, rank_k, ctx.before, ctx.after, pcre);
}

/// Consume the `[u8 pcre]` engine trailer. A same-version peer always writes it,
/// but a truncated tail tolerates as `false` (linear) — the same forward-lenient
/// rule as `takeRank`, so a stray short frame degrades to a correct linear
/// answer rather than a `BadFrame`.
fn takePcre(rest: *[]const u8) bool {
    if (rest.len == 0) return false;
    const b = rest.*[0];
    rest.* = rest.*[1..];
    return b != 0;
}

/// Consume the `[u8 present][opt u64 k]` rank trailer. Absent (a v3 peer always
/// writes at least the presence byte, but tolerate a truncated tail as null) →
/// not a rank query. Truncation of a present k → `BadFrame` (fail closed).
fn takeRank(rest: *[]const u8) WireError!?usize {
    if (rest.len < 1) return null;
    const present = rest.*[0] == 1;
    rest.* = rest.*[1..];
    if (!present) return null;
    if (rest.len < 8) return WireError.BadFrame;
    const k = std.mem.readInt(u64, rest.*[0..8], .little);
    rest.* = rest.*[8..];
    return @intCast(k);
}

/// Consume the `[u8 present][opt u64 before][opt u64 after]` context trailer.
/// A missing trailer (an older peer that stopped after rank) → no window;
/// truncation of a present pair → `BadFrame` (fail closed).
fn takeContext(rest: *[]const u8) WireError!struct { before: u64, after: u64 } {
    if (rest.len < 1) return .{ .before = 0, .after = 0 };
    const present = rest.*[0] == 1;
    rest.* = rest.*[1..];
    if (!present) return .{ .before = 0, .after = 0 };
    if (rest.len < 16) return WireError.BadFrame;
    const before = std.mem.readInt(u64, rest.*[0..8], .little);
    const after = std.mem.readInt(u64, rest.*[8..16], .little);
    rest.* = rest.*[16..];
    return .{ .before = before, .after = after };
}

/// Consume a `[u32 len][bytes]` field from the front of `rest`, advancing it.
/// The returned slice aliases the frame buffer. Truncation → `BadFrame`.
fn takeLenPrefixed(rest: *[]const u8) WireError![]const u8 {
    if (rest.len < 4) return WireError.BadFrame;
    const n = std.mem.readInt(u32, rest.*[0..4], .little);
    if (rest.len < 4 + @as(usize, n)) return WireError.BadFrame;
    const s = rest.*[4 .. 4 + n];
    rest.* = rest.*[4 + n ..];
    return s;
}

/// Consume a `[u8 count]{[u32 len][bytes]}` string list, allocating the slice
/// of headers from `a` (tokens alias the frame). Truncation → `BadFrame`.
fn takeStrList(a: std.mem.Allocator, rest: *[]const u8) WireError![]const []const u8 {
    if (rest.len < 1) return WireError.BadFrame;
    const n = rest.*[0];
    rest.* = rest.*[1..];
    const out = a.alloc([]const u8, n) catch return WireError.BadFrame;
    for (out) |*s| s.* = try takeLenPrefixed(rest);
    return out;
}

pub fn encodeFiles(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, files: []const []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(request.Mode.files));
    try wire.appendInt(u32, &body, gpa, @intCast(files.len));
    for (files) |f| {
        try wire.appendInt(u32, &body, gpa, @intCast(f.len));
        try body.appendSlice(gpa, f);
    }
    try writeFrame(buf, gpa, .result, body.items);
}

pub fn encodeCount(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, count: u64) !void {
    var body: [9]u8 = undefined;
    body[0] = @intFromEnum(request.Mode.count);
    std.mem.writeInt(u64, body[1..9], count, .little);
    try writeFrame(buf, gpa, .result, &body);
}

/// Frame a pre-rendered `lines` answer: `out` split into ≤`chunk_bytes` `chunk`
/// frames, then a terminal `result` with the matched flag. Zero chunks is legal.
pub fn encodeLines(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, out: []const u8, matched: bool) !void {
    var rest = out;
    while (rest.len > 0) {
        const n = @min(rest.len, chunk_bytes);
        try writeFrame(buf, gpa, .chunk, rest[0..n]);
        rest = rest[n..];
    }
    const body = [_]u8{ @intFromEnum(request.Mode.lines), @intFromBool(matched) };
    try writeFrame(buf, gpa, .result, &body);
}

/// Hand a rendered `lines` answer to the client as a shared-memory fd: one
/// terminal `chunk_fd` frame carries `{length, matched}` while the answer bytes
/// ride an SCM_RIGHTS fd (`shm_fd`, already filled + frozen by the caller), so
/// they never traverse the socket. REPLACES the `chunk` stream + terminal
/// `result` for this answer. The caller owns the shm buffer (closes it after);
/// the client owns the received fd until it has written stdout. Returns `false`
/// on a dead peer / sendmsg failure — the caller drops the connection.
pub fn sendChunkFd(fd: std.posix.fd_t, len: u64, matched: bool, shm_fd: std.posix.fd_t) bool {
    // [u32 len=10][op][u64 length][u8 matched] — a fixed 14-byte control frame.
    var frame: [14]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], 1 + 8 + 1, .little);
    frame[4] = @intFromEnum(Opcode.chunk_fd);
    std.mem.writeInt(u64, frame[5..13], len, .little);
    frame[13] = @intFromBool(matched);
    return wire.sendWithFd(fd, &frame, shm_fd);
}

pub const ChunkFd = struct { length: u64, matched: bool };

/// Decode a `chunk_fd` payload (`[u64 length][u8 matched]`); the fd arrives
/// separately via `recvFrameWithFd`.
pub fn decodeChunkFd(payload: []const u8) WireError!ChunkFd {
    if (payload.len < 9) return WireError.BadFrame;
    return .{ .length = std.mem.readInt(u64, payload[0..8], .little), .matched = payload[8] != 0 };
}

pub const ResultView = union(request.Mode) {
    files: FileIter,
    count: u64,
    /// Terminal `lines` frame: whether any file matched (bytes arrived in prior `chunk`s).
    lines: bool,
};

/// Zero-copy view over a decoded `result` payload; `FileIter` yields slices into `payload`.
pub fn decodeResult(payload: []const u8) WireError!ResultView {
    if (payload.len < 1) return WireError.BadFrame;
    const mode = std.enums.fromInt(request.Mode, payload[0]) orelse return WireError.BadFrame;
    return switch (mode) {
        .count => if (payload.len < 9) WireError.BadFrame else .{ .count = std.mem.readInt(u64, payload[1..9], .little) },
        .files => if (payload.len < 5) WireError.BadFrame else .{ .files = .{ .rest = payload[5..], .remaining = std.mem.readInt(u32, payload[1..5], .little) } },
        .lines => if (payload.len < 2) WireError.BadFrame else .{ .lines = payload[1] != 0 },
    };
}

pub const FileIter = struct {
    rest: []const u8,
    remaining: u32,

    pub fn next(self: *FileIter) WireError!?[]const u8 {
        if (self.remaining == 0) return null;
        if (self.rest.len < 4) return WireError.BadFrame;
        const len = std.mem.readInt(u32, self.rest[0..4], .little);
        if (self.rest.len < 4 + @as(usize, len)) return WireError.BadFrame;
        const s = self.rest[4 .. 4 + len];
        self.rest = self.rest[4 + len ..];
        self.remaining -= 1;
        return s;
    }
};

/// Encode the annals consult: one signed instant. `since_ns` is the amend's
/// last freshness anchor (`built.ns`), which is already bounded to i64.
pub fn encodeChanged(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, since_ns: i64) !void {
    var body: [8]u8 = undefined;
    std.mem.writeInt(i64, &body, since_ns, .little);
    try writeFrame(buf, gpa, .changed, &body);
}

pub fn decodeChanged(payload: []const u8) WireError!i64 {
    if (payload.len < 8) return WireError.BadFrame;
    return std.mem.readInt(i64, payload[0..8], .little);
}

/// Encode an annals answer. `vouched == null` ⇒ the single `ok=0` byte (the
/// ledger cannot vouch); otherwise the armed prefix + the changed-path list.
pub fn encodeAnnals(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, vouched: ?struct { prefix: []const u8, paths: []const []const u8 }) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const v = vouched orelse {
        try body.append(gpa, 0);
        return writeFrame(buf, gpa, .annals, body.items);
    };
    try body.append(gpa, 1);
    try wire.appendInt(u32, &body, gpa, @intCast(v.prefix.len));
    try body.appendSlice(gpa, v.prefix);
    try wire.appendInt(u32, &body, gpa, @intCast(v.paths.len));
    for (v.paths) |p| {
        try wire.appendInt(u32, &body, gpa, @intCast(p.len));
        try body.appendSlice(gpa, p);
    }
    try writeFrame(buf, gpa, .annals, body.items);
}

/// A vouched annals answer: the daemon's armed watch prefix + a path iterator
/// (both alias the frame buffer — caller keeps it alive while iterating).
pub const AnnalsView = struct { prefix: []const u8, paths: FileIter };

/// Decode an `annals` payload. Null ⇒ the daemon declined to vouch (the
/// caller runs its fallback); truncation fails closed as `BadFrame`.
pub fn decodeAnnals(payload: []const u8) WireError!?AnnalsView {
    if (payload.len < 1) return WireError.BadFrame;
    if (payload[0] == 0) return null;
    var rest = payload[1..];
    const prefix = try takeLenPrefixed(&rest);
    if (rest.len < 4) return WireError.BadFrame;
    const n = std.mem.readInt(u32, rest[0..4], .little);
    return .{ .prefix = prefix, .paths = .{ .rest = rest[4..], .remaining = n } };
}

pub fn encodeReady(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, daemon_gen: u64, session_gen: u64, index_gen: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, protocol_version);
    try wire.appendInt(u64, &body, gpa, daemon_gen);
    try wire.appendInt(u64, &body, gpa, session_gen);
    try wire.appendInt(u32, &body, gpa, @intCast(index_gen.len));
    try body.appendSlice(gpa, index_gen);
    try writeFrame(buf, gpa, .ready, body.items);
}

pub const Ready = struct { proto: u8, daemon_gen: u64, session_gen: u64, index_gen: []const u8 };

pub fn decodeReady(payload: []const u8) WireError!Ready {
    if (payload.len < 21) return WireError.BadFrame;
    const n = std.mem.readInt(u32, payload[17..21], .little);
    if (payload.len < 21 + @as(usize, n)) return WireError.BadFrame;
    return .{
        .proto = payload[0],
        .daemon_gen = std.mem.readInt(u64, payload[1..9], .little),
        .session_gen = std.mem.readInt(u64, payload[9..17], .little),
        .index_gen = payload[21 .. 21 + n],
    };
}

/// SIGPIPE-safe full write — re-exported from the shared plumbing so
/// `protocol.writeAll` call sites (serve/client) are stable.
pub const writeAll = wire.writeAll;

/// Send one framed message on `fd` (gist opcode → raw byte).
pub fn sendFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t, op: Opcode, payload: []const u8) WireError!void {
    return wire.sendFrame(gpa, fd, @intFromEnum(op), payload);
}

/// A framed message read off `fd`, owning its bytes (payload aliases into it).
/// The typed `op` is this protocol's enum; a byte outside it fails closed.
pub const Frame = struct {
    op: Opcode,
    bytes: []u8, // whole frame; payload is bytes[5..]
    gpa: std.mem.Allocator,

    pub fn payload(self: *const Frame) []const u8 {
        return self.bytes[5..];
    }
    pub fn deinit(self: *Frame) void {
        self.gpa.free(self.bytes);
    }
};

/// Receive one whole frame from `fd`. `ConnClosed` on truncated peer;
/// `FrameTooLarge`/`BadOpcode` fail closed.
pub fn recvFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!Frame {
    var raw = try wire.recvFrame(gpa, fd);
    const op = std.enums.fromInt(Opcode, raw.op) orelse {
        raw.deinit();
        return WireError.BadOpcode;
    };
    return .{ .op = op, .bytes = raw.bytes, .gpa = raw.gpa };
}

/// A frame plus any fd the peer passed with it (via SCM_RIGHTS). Non-null only
/// for a `chunk_fd` answer; the caller owns and must close (or munmap+close) it.
pub const FdFrame = struct { frame: Frame, passed_fd: ?std.posix.fd_t };

/// Like `recvFrame`, but over `recvmsg` so a passed shm fd is captured. A client
/// that advertised `cap_fd_transport` uses this for the response so it can serve
/// either a `chunk_fd` answer or the classic `chunk`/`result` frames (which
/// simply arrive with `passed_fd == null`).
pub fn recvFrameWithFd(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!FdFrame {
    var raw = try wire.recvFrameWithFd(gpa, fd);
    const op = std.enums.fromInt(Opcode, raw.frame.op) orelse {
        raw.frame.deinit();
        if (raw.passed_fd) |p| _ = std.c.close(p);
        return WireError.BadOpcode;
    };
    return .{ .frame = .{ .op = op, .bytes = raw.frame.bytes, .gpa = raw.frame.gpa }, .passed_fd = raw.passed_fd };
}

/// Send one framed message on `fd` carrying `pass_fd` over SCM_RIGHTS — the
/// zero-copy `chunk_fd` transport (see `sendChunkFd`). Re-exported so serve/
/// client call sites don't reach through `wire`.
pub const sendWithFd = wire.sendWithFd;
