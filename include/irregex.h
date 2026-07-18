/* gist — fast, agent-friendly code locator kernel.
 *
 * This C ABI covers ABI/engine-version introspection, one allocation-free
 * trigram primitive, and an in-process warm search SESSION:
 * gist_open / gist_search / gist_close stream match records to a callback with
 * no subprocess, socket, stdout, or exit. Every session call returns a status
 * code instead of aborting, so a bad query never terminates the host. Index
 * BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree). */
#ifndef GIST_H
#define GIST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C-ABI version; bump on any breaking change so consumers can reject a
 * mismatched shared library. Additive symbols do not bump it. */
uint32_t gist_abi_version(void);

/* The engine semantic version (e.g. "0.1.0"), NUL-terminated, static-lifetime;
 * never NULL. Lets a binding version-gate the library/binary it drives. */
const char *gist_version(void);

/* Extract the distinct, ascending trigrams of text[0..len] into out[0..len]
 * (caller sizes out >= len). Returns the count written; len < 3 yields 0. */
size_t gist_trigram_count(const uint8_t *text, size_t len, uint32_t *out);

/* ── in-process warm search session (ADR-352 rung 3) ──────────────────────── */

/* Session status codes. Non-negative = success (GIST_OK ran with no match,
 * GIST_MATCH had >=1 match); negative = a typed failure. GIST_STALE means the
 * pattern is outside gist's linear-time syntax (or freshness is unprovable) —
 * the caller answers cold, unchanged. */
#define GIST_OK 0
#define GIST_MATCH 1
#define GIST_STALE (-1)
#define GIST_OOM (-2)
#define GIST_OPEN_FAILED (-3)
#define GIST_INVALID (-4)

/* search() flags bitset. */
#define GIST_FIXED (1u << 0)       /* -F: fixed string, not a regex   */
#define GIST_IGNORE_CASE (1u << 1) /* -i: case-insensitive            */

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

/* One matching line. `path` and `line` alias session bytes (NOT NUL-terminated);
 * `submatches[0..nsubmatches]` alias per-line scratch. Everything a match points
 * at is valid ONLY during the callback that receives it — copy what you keep. */
typedef struct {
  const uint8_t *path;
  size_t path_len;
  uint64_t line_number; /* 1-based */
  const uint8_t *line;
  size_t line_len;
  const gist_submatch *submatches;
  size_t nsubmatches;
} gist_match;

/* Per-line callback, invoked once per matching line while the session lock is
 * held (do NOT re-enter the session). `ctx` is the userdata passed to search.
 * Return 0 to CONTINUE the stream, or non-zero to STOP it early (a bounded /
 * first-match query): gist_search then returns GIST_MATCH and leaves the rest
 * of the corpus unscanned. The non-zero value is otherwise opaque to gist. */
typedef int32_t (*gist_match_fn)(void *ctx, const gist_match *m);

/* Open a warm session over roots[0..nroots] (each a NUL-terminated path).
 * nroots == 0 means the ROOTLESS current-working-directory walk — the exact
 * tree a bare `gist <pattern>` walks (CWD-relative paths, no "./" prefix), so
 * the answer is byte-identical to a rootless cold run. On success writes the
 * handle to *out and returns GIST_OK; else a negative status, *out unchanged. */
int32_t gist_open(const char *const *roots, size_t nroots, gist_session **out);

/* Stream every matching line of pattern[0..pattern_len] over the warm corpus to
 * on_match. Returns GIST_MATCH if any line matched, GIST_OK if none, or a
 * negative status on error (GIST_STALE => answer cold). on_match may return
 * non-zero to stop early — a bounded / first-match query then still returns
 * GIST_MATCH without scanning the rest of the corpus. */
int32_t gist_search(gist_session *s, const uint8_t *pattern, size_t pattern_len,
                    uint32_t flags, gist_match_fn on_match, void *ctx);

/* Free a session opened by gist_open. */
void gist_close(gist_session *s);

#ifdef __cplusplus
}
#endif

#endif /* GIST_H */
