//! gist in-process FFI session — the C-ABI search entry.
//!
//! `open` / `search` / `close` let a non-Zig host (the Python `cffi` binding,
//! or any C caller) hold a gist corpus WARM in its own process and stream match
//! records over a callback — no subprocess, no Unix socket, no `stdout`, no
//! `exit`. It is the in-process face of the same warm engine the resident
//! daemon (`exec/session/warm/resident.zig`) serves over a socket, and it draws on the
//! same shared search core (`kernel/query/query.zig`), so an in-process answer is
//! byte-identical to the cold `gist --json` stream and to the UDS daemon.
//!
//! ## Why this is the rung the C ABI graduated on
//!
//! The C search ABI is gated on one property: a bad query must never
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
const resident = @import("irregex").session.resident;
const request = @import("irregex").session.request;
const assay = @import("irregex").assay;

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
    /// The allocator this handle (and everything under it) was opened with, so
    /// `close` returns the memory where it came from. It is `gpa` for every C
    /// caller; carrying it is what lets the adverse OOM suite drive this exact
    /// entry under a failing allocator instead of asserting against a path
    /// where the allocation cannot fail.
    alloc: std.mem.Allocator,
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
    return openWith(gpa, roots_ptr, nroots, out);
}

/// `open`, with the heap named. The C entry pins `gpa`; the OOM suite passes a
/// failing allocator so a walk-time allocation failure is a status the caller
/// reads rather than a hypothetical.
pub fn openWith(alloc: std.mem.Allocator, roots_ptr: ?[*]const [*:0]const u8, nroots: usize, out: ?**Session) Status {
    // Never-write, by construction: route every diagnostic
    // this process might emit (reconcile traces, degradation notices, summary
    // lines) to the dark sink, so no warm-path `assay.diag` can reach the
    // embedding host's stderr. Installed on first `open`; idempotent.
    assay.install(.{ .sink = .dark });
    contract.beginCall();
    const out_slot = out orelse return .invalid;
    const roots = alloc.alloc([]const u8, nroots) catch return contract.report(.{ .code = error.OutOfMemory });
    defer alloc.free(roots);
    if (nroots != 0) {
        const rp = roots_ptr orelse return .invalid;
        for (roots, 0..) |*r, i| r.* = std.mem.span(rp[i]);
    }

    const s = alloc.create(Session) catch return contract.report(.{ .code = error.OutOfMemory });
    s.alloc = alloc;
    s.threaded = std.Io.Threaded.init(alloc, .{});
    s.io = s.threaded.io();
    s.inner = resident.ResidentSession.init(alloc, s.io, roots) catch |e| {
        s.threaded.deinit();
        alloc.destroy(s);
        return contract.reportAny(e, .open_failed);
    };
    out_slot.* = s;
    return .ok;
}

/// Execute one complete search shape. Null, wrongly-sized, or unknown options
/// fail closed; unsupported patterns return `.stale` for authoritative fallback.
pub fn search(s: *Session, pattern_ptr: ?[*]const u8, pattern_len: usize, options_ptr: ?*const SearchOptions, on_match: MatchFn, ctx: ?*anyopaque) Status {
    contract.beginCall();
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
    var arena = std.heap.ArenaAllocator.init(s.alloc);
    defer arena.deinit();
    const any = switch (s.inner.search(arena.allocator(), req, &relay) catch
        return contract.report(.{ .code = error.OutOfMemory })) {
        .got => |got| got,
        // A declinature, not a fault: the cold tier answers this identically, so
        // it installs nothing and `irregex_last_fault` stays silent about it.
        .declined => return .stale,
    };
    if (relay.oom) return contract.report(.{ .code = error.OutOfMemory });
    return if (any) .match else .ok;
}

/// Free the session and all its warm state (corpus, index, I/O pool, handle).
pub fn close(s: *Session) void {
    const alloc = s.alloc;
    s.inner.deinit();
    s.threaded.deinit();
    alloc.destroy(s);
}

test {
    // The seam's adverse allocation-failure suite lives in a sibling file (shape
    // cap) and is wired in from here, the entry it proves things about.
    _ = @import("oom_test.zig");
}
