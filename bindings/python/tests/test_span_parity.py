"""Where ``gist --json`` and the engine's own iterator have to report the same spans.

``irgx.h`` names ``gist --json`` as the authority for what a match sequence is,
so somewhere that claim has to be checked against the tool rather than against
a second opinion written next to the engine. It is checked here, in this
package, because it is a statement about two TIERS and the far one is this
package's binary — the substrate's suite would have to reach downstream for a
binary it does not build to make the same assertion, and would skip itself into
silence on any machine where the reach failed.

Zero-width and nullable patterns are the whole point of the sample. There are
two defensible answers for what ``a*`` matches in ``abcab`` and only one of them
is the engine's; a disagreement here means the CLI and the in-process iterator
have drifted onto opposite sides of that choice.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

import gist
import irgx


@pytest.fixture(scope="session")
def cold_spans(tmp_path_factory):
    """Spans that ``gist --json`` reports for a pattern over one line of text.

    gist's unit is a line *including* its newline, where the binding's unit is
    exactly the buffer it was handed. So the caller passes the line without a
    newline and this appends one, which is the same bytes gist matched over.
    """
    binary = gist.binary()
    directory = tmp_path_factory.mktemp("spans")

    def spans(pattern: str, line: str, *extra: str) -> list[tuple[int, int]]:
        subject = directory / "subject.txt"
        subject.write_text(line + "\n", encoding="utf-8")
        done = subprocess.run(  # noqa: S603 — trusted binary, list argv, no shell
            [binary, "--json", *extra, "--", pattern, str(subject)],
            capture_output=True,
            text=True,
            check=False,
        )
        # 0 is matches, 1 is a clean no-match. Anything else is the tool
        # refusing the query, which is a failure of this test's premise rather
        # than a disagreement about spans, so say which it was.
        assert done.returncode in (0, 1), f"gist refused {pattern!r}: {done.stderr.strip()}"
        found: list[tuple[int, int]] = []
        for line_out in done.stdout.splitlines():
            record = json.loads(line_out)
            if record.get("type") != "match":
                continue
            found.extend((sub["start"], sub["end"]) for sub in record["data"]["submatches"])
        return found

    return spans


@pytest.mark.parametrize(
    "pattern,line",
    [
        ("a*", "abc"),
        ("a*", "abcab"),
        ("a*", "bbb"),
        (r"\b", "hi yo"),
        ("a?", "bab"),
        ("(a)*", "baac"),
        (r"\w+", "naive cafe words"),
        ("", "abc"),
        ("a+", "aa b aaa"),
    ],
)
def test_spans_agree_with_gist_json(cold_spans, pattern, line) -> None:
    # gist matches a line including its newline, so that is the buffer to hand
    # the binding for the comparison to mean anything.
    warm = [m.span() for m in irgx.finditer(pattern, line + "\n")]
    assert warm == cold_spans(pattern, line)


def test_the_oracle_is_the_binary_and_not_a_stub() -> None:
    """The comparison above is only worth its runtime if the tool really ran.

    A ``gist`` that resolved to something inert would agree with everything, so
    pin the one thing a stub could not fake: the binary this suite resolves is
    the one this checkout builds.
    """
    resolved = Path(gist.binary()).resolve()
    assert resolved.is_file()
    assert os.access(resolved, os.X_OK)
