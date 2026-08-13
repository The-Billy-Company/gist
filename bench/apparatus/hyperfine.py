#!/usr/bin/env python3
"""Reading a hyperfine `--export-json` file — the one wire format every race speaks.

VENDORED, BYTE-IDENTICAL across all four ecosystem packages
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

`field.sh` times every cell through one `hyperfine --export-json` invocation, so
its output is the seam between the shell that measures and the Python that
judges. That makes the reader apparatus, not a claim: it lives here rather than
in any one package's report module, because a Layer A splice in the exact-search
package and a Layer K splice in the kinship package reading the same file
differently is a difference in the *numbers* that no verdict math downstream can
catch.

Deliberately not in `statcore.py`: that file is pure math with no ingestion, and
the split is load-bearing — the verdict is a claim about samples, this is where
samples come from. Deliberately not a `dataclass` either; hyperfine's schema is
the source of truth and wrapping it would invite a second one.

Also the shell's reader: `field.sh::_hf_value` runs this module as a script
(`python3 hyperfine.py <json> mean|min`) so a timing printed by a race and a
timing parsed by a splice come from the same three lines.

stdlib only.
"""

import json
import sys
from pathlib import Path


def times_ms(path: Path | str) -> list[float]:
    """Per-run wall times in **milliseconds**, in run order.

    hyperfine reports seconds; every certificate in the ecosystem reports
    milliseconds, and converting at the boundary is what keeps a stray factor of
    1000 from reaching a sidecar.
    """
    doc = json.loads(Path(path).read_text())
    return [t * 1000.0 for t in doc["results"][0].get("times") or []]


def summary_ms(path: Path | str, stat: str) -> float:
    """`mean` (hyperfine's own) or `min` (the least-noise run), in milliseconds.

    A mean carries the machine's interference and is the honest headline; a min
    is the cleanest observation and is what a ratio against a rival's min stays
    comparable to. Both are wanted, and which one a lane uses is the lane's call.
    """
    if stat == "min":
        samples = times_ms(path)
        if not samples:
            raise ValueError(f"{path}: hyperfine recorded no runs")
        return min(samples)
    if stat != "mean":
        raise ValueError(f"unknown statistic {stat!r} (want 'mean' or 'min')")
    doc = json.loads(Path(path).read_text())
    return float(doc["results"][0]["mean"]) * 1000.0


if __name__ == "__main__":
    print(f"{summary_ms(sys.argv[1], sys.argv[2]):.1f}")
