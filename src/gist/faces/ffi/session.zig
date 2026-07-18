//! gist in-process FFI session — the C-ABI search entry (ADR-352 rung 3).
//!
//! `open` / `search` / `close` let a non-Zig host (the Python `cffi` binding,
//! or any C caller) hold a gist corpus WARM in its own process and stream match
//! records over a callback — no subprocess, no Unix socket, no `stdout`, no
//! `exit`. It is the in-process face of the same warm engine the resident
//! daemon (`session/resident.zig`) serves over a socket, and it draws on the
//! same shared search core (`engine/query.zig`), so an in-process answer is
//! byte-identical to the cold `gist --json` stream and to the UDS daemon.
//!
//! ## Why this is the rung the C ABI graduated on
//!
//! ADR-352 gates the C search ABI on one property: a bad query must never
//! terminate the embedding host. The whole warm path — compile, trigram
//! prefilter, per-line span emission — RETURNS typed errors instead of calling
//! `die()`/`exit` (the cold CLI keeps its own fatal shell; this path does not
//! touch it). So every failure here is a negative status code the caller reads
//! and recovers from (a `Stale` pattern → answer cold), not a dead process.
//!
//! ## Ownership + lifetime
//!
//! `open` heap-allocates the session (stable address) and stands up its own
//! `std.Io.Threaded` I/O — the FFI has no `std.process.Init`, so it brings the
//! threaded I/O implementation the daemon gets from the runtime. Every pointer
//! handed to the match callback (`path`, `line`, each submatch `text`) aliases
//! session/scratch memory valid ONLY for that one callback invocation; the
//! caller copies anything it keeps. `close` tears down the corpus, index, I/O
//! pool, and the handle.

const std = @import("std");
const resident = @import("../../session/resident.zig");
const request = @import("../../session/request.zig");

/// The FFI allocates through the C allocator so a host that already owns the C
/// heap (the Python process) shares one arena, and teardown needs no Zig GPA.
const gpa = std.heap.c_allocator;

/// C-ABI status codes (the `i32` every entry returns). Non-negative = success
/// (`ok` = ran, no match; `match` = at least one line matched); negative = a
/// typed failure the caller recovers from (`stale` → answer cold).
pub const Status = enum(i32) {
    ok = 0,
    match = 1,
    /// The pattern is outside gist's linear-time syntax (or freshness could not
    /// be proven): the caller answers cold, exactly as the daemon client does.
    stale = -1,
    out_of_memory = -2,
    /// The session could not be opened (corpus/index build failed).
    open_failed = -3,
    /// A null/zero required argument.
    invalid = -4,
};

/// `flags` bitset for `search` — the transport-neutral subset of the request
/// contract the warm path accepts (mirrors `request.Request`).
pub const flag_fixed: u32 = 1 << 0; // `-F`: fixed string, not a regex
pub const flag_ignore_case: u32 = 1 << 1; // `-i`: case-insensitive

/// One submatch span, C-ABI layout. `text` aliases the line bytes (NOT
/// NUL-terminated — use `len`); `[start,end)` are byte offsets within the line.
pub const Submatch = extern struct {
    text: [*]const u8,
    len: usize,
    start: usize,
    end: usize,
};

/// One matching line, C-ABI layout. `path`/`line` alias session bytes (NOT
/// NUL-terminated); `submatches[0..nsubmatches]` alias per-line scratch. All
/// valid only for the duration of the callback that receives it.
pub const Match = extern struct {
    path: [*]const u8,
    path_len: usize,
    line_number: u64,
    line: [*]const u8,
    line_len: usize,
    submatches: [*]const Submatch,
    nsubmatches: usize,
};

/// The caller's per-line callback (C calling convention). Invoked once per
/// matching line, synchronously, while the session lock is held — it MUST NOT
/// re-enter the session. Return `0` to CONTINUE the stream, or NON-ZERO to stop
/// it early (a bounded / first-match query): `search` then reports `.match` and
/// leaves the rest of the corpus unscanned. `ctx` is the userdata passed to
/// `search`.
pub const MatchFn = *const fn (ctx: ?*anyopaque, m: *const Match) callconv(.c) i32;

/// An opaque warm session: its threaded I/O and the resident engine over one
/// corpus. Heap-allocated by `open` so the `std.Io.Threaded.io()` interface can
/// capture a stable `&self.threaded`. Each `search` stands up (and tears down)
/// its OWN arena for that call's transient candidate list — no session-wide
/// mutable arena to race, so a caller that does not serialize its own calls
/// still can't corrupt one search's scratch from another (the resident engine's
/// mutex already serializes the corpus/reconcile state under the hood).
pub const Session = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    inner: resident.ResidentSession,
};

/// Marshals resident `MatchRecord`s into C `Match`/`Submatch` structs and fires
/// the caller's callback, translating its C return into the sink's halt bool: a
/// non-zero return stops the stream early (caller-requested). `subs` is a reused
/// span buffer (cleared per line); an allocation failure sets `oom` and halts so
/// `emit` stays infallible, and `search` maps `oom` to `out_of_memory` afterward.
/// Satisfies `resident.search`'s duck-typed sink (a `pub fn emit(*Relay,
/// MatchRecord) bool` method, comptime-bound — no `*anyopaque`, no cast back).
const Relay = struct {
    cb: MatchFn,
    ctx: ?*anyopaque,
    subs: std.ArrayList(Submatch) = .empty,
    oom: bool = false,

    pub fn emit(self: *Relay, rec: resident.MatchRecord) bool {
        if (self.oom) return true;
        self.subs.clearRetainingCapacity();
        self.subs.ensureTotalCapacity(gpa, rec.spans.len) catch {
            self.oom = true;
            return true; // halt; `search` maps `oom` to `out_of_memory`
        };
        for (rec.spans) |sp| self.subs.appendAssumeCapacity(.{
            .text = rec.text.ptr + sp.start,
            .len = sp.end - sp.start,
            .start = sp.start,
            .end = sp.end,
        });
        const m = Match{
            .path = rec.path.ptr,
            .path_len = rec.path.len,
            .line_number = rec.line_number,
            .line = rec.text.ptr,
            .line_len = rec.text.len,
            .submatches = self.subs.items.ptr,
            .nsubmatches = self.subs.items.len,
        };
        return self.cb(self.ctx, &m) != 0; // non-zero → caller asked to stop
    }
};

/// Open a warm session over `roots[0..nroots]` (each a NUL-terminated path).
/// `nroots == 0` means the ROOTLESS current-working-directory walk — the exact
/// tree a bare `gist <pattern>` walks (CWD-relative paths, no `./` prefix), so
/// the in-process answer is byte-identical to a rootless cold run; `roots_ptr`
/// may then be null (the Python binding passes NULL, not an empty array) and
/// is never read. Writes the handle to `out` and returns `.ok`, or leaves
/// `out` untouched and returns a negative status (`.invalid` for a null `out`,
/// or a null `roots_ptr` with `nroots > 0`).
pub fn open(roots_ptr: ?[*]const [*:0]const u8, nroots: usize, out: ?**Session) Status {
    const out_slot = out orelse return .invalid;
    const roots = gpa.alloc([]const u8, nroots) catch return .out_of_memory;
    defer gpa.free(roots);
    if (nroots != 0) {
        const rp = roots_ptr orelse return .invalid;
        for (roots, 0..) |*r, i| r.* = std.mem.span(rp[i]);
    }

    const s = gpa.create(Session) catch return .out_of_memory;
    s.threaded = std.Io.Threaded.init(gpa, .{});
    s.io = s.threaded.io();
    s.inner = resident.ResidentSession.init(gpa, s.io, roots) catch {
        s.threaded.deinit();
        gpa.destroy(s);
        return .open_failed;
    };
    out_slot.* = s;
    return .ok;
}

/// Stream every matching line of `pattern[0..pattern_len]` over the warm corpus
/// to `on_match`. Returns `.match` if any line matched, `.ok` if none, or a
/// negative status (`.stale` → the caller answers cold, unchanged). `on_match`
/// may return non-zero to stop early — a bounded / first-match query then still
/// returns `.match` (a line was seen) without scanning the rest of the corpus.
/// A null `pattern_ptr` with `pattern_len > 0` is `.invalid`, never a blind
/// deref; `pattern_len == 0` never reads the pointer (the empty pattern keeps
/// its engine-defined meaning).
pub fn search(s: *Session, pattern_ptr: ?[*]const u8, pattern_len: usize, flags: u32, on_match: MatchFn, ctx: ?*anyopaque) Status {
    const pattern: []const u8 = if (pattern_len == 0) "" else blk: {
        const p = pattern_ptr orelse return .invalid;
        break :blk p[0..pattern_len];
    };
    const req = request.Request{
        .pattern = pattern,
        .mode = .files, // ignored by the match stream; any value compiles
        .fixed = flags & flag_fixed != 0,
        .ignore_case = flags & flag_ignore_case != 0,
    };

    var relay = Relay{ .cb = on_match, .ctx = ctx };
    defer relay.subs.deinit(gpa);

    // A fresh per-call arena for the transient candidate list — no session-wide
    // mutable state, so overlapping calls can't reset each other's scratch.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const any = s.inner.search(arena.allocator(), req, &relay) catch |e| switch (e) {
        error.Stale => return .stale,
        error.OutOfMemory => return .out_of_memory,
    };
    if (relay.oom) return .out_of_memory;
    return if (any) .match else .ok;
}

/// Free the session and all its warm state (corpus, index, I/O pool, handle).
pub fn close(s: *Session) void {
    s.inner.deinit();
    s.threaded.deinit();
    gpa.destroy(s);
}
