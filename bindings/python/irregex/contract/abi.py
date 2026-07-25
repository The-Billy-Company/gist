"""Runtime mirror of `contract/search_api.toml` (ADR-352). The package embeds the contract's load-bearing constants so it has no runtime dependency on the repo file (a wheel ships without it); the package's parity test reads the canonical TOML and asserts this mirror matches it — the standard mirror-plus-parity-test shape, so the two cannot silently drift."""

from __future__ import annotations

from pathlib import Path


# Mirrors `[meta]` in contract/search_api.toml.
ABI_VERSION = 2
ENGINE_VERSION = "0.2.0"
PACKAGE_DIST = "billy-irregex"
PACKAGE_IMPORT = "gist"

# Mirrors `[request_options]` keys — the deep SearchRequest surface.
REQUEST_OPTIONS: frozenset[str] = frozenset(
    {
        "pattern",
        "paths",
        "fixed",
        "ignore_case",
        "smart_case",
        "word",
        "quiet",
        "invert",
        "globs",
        "iglobs",
        "types",
        "not_types",
        "before",
        "after",
        "context",
        "max_count",
        "max_depth",
        "hidden",
        "no_ignore",
        "follow",
        "no_index",
        "engine",
        "multiline",
        "multiline_dotall",
        "unicode",
    }
)

# Mirrors `[match_kinds]` and `[exit_codes]`.
MATCH_KINDS: frozenset[str] = frozenset({"match", "context"})
EXIT_MATCHED = 0
EXIT_NO_MATCH = 1
EXIT_ERROR = 2

# Mirrors `[tool_boundary]` — the agent / code-place seam (ADR-352). `ALIASES`
# rename a tool-boundary param onto its canonical request option; `ROUTING_KEYS`
# are recognized-but-ignored (place/transport routing stays outside GIST).
ALIASES: dict[str, str] = {
    "query": "pattern",
    "glob": "globs",
    "context_lines": "context",
}
ROUTING_KEYS: frozenset[str] = frozenset({"place", "at", "semantic"})


def contract_path() -> Path:
    """Path to the canonical `search_api.toml` in the repo (for the parity test); may not exist in an installed wheel."""
    return Path(__file__).resolve().parents[3] / "contract" / "search_api.toml"


# C declarations mirroring `include/irregex.h` — the other frozen input this
# package mirrors. cffi ABI mode needs no struct field layout beyond what we
# read, but the full structs let it compute offsets for the callback's
# `irregex_match *`. Kept here rather than in the loader so the header has one
# mirror site, next to the contract's.
CDEF = """
typedef struct irregex_session irregex_session;
typedef struct {
  const uint8_t *text; size_t len; size_t start; size_t end;
} irregex_submatch;
typedef struct {
  const uint8_t *path; size_t path_len; uint64_t line_number;
  const uint8_t *line; size_t line_len;
  const irregex_submatch *submatches; size_t nsubmatches;
  uint32_t kind;
} irregex_match;
typedef int32_t (*irregex_match_fn)(void *ctx, const irregex_match *m);
typedef struct {
  uint32_t struct_size; uint32_t flags; uint64_t max_count;
  uint64_t before_context; uint64_t after_context;
} irregex_search_options;
uint32_t irregex_abi_version(void);
int32_t irregex_open(const char *const *roots, size_t nroots, irregex_session **out);
int32_t irregex_search(irregex_session *s, const uint8_t *pattern,
                    size_t pattern_len, const irregex_search_options *options,
                    irregex_match_fn on_match, void *ctx);
void irregex_close(irregex_session *s);

/* the pull-cursor surface (ADR-352): open an engine, materialize a cursor,
   walk it with next / next_batch — no C-to-Python callback, so cffi releases
   the GIL for the duration of each native pull. */
typedef struct irregex_engine irregex_engine;
typedef struct irregex_cursor irregex_cursor;
typedef struct irregex_cancel irregex_cancel;
typedef struct {
  uint32_t struct_size; uint32_t flags; uint64_t max_count;
  uint64_t before_context; uint64_t after_context;
  const uint8_t *pattern; size_t pattern_len;
  uint64_t timeout_ns; size_t max_results; irregex_cancel *cancel;
} irregex_search_request;
int32_t irregex_engine_open(const char *const *roots, size_t nroots, irregex_engine **out);
void irregex_engine_close(irregex_engine *engine);
int32_t irregex_cancel_new(irregex_cancel **out);
void irregex_cancel_request(irregex_cancel *token);
void irregex_cancel_free(irregex_cancel *token);
int32_t irregex_search_cursor(irregex_engine *engine, const irregex_search_request *request,
                              irregex_cursor **out);
int32_t irregex_cursor_next(irregex_cursor *cursor, irregex_match *out);
int32_t irregex_cursor_next_batch(irregex_cursor *cursor, irregex_match *out, size_t cap,
                                  size_t *written);
int32_t irregex_cursor_matched(irregex_cursor *cursor);
void irregex_cursor_close(irregex_cursor *cursor);
const char *irregex_status_message(int32_t code);
"""

# The analytic plane (ADR-377): one dispatch, one self-describing row type, and
# schema introspection. Declared separately because these symbols may be absent
# from a library built before the plane landed — a declinature (answer through
# the subprocess tier), not a failure — while cffi fixes a library's type
# universe at `cdef` time and so must be told about them regardless.
ANALYTIC_CDEF = """
typedef struct { const uint8_t *ptr; size_t len; } irregex_text;
typedef struct irregex_row irregex_row;
typedef struct {
  uint32_t tag; uint32_t reserved; int64_t integer; double real;
  const void *ptr; size_t len;
} irregex_value;
struct irregex_row {
  uint32_t schema_id; uint32_t nvalues; uint64_t present; const irregex_value *values;
};
typedef struct {
  const char *name; uint32_t tag; uint32_t nested; int32_t optional; int32_t reserved;
} irregex_field;
typedef struct {
  uint32_t struct_size; uint32_t id; const char *name;
  uint32_t nfields; uint32_t reserved; const irregex_field *fields;
} irregex_schema;
typedef struct {
  uint32_t struct_size; uint32_t source; uint64_t elapsed_ns;
  uint64_t files_considered; uint64_t refreshed; uint64_t foreign;
  uint64_t omitted; uint64_t rows;
} irregex_stats;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *target; size_t target_len;
  uint32_t channel; uint32_t unit; double max_distance; double min_echo;
  uint32_t min_grade; uint32_t min_size; uint32_t min_lines; uint32_t top;
} irregex_kinship_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *query; size_t query_len;
  uint32_t top; uint32_t reserved;
} irregex_retrieval_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const irregex_text *patterns; size_t npatterns;
  const uint8_t *under; size_t under_len; uint32_t top; uint32_t reserved;
} irregex_sweep_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *text; size_t text_len;
  const irregex_text *patterns; size_t npatterns; double max_distance; double min_echo;
  uint32_t budget; uint32_t top;
} irregex_compose_params;
typedef struct {
  uint32_t struct_size; uint32_t flags; const uint8_t *pattern; size_t pattern_len;
  uint32_t top; uint32_t reserved;
} irregex_rank_params;
typedef struct irregex_rows irregex_rows;
int32_t irregex_analytic_run(irregex_engine *engine, uint32_t op, const void *params,
                             irregex_cancel *cancel, irregex_rows **out);
int32_t irregex_rows_next(irregex_rows *rows, irregex_row *out);
int32_t irregex_rows_next_batch(irregex_rows *rows, irregex_row *out, size_t cap,
                                size_t *written);
int32_t irregex_rows_stats(irregex_rows *rows, irregex_stats *out);
void irregex_rows_close(irregex_rows *rows);
const char *irregex_schema_digest(void);
uint32_t irregex_schema_count(void);
int32_t irregex_schema_get(uint32_t id, irregex_schema *out);
"""
