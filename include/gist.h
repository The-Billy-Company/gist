/* gist — the search product's C ABI.
 *
 * Session, exact-plane pull cursor, trigram primitive, and the rank producer
 * (gist_run). Status codes, the fault pull, pattern-semantics bits, and the
 * row cursor (irregex_rows_*) come from libirregex via <irregex.h> — this
 * header does not redeclare them. Kinship and sweep live in relate.h;
 * compose lives in blast.h. Link libgist and libirregex.
 *
 * gist_run returns an irregex_rows * walked by the four irregex_rows_*
 * symbols. That is deliberate: gist_run, relate_run, and blast_run all hand
 * back the same cursor. */
#ifndef GIST_H
#define GIST_H

#include <irregex.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Session C-ABI version for THIS library; bump on any breaking change so a
 * consumer can reject a mismatched shared object. Additive symbols do not bump
 * it. Independent of gist_abi_version — they are separate axes. */
uint32_t gist_abi_version(void);

/* Extract the distinct, ascending trigrams of text[0..len] into out[0..len]
 * (caller sizes out >= len). Returns the count written; len < 3 yields 0. */
size_t gist_trigram_count(const uint8_t *text, size_t len, uint32_t *out);

/* ── in-process warm search session ──────────────────────── */

/* Behavioral search() flags. Pattern-semantics bits (FIXED, IGNORE_CASE,
 * WORD, SMART_CASE, NO_UNICODE) are IRREGEX_* from <gist.h>. Any set bit
 * outside the union of those and the three below makes gist_search return
 * IRREGEX_INVALID. */
#define GIST_QUIET (1u << 3)     /* -q: existence-only early halt   */
#define GIST_MAX_COUNT (1u << 4) /* options.max_count is present    */
#define GIST_INVERT (1u << 7)    /* -v: select nonmatching lines    */

/* An opaque warm session (one corpus held in-memory). */
typedef struct gist_session gist_session;

/* One submatch span within a matched line. `text` aliases the line bytes and is
 * NOT NUL-terminated (use `len`); [start,end) are byte offsets within the line. */
typedef struct {
  const uint8_t *text;
  size_t len;
  size_t start;
  size_t end;
} gist_submatch;

/* One selected line. `path` and `line` alias session bytes (NOT NUL-terminated);
 * `submatches[0..nsubmatches]` alias per-line scratch. Everything a match points
 * at is valid ONLY during the callback that receives it — copy what you keep.
 * `kind` distinguishes context from selected match lines. */
#define GIST_KIND_MATCH 0u
#define GIST_KIND_CONTEXT 1u
typedef struct {
  const uint8_t *path;
  size_t path_len;
  uint64_t line_number; /* 1-based */
  const uint8_t *line;
  size_t line_len;
  const gist_submatch *submatches;
  size_t nsubmatches;
  uint32_t kind;
} gist_match;

/* Per-line callback, invoked once per matching line while the session lock is
 * held (do NOT re-enter the session). `ctx` is the userdata passed to search.
 * Return 0 to CONTINUE the stream, or non-zero to STOP it early. */
typedef int32_t (*gist_match_fn)(void *ctx, const gist_match *m);

/* Complete options for gist_search. Initialize struct_size to
 * sizeof(gist_search_options). Unknown sizes/flags fail closed with
 * IRREGEX_INVALID rather than being silently ignored. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  uint64_t max_count;
  uint64_t before_context;
  uint64_t after_context;
} gist_search_options;

/* Open a warm session over roots[0..nroots] (each a NUL-terminated path).
 * nroots == 0 means the ROOTLESS current-working-directory walk. On success
 * writes the handle to *out and returns IRREGEX_OK; else a negative status. */
int32_t gist_open(const char *const *roots, size_t nroots, gist_session **out);

/* Execute one complete, size-checked search shape. Selected records stream to
 * on_match; a non-zero callback return stops early. Returns IRREGEX_MATCH,
 * IRREGEX_OK, or a negative fail-closed status. */
int32_t gist_search(gist_session *s, const uint8_t *pattern, size_t pattern_len,
                    const gist_search_options *options, gist_match_fn on_match,
                    void *ctx);

/* Free a session opened by gist_open. */
void gist_close(gist_session *s);

/* ── the pull-cursor surface ─────────────────────────────────────
 * The triad above PUSHES matches to on_match; these PULL. A host opens an
 * irregex_engine, runs gist_search_cursor to materialize a gist_cursor, then
 * walks it with gist_cursor_next / _next_batch. Cancellation is an
 * irregex_cancel handle any thread may trip mid search. Additive over the
 * triad, so gist_abi_version stays 2.
 *
 * The engine and the token come from libirregex (irregex_engine_open /
 * irregex_cancel_new), not from here. Every package's producer - gist_run,
 * relate_run, blast_run - takes the same engine, and an engine is only
 * interpretable by the copy of the engine code that opened it, so one opener
 * has to serve all four libraries. Search owns what it does WITH a corpus. */

/* Opaque owned handle for a cursor. One NULL-safe destructor, below. */
typedef struct gist_cursor gist_cursor;

/* One complete cursor search shape. Initialize struct_size to
 * sizeof(gist_search_request); it is append-only. Budgets use 0 = "unset";
 * cancel is optional (NULL = none). Flag bits reuse IRREGEX_* + GIST_*. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  uint64_t max_count;
  uint64_t before_context;
  uint64_t after_context;
  const uint8_t *pattern;
  size_t pattern_len;
  uint64_t timeout_ns; /* monotonic wall-clock budget; 0 = no deadline */
  size_t max_results;  /* result-count budget; 0 = unbounded */
  irregex_cancel *cancel;
} gist_search_request;

/* Run one search and materialize a pull cursor; writes it to *out. Returns
 * IRREGEX_OK, or a negative fail-closed status (IRREGEX_STALE = answer cold). */
int32_t gist_search_cursor(irregex_engine *engine, const gist_search_request *request,
                           gist_cursor **out);

/* Fill *out with the next record. Returns IRREGEX_MATCH, IRREGEX_OK (end), or
 * a negative status. The view BORROWS: path/line alias the cursor arena (valid
 * until gist_cursor_close), submatches alias reusable scratch (valid only until
 * the next next/_next_batch). */
int32_t gist_cursor_next(gist_cursor *cursor, gist_match *out);

/* Fill up to cap records into out[0..cap]; writes the count to *written. */
int32_t gist_cursor_next_batch(gist_cursor *cursor, gist_match *out, size_t cap,
                               size_t *written);

/* Whether any file matched (cold's exit-code boolean): 1 matched, 0 none. */
int32_t gist_cursor_matched(gist_cursor *cursor);

/* Free a cursor from gist_search_cursor. */
void gist_cursor_close(gist_cursor *cursor);

/* ── the rank producer ───────────────────────────────────────────
 * One verb. Kinship / sweep / compose left with the libraries that own
 * them (relate.h / blast.h). Every producer returns the same
 * self-describing irregex_row; what a row MEANS is declared in
 * irregex/contract/analytic.toml and lowered into a generated decoder per language.
 *
 * Additive: gist_abi_version stays 2. The plane's own compatibility axis is
 * irregex_schema_digest. */

/* Verb op code for gist_run — same number as the ecosystem-wide table. */
#define GIST_OP_RANK 17u

/* Analytic params flags the rank verb accepts. Same bit values as every
 * other producer; an unknown bit fails closed with IRREGEX_INVALID. */
#define GIST_AN_FIXED (1u << 3)       /* -F for the pattern */
#define GIST_AN_IGNORE_CASE (1u << 4) /* -i for the pattern */

/* rank — the definition-first view of an exact query. Initialize
 * struct_size to sizeof(gist_rank_params). `top` 0 = unbounded. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *pattern;
  size_t pattern_len;
  uint32_t top;
  uint32_t reserved;
} gist_rank_params;

/* Run the rank verb and materialize a row cursor; writes it to *out.
 * `op` must be GIST_OP_RANK and `params` a gist_rank_params — any other op
 * or a wrongly-sized struct is IRREGEX_INVALID. `cancel` is optional
 * (NULL = none) and is the same token the exact plane uses.
 *
 * Returns IRREGEX_OK, or a negative fail-closed status. IRREGEX_STALE means
 * this tier declines and the caller should answer through the subprocess
 * fallback — it is NOT a failure.
 *
 * The cursor is an irregex_rows *: walk it with irregex_rows_next /
 * _next_batch / _stats and free it with irregex_rows_close from libirregex. */
int32_t gist_run(irregex_engine *engine, uint32_t op, const void *params,
                 irregex_cancel *cancel, irregex_rows **out);

#ifdef __cplusplus
}
#endif

#endif /* GIST_H */
