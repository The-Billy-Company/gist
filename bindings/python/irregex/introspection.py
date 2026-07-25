"""Typed lifecycle and capability introspection for the GIST binary."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
import json
import subprocess
from typing import TYPE_CHECKING, NotRequired, TypedDict

from .errors import SearchFailedError


if TYPE_CHECKING:
    import os


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
    from .engine import binary

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
