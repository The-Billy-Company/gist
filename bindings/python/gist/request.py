"""The unified `SearchRequest` → `Match` contract (ADR-352).

One request shape for every face — the importable package, the CLI, and Billy's
agent code-search tool. It carries only match-finding *intent*; presentation,
ranking, stats, replace, and stdin stay CLI-only surfaces. `to_argv()` lowers a
request into the exact rg-parity argv the certified `gist` binary accepts, so
the package never reimplements search — it drives the same engine.

The field set mirrors `contract/search_api.toml`'s `[request_options]`; the
package's parity test asserts the two never drift.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class MatchKind(StrEnum):
    """What a `Match` line is."""

    MATCH = "match"  # a line with ≥1 submatch
    CONTEXT = "context"  # an -A/-B/-C neighborhood line (no submatches)


@dataclass(frozen=True, slots=True)
class Submatch:
    """One matched span within a line: `text` and its byte offsets `[start,end)`."""

    text: str
    start: int
    end: int


@dataclass(frozen=True, slots=True)
class Match:
    """One structured result line, as the engine's `--json` stream reports it."""

    path: str
    line_number: int
    text: str
    kind: MatchKind = MatchKind.MATCH
    submatches: tuple[Submatch, ...] = ()

    @property
    def column(self) -> int:
        """1-based column of the first submatch (0 when a context line)."""
        return self.submatches[0].start + 1 if self.submatches else 0


class RankKind(StrEnum):
    """How the engine's `--rank` view classified a file — the property `grep`
    can't express (`src/rank/signals.zig`)."""

    DEF = "def"  # a match on this file's line defines the symbol
    USE = "use"  # only call sites / references
    GEN = "gen"  # generated file (codegen), demoted by the authored boost


@dataclass(frozen=True, slots=True)
class Ranked:
    """One row of the engine's `--rank` view: a file ranked definition-first by
    the RRF kernel, tagged with the engine's own class. This is gist's native
    ranked shape (no rg equivalent) — a *presentation* result, deliberately not
    a wire-contract match kind, so it lives beside `Match` but outside the
    `SearchRequest` contract."""

    path: str
    line_number: int  # the best line to surface (the definition, if the file has one)
    kind: RankKind
    count: int  # matching lines in this file
    snippet: str  # the surfaced line, trimmed by the engine

    @property
    def generated(self) -> bool:
        """True for codegen the engine demotes — never the agent's edit target."""
        return self.kind is RankKind.GEN


@dataclass(frozen=True, slots=True)
class SearchRequest:
    """A search expressed once, runnable on any face. Only `pattern` is
    required; `paths` empty means the engine's default roots (or CWD for the
    live walk). Every other field maps to a single rg-parity flag."""

    pattern: str
    paths: tuple[str, ...] = ()
    fixed: bool = False
    ignore_case: bool = False
    smart_case: bool = False
    word: bool = False
    invert: bool = False
    globs: tuple[str, ...] = ()
    iglobs: tuple[str, ...] = ()
    types: tuple[str, ...] = ()
    not_types: tuple[str, ...] = ()
    before: int = 0
    after: int = 0
    context: int = 0
    max_count: int = 0
    max_depth: int = 0
    hidden: bool = False
    no_ignore: bool = False
    follow: bool = False
    no_index: bool = False
    # Extra raw argv flags an advanced caller needs before the package grows a
    # first-class option for them — kept last so they never shadow the contract.
    extra_flags: tuple[str, ...] = field(default_factory=tuple)

    def to_argv(self) -> list[str]:
        """Lower this request into the flag argv (without the pattern/paths,
        which the engine adapter positions). Order is deterministic."""
        argv: list[str] = []
        if self.fixed:
            argv.append("-F")
        if self.ignore_case:
            argv.append("-i")
        if self.smart_case:
            argv.append("-S")
        if self.word:
            argv.append("-w")
        if self.invert:
            argv.append("-v")
        if self.hidden:
            argv.append("--hidden")
        if self.no_ignore:
            argv.append("--no-ignore")
        if self.follow:
            argv.append("-L")
        if self.no_index:
            argv.append("--no-index")
        for g in self.globs:
            argv += ["-g", g]
        for g in self.iglobs:
            argv += ["--iglob", g]
        for t in self.types:
            argv += ["-t", t]
        for t in self.not_types:
            argv += ["-T", t]
        # -A/-B take precedence over -C in the engine; emit the explicit sides
        # when set, else the symmetric context.
        if self.before:
            argv += ["-B", str(self.before)]
        if self.after:
            argv += ["-A", str(self.after)]
        if self.context and not (self.before or self.after):
            argv += ["-C", str(self.context)]
        if self.max_count:
            argv += ["-m", str(self.max_count)]
        if self.max_depth:
            argv += ["--max-depth", str(self.max_depth)]
        argv += list(self.extra_flags)
        return argv
