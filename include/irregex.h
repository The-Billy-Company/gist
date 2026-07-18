/* gist — fast, agent-friendly code locator kernel.
 *
 * This C ABI covers ABI/engine-version introspection, one allocation-free
 * trigram primitive, and an in-process warm search SESSION:
 * irregex_open / irregex_search / irregex_close stream match records to a callback with
 * no subprocess, socket, stdout, or exit. Every session call returns a status
 * code instead of aborting, so a bad query never terminates the host. Index
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

/* search() flags bitset. */
#define IRREGEX_FIXED (1u << 0)       /* -F: fixed string, not a regex   */
#define IRREGEX_IGNORE_CASE (1u << 1) /* -i: case-insensitive            */

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

/* One matching line. `path` and `line` alias session bytes (NOT NUL-terminated);
 * `submatches[0..nsubmatches]` alias per-line scratch. Everything a match points
 * at is valid ONLY during the callback that receives it — copy what you keep. */
typedef struct {
  const uint8_t *path;
  size_t path_len;
  uint64_t line_number; /* 1-based */
  const uint8_t *line;
  size_t line_len;
  const irregex_submatch *submatches;
  size_t nsubmatches;
} irregex_match;

/* Per-line callback, invoked once per matching line while the session lock is
 * held (do NOT re-enter the session). `ctx` is the userdata passed to search.
 * Return 0 to CONTINUE the stream, or non-zero to STOP it early (a bounded /
 * first-match query): irregex_search then returns IRREGEX_MATCH and leaves the rest
 * of the corpus unscanned. The non-zero value is otherwise opaque to gist. */
typedef int32_t (*irregex_match_fn)(void *ctx, const irregex_match *m);

/* Open a warm session over roots[0..nroots] (each a NUL-terminated path).
 * nroots == 0 means the ROOTLESS current-working-directory walk — the exact
 * tree a bare `gist <pattern>` walks (CWD-relative paths, no "./" prefix), so
 * the answer is byte-identical to a rootless cold run. On success writes the
 * handle to *out and returns IRREGEX_OK; else a negative status, *out unchanged. */
int32_t irregex_open(const char *const *roots, size_t nroots, irregex_session **out);

/* Stream every matching line of pattern[0..pattern_len] over the warm corpus to
 * on_match. Returns IRREGEX_MATCH if any line matched, IRREGEX_OK if none, or a
 * negative status on error (IRREGEX_STALE => answer cold). on_match may return
 * non-zero to stop early — a bounded / first-match query then still returns
 * IRREGEX_MATCH without scanning the rest of the corpus. */
int32_t irregex_search(irregex_session *s, const uint8_t *pattern, size_t pattern_len,
                    uint32_t flags, irregex_match_fn on_match, void *ctx);

/* Free a session opened by irregex_open. */
void irregex_close(irregex_session *s);

#ifdef __cplusplus
}
#endif

#endif /* IRREGEX_H */
