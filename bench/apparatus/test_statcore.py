#!/usr/bin/env python3
"""Known-answer tests for the shared bench statistics.

Every expectation here is derived from the *definition* — the Type-7 quantile
formula, and what a fail-closed dominance verdict has to mean — not from a run
of the code underneath. That is the point: this module is a twin of the one the
certificate uses in the exact-search package, and a twin that is only ever
checked against itself can drift while both halves agree.

    python3 bench/apparatus/test_statcore.py
"""

import random
import sys

from statcore import ALPHA, dominance, median_ci, quantile


def check(name: str, got, want, tol: float = 0.0) -> bool:
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    print(f"  {'ok  ' if ok else 'FAIL'} {name}: got {got!r}, want {want!r}")
    return ok


def main() -> int:
    ok = True

    # Type-7 by hand. Odd n: the middle element. Even n: h = p(n-1) = 1.5, so
    # halfway between the two middles.
    ok &= check("quantile odd median", quantile([1.0, 2, 3, 4, 5], 0.50), 3.0)
    ok &= check("quantile even median", quantile([1.0, 2, 3, 4], 0.50), 2.5)
    ok &= check("quantile p=0 is the min", quantile([7.0, 8, 9], 0.0), 7.0)
    ok &= check("quantile p=1 is the max", quantile([7.0, 8, 9], 1.0), 9.0)
    ok &= check("quantile of empty is 0", quantile([], 0.5), 0.0)
    ok &= check("quantile of one", quantile([42.0], 0.5), 42.0)

    # A CI over zero-variance samples cannot be wider than the point itself.
    rng = random.Random(1)
    med, lo, hi = median_ci([5.0] * 8, rng)
    ok &= check("median_ci constant median", med, 5.0)
    ok &= check("median_ci constant lo", lo, 5.0)
    ok &= check("median_ci constant hi", hi, 5.0)

    # And it must bracket the median it reports.
    med, lo, hi = median_ci([1.0, 2, 3, 4, 5, 6, 7, 8, 9], rng)
    ok &= check("median_ci brackets the median", lo <= med <= hi, True)

    # Fully separated, a faster: win, and speedup is median(b)/median(a).
    d = dominance([1.0] * 10, [2.0] * 10)
    ok &= check("separated a-faster verdict", d.verdict, "win")
    ok &= check("separated a-faster speedup", d.speedup, 2.0, 1e-12)
    ok &= check("separated a-faster is significant", d.p < ALPHA, True)

    # The complement must not also be a win, or the verdict means nothing.
    d = dominance([2.0] * 10, [1.0] * 10)
    ok &= check("separated a-slower verdict", d.verdict, "loss")
    ok &= check("separated a-slower speedup below 1", d.speedup < 1.0, True)

    # Identical distributions are PARITY, never a win. This is the fail-closed
    # half: all ties, so the tie correction has to hold sigma together.
    d = dominance([3.0] * 10, [3.0] * 10)
    ok &= check("identical samples are parity", d.verdict, "parity")
    ok &= check("identical samples are not significant", d.p >= ALPHA, True)
    ok &= check("identical samples speedup is 1", d.speedup, 1.0, 1e-12)

    # A tiny median gap with heavy overlap must stay parity rather than being
    # promoted on the strength of the medians alone.
    d = dominance([1.0, 2, 3, 4, 5], [1.1, 2.1, 3.1, 4.1, 5.1])
    ok &= check("overlapping samples are parity", d.verdict, "parity")

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
