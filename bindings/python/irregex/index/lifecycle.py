"""Typed lifecycle and capability introspection — what the accelerators know.

Every verb in this package answers correctly with no persisted artifact at all;
warmth is an optimization tier, never a dependency. This module is how a program
*sees* that tier instead of guessing at it: the trigram index behind exact
search (`status`/`index`), and the kinship atlas, fragment index, and codex
shelf behind the compression verbs (`atlas_status`/`atlas_index`).

Two reasons a caller reaches here rather than shelling `gist status`. A long-
running process can decide *once* whether to pay for a build before a batch of
queries, instead of eating a cold walk per call. And a verb that needs an
artifact rather than merely preferring one — `retrieval.quote` and
`compose.provenance` read the shelf — can be preflighted rather than failed.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
import json
import subprocess
import time
from typing import TYPE_CHECKING, NotRequired, TypedDict

from ..runtime.errors import SearchFailedError


if TYPE_CHECKING:
    import os

    from ..runtime.shell import Output


class IndexState(StrEnum):
    """Availability state in the versioned status schema."""

    READY = "ready"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True, slots=True)
class IndexStatus:
    """Current persisted-index state reported by ``gist status``."""

    schema_version: int
    state: IndexState
    path: str | None
    paths_file: str | None
    files: int = 0
    trigrams: int = 0
    postings: int = 0
    index_bytes: int = 0
    paths_bytes: int = 0
    anchor_unix_ns: int | None = None
    age_seconds: float | None = None
    roots: tuple[str, ...] = ()
    bound_here: bool = True
    built_over: str | None = None

    @property
    def ready(self) -> bool:
        """Whether a complete persisted pair is available."""
        return self.state is IndexState.READY

    @property
    def freshness_anchor(self) -> bool:
        """Whether changed files can be folded in against a build anchor."""
        return self.anchor_unix_ns is not None and self.bound_here


@dataclass(frozen=True, slots=True)
class FlagCapability:
    """One CLI flag row from the binary's generated schema."""

    spellings: tuple[str, ...]
    note: str | None = None


@dataclass(frozen=True, slots=True)
class Capabilities:
    """Machine-readable feature surface emitted by ``gist --schema``."""

    tool: str
    version: str
    verbs: tuple[str, ...]
    buckets: tuple[tuple[str, tuple[FlagCapability, ...]], ...]
    native_additions: tuple[str, ...]

    def compatibility(self, spelling: str) -> str | None:
        """Compatibility bucket for ``spelling``, or ``None`` when unknown."""
        return next(
            (
                bucket
                for bucket, flags in self.buckets
                if any(spelling in flag.spellings for flag in flags)
            ),
            None,
        )

    def supports(self, spelling: str) -> bool:
        """Whether the binary recognizes ``spelling`` as a search capability."""
        return self.compatibility(spelling) not in (None, "unsupported-fail-loud")


class _IndexPayload(TypedDict):
    path: str
    paths_file: str
    files_indexed: int
    distinct_trigrams: int
    postings: int
    index_bytes: int
    paths_bytes: int


class _FreshnessPayload(TypedDict):
    anchor_unix_ns: int | None
    age_seconds: float | None


class _StatusPayload(TypedDict):
    schema_version: int
    state: str
    index: _IndexPayload | None
    freshness: _FreshnessPayload
    roots: list[str]
    # Added within schema_version 1 (additive); absent from an older binary.
    bound_here: NotRequired[bool]
    built_over: NotRequired[str | None]


class _FlagPayload(TypedDict):
    spellings: list[str]
    note: NotRequired[str]


class _NativePayload(TypedDict):
    native: str


class _CompatibilityPayload(TypedDict):
    buckets: dict[str, list[_FlagPayload]]


class _RipgrepPayload(TypedDict):
    ripgrep_compatibility: _CompatibilityPayload
    native_additions: list[_NativePayload]


class _SchemaPayload(TypedDict):
    tool: str
    version: str
    verbs: dict[str, object]
    search: _RipgrepPayload


def _command(
    argv: list[str],
    *,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    from ..runtime.shell import binary

    try:
        proc = subprocess.run(  # noqa: S603 — fixed executable and argv list
            [binary(), *argv],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired as exc:
        msg = f"gist {' '.join(argv)} timed out after {timeout}s"
        raise SearchFailedError(msg) from exc
    if proc.returncode != 0:
        raise SearchFailedError(proc.stderr.strip() or f"gist {' '.join(argv)} failed")
    return proc


def parse_status(report: str) -> IndexStatus:
    """Decode the binary's versioned status JSON without scraping prose."""
    payload: _StatusPayload = json.loads(report)
    index = payload["index"]
    freshness = payload["freshness"]
    return IndexStatus(
        schema_version=payload["schema_version"],
        state=IndexState(payload["state"]),
        path=index["path"] if index else None,
        paths_file=index["paths_file"] if index else None,
        files=index["files_indexed"] if index else 0,
        trigrams=index["distinct_trigrams"] if index else 0,
        postings=index["postings"] if index else 0,
        index_bytes=index["index_bytes"] if index else 0,
        paths_bytes=index["paths_bytes"] if index else 0,
        anchor_unix_ns=freshness["anchor_unix_ns"],
        age_seconds=freshness["age_seconds"],
        roots=tuple(payload["roots"]),
        # An artifact directory built over ANOTHER tree reports real counts and
        # a real anchor that describe none of the files here, so every
        # accelerator declines and the answer comes live. Default True: an older
        # binary that never published a binding has no other tree to name.
        bound_here=payload.get("bound_here", True),
        built_over=payload.get("built_over"),
    )


def status(
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 30.0,
) -> IndexStatus:
    """Inspect the persisted index without mutating it."""
    return parse_status(_command(["status", "--json"], cwd=cwd, timeout=timeout).stdout)


def index(
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 600.0,
) -> IndexStatus:
    """Build and atomically publish the index, then return its observed state."""
    _command(["index"], cwd=cwd, timeout=timeout)
    result = status(cwd=cwd, timeout=timeout)
    if not result.ready:
        msg = "gist index completed without a readable index"
        raise SearchFailedError(msg)
    return result


def parse_capabilities(payload: str) -> Capabilities:
    """Decode the generated JSON capability manifest."""
    raw: _SchemaPayload = json.loads(payload)
    compat = raw["search"]["ripgrep_compatibility"]["buckets"]
    buckets = tuple(
        (
            name,
            tuple(FlagCapability(tuple(row["spellings"]), row.get("note")) for row in rows),
        )
        for name, rows in compat.items()
    )
    additions = tuple(row["native"] for row in raw["search"]["native_additions"])
    return Capabilities(
        tool=raw["tool"],
        version=raw["version"],
        verbs=tuple(raw["verbs"]),
        buckets=buckets,
        native_additions=additions,
    )


def capabilities(
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 30.0,
) -> Capabilities:
    """Return the binary's parser-derived capability schema."""
    return parse_capabilities(_command(["--schema"], cwd=cwd, timeout=timeout).stdout)


# ── the compression tier: kinship atlas, fragment index, codex shelf ─────────


@dataclass(frozen=True, slots=True)
class Artifact:
    """One persisted compression artifact. `stale_files` is not damage — a warm answer folds changed files back in from live bytes and stays byte-identical to a cold rebuild, so staleness costs time, never correctness."""

    state: IndexState
    files: int = 0
    fragments: int = 0
    bytes: int = 0
    stale_files: int = 0
    built_unix_ns: int | None = None

    @property
    def ready(self) -> bool:
        """Whether this artifact can accelerate a query at all."""
        return self.state is IndexState.READY

    @property
    def staleness(self) -> float | None:
        """Share of the snapshotted corpus that changed since the anchor, in [0, 1] — the work a warm query will redo live. `None` when this artifact publishes no comparable file population (the fragment index counts fragments, the shelf counts bytes), where `stale_files` is still the raw truth."""
        return self.stale_files / self.files if self.files else None

    @property
    def age_seconds(self) -> float | None:
        """Wall-clock seconds since this artifact was built, or `None` when it was never built."""
        if self.built_unix_ns is None:
            return None
        return max(0.0, time.time() - self.built_unix_ns / 1e9)


@dataclass(frozen=True, slots=True)
class AtlasStatus:
    """What relate's three artifacts can accelerate right now.

    They are independent because the verbs are: `atlas` carries the kinship
    sketches and structure silhouettes (`similar`/`dups`/`clusters`/`echoes` and
    the composed `family`), `fragments` carries the sub-file fragment index
    (`concepts`/`fragments`), and `shelf` carries the corpus codex that
    quotation reads.
    """

    schema_version: int
    atlas: Artifact
    fragments: Artifact
    shelf: Artifact

    @property
    def ready(self) -> bool:
        """Whether kinship queries can run warm — the tier most verbs use."""
        return self.atlas.ready

    @property
    def can_quote(self) -> bool:
        """Whether `retrieval.quote` and `compose.provenance` have their shelf. Unlike every other artifact these two *require* it, so preflight this rather than catching the failure."""
        return self.shelf.ready


def parse_atlas_status(report: str) -> AtlasStatus:
    """Decode relate's versioned status JSON."""
    payload = json.loads(report)
    return AtlasStatus(
        schema_version=int(payload.get("schema_version", 1)),
        atlas=_artifact(payload.get("atlas")),
        fragments=_artifact(payload.get("frag")),
        shelf=_artifact(payload.get("shelf")),
    )


def _artifact(section: object) -> Artifact:
    """Decode one artifact section, defaulting an absent one to `unavailable`."""
    if not isinstance(section, dict):
        return Artifact(IndexState.UNAVAILABLE)
    return Artifact(
        state=IndexState(section.get("state", "unavailable")),
        files=_count(section, "files"),
        fragments=_count(section, "fragments"),
        bytes=_count(section, "bytes"),
        stale_files=_count(section, "stale_files"),
        built_unix_ns=_count(section, "built_unix_ns") or None,
    )


def _count(section: dict[str, object], key: str) -> int:
    """One count field — absent or JSON `null` reads as zero (the shelf publishes no file counts)."""
    value = section.get(key)
    return int(value) if isinstance(value, int | float) else 0


def atlas_status(
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 60.0,
) -> AtlasStatus:
    """Inspect relate's persisted artifacts without building anything.

    Read-only and cheap. `relate status` exits 1 when the atlas is missing — that
    is a report, not a failure, so this returns an `unavailable` artifact rather
    than raising.
    """
    out = _relate(["status", "--json"], cwd=cwd, timeout=timeout, ok_codes=(0, 1))
    return parse_atlas_status(out.stdout)


def atlas_index(
    *,
    shelf: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 900.0,
) -> AtlasStatus:
    """Build and publish relate's kinship atlas, then report what is ready.

    Warm kinship costs seconds to build and returns roughly an order of magnitude
    on every later query, so a process about to ask many kinship questions should
    pay this once up front. `shelf=True` additionally builds the codex shelf,
    which is the *only* way `quote`/`provenance` become available — it is much
    larger, so it stays opt-in.

    The corpus is not a parameter: an artifact records the roots it was built
    over, so the build takes them from the tree at `cwd` (or `$GIST_ROOTS`) and
    the *query* verbs narrow within it. Point `$GIST_DIR` elsewhere to keep an
    artifact home of your own.
    """
    _relate(["index", *(["--shelf"] if shelf else [])], cwd=cwd, timeout=timeout)
    return atlas_status(cwd=cwd, timeout=60.0)


def _relate(
    argv: list[str],
    *,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
    ok_codes: tuple[int, ...] = (0,),
) -> Output:
    """Invoke the `relate` binary. Imported at call time because `engine` imports this module for `IndexStatus` — lifecycle types are the lower layer, and the transport is the upper one."""
    from ..runtime.shell import run_verb

    return run_verb("relate", argv, cwd=cwd, timeout=timeout, ok_codes=ok_codes)
