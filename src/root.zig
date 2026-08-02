//! gist — the product chassis of the irregex ecosystem.
//!
//! This package ships the `gist` binary (indexed rg-parity pattern search)
//! plus the machinery only a product needs: the resident daemon and its UDS
//! conduit, the answer keep, the memory warden, the session-shaped C ABI
//! (`include/gist.h` + `surface/ffi/`), and the `--generate` primer. The
//! `relate` binary lives in the `relate` package now; it imports this
//! chassis for the daemon and the answer keep.
//!
//! The exact engine lives beneath as `@import("irregex")` (syntax → automata
//! → scan → cold pipeline → warm resident core). Dependents reach this
//! package as `@import("gist")`.

const std = @import("std");
const engine = @import("irregex");

const api = engine.api;
const ngram = engine.ngram;
const portal = engine.portal;

// ── the CLI vocabulary that stays with this product ──
pub const cli = struct {
    /// `--generate`: the Surface vocabulary rendered as the man page and the
    /// bash/zsh/fish/PowerShell completions.
    pub const primer = @import("surface/cli/primer/primer.zig");
};

// ── the face drivers, reached through the module ──
// The face mains are thin exe roots (a Zig executable's imports cannot climb
// above its root file's directory), so every driver is analyzed HERE — inside
// the chassis module, where its relative imports resolve — and the binaries
// dispatch through `@import("gist").faces.*`, exactly as the pre-split tree
// dispatched through the engine module's `commands.*`.
pub const faces = struct {
    /// Read-only index introspection (the `status` verb).
    pub const status = @import("surface/face/gist/verbs/status.zig");
    /// `gist config` — the resolved persisted-configuration stack.
    pub const config = @import("surface/face/gist/verbs/config.zig");
    /// `gist --schema` JSON capability manifest.
    pub const schema = @import("surface/face/gist/verbs/schema.zig");
    /// The `index` verb — build + persist the trigram index the engine reads.
    pub const indexer = @import("surface/face/gist/verbs/index.zig");
    /// The `codex` verbs — exact existence/count tier over the self-index shelf.
    pub const codex = @import("surface/face/gist/verbs/codex.zig");
    /// `gist --generate` — the man page + shell completions, from the flag table.
    pub const primer = @import("surface/face/gist/generate.zig");
};

// ── the resident session's transport + daemon ──
pub const session = struct {
    pub const protocol = @import("exec/session/conduit/protocol/protocol.zig");
    pub const spawn = @import("exec/session/conduit/spawn.zig");
    pub const vigil = @import("exec/session/conduit/vigil.zig");
    pub const serve = @import("exec/session/daemon/serve/serve.zig");
    pub const client = @import("exec/session/daemon/client/client.zig");
    /// The answer keep's frame types + dial — exported so the `relate` face
    /// (which owns the CLI-side keep passenger) can reach them without a
    /// cross-package file import.
    pub const keep = @import("exec/session/daemon/client/keep.zig");
    pub const warden = @import("exec/session/warden/warden.zig");
};

// ── in-process C-ABI search session ──
// The library's warm engine, exposed to non-Zig hosts as an
// `open`/`search`/`close` callback-streaming C ABI — no subprocess, socket,
// stdout, or exit. Backs the `cffi` Python transport; the `export fn`s below
// forward into it. Substrate symbols (`irgx_rows_*`, status/fault, schema
// digest) live in `libirgx` and are not re-exported here.
pub const ffi = struct {
    pub const contract = @import("surface/ffi/contract.zig");
    pub const session = @import("surface/ffi/session.zig");
    /// The pull-cursor sibling of `session`: open an `Engine`, run a
    /// `search` that materializes a `Cursor`, then `next`/`next_batch` it — with
    /// thread-safe cancellation and per-operation budgets. Additive over the
    /// legacy triad; backs the Go/cgo binding and any callback-averse host.
    pub const cursor = @import("surface/ffi/cursor.zig");
    /// Analytic row layout + params — owned by the engine substrate so every
    /// product returns the same `irgx_row`.
    pub const rows = engine.ffi.rows;
    /// Shared answer cursor; walked by `irgx_rows_*` from `libirgx`.
    pub const answer = engine.ffi.answer;
    /// The rank producer's dispatch: one verb materializing an `Answer`.
    /// Kinship/sweep live in `relate`; compose lives in `blast`. A verb this
    /// build cannot answer in-process returns `.stale` — the ABI's "answer
    /// through the fallback".
    pub const analytic = @import("surface/ffi/analytic.zig");
};

/// The session C-ABI compatibility integer. Started at 1 (introspection + the
/// allocation-free trigram primitive); the rung-3 warm session's match callback
/// (`gist_match_fn`) gaining an `i32` abort return was a breaking signature
/// change that stepped it to 2. Bump only for a breaking layout or
/// signature change; additive symbols preserve the version. Independent of
/// `libirgx`'s own `gist_abi_version` (which versions the engine plane).
pub fn abi() u32 {
    return 2;
}

export fn gist_abi_version() u32 {
    return abi();
}

/// Extract the distinct, ascending trigrams of `text[0..len]` into
/// `out[0..len]` (caller sizes `out` ≥ `len`). Returns the count written.
/// This deterministic primitive is the C ABI's only data operation; search and
/// index lifecycle remain Zig-native/CLI surfaces.
export fn gist_trigram_count(text: [*]const u8, len: usize, out: [*]u32) usize {
    if (len < 3) return 0;
    return ngram.extractSortedUnique(text[0..len], out[0..len]);
}

// ── in-process warm search session ──
// Thin C shims over `ffi/session.zig`; the `Status` enum lowers to its `i32`
// tag. `gist_session` is opaque to C (`ffi.Session` by pointer).

/// Open a warm session over `roots[0..nroots]` (NUL-terminated paths); writes
/// the handle to `*out`. Returns 0 on success, negative on failure.
export fn gist_open(roots: [*]const [*:0]const u8, nroots: usize, out: **ffi.session.Session) i32 {
    return @intFromEnum(ffi.session.open(roots, nroots, out));
}

/// Stream each matching line of `pattern[0..pattern_len]` to `on_match`.
/// Returns 1 if any line matched, 0 if none, negative on error (−1 = the caller
/// should answer cold). `on_match` returns 0 to continue or non-zero to stop the
/// stream early (a bounded / first-match query still returns 1). `flags`: bit0
/// `-F` fixed, bit1 `-i` ignore-case.
export fn gist_search(s: *ffi.session.Session, pattern: [*]const u8, pattern_len: usize, options: ?*const ffi.contract.SearchOptions, on_match: ffi.contract.MatchFn, ctx: ?*anyopaque) i32 {
    return @intFromEnum(ffi.session.search(s, pattern, pattern_len, options, on_match, ctx));
}

/// Free a session opened by `gist_open`.
export fn gist_close(s: *ffi.session.Session) void {
    ffi.session.close(s);
}

// ── the pull-cursor surface ──
// Additive siblings of the callback triad: a host opens an `irgx_engine`,
// runs `gist_search_cursor` to materialize a `gist_cursor`, then walks it
// with `gist_cursor_next`/`_next_batch` — inverting control for a caller that
// can't yield its stack to a callback. Cancellation is an `irgx_cancel`
// handle any thread may trip. All statuses are the same `Status` tags; nothing
// here can `die()` the host, and none of it bumps `abi()` (additive symbols).
//
// The engine and the token are `libirgx`'s, not this library's: every
// package's `…_run` takes one, and an engine is only interpretable by the copy
// of the engine code that opened it, so one opener has to serve all four
// libraries. Search owns what it does WITH a corpus, not the corpus.

/// Run one search and materialize a pull cursor; writes it to `*out`. Returns 0
/// on success, 1 unused here, negative on failure (−1 = stale → answer cold).
export fn gist_search_cursor(eng: *api.Engine, request: ?*const ffi.contract.SearchRequest, out: ?**ffi.cursor.Cursor) i32 {
    return @intFromEnum(ffi.cursor.searchCursor(eng, request, out));
}

/// Fill `*out` with the next record. Returns 1 (record written), 0 (end of
/// stream), or negative on error. The view borrows cursor/scratch memory.
export fn gist_cursor_next(cursor: *ffi.cursor.Cursor, out: ?*ffi.contract.Match) i32 {
    return @intFromEnum(ffi.cursor.cursorNext(cursor, out));
}

/// Fill up to `cap` records into `out[0..cap]`; writes the count to `*written`.
/// Returns 1 (≥1 written), 0 (end), or negative on error.
export fn gist_cursor_next_batch(cursor: *ffi.cursor.Cursor, out: ?[*]ffi.contract.Match, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(ffi.cursor.cursorNextBatch(cursor, out, cap, written));
}

/// Whether any file matched (cold's exit-code boolean): 1 matched, 0 none.
export fn gist_cursor_matched(cursor: *ffi.cursor.Cursor) i32 {
    return ffi.cursor.cursorMatched(cursor);
}

/// Free a cursor from `gist_search_cursor`.
export fn gist_cursor_close(cursor: *ffi.cursor.Cursor) void {
    ffi.cursor.cursorClose(cursor);
}

// ── the rank producer ──
// Gist's one analytic verb: the definition-first view of an exact query.
// Kinship, retrieval, and the multi-pattern sweep live in `librelate`;
// compose lives in `libblast`. The cursor it returns is the substrate's
// `irgx_rows *`, walked by `libirgx`'s four symbols. Purely additive,
// so `gist_abi_version` stays 2; the plane's own compatibility axis is
// `irgx_schema_digest`.

/// Run the rank verb and materialize a row cursor into `*out`. Returns 0 on
/// success, or negative — where −1 (stale) means this tier declines and the
/// caller should answer through the CLI fallback, NOT that the query failed.
export fn gist_run(eng: *api.Engine, op: u32, params: ?*const ffi.rows.Params, cancel: ?*api.CancelToken, out: ?**ffi.answer.Answer) i32 {
    return @intFromEnum(ffi.analytic.run(eng, op, params, cancel, out));
}

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`;
    // dedicated `*_test.zig` siblings (not re-exported) are wired explicitly.
    std.testing.refAllDecls(@This());
    _ = @import("surface/ffi/analytic.zig"); // analytic plane: dispatch fails closed
    _ = @import("exec/session/conduit/protocol/protocol_test.zig"); // UDS frame codec round-trip + adversarial
    _ = @import("exec/session/conduit/vigil.zig"); // the daemon's readiness wait + the bell that cuts it short
    _ = @import("exec/session/daemon/client/spawn.zig"); // best-effort detached daemon auto-spawn
    _ = @import("surface/face/gist/verbs/status.zig"); // read-only index introspection
    _ = @import("surface/face/gist/verbs/schema.zig"); // `--schema` manifest
    _ = @import("surface/face/gist/verbs/index.zig"); // the `index` verb: build + persist
    _ = @import("surface/face/gist/generate.zig"); // gist's own surface: value/rivalry/section derived from the parse table
    _ = @import("surface/cli/primer/page.zig"); // `--generate man`: reach-grouped roff
    _ = @import("surface/cli/primer/shell.zig"); // `--generate complete-{bash,fish,powershell}`
    _ = @import("surface/cli/primer/zsh.zig"); // `--generate complete-zsh`: captioned groups, baked sets

    // The daemon's two end-to-end suites stand or fall with its transport: both
    // build a real `AF_UNIX` socketpair and poll it, which is the one thing a
    // platform without `portal.resident_sessions` has no version of. Gated at the
    // aggregator rather than skipped inside, because `socketpair`/`pollfd` are not
    // merely absent on Windows — they are untyped, so *analyzing* the file is the
    // error, and a runtime `SkipZigTest` never gets the chance to run. They return
    // with the transport (rung 2) instead of needing a rewrite.
    if (comptime portal.resident_sessions) {
        _ = @import("exec/session/daemon/client/client_test.zig"); // wedged-daemon → cold deadline (no hang)
        _ = @import("exec/session/daemon/serve/serve_test.zig"); // end-to-end daemon lifecycle + client round-trip
    }
}
