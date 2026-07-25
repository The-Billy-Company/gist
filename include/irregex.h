/* gist — fast, agent-friendly code locator kernel.
 *
 * This C ABI covers ABI/engine-version introspection, one allocation-free
 * trigram primitive, and an in-process warm search SESSION:
 * irregex_open / irregex_search / irregex_close
 * stream match records to a callback with no subprocess, socket, stdout, or
 * exit. Every session call returns a status code instead of aborting, so a bad
 * query never terminates the host. Index
 * BUILD lifecycle stays a Zig/CLI surface (a session searches the live tree).
 *
 * Past the exact engine sits the ANALYTIC PLANE (ADR-377): compression kinship,
 * retrieval, the multi-pattern sweep, and the composed verbs, all reached
 * through one irregex_analytic_run dispatch returning one self-describing
 * irregex_row. See the analytic section at the bottom of this header. */
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

/* ── the last-fault pull (ADR-373 law 7) ───────────────────────────────────
 * irregex_status_message names a CODE; this names the INCIDENT — which fault,
 * about which file, at which byte. A status code is one of six values, so it
 * cannot carry that, and gist writes nothing to your streams to tell you.
 *
 * Additive, so irregex_abi_version stays 2. */

/* Detail for the LAST failing call on THIS thread. Set struct_size to
 * sizeof(irregex_fault); the layout is append-only, so an unknown size fails
 * closed with IRREGEX_INVALID rather than being reinterpreted.
 *
 * `status` is the status that fault was reported as (always one of IRREGEX_OOM
 * / IRREGEX_OPEN_FAILED / IRREGEX_INVALID). `name` is the fault's name
 * ("Corrupt", "AccessDenied"), NUL-terminated with static lifetime, never NULL.
 * `path` is the file the fault was about or NULL when it was about no single
 * one; it is NOT NUL-terminated (use path_len) and BORROWS thread-local storage
 * valid only until this thread's next irregex call. `at` is a byte offset within
 * `path`, meaningful only when has_at is 1 (offset 0 is a real offset). */
typedef struct {
  uint32_t struct_size;
  int32_t status;
  int32_t has_at;
  const char *name;
  const uint8_t *path;
  size_t path_len;
  uint64_t at;
} irregex_fault;

/* Fill *out with this thread's last fault. Returns IRREGEX_MATCH (a detail was
 * written), IRREGEX_OK (this thread has none; *out untouched), or
 * IRREGEX_INVALID (NULL or wrongly-sized *out). Mirrors sqlite3_errmsg /
 * git_error_last: per thread, last fault wins, borrowed until the next call.
 *
 * Reading does not consume — ask twice and get the same answer. IRREGEX_OK is
 * NOT a contradiction of a preceding negative status: a declinature
 * (IRREGEX_STALE) is not a fault at all, and gist's own argument checks
 * (IRREGEX_INVALID for a NULL or wrongly-sized argument) have nothing to add
 * over irregex_status_message. It means "nothing further to say", never "the
 * call succeeded".
 *
 * Every entry point that STARTS work clears the slot first, so asking after a
 * successful call reports IRREGEX_OK rather than an earlier failure. The
 * destructors (irregex_close / _engine_close / _cursor_close / _cancel_free)
 * and both readers leave it alone, so a cleanup path can still report it. */
int32_t irregex_last_fault(irregex_fault *out);

/* ── the analytic plane (ADR-377) ──────────────────────────────────────────
 * Everything above answers "where is this exact pattern?". This answers the
 * questions regex cannot: compression kinship (similar/dups/clusters/echoes/
 * concepts/fragments), retrieval (recall/pack/quote), the multi-pattern sweep,
 * the composed exact-then-compression verbs (context/family/provenance/blast),
 * and the definition-first ranked view.
 *
 * Seventeen verbs, ONE entry point. A C function per verb would be seventeen
 * result structs hand-mirrored into every binding, drifting independently, with
 * nothing able to prove they agree — so instead every verb returns the same
 * self-describing irregex_row, and what a row MEANS is declared once in
 * contract/search_api.toml ([row_schemas]) and lowered into a generated decoder
 * per language. A verb reusing an existing schema costs zero new C surface.
 *
 * Additive: no existing symbol changes, so irregex_abi_version stays 2. The
 * plane's own compatibility axis is irregex_schema_digest. */

/* Verb op codes for irregex_analytic_run — [analytic.verbs], append-only. */
#define IRREGEX_OP_SIMILAR 1u
#define IRREGEX_OP_DUPS 2u
#define IRREGEX_OP_CLUSTERS 3u
#define IRREGEX_OP_ECHOES 4u
#define IRREGEX_OP_CONCEPTS 5u
#define IRREGEX_OP_FRAGMENTS 6u
#define IRREGEX_OP_DISTINCT 7u
#define IRREGEX_OP_RECALL 8u
#define IRREGEX_OP_PACK 9u
#define IRREGEX_OP_QUOTE 10u
#define IRREGEX_OP_PATTERNS 11u
#define IRREGEX_OP_PATTERN_COUNTS 12u
#define IRREGEX_OP_CONTEXT 13u
#define IRREGEX_OP_FAMILY 14u
#define IRREGEX_OP_PROVENANCE 15u
#define IRREGEX_OP_BLAST 16u
#define IRREGEX_OP_RANK 17u

/* Value tags. A field's tag comes from its [row_schemas] declaration, so a
 * decoder knows the shape before it reads; the tag on the wire is what lets it
 * FAIL rather than mis-read when the two disagree. */
#define IRREGEX_VAL_TEXT 0u  /* ptr/len: UTF-8 bytes, NOT NUL-terminated */
#define IRREGEX_VAL_I64 1u   /* integer                                  */
#define IRREGEX_VAL_F64 2u   /* real                                     */
#define IRREGEX_VAL_BOOL 3u  /* integer, 0 or 1                          */
#define IRREGEX_VAL_ENUM 4u  /* integer = ordinal; field.nested = enum id */
#define IRREGEX_VAL_TEXTS 5u /* ptr/len: irregex_text[]                  */
#define IRREGEX_VAL_ROWS 6u  /* ptr/len: irregex_row[]; field.nested = schema id */

/* [row_enums] ordinals. Append-only: an ordinal above the highest a binding
 * knows is UNKNOWN, and must be surfaced as such rather than guessed. */
#define IRREGEX_GRADE_NONE 0u
#define IRREGEX_GRADE_WEAK 1u
#define IRREGEX_GRADE_MODERATE 2u
#define IRREGEX_GRADE_STRONG 3u
#define IRREGEX_GRADE_IDENTICAL 4u
#define IRREGEX_CHANNEL_COPIES 0u
#define IRREGEX_CHANNEL_TWINS 1u
#define IRREGEX_CHANNEL_SHAPES 2u
#define IRREGEX_CHANNEL_ANY 3u
#define IRREGEX_UNIT_FILE 0u
#define IRREGEX_UNIT_FUNCTION 1u
#define IRREGEX_UNIT_MATCH 2u

/* Analytic params flags. The presence bits exist because 0.0 is a MEANINGFUL
 * threshold (max_distance 0.0 = byte-identical only), so "unset" cannot be
 * spelled as zero the way an integer budget can. */
#define IRREGEX_AN_MAX_DISTANCE (1u << 0) /* params.max_distance is present  */
#define IRREGEX_AN_MIN_ECHO (1u << 1)     /* params.min_echo is present      */
#define IRREGEX_AN_NO_INDEX (1u << 2)     /* force the live build, skip warm */
#define IRREGEX_AN_FIXED (1u << 3)        /* -F for the verb's patterns      */
#define IRREGEX_AN_IGNORE_CASE (1u << 4)  /* -i for the verb's patterns      */
#define IRREGEX_AN_MATCH_ALL (1u << 5)    /* compose: --match all, else any  */
#define IRREGEX_AN_BY_PATTERN (1u << 6)   /* sweep: tally per pattern        */
#define IRREGEX_AN_BY_FILE (1u << 7)      /* sweep: tally per file           */
#define IRREGEX_AN_DISTINCT (1u << 8)     /* kinship: the un-echoed polarity */

/* A borrowed UTF-8 span. NOT NUL-terminated; `len` is authoritative. */
typedef struct {
  const uint8_t *ptr;
  size_t len;
} irregex_text;

typedef struct irregex_row irregex_row;

/* One field of one row. Deliberately a flat tagged record rather than a union:
 * a union saves 16 bytes against queries that scan megabytes, and costs every
 * binding an anonymous-type parse its FFI layer may not support. `tag` selects
 * exactly one payload; the others are zero. */
typedef struct {
  uint32_t tag;
  uint32_t reserved; /* always 0 */
  int64_t integer;   /* I64 · BOOL · ENUM ordinal */
  double real;       /* F64 */
  const void *ptr;   /* TEXT bytes · TEXTS irregex_text[] · ROWS irregex_row[] */
  size_t len;        /* element count for ptr (bytes for TEXT) */
} irregex_value;

/* One result row. `schema_id` names a [row_schemas] table, whose field order IS
 * `values`. `present` bit i is clear when field i is absent — which is NOT the
 * same as zero: distance 0.0 means identical, so a binding must be able to tell
 * "no distance" from "no distance between them". Schemas cap at 64 fields.
 *
 * Rows BORROW the cursor arena: they, their nested rows, and their texts stay
 * valid until irregex_rows_close. */
struct irregex_row {
  uint32_t schema_id;
  uint32_t nvalues;
  uint64_t present;
  const irregex_value *values;
};

/* One declared field, for irregex_schema_get. `name` is static and
 * NUL-terminated. `nested` is the schema id for ROWS, the enum id for ENUM, and
 * 0 otherwise. */
typedef struct {
  const char *name;
  uint32_t tag;
  uint32_t nested;
  int32_t optional;
  int32_t reserved;
} irregex_field;

/* One declared row schema. Set struct_size to sizeof(irregex_schema). */
typedef struct {
  uint32_t struct_size;
  uint32_t id;
  const char *name; /* static, NUL-terminated */
  uint32_t nfields;
  uint32_t reserved;
  const irregex_field *fields;
} irregex_schema;

/* Answer-level facts no row can carry. `foreign` is load-bearing for the
 * retrieval verbs: it counts query fingerprints the corpus has NEVER seen, so a
 * caller can tell "your text isn't in this repo" from "no results". `omitted`
 * is what a budget trimmed, so a truncated answer says so. Set struct_size to
 * sizeof(irregex_stats). */
#define IRREGEX_SOURCE_LIVE 0u
#define IRREGEX_SOURCE_ATLAS 1u
#define IRREGEX_SOURCE_SHELF 2u
typedef struct {
  uint32_t struct_size;
  uint32_t source; /* IRREGEX_SOURCE_*: which tier answered */
  uint64_t elapsed_ns;
  uint64_t files_considered;
  uint64_t refreshed; /* files re-sketched into a warm answer */
  uint64_t foreign;
  uint64_t omitted;
  uint64_t rows;
} irregex_stats;

/* The five params families ([analytic.params]). Five shapes rather than
 * seventeen: a caller learns one struct per KIND of question. Each opens with
 * struct_size — append-only, so an unknown size fails closed with
 * IRREGEX_INVALID instead of being reinterpreted. `top` 0 = unbounded. */

/* similar · dups · clusters · echoes · concepts · fragments · distinct.
 * `target` NULL = the corpus-wide sweep (dups/clusters/echoes/concepts). */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *target;
  size_t target_len;
  uint32_t channel; /* IRREGEX_CHANNEL_* */
  uint32_t unit;    /* IRREGEX_UNIT_*    */
  double max_distance;
  double min_echo;
  uint32_t min_grade; /* IRREGEX_GRADE_*: withhold anything weaker */
  uint32_t min_size;
  uint32_t min_lines;
  uint32_t top;
} irregex_kinship_params;

/* recall · pack · quote — free text priced against the corpus. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *query;
  size_t query_len;
  uint32_t top;
  uint32_t reserved;
} irregex_retrieval_params;

/* patterns · pattern_counts — N patterns, one walk, exact attribution. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const irregex_text *patterns;
  size_t npatterns;
  const uint8_t *under; /* optional glob scope; NULL = the whole corpus */
  size_t under_len;
  uint32_t top;
  uint32_t reserved;
} irregex_sweep_params;

/* context · family · provenance · blast — an exact PatternSet narrows a
 * candidate set, then the compression kernel reasons INSIDE it. `text` is the
 * task text (context), the pasted snippet (provenance), or the symbol (blast);
 * `patterns` are the exact intents. `budget` 0 = unbounded. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *text;
  size_t text_len;
  const irregex_text *patterns;
  size_t npatterns;
  double max_distance;
  double min_echo;
  uint32_t budget;
  uint32_t top;
} irregex_compose_params;

/* rank — the definition-first view of an exact query. The one exact-plane verb
 * whose answer is analytic rows rather than irregex_match records. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *pattern;
  size_t pattern_len;
  uint32_t top;
  uint32_t reserved;
} irregex_rank_params;

/* An opaque analytic row cursor. */
typedef struct irregex_rows irregex_rows;

/* Run one analytic verb and materialize a row cursor; writes it to *out.
 * `op` is an IRREGEX_OP_* code and `params` MUST be its declared family
 * ([analytic.verbs]) — a mismatched or wrongly-sized struct is IRREGEX_INVALID.
 * `cancel` is optional (NULL = none) and is the same token the exact plane uses.
 *
 * The engine is the same irregex_engine: the analytic corpus (and the atlas /
 * codex shelf a warm answer folds) loads lazily on first analytic use, so a host
 * that only searches never pays for it.
 *
 * Returns IRREGEX_OK, or a negative fail-closed status. IRREGEX_STALE means this
 * tier declines and the caller should answer through the subprocess fallback —
 * it is NOT a failure, and the answer there is identical. */
int32_t irregex_analytic_run(irregex_engine *engine, uint32_t op, const void *params,
                             irregex_cancel *cancel, irregex_rows **out);

/* Fill *out with the next row. Returns IRREGEX_MATCH (a row was written),
 * IRREGEX_OK (end of stream; *out untouched), or a negative status. */
int32_t irregex_rows_next(irregex_rows *rows, irregex_row *out);

/* Fill up to cap rows into out[0..cap]; writes the count to *written. Returns
 * IRREGEX_MATCH (>=1 written), IRREGEX_OK (end, 0 written), or a negative
 * status.
 *
 * Unlike irregex_cursor_next_batch, which recycles one submatch scratch per
 * pull, an analytic answer is materialized into a single cursor arena — so
 * every row, nested row, and text stays valid until irregex_rows_close, NOT
 * merely until the next pull. A batching host can therefore hold many batches
 * at once without copying. */
int32_t irregex_rows_next_batch(irregex_rows *rows, irregex_row *out, size_t cap,
                                size_t *written);

/* Fill *out with the answer-level stats. Valid at any point; the counters are
 * final once the cursor is drained. IRREGEX_OK, or IRREGEX_INVALID for a NULL
 * or wrongly-sized *out. */
int32_t irregex_rows_stats(irregex_rows *rows, irregex_stats *out);

/* Free a cursor from irregex_analytic_run. */
void irregex_rows_close(irregex_rows *rows);

/* A stable, static, NUL-terminated digest of this engine's WHOLE row-schema
 * table. A binding compares it to the digest its decoder was generated from, so
 * a stale shared library is a loud startup failure rather than a silently
 * mis-decoded row. Never NULL. */
const char *irregex_schema_digest(void);

/* How many row schemas this engine declares (ids are 1..count, contiguous). */
uint32_t irregex_schema_count(void);

/* Fill *out with schema `id` (1-based). Returns IRREGEX_OK, or IRREGEX_INVALID
 * for an unknown id or a NULL / wrongly-sized *out. Lets a binding NAME a
 * digest mismatch instead of only detecting one; `name` and `fields` are static
 * and outlive every call. */
int32_t irregex_schema_get(uint32_t id, irregex_schema *out);

#ifdef __cplusplus
}
#endif

#endif /* IRREGEX_H */
