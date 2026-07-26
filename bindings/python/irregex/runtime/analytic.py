"""The analytic plane: one dispatch, one row cursor, one ladder (ADR-377).

Seventeen verbs used to mean seventeen subprocess spawns and seventeen NDJSON
parsers. They now mean one C call — `irregex_analytic_run(engine, op, params)` —
returning a cursor of self-describing rows that `decode` turns into records.

**Five parameter families, not seventeen argument lists.** A caller learns one
struct per *kind* of question (`Kinship`, `Retrieval`, `Sweep`, `Compose`,
`Rank`), and the contract says which family a verb takes — checked here, so a
verb can never be dispatched with the wrong struct. Thresholds carry presence
flags because `0.0` is a meaningful threshold: `max_distance=0.0` means
byte-identical only, and "unset" cannot be spelled as zero.

**The ladder is invisible.** `answer()` tries the in-process plane and falls to
the `cold` continuation when the library is absent, the schema table disagrees,
the roots are not this process's, or the engine returns `IRREGEX_STALE` — the
kernel's way of saying *"ask the tier below"*. Both tiers produce the same rows
through the same decoder, so only the latency differs. A hard status (`OOM`,
`INVALID`) is a bug in this layer's marshaling rather than a query the kernel
declined, so it raises instead of quietly answering slower.

**Rows outlive their pull.** Unlike the exact cursor, an analytic answer is
materialized into one arena that stays valid until `close`, so batching costs
nothing and a caller may hold every batch at once. Records are decoded into
owned Python objects on the way out anyway, which is what makes `drain()` safe
after the cursor is gone.
"""

from __future__ import annotations

from contextlib import suppress
from dataclasses import dataclass
from itertools import chain, islice
import os
from pathlib import Path
import threading
from typing import TYPE_CHECKING, Final, Protocol

from ..contract import table
from . import native
from .decode import Row, record
from .errors import GistError, SchemaDriftError
from .params import Compose, Kinship, Params, Rank, Retrieval, Sweep


if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Iterator, Sequence

    from cffi import FFI


# The params families are re-exported here because this module is the plane's
# entry point: a verb names one thing (`analytic.Retrieval`) rather than tracking
# which file the struct happens to live in.
__all__ = [
    "DEFAULT_BATCH",
    "Compose",
    "Kinship",
    "Params",
    "Rank",
    "Retrieval",
    "Rows",
    "Stats",
    "Sweep",
    "answer",
    "available",
    "rows_of",
    "verify",
]

_OK, _MATCH, _STALE = 0, 1, -1

#: Rows per native pull when iterating. Large enough that per-call overhead
#: disappears against decode cost, small enough to stay cache-resident.
DEFAULT_BATCH: Final = 256

_SOURCES: Final = ("live", "atlas", "shelf")


@dataclass(frozen=True, slots=True)
class Stats:
    """What the answer as a whole cost and covered — the facts no row can carry.

    `foreign` counts query fingerprints the corpus has **never** seen, which is
    the difference between *"your text isn't in this repository"* and *"nothing
    scored"*; ranking alone cannot tell those apart. `omitted` is what a budget
    trimmed, so a truncated answer says so instead of looking complete.
    `source` names the tier that answered (`live` · `atlas` · `shelf` · `cold`).
    """

    source: str = "cold"
    elapsed_ms: float = 0.0
    files_considered: int = 0
    refreshed: int = 0
    foreign: int = 0
    omitted: int = 0
    rows: int = 0

    @property
    def warm(self) -> bool:
        """Whether a persisted artifact served this answer. Never changes the rows — warm and live answers are identical."""
        return self.source in {"atlas", "shelf"}

    @property
    def truncated(self) -> bool:
        """Whether a budget trimmed rows out of this answer."""
        return self.omitted > 0


class Pull(Protocol):
    """A source of raw rows, pulled in bounded chunks."""

    def __call__(self, cap: int) -> list[object]:
        """Up to `cap` more rows; empty means the stream ended."""
        ...


class Rows:
    """An analytic answer: rows decoded on demand, plus the stats behind them.

    Iterate it for records one at a time, `batches(n)` to trade call overhead for
    a wider window, or `drain()` for everything at once. Every record is an owned
    Python object, so nothing here dangles once the cursor closes — which happens
    automatically at the end of the stream, on `__exit__`, and on collection.
    """

    __slots__ = ("_closer", "_final", "_pull", "_stats", "closed")

    def __init__(
        self,
        pull: Pull,
        stats: Callable[[], Stats],
        *,
        close: Callable[[], None] | None = None,
    ) -> None:
        """Wrap a row source. `stats` is read lazily — the counters are only final once the stream is drained."""
        self._pull = pull
        self._stats = stats
        self._closer = close
        self._final: Stats | None = None
        self.closed = False

    def __iter__(self) -> Iterator[object]:
        """Decode rows lazily, one native pull per record."""
        return chain.from_iterable(self.batches(1))

    def batches(self, size: int = DEFAULT_BATCH) -> Iterator[list[object]]:
        """Yield lists of up to `size` decoded records, one native pull each."""
        if size < 1:
            msg = "batch size must be >= 1"
            raise ValueError(msg)
        try:
            while raw := self._pull(size):
                # A tier may hand back rows to decode or records it already typed
                # (the `--rank` scrape has no wire objects to walk), and the
                # caller must not be able to tell which answered.
                yield [record(r) if isinstance(r, Row) else r for r in raw]
        finally:
            self.close()

    def drain(self) -> tuple[object, ...]:
        """Every record, then close. The shape a verb with a bounded `top` wants."""
        return tuple(chain.from_iterable(self.batches()))

    def one(self) -> object | None:
        """The single record of a one-row verb (`quote`, `blast`), or None when the answer is empty."""
        return next(iter(islice(iter(self), 1)), None)

    @property
    def stats(self) -> Stats:
        """The answer-level stats. Snapshotted at close, because the counters live in the arena the cursor frees."""
        return self._final if self._final is not None else self._stats()

    def close(self) -> None:
        """Release the native arena (idempotent). Decoded records and `stats` stay valid."""
        if self.closed:
            return
        self._final = self._stats()
        self.closed = True
        if self._closer is not None:
            self._closer()

    def __enter__(self) -> Rows:
        """Return self for `with rows:`."""
        return self

    def __exit__(self, *_exc: object) -> None:
        """Close on context exit."""
        self.close()

    def __del__(self) -> None:
        """Best-effort release if a caller abandoned the cursor mid-stream."""
        with suppress(Exception):  # teardown must never raise
            self.close()


def rows_of(rows: Iterable[object], stats: Stats) -> Rows:
    """An answer already materialized — how a lower tier presents itself as the same thing. Takes raw rows to decode, or records a tier typed itself."""
    pending = iter(rows)

    def pull(cap: int) -> list[object]:
        return list(islice(pending, cap))

    return Rows(pull, lambda: stats)


def answer(
    verb: str,
    params: Params,
    *,
    cold: Callable[[], Rows],
    roots: Sequence[str] = (),
    cwd: str | os.PathLike[str] | None = None,
    native: bool = True,
) -> Rows:
    """Answer `verb` through the best available transport.

    In-process when the library exports the plane, its schema table matches, and
    the query's roots are this process's; otherwise through `cold`, which must
    produce the same rows. A declinature is never visible to the caller — that is
    the whole point of the ladder.

    `native=False` is a verb saying *this particular request is outside what the
    params struct can say* (a CLI-only knob), so the ladder starts one rung down
    rather than dispatching a request that would quietly mean something else.
    """
    family = table.VERBS[verb][1]
    if params.family != family:
        msg = f"{verb} takes the {family} params family, got {params.family}"
        raise ValueError(msg)
    return (native and _in_process(verb, params, roots, cwd)) or cold()


def available() -> bool:
    """Whether the in-process analytic plane can answer at all (library present, symbols exported, digest agrees)."""
    return _plane() is not None


_PLANE_SYMBOLS: Final = (
    "irregex_engine_open",
    "irregex_analytic_run",
    "irregex_rows_next",
    "irregex_rows_next_batch",
    "irregex_rows_stats",
    "irregex_rows_close",
    "irregex_schema_digest",
)

_plane_cache: tuple[FFI, object] | None = None
_plane_probed = False
_plane_lock = threading.Lock()


def _plane() -> tuple[FFI, object] | None:
    """The loaded library iff it exports the analytic plane and its schemas match ours. Raises on drift; None when the plane simply isn't there."""
    global _plane_cache, _plane_probed
    if _plane_probed:
        return _plane_cache
    with _plane_lock:
        if _plane_probed:
            return _plane_cache
        loaded = native.load()
        if loaded is None or not native.exports(*_PLANE_SYMBOLS):
            _plane_cache, _plane_probed = None, True
            return None
        verify(*loaded)
        _plane_cache, _plane_probed = loaded, True
        return loaded


def verify(ffi: FFI, lib: object) -> None:
    """Fail loudly when the library's row-schema table is not the one this decoder was generated from.

    A digest mismatch means every subsequent row would decode into a plausible
    lie — a distance read out of a grade's slot — so it can never be a warning.
    `irregex_schema_get` lets the failure *name* the schemas that moved instead
    of only reporting that something did.
    """
    theirs = ffi.string(lib.irregex_schema_digest()).decode()
    if theirs == table.DIGEST:
        return
    msg = (
        f"row-schema drift: library digest {theirs}, this binding was generated "
        f"from {table.DIGEST}. Differing schemas: {', '.join(_drifted(ffi, lib)) or 'unknown'}. "
        f"Rebuild libirregex and rerun `make gen`."
    )
    raise SchemaDriftError(msg)


def _drifted(ffi: FFI, lib: object) -> list[str]:
    """Names of the schemas whose declared shape differs from this table's, plus any this table has and the library does not."""
    # Interrogate the library that was handed in, not the process-wide handle: the
    # digest check must be able to report on any library, including one loaded for
    # comparison.
    if not all(hasattr(lib, sym) for sym in ("irregex_schema_count", "irregex_schema_get")):
        return []
    count = lib.irregex_schema_count()
    out = ffi.new("irregex_schema *")
    names: list[str] = []
    for sid in range(1, count + 1):
        out.struct_size = ffi.sizeof("irregex_schema")
        if lib.irregex_schema_get(sid, out) != _OK:
            names.append(f"{table.schema_name(sid)} (unreadable)")
            continue
        name = ffi.string(out.name).decode()
        theirs = [
            (ffi.string(f.name).decode(), f.tag, f.nested, bool(f.optional))
            for f in (out.fields[i] for i in range(out.nfields))
        ]
        ours = table.SCHEMAS.get(sid)
        if ours is None or ours[0] != name or [tuple(f) for f in ours[1]] != theirs:
            names.append(name)
    names += [table.schema_name(sid) for sid in table.SCHEMAS if sid > count]
    return names


# One analytic engine per (process CWD, roots). The corpus and its warm
# artifacts load lazily on first analytic use, so a host that only searches
# never pays for them — and a `chdir` can never reuse the wrong corpus.
_MAX_ENGINES: Final = 4
_engines: dict[tuple[str, tuple[str, ...]], object] = {}
_engines_lock = threading.Lock()


def _engine(ffi: FFI, lib: object, roots: tuple[str, ...]) -> object | None:
    key = (str(Path.cwd()), roots)
    with _engines_lock:
        if (cached := _engines.get(key)) is not None:
            return cached
        out = ffi.new("irregex_engine **")
        bufs = [ffi.new("char[]", os.fsencode(r)) for r in roots]
        array = ffi.new("char *[]", bufs) if bufs else ffi.NULL
        if lib.irregex_engine_open(array, len(bufs), out) != _OK:
            return None
        if len(_engines) >= _MAX_ENGINES:
            lib.irregex_engine_close(_engines.pop(next(iter(_engines))))
        _engines[key] = out[0]
        return out[0]


def _in_process(
    verb: str,
    params: Params,
    roots: Sequence[str],
    cwd: str | os.PathLike[str] | None,
) -> Rows | None:
    """Run `verb` through `irregex_analytic_run`, or None to answer through the tier below."""
    plane = _plane()
    if plane is None or not _is_process_cwd(cwd):
        return None
    ffi, lib = plane
    engine = _engine(ffi, lib, tuple(os.fspath(r) for r in roots))
    if engine is None:
        return None
    # `_keep` holds the buffers the struct's pointers borrow; the engine copies
    # what it needs before returning, so this local's scope is exactly the window
    # they must survive.
    struct, _keep = params.lower(ffi)
    out = ffi.new("irregex_rows **")
    status = lib.irregex_analytic_run(engine, table.VERBS[verb][0], struct, ffi.NULL, out)
    if status == _STALE:
        return None  # the kernel declined this query — identical answer, one tier down
    if status != _OK:
        msg = f"irregex_analytic_run({verb}) failed closed with status {status}"
        raise GistError(msg)
    return _cursor(ffi, lib, out[0])


def _is_process_cwd(cwd: str | os.PathLike[str] | None) -> bool:
    """Whether `cwd` is this process's — corpus-relative paths must render identically to the cold tier's."""
    return cwd is None or Path(cwd).resolve() == Path.cwd().resolve()


def _cursor(ffi: FFI, lib: object, handle: object) -> Rows:
    """Wrap a native `irregex_rows` as decoded `Rows`."""
    live = [handle]

    def pull(cap: int) -> list[Row]:
        if not live:
            return []
        buf = ffi.new("irregex_row[]", cap)
        written = ffi.new("size_t *")
        status = lib.irregex_rows_next_batch(live[0], buf, cap, written)
        if status == _MATCH:
            return [_row(ffi, buf[i]) for i in range(written[0])]
        if status == _OK:
            return []
        msg = f"analytic row pull failed with status {status}"
        raise GistError(msg)

    def stats() -> Stats:
        if not live:
            return Stats(source="live")  # unreachable: `Rows` snapshots before closing
        out = ffi.new("irregex_stats *")
        out.struct_size = ffi.sizeof("irregex_stats")
        if lib.irregex_rows_stats(live[0], out) != _OK:
            return Stats(source="live")
        source = _SOURCES[out.source] if out.source < len(_SOURCES) else "live"
        return Stats(
            source=source,
            elapsed_ms=out.elapsed_ns / 1e6,
            files_considered=out.files_considered,
            refreshed=out.refreshed,
            foreign=out.foreign,
            omitted=out.omitted,
            rows=out.rows,
        )

    def close() -> None:
        if live:
            lib.irregex_rows_close(live.pop())

    return Rows(pull, stats, close=close)


def _row(ffi: FFI, raw: object) -> Row:
    """One `irregex_row` into the transport-neutral IR, copying every borrowed byte."""
    values = [_value(ffi, raw.values[i]) for i in range(raw.nvalues)]
    return Row.masked(raw.schema_id, values, raw.present)


def _value(ffi: FFI, value: object) -> object:
    """One `irregex_value`, read by its tag. Texts and nested rows are copied out of the arena on the way."""
    match table.Tag(value.tag):
        case table.Tag.TEXT:
            return _utf8(ffi, value.ptr, value.len)
        case table.Tag.I64 | table.Tag.BOOL | table.Tag.ENUM:
            return value.integer
        case table.Tag.F64:
            return value.real
        case table.Tag.TEXTS:
            texts = ffi.cast("irregex_text *", value.ptr)
            return [_utf8(ffi, texts[i].ptr, texts[i].len) for i in range(value.len)]
        case table.Tag.ROWS:
            nested = ffi.cast("irregex_row *", value.ptr)
            return [_row(ffi, nested[i]) for i in range(value.len)]


def _utf8(ffi: FFI, ptr: object, length: int) -> str:
    """Borrowed engine bytes as an owned str, surrogate-escaping anything invalid so a non-UTF-8 path never raises."""
    if not ptr or length == 0:
        return ""
    return bytes(ffi.buffer(ffi.cast("char *", ptr), length)).decode(
        "utf-8", errors="surrogateescape"
    )
