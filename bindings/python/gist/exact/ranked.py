"""The definition-first view — the one exact verb whose answer is analytic rows.

`--rank` asks a question `grep` cannot express: *which file DEFINES this?* The
engine fuses trigram, symbol, and authored-vs-generated signals and hands back a
short ranked list with each file's class attached.

It is also the verb the binding used to reach by **scraping rendered stdout**,
because the human view has no `--json`. The analytic plane answers it as typed
rows instead (`op` 17, schema `ranked`), and the scrape survives only as the
bottom rung — same rows, one process later.

Ranking needs a persisted index: with none there is nothing to rank, and the
answer is legitimately empty rather than an error.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from irgx.runtime import analytic, shell

if TYPE_CHECKING:
    import os

    from irgx.request import Ranked, SearchRequest


def rank(
    request: SearchRequest,
    *,
    limit: int = 20,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = shell.DEFAULT_TIMEOUT,
) -> list[Ranked]:
    """The top-`limit` files for `request`'s pattern, definition first (`limit <= 0` takes the engine's own default).

    The class on each row (`def` · `use` · `gen`) is the engine's, never
    reclassified here — a demoted generated file is demoted because the ranking
    kernel said so.
    """
    return list(
        analytic.answer(
            "rank",
            analytic.Rank(
                pattern=request.pattern,
                top=max(limit, 0),
                fixed=request.fixed,
                ignore_case=request.ignore_case,
            ),
            roots=request.paths,
            cwd=cwd,
            cold=lambda: analytic.rows_of(
                shell.rank_rows(request, limit=limit, cwd=cwd, timeout=timeout),
                analytic.Stats(source="cold"),
            ),
        ).drain()
    )
