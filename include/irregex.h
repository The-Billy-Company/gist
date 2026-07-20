/* gist — fast, agent-friendly code locator kernel.
 *
 * This C ABI covers ABI/engine-version introspection, one allocation-free
 * trigram primitive, and an in-process warm search SESSION:
 * irregex_open / irregex_search / irregex_close
 * stream match records to a callback with no subprocess, socket, stdout, or
 * exit. Every session call returns a status code instead of aborting, so a bad
 * query never terminates the host. Index
 * BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree). */
#ifndef IRREGEX_H
#define IRREGEX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C-ABI version; bump on any breaking change so consumers can reject a
 * mismatched shared library. Additive symbols do not bump it. */
uint32_t irregex_abi_version(void);

/* The engine semantic version (e.g. "0.1.0"), NUL-terminated, static-lifetime;
 * never NULL. Lets a binding version-gate the library/binary it drives. */
const char *irregex_version(void);

/* Extract the distinct, ascending trigrams of text[0..len] into out[0..len]
 * (caller sizes out >= len). Returns the count written; len < 3 yields 0. */
size_t irregex_trigram_count(const uint8_t *text, size_t len, uint32_t *out);

/* ── in-process warm search session (ADR-352 rung 3) ──────────────────────── */

/* Session status codes. Non-negative = success (IRREGEX_OK ran with no match,
 * IRREGEX_MATCH had >=1 match); negative = a typed failure. IRREGEX_STALE means the
 * pattern is outside gist's linear-time syntax (or freshness is unprovable) —
 * the caller answers cold, unchanged. */
#define IRREGEX_OK 0
#define IRREGEX_MATCH 1
#define IRREGEX_STALE (-1)
#define IRREGEX_OOM (-2)
#define IRREGEX_OPEN_FAILED (-3)
#define IRREGEX_INVALID (-4)

/* search() flags bitset. Any set bit outside these makes irregex_search
 * return IRREGEX_INVALID (fail closed): an unknown flag is never silently
 * dropped in-process — the caller answers cold instead. */
#define IRREGEX_FIXED (1u << 0)       /* -F: fixed string, not a regex   */
#define IRREGEX_IGNORE_CASE (1u << 1) /* -i: case-insensitive            */
#define IRREGEX_WORD (1u << 2)        /* -w: word-bounded matches only   */
#define IRREGEX_QUIET (1u << 3)       /* -q: existence-only early halt   */
#define IRREGEX_MAX_COUNT (1u << 4)   /* options.max_count is present    */
#define IRREGEX_SMART_CASE (1u << 5)  /* -S: fold iff pattern has no caps */
#define IRREGEX_NO_UNICODE (1u << 6)  /* ASCII classes/fold/boundaries   */
#define IRREGEX_INVERT (1u << 7)      /* -v: select nonmatching lines    */

/* An opaque warm session (one corpus held in-memory). */
typedef struct irregex_session irregex_session;

/* One submatch span within a matched line. `text` aliases the line bytes and is
 * NOT NUL-terminated (use `len`); [start,end) are byte offsets within the line. */
typedef struct {
  const uint8_t *text;
  size_t len;
  size_t start;
  size_t end;
} irregex_submatch;

/* One selected line. `path` and `line` alias session bytes (NOT NUL-terminated);
 * `submatches[0..nsubmatches]` alias per-line scratch. Everything a match points
 * at is valid ONLY during the callback that receives it — copy what you keep.
 * Context and IRREGEX_INVERT selections have zero submatches; `kind`
 * distinguishes context from selected match lines. */
#define IRREGEX_KIND_MATCH 0u
#define IRREGEX_KIND_CONTEXT 1u
typedef struct {
  const uint8_t *path;
  size_t path_len;
  uint64_t line_number; /* 1-based */
  const uint8_t *line;
  size_t line_len;
  const irregex_submatch *submatches;
  size_t nsubmatches;
  uint32_t kind;
} irregex_match;

/* Per-line callback, invoked once per matching line while the session lock is
 * held (do NOT re-enter the session). `ctx` is the userdata passed to search.
 * Return 0 to CONTINUE the stream, or non-zero to STOP it early (a bounded /
 * first-match query): irregex_search then returns IRREGEX_MATCH and leaves the rest
 * of the corpus unscanned. The non-zero value is otherwise opaque to gist. */
typedef int32_t (*irregex_match_fn)(void *ctx, const irregex_match *m);

/* Complete options for irregex_search. Initialize
 * struct_size to sizeof(irregex_search_options). Unknown sizes/flags fail
 * closed with IRREGEX_INVALID rather than being silently ignored. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  uint64_t max_count;
  uint64_t before_context;
  uint64_t after_context;
} irregex_search_options;

/* Open a warm session over roots[0..nroots] (each a NUL-terminated path).
 * nroots == 0 means the ROOTLESS current-working-directory walk — the exact
 * tree a bare `gist <pattern>` walks (CWD-relative paths, no "./" prefix), so
 * the answer is byte-identical to a rootless cold run. On success writes the
 * handle to *out and returns IRREGEX_OK; else a negative status, *out unchanged. */
int32_t irregex_open(const char *const *roots, size_t nroots, irregex_session **out);

/* Execute one complete, size-checked search shape. Selected records stream to
 * on_match; a non-zero callback return stops early. Returns IRREGEX_MATCH,
 * IRREGEX_OK, or a negative fail-closed status. */
int32_t irregex_search(irregex_session *s, const uint8_t *pattern,
                    size_t pattern_len, const irregex_search_options *options,
                    irregex_match_fn on_match, void *ctx);

/* Free a session opened by irregex_open. */
void irregex_close(irregex_session *s);

/* ── the pull-cursor surface (ADR-352) ─────────────────────────────────────
 * The triad above PUSHES matches to on_match; these PULL. A host opens an
 * irregex_engine, runs irregex_search_cursor to materialize an irregex_cursor,
 * then walks it with irregex_cursor_next / _next_batch — inverting control for a
 * caller (Go's cgo, an async runtime, a REPL) that can't hand its stack to a
 * callback. Cancellation is an irregex_cancel handle any thread may trip mid
 * search. Additive over the triad, so irregex_abi_version stays 2; every entry
 * still returns a status and never terminates the host. */

/* Opaque owned handles. Each has exactly one NULL-safe destructor. */
typedef struct irregex_engine irregex_engine;
typedef struct irregex_cursor irregex_cursor;
typedef struct irregex_cancel irregex_cancel;

/* One complete cursor search shape. Initialize struct_size to
 * sizeof(irregex_search_request); it is append-only, so a newer field is a
 * forward-compatible extension and an unknown size/flag fails closed with
 * IRREGEX_INVALID. Budgets use 0 = "unset"; cancel is an optional irregex_cancel
 * (NULL = none). Flag bits reuse the IRREGEX_* set above. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  uint64_t max_count;
  uint64_t before_context;
  uint64_t after_context;
  const uint8_t *pattern;
  size_t pattern_len;
  uint64_t timeout_ns;  /* monotonic wall-clock budget; 0 = no deadline */
  size_t max_results;   /* result-count budget; 0 = unbounded */
  irregex_cancel *cancel;
} irregex_search_request;

/* Open a warm engine over roots[0..nroots] (NUL-terminated; nroots == 0 = the
 * rootless CWD walk). Writes the handle to *out; IRREGEX_OK or a negative status. */
int32_t irregex_engine_open(const char *const *roots, size_t nroots, irregex_engine **out);

/* Free an engine opened by irregex_engine_open. */
void irregex_engine_close(irregex_engine *engine);

/* Allocate a fresh (unset) cancellation token; writes it to *out. */
int32_t irregex_cancel_new(irregex_cancel **out);

/* Request cancellation of any in-flight search using this token (thread-safe;
 * the search stops at its next record boundary). */
void irregex_cancel_request(irregex_cancel *token);

/* Free a token from irregex_cancel_new (after searches using it complete). */
void irregex_cancel_free(irregex_cancel *token);

/* Run one search and materialize a pull cursor; writes it to *out. Returns
 * IRREGEX_OK, or a negative fail-closed status (IRREGEX_STALE = answer cold). */
int32_t irregex_search_cursor(irregex_engine *engine, const irregex_search_request *request,
                              irregex_cursor **out);

/* Fill *out with the next record. Returns IRREGEX_MATCH (a record was written),
 * IRREGEX_OK (end of stream; *out untouched), or a negative status. The view
 * BORROWS: path/line alias the cursor arena (valid until irregex_cursor_close),
 * submatches alias reusable scratch (valid only until the next next/_next_batch). */
int32_t irregex_cursor_next(irregex_cursor *cursor, irregex_match *out);

/* Fill up to cap records into out[0..cap]; writes the count to *written. Returns
 * IRREGEX_MATCH (>=1 written), IRREGEX_OK (end, 0 written), or a negative status.
 * All views in a batch share the cursor scratch — valid only until the next call. */
int32_t irregex_cursor_next_batch(irregex_cursor *cursor, irregex_match *out, size_t cap,
                                  size_t *written);

/* Whether any file matched (cold's exit-code boolean), even if a budget cut the
 * scan short: 1 matched, 0 none. */
int32_t irregex_cursor_matched(irregex_cursor *cursor);

/* Free a cursor from irregex_search_cursor. */
void irregex_cursor_close(irregex_cursor *cursor);

/* A stable, static, NUL-terminated human message for a status code (for logs;
 * the typed code stays the contract). Never NULL. */
const char *irregex_status_message(int32_t code);

#ifdef __cplusplus
}
#endif

#endif /* IRREGEX_H */
