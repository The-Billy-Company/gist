//! gist — the product chassis of the irregex ecosystem.
//!
//! This package ships the two search binaries — `gist` (indexed rg-parity
//! pattern search) and `relate` (compression-as-search kinship) — plus the
//! machinery only a product needs: the resident daemon and its UDS conduit,
//! the answer keep, the memory warden, the session-shaped C ABI
//! (`include/irregex.h` + `surface/ffi/`), and the CLI chassis (verb-table
//! renderer, flag surface, grade verdicts, the `--generate` primer).
//!
//! The engines live beneath it as modules: `@import("irregex")` (the exact
//! library — syntax → automata → scan → cold pipeline → warm resident core)
//! and `@import("relate")` (compression kinship + codex + compose). The
//! `blast` package rides this chassis the same way (`@import("gist").cli`).

const std = @import("std");
const engine = @import("irregex");

const api = engine.api;
const ngram = engine.ngram;
const portal = engine.portal;

// ── the CLI chassis (what `blast` imports) ──
pub const cli = struct {
    /// The shared flag surface every face parses (scope, presentation, JSON).
    pub const flags = @import("surface/cli/flags.zig");
    /// The shared verb-table renderer: one `Face` declaration becomes the
    /// help, the `--schema` manifest, the dispatch, and the unknown-verb line.
    pub const manifest = @import("surface/cli/manifest.zig");
    /// Kinship channels, calibrated grades, the weak-result verdict.
    pub const grade = @import("surface/cli/grade.zig");
    /// The answer keep's CLI side (a passenger on the resident daemon; it
    /// installs itself into the library's `outcome.departure` hook).
    pub const reprise = @import("surface/cli/reprise.zig");
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
    /// relate's verb table — the single source its help/schema/dispatch read.
    pub const relate_repertoire = @import("surface/face/relate/repertoire.zig");
};

// ── the resident session's transport + daemon (ADR-352 rung 2.5) ──
pub const session = struct {
    pub const protocol = @import("exec/session/conduit/protocol/protocol.zig");
    pub const spawn = @import("exec/session/conduit/spawn.zig");
    pub const vigil = @import("exec/session/conduit/vigil.zig");
    pub const serve = @import("exec/session/daemon/serve/serve.zig");
    pub const client = @import("exec/session/daemon/client/client.zig");
    pub const warden = @import("exec/session/warden/warden.zig");
};

// ── in-process C-ABI search session (ADR-352 rung 3) ──
// The library's warm engine, exposed to non-Zig hosts as an
// `open`/`search`/`close` callback-streaming C ABI — no subprocess, socket,
// stdout, or exit. Backs the `cffi` Python transport; the `export fn`s below
// forward into it.
pub const ffi = struct {
    pub const contract = @import("surface/ffi/contract.zig");
    pub const session = @import("surface/ffi/session.zig");
    /// The pull-cursor sibling of `session` (ADR-352): open an `Engine`, run a
    /// `search` that materializes a `Cursor`, then `next`/`next_batch` it — with
    /// thread-safe cancellation and per-operation budgets. Additive over the
    /// legacy triad; backs the Go/cgo binding and any callback-averse host.
    pub const cursor = @import("surface/ffi/cursor.zig");
    /// The analytic plane's data contract (ADR-377): the self-describing row
    /// every kinship/retrieval/sweep/composed verb answers with, the five
    /// params families, and the generated schema table all three bindings
    /// decode against.
    pub const rows = @import("surface/ffi/rows.zig");
    /// The analytic plane's dispatch: one entry for seventeen verbs, each
    /// materializing a `Rows` cursor. A verb this build cannot answer
    /// in-process returns `.stale` — the ABI's "answer through the fallback",
    /// so the plane graduates verb by verb without a binding changing.
    pub const analytic = @import("surface/ffi/analytic.zig");
};

/// The C-ABI compatibility integer. Started at 1 (introspection + the
/// allocation-free trigram primitive); the rung-3 warm session's match callback
/// (`irregex_match_fn`) gaining an `i32` abort return was a breaking signature
/// change that stepped it to 2 (ADR-352). Bump only for a breaking layout or
/// signature change; additive symbols preserve the version. This is the single
/// C-ABI axis — the semantic contract revision, result schema, corpus/index/atlas
/// formats, and engine semver version independently (see `contract/search_api.toml`).
pub fn abi() u32 {
    return 2;
}

export fn irregex_abi_version() u32 {
    return abi();
}

/// The engine semver (the library's `version_string`), NUL-terminated,
/// static-lifetime. Lets a binding version-gate the shared library / binary it
/// drives against its own packaged version (the unified-search contract's
/// `engine_version`, ADR-352).
export fn irregex_version() [*:0]const u8 {
    return engine.version_string.ptr;
}

/// Extract the distinct, ascending trigrams of `text[0..len]` into
/// `out[0..len]` (caller sizes `out` ≥ `len`). Returns the count written.
/// This deterministic primitive is the C ABI's only data operation; search and
/// index lifecycle remain Zig-native/CLI surfaces.
export fn irregex_trigram_count(text: [*]const u8, len: usize, out: [*]u32) usize {
    if (len < 3) return 0;
    return ngram.extractSortedUnique(text[0..len], out[0..len]);
}

// ── in-process warm search session (ADR-352 rung 3) ──
// Thin C shims over `ffi/session.zig`; the `Status` enum lowers to its `i32`
// tag. `irregex_session` is opaque to C (`ffi.Session` by pointer). These are the
// first ABI symbols that open/query a corpus; their match callback carries an
// `i32` abort return (0 continue / non-zero stop).

/// Open a warm session over `roots[0..nroots]` (NUL-terminated paths); writes
/// the handle to `*out`. Returns 0 on success, negative on failure.
export fn irregex_open(roots: [*]const [*:0]const u8, nroots: usize, out: **ffi.session.Session) i32 {
    return @intFromEnum(ffi.session.open(roots, nroots, out));
}

/// Stream each matching line of `pattern[0..pattern_len]` to `on_match`.
/// Returns 1 if any line matched, 0 if none, negative on error (−1 = the caller
/// should answer cold). `on_match` returns 0 to continue or non-zero to stop the
/// stream early (a bounded / first-match query still returns 1). `flags`: bit0
/// `-F` fixed, bit1 `-i` ignore-case.
export fn irregex_search(s: *ffi.session.Session, pattern: [*]const u8, pattern_len: usize, options: ?*const ffi.contract.SearchOptions, on_match: ffi.contract.MatchFn, ctx: ?*anyopaque) i32 {
    return @intFromEnum(ffi.session.search(s, pattern, pattern_len, options, on_match, ctx));
}

/// Free a session opened by `irregex_open`.
export fn irregex_close(s: *ffi.session.Session) void {
    ffi.session.close(s);
}

// ── the pull-cursor surface (ADR-352) ──
// Additive siblings of the callback triad: a host opens an `irregex_engine`,
// runs `irregex_search_cursor` to materialize an `irregex_cursor`, then walks it
// with `irregex_cursor_next`/`_next_batch` — inverting control for a caller that
// can't yield its stack to a callback. Cancellation is an `irregex_cancel` handle
// any thread may trip. All statuses are the same `Status` tags; nothing here can
// `die()` the host, and none of it bumps `abi()` (purely additive symbols).

/// Open a warm engine over `roots[0..nroots]`; writes the handle to `*out`.
export fn irregex_engine_open(roots: ?[*]const [*:0]const u8, nroots: usize, out: ?**api.Engine) i32 {
    return @intFromEnum(ffi.cursor.engineOpen(roots, nroots, out));
}

/// Free an engine opened by `irregex_engine_open`.
export fn irregex_engine_close(eng: *api.Engine) void {
    ffi.cursor.engineClose(eng);
}

/// Allocate a fresh (unset) cancellation token; writes it to `*out`.
export fn irregex_cancel_new(out: ?**api.CancelToken) i32 {
    return @intFromEnum(ffi.cursor.cancelNew(out));
}

/// Request cancellation of any in-flight search using this token (thread-safe).
export fn irregex_cancel_request(token: *api.CancelToken) void {
    ffi.cursor.cancelRequest(token);
}

/// Free a token from `irregex_cancel_new` (after searches using it complete).
export fn irregex_cancel_free(token: *api.CancelToken) void {
    ffi.cursor.cancelFree(token);
}

/// Run one search and materialize a pull cursor; writes it to `*out`. Returns 0
/// on success, 1 unused here, negative on failure (−1 = stale → answer cold).
export fn irregex_search_cursor(eng: *api.Engine, request: ?*const ffi.contract.SearchRequest, out: ?**ffi.cursor.Cursor) i32 {
    return @intFromEnum(ffi.cursor.searchCursor(eng, request, out));
}

/// Fill `*out` with the next record. Returns 1 (record written), 0 (end of
/// stream), or negative on error. The view borrows cursor/scratch memory.
export fn irregex_cursor_next(cursor: *ffi.cursor.Cursor, out: ?*ffi.contract.Match) i32 {
    return @intFromEnum(ffi.cursor.cursorNext(cursor, out));
}

/// Fill up to `cap` records into `out[0..cap]`; writes the count to `*written`.
/// Returns 1 (≥1 written), 0 (end), or negative on error.
export fn irregex_cursor_next_batch(cursor: *ffi.cursor.Cursor, out: ?[*]ffi.contract.Match, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(ffi.cursor.cursorNextBatch(cursor, out, cap, written));
}

/// Whether any file matched (cold's exit-code boolean): 1 matched, 0 none.
export fn irregex_cursor_matched(cursor: *ffi.cursor.Cursor) i32 {
    return ffi.cursor.cursorMatched(cursor);
}

/// Free a cursor from `irregex_search_cursor`.
export fn irregex_cursor_close(cursor: *ffi.cursor.Cursor) void {
    ffi.cursor.cursorClose(cursor);
}

// ── the analytic plane (ADR-377) ──
// Past the exact engine: compression kinship, retrieval, the multi-pattern
// sweep, and the composed verbs, all reached through ONE dispatch returning one
// self-describing row type. Seventeen verbs, eight symbols — a verb is a `u32`
// op plus one of five params families, so the next verb adds no C surface.
// Purely additive, so `irregex_abi_version` stays 2; the plane's own
// compatibility axis is `irregex_schema_digest`.

/// Run analytic verb `op` with its declared params family and materialize a row
/// cursor into `*out`. Returns 0 on success, or negative — where −1 (stale)
/// means this tier declines and the caller should answer through the CLI
/// fallback, NOT that the query failed.
export fn irregex_analytic_run(eng: *api.Engine, op: u32, params: ?*const ffi.rows.Params, cancel: ?*api.CancelToken, out: ?**ffi.analytic.Rows) i32 {
    return @intFromEnum(ffi.analytic.run(eng, op, params, cancel, out));
}

/// Fill `*out` with the next row. Returns 1 (a row was written), 0 (end), or
/// negative. Rows borrow the cursor arena and stay valid until `_close`.
export fn irregex_rows_next(cursor: *ffi.analytic.Rows, out: ?*ffi.rows.Row) i32 {
    return @intFromEnum(ffi.analytic.next(cursor, out));
}

/// Fill up to `cap` rows into `out[0..cap]`; writes the count to `*written`.
/// The one crossing a batching binding amortizes N rows over.
export fn irregex_rows_next_batch(cursor: *ffi.analytic.Rows, out: ?[*]ffi.rows.Row, cap: usize, written: ?*usize) i32 {
    return @intFromEnum(ffi.analytic.nextBatch(cursor, out, cap, written));
}

/// Answer-level facts no row carries — which tier answered, the freshness fold,
/// and `foreign` (query fingerprints this corpus has never seen).
export fn irregex_rows_stats(cursor: *ffi.analytic.Rows, out: ?*ffi.rows.Stats) i32 {
    return @intFromEnum(ffi.analytic.stats(cursor, out));
}

/// Free a cursor from `irregex_analytic_run` (and everything its rows borrow).
export fn irregex_rows_close(cursor: *ffi.analytic.Rows) void {
    ffi.analytic.close(cursor);
}

/// A stable, static, NUL-terminated digest of the WHOLE row-schema table. A
/// binding compares it to the digest its decoder was generated from, so a stale
/// shared library is a loud startup failure, not a mis-decoded row.
export fn irregex_schema_digest() [*:0]const u8 {
    return ffi.rows.digest();
}

/// How many row schemas this build declares (ids are 1..count).
export fn irregex_schema_count() u32 {
    return ffi.rows.schemaCount();
}

/// Fill `*out` with schema `id`. The names, tags, and field arrays are static
/// and outlive every call.
export fn irregex_schema_get(id: u32, out: ?*ffi.rows.Schema) i32 {
    return @intFromEnum(ffi.rows.schemaGet(id, out));
}

/// A stable, static, NUL-terminated human message for a status code (for logs;
/// the typed code stays the contract).
export fn irregex_status_message(code: i32) [*:0]const u8 {
    return ffi.cursor.statusMessage(code);
}

/// Detail for the LAST failing call on THIS thread — which fault member, and
/// where. Additive: a new symbol changes no existing layout or signature, so
/// `irregex_abi_version` stays 2. Reading does not consume, and a declinature
/// never lands here (ADR-373).
export fn irregex_last_fault(out: ?*ffi.contract.FaultDetail) i32 {
    return @intFromEnum(ffi.contract.lastFault(out));
}

test {
    // `refAllDecls` pulls each `pub` tier re-export above into `zig build test`;
    // dedicated `*_test.zig` siblings (not re-exported) are wired explicitly.
    std.testing.refAllDecls(@This());
    _ = @import("surface/ffi/rows.zig"); // analytic plane: C layout parity, schema table integrity, the row builder
    _ = @import("surface/ffi/analytic.zig"); // analytic plane: dispatch fails closed, the cursor walks/batches/reports
    _ = @import("exec/session/conduit/protocol/protocol_test.zig"); // UDS frame codec round-trip + adversarial
    _ = @import("exec/session/conduit/vigil.zig"); // the daemon's readiness wait + the bell that cuts it short
    _ = @import("exec/session/daemon/client/spawn.zig"); // best-effort detached daemon auto-spawn
    _ = @import("surface/face/gist/verbs/status.zig"); // read-only index introspection
    _ = @import("surface/face/gist/verbs/schema.zig"); // `--schema` manifest
    _ = @import("surface/face/gist/verbs/index.zig"); // the `index` verb: build + persist
    _ = @import("surface/face/gist/generate.zig"); // gist's own surface: value/rivalry/section derived from the parse table
    _ = @import("surface/face/relate/repertoire.zig"); // relate's verb table (schema validity + both registers)
    _ = @import("surface/face/relate/kinship.zig"); // relate shared plumbing: view resolver + verified-pair machinery
    _ = @import("surface/face/relate/units.zig"); // the unit view: file|function|match × warm/live × exact narrowing
    _ = @import("surface/face/relate/options.zig"); // the one query option surface (flag loop + unit-scaled floors)
    _ = @import("surface/face/relate/similar.zig"); // the neighbor verb: probe classification, self-exclusion, both polarities
    _ = @import("surface/face/relate/echoes.zig"); // the repetition verb: unit × channel × shape rendering
    _ = @import("surface/face/relate/patterns.zig"); // `relate patterns` driver body (one walk, N patterns)
    _ = @import("surface/face/relate/pack.zig"); // `relate pack` driver body (greedy coverage semantics tested here)
    _ = @import("surface/face/relate/lifecycle.zig"); // `relate index`/`status` driver bodies
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
