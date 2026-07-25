"""The blast radius of a symbol — what moves if I change this?

The question you ask *before* an edit, and the one no single engine answers.
Exact search finds the call sites but misses the file that will need the same
change because it is a fork of this one; compression finds the fork but cannot
tell a reference from a coincidence. `blast` runs both and keeps their evidence
apart (ADR-367).

Computed from the tree's **current bytes** — there is no precomputed graph to go
stale, so a file counts the moment it is saved, including a coworker's edit that
landed thirty seconds ago. Six evidence classes come back:

  * `definitions` — where the symbol is declared.
  * `dependents` — functions that reference it, def/use classified.
  * `dependencies` — what its own body leans on, resolved to their definitions.
  * `twins` — compression kin of the seed's *file*: co-edit risk, not a reference.
  * `ripple` — second-hop callers, reached through a direct dependent.
  * `comments` — prose that names it, where stale docs and invariants hide.

The first three and the last are **exact**: the identifier was found. `twins` and
`ripple` are **statistical**. They never merge into one relevance number, here or
in the engine — a fused score would let a coincidence outrank a call site.

The CLI prints these as six panes for a human to skim. A caller usually wants the
conclusion underneath them, so `Blast.paths` is the edit set in load-bearing
order and `Blast.exact_paths` is the subset that provably names the symbol.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from . import engine
from .corpus import CORPUS_TIMEOUT, Scope, merge_paths, run


if TYPE_CHECKING:
    import os


@dataclass(frozen=True, slots=True)
class Site:
    """One definition site of the seed symbol."""

    path: str
    line: int

    def __str__(self) -> str:
        """`path:line`."""
        return f"{self.path}:{self.line}"


@dataclass(frozen=True, slots=True)
class Reference:
    """One function that references the seed. `enclosing` names it; `defines` is the engine's def/use classification — True for the declaration itself."""

    path: str
    line: int
    enclosing: str
    defines: bool

    def __str__(self) -> str:
        """`path:line (enclosing)`."""
        return f"{self.path}:{self.line} ({self.enclosing})"


@dataclass(frozen=True, slots=True)
class Dependency:
    """One identifier the seed's body leans on, resolved to its own definition site — the seed's own parameters and locals excluded."""

    symbol: str
    path: str
    line: int


@dataclass(frozen=True, slots=True)
class Twin:
    """A compression neighbor of the seed's *file* — co-edit risk, not a reference. Statistical evidence: nothing here provably mentions the symbol."""

    path: str
    distance: float


@dataclass(frozen=True, slots=True)
class Ripple:
    """A second-hop caller: it calls `via`, which references the seed."""

    path: str
    via: str
    hops: int = 2


@dataclass(frozen=True, slots=True)
class Mention:
    """A comment that names the seed — the stale-doc, TODO, and invariant surface a reference search misses."""

    path: str
    line: int
    text: str


@dataclass(frozen=True, slots=True)
class Stats:
    """Totals the engine measured, independent of how many rows it surfaced. `omitted` counts rows a `budget` trimmed; `short_name` warns that the symbol is short enough for incidental collisions."""

    files: int = 0
    with_symbol: int = 0
    dependents: int = 0
    dependencies: int = 0
    twins: int = 0
    ripple: int = 0
    comments: int = 0
    omitted: int = 0
    short_name: bool = False


@dataclass(frozen=True, slots=True)
class Blast:
    """The blast radius of one symbol, computed from the tree's current bytes."""

    symbol: str
    kind: str
    definitions: tuple[Site, ...]
    dependents: tuple[Reference, ...]
    dependencies: tuple[Dependency, ...]
    twins: tuple[Twin, ...]
    ripple: tuple[Ripple, ...]
    comments: tuple[Mention, ...]
    stats: Stats
    notes: tuple[str, ...] = ()

    @property
    def paths(self) -> tuple[str, ...]:
        """Every distinct file in the radius, most load-bearing first: definitions, then dependents, dependencies, comments, twins, ripple. The edit set — what a refactor of this symbol has to open."""
        return merge_paths(
            (s.path for s in self.definitions),
            (r.path for r in self.dependents),
            (d.path for d in self.dependencies),
            (m.path for m in self.comments),
            (t.path for t in self.twins),
            (r.path for r in self.ripple),
        )

    @property
    def exact_paths(self) -> tuple[str, ...]:
        """`paths` restricted to exact evidence — files that provably name the symbol, with the statistical tail (twins, ripple) dropped."""
        return merge_paths(
            (s.path for s in self.definitions),
            (r.path for r in self.dependents),
            (d.path for d in self.dependencies),
            (m.path for m in self.comments),
        )

    @property
    def truncated(self) -> bool:
        """Whether a `budget` trimmed rows out of this report."""
        return self.stats.omitted > 0

    @property
    def defined(self) -> bool:
        """Whether the engine located any definition site at all. False means the symbol is referenced-only (or misspelled) — read `notes`."""
        return bool(self.definitions)


def blast(
    symbol: str,
    *,
    budget: int | None = None,
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Blast:
    """What moves if `symbol` changes — one bounded report from the tree's current bytes.

    Corpus-wide by default (a blast radius that stopped at a directory would
    lie); narrow it with `roots` when you know the change is contained. `budget`
    is a soft token cap that trims the lowest-priority tail (ripple, twins,
    comments first) and records the loss in `stats.omitted` — leave it unset for
    a complete answer, which is what a program usually wants.
    """
    argv = [symbol, *(["--budget", str(budget)] if budget is not None else [])]
    rows, _ = run("irregex", "blast", argv, roots, cwd=cwd, timeout=timeout)
    return _decode(rows[0] if rows else {})


def _decode(report: dict[str, object]) -> Blast:
    """Decode the single-object blast report."""
    seed = _section(report, "seed")
    direct = _section(report, "direct")
    tangential = _section(report, "tangential")
    stats = _section(report, "stats")
    return Blast(
        symbol=engine.as_str(seed, "symbol"),
        kind=engine.as_str(seed, "kind"),
        definitions=tuple(
            Site(engine.as_str(r, "path"), engine.as_int(r, "line"))
            for r in engine.as_rows(seed, "def")
        ),
        dependents=tuple(
            Reference(
                path=engine.as_str(r, "path"),
                line=engine.as_int(r, "line"),
                enclosing=engine.as_str(r, "in"),
                defines=engine.as_str(r, "use") == "def",
            )
            for r in engine.as_rows(direct, "dependents")
        ),
        dependencies=tuple(
            Dependency(
                symbol=engine.as_str(r, "symbol"),
                path=engine.as_str(r, "path"),
                line=engine.as_int(r, "line"),
            )
            for r in engine.as_rows(direct, "dependencies")
        ),
        twins=tuple(
            Twin(engine.as_str(r, "path"), engine.as_float(r, "distance", 1.0) or 0.0)
            for r in engine.as_rows(tangential, "twins")
        ),
        ripple=tuple(
            Ripple(
                path=engine.as_str(r, "path"),
                via=engine.as_str(r, "via"),
                hops=engine.as_int(r, "hops", 2),
            )
            for r in engine.as_rows(tangential, "ripple")
        ),
        comments=tuple(
            Mention(
                path=engine.as_str(r, "path"),
                line=engine.as_int(r, "line"),
                text=engine.as_str(r, "text"),
            )
            for r in engine.as_rows(report, "comments")
        ),
        stats=Stats(
            files=engine.as_int(stats, "files"),
            with_symbol=engine.as_int(stats, "with_symbol"),
            dependents=engine.as_int(stats, "dependents"),
            dependencies=engine.as_int(stats, "dependencies"),
            twins=engine.as_int(stats, "twins"),
            ripple=engine.as_int(stats, "ripple"),
            comments=engine.as_int(stats, "comments"),
            omitted=engine.as_int(stats, "omitted"),
            short_name=bool(stats.get("short_name")),
        ),
        notes=engine.as_strs(report, "notes"),
    )


def _section(report: dict[str, object], key: str) -> dict[str, object]:
    """One nested object, defaulting to empty so a partial report still decodes."""
    value = report.get(key)
    return value if isinstance(value, dict) else {}
