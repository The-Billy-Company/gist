//! gist in-process FFI session — the C-ABI search entry (ADR-352 rung 3).
//!
//! `open` / `search` / `close` let a non-Zig host (the Python `cffi` binding,
//! or any C caller) hold a gist corpus WARM in its own process and stream match
//! records over a callback — no subprocess, no Unix socket, no `stdout`, no
//! `exit`. It is the in-process face of the same warm engine the resident
//! daemon (`surface/exec/session/resident.zig`) serves over a socket, and it draws on the
//! same shared search core (`kernel/match/query.zig`), so an in-process answer is
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
const contract = @import("contract.zig");
const Relay = @import("relay.zig").Relay;
const resident = @import("../exec/session/resident.zig");
const request = @import("../exec/session/request.zig");
const assay = @import("../../assay/assay.zig");

/// The FFI allocates through the C allocator so a host that already owns the C
/// heap (the Python process) shares one arena, and teardown needs no Zig GPA.
const gpa = std.heap.c_allocator;
const Status = contract.Status;
const SearchOptions = contract.SearchOptions;
const MatchFn = contract.MatchFn;

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

/// Open a warm session over `roots[0..nroots]` (each a NUL-terminated path).
/// `nroots == 0` means the ROOTLESS current-working-directory walk — the exact
/// tree a bare `gist <pattern>` walks (CWD-relative paths, no `./` prefix), so
/// the in-process answer is byte-identical to a rootless cold run; `roots_ptr`
/// may then be null (the Python binding passes NULL, not an empty array) and
/// is never read. Writes the handle to `out` and returns `.ok`, or leaves
/// `out` untouched and returns a negative status (`.invalid` for a null `out`,
/// or a null `roots_ptr` with `nroots > 0`).
pub fn open(roots_ptr: ?[*]const [*:0]const u8, nroots: usize, out: ?**Session) Status {
    // ADR-352's never-write contract, by construction: route every diagnostic
    // this process might emit (reconcile traces, degradation notices, summary
    // lines) to the dark sink, so no warm-path `assay.diag` can reach the
    // embedding host's stderr. Installed on first `open`; idempotent.
    assay.install(.{ .sink = .dark });
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

/// Execute one complete search shape. Null, wrongly-sized, or unknown options
/// fail closed; unsupported patterns return `.stale` for authoritative fallback.
pub fn search(s: *Session, pattern_ptr: ?[*]const u8, pattern_len: usize, options_ptr: ?*const SearchOptions, on_match: MatchFn, ctx: ?*anyopaque) Status {
    const options = options_ptr orelse return .invalid;
    if (options.struct_size != @sizeOf(SearchOptions) or options.flags & ~contract.known_flags != 0)
        return .invalid;
    const max_count: ?u64 = if (options.flags & contract.flag_max_count != 0) options.max_count else null;
    return searchRequest(s, pattern_ptr, pattern_len, options.flags, max_count, options.before_context, options.after_context, on_match, ctx);
}

fn searchRequest(s: *Session, pattern_ptr: ?[*]const u8, pattern_len: usize, flags: u32, max_count: ?u64, before: u64, after: u64, on_match: MatchFn, ctx: ?*anyopaque) Status {
    const pattern: []const u8 = if (pattern_len == 0) "" else blk: {
        const p = pattern_ptr orelse return .invalid;
        break :blk p[0..pattern_len];
    };
    const req = request.Request{
        .pattern = pattern,
        .mode = .files, // ignored by the match stream; any value compiles
        .fixed = flags & contract.flag_fixed != 0,
        .ignore_case = flags & contract.flag_ignore_case != 0,
        .smart_case = flags & contract.flag_smart_case != 0,
        .unicode = flags & contract.flag_no_unicode == 0,
        .word = flags & contract.flag_word != 0,
        .invert = flags & contract.flag_invert != 0,
        .before = before,
        .after = after,
        .quiet = flags & contract.flag_quiet != 0,
        .max_count = max_count,
    };

    var relay = Relay{ .callback = on_match, .context = ctx };
    defer relay.deinit();

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
