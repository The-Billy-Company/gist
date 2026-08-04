#!/usr/bin/env python3
"""The vendored-apparatus gate — shared instruments must be byte-identical everywhere.

VENDORED, BYTE-IDENTICAL (this file is in its own manifest).

`irregex`, `gist`, `relate`, and `blast` are four independently releasable
packages. Each mints its own certificate over its own claims, but they must all
mean the same thing by "median", "significant", "reproducible bundle", and
"where are my siblings" — a `win` computed by a drifted copy of the verdict math
is not comparable to a `win` computed by the real one, and a bundle blessed by a
drifted reproducibility gate is not evidence of the same thing the other
packages published. Python and shell cannot be imported across a repository
boundary, so the instruments are vendored rather than shared, and this gate is
what keeps "vendored" from decaying into "forked".

WHAT IS SHARED IS THE METHOD, NEVER THE CLAIM. Every file below is generic: it
knows how to judge a certificate, not what this package certifies. The roster of
layers, the tools that must appear, the probe classes, the sidecars — all of that
is one per-package `bench/certificate/guard/profile.py`, deliberately outside the
manifest, because four packages measuring four different things is the whole
point of having four packages.

It is deliberately not clever. Recompute each shared file's sha256, compare
against the pinned manifest, exit 1 on any mismatch. What makes it load-bearing
is that the manifest is ITSELF in the shared set: changing an instrument means
regenerating the manifest, which changes a file every sibling also carries, so
the change cannot land in one package and be forgotten in the other three
without their gates going red.

    python3 bench/apparatus/shared_drift.py              # verify (CI)
    python3 bench/apparatus/shared_drift.py --update     # after a deliberate edit
    python3 bench/apparatus/shared_drift.py --propagate  # push to sibling checkouts

`--update` is the ratchet-refresh of this gate and carries the same discipline:
run it only when you meant to change a shared instrument, and land the refreshed
manifest in the same change as the edit — in every package.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent  # <pkg>/bench/apparatus
PKG = HERE.parents[1]  # <pkg>
MANIFEST = HERE / "SHARED.sha256"

#: The vendored set, as paths relative to the PACKAGE ROOT. Package-relative
#: rather than relative to this file, because the shared instruments outgrew one
#: directory: the measurement floor lives in `bench/apparatus/`, and the gates
#: that judge a minted bundle live beside the bundle in `bench/certificate/`.
#: A package that mints nothing carries only the first group.
SHARED: tuple[str, ...] = (
    "bench/apparatus/roots.sh",
    "bench/apparatus/field.sh",
    # The one corpus every package can measure and every stranger can rebuild.
    # Vendored rather than owned by `irregex`, because two packages certifying
    # over "the ecosystem" from two recipes would be two different corpora
    # wearing one id — precisely the confusion `corpus.toml` exists to end.
    "bench/apparatus/corpora/ecosystem.sh",
    "bench/apparatus/hyperfine.py",
    "bench/apparatus/statcore.py",
    "bench/apparatus/test_statcore.py",
    "bench/apparatus/provenance.py",
    "bench/apparatus/test_provenance.py",
    "bench/apparatus/shared_drift.py",
    "bench/certificate/guard/charter.py",
    "bench/certificate/guard/artifacts.py",
    "bench/certificate/guard/publish.py",
    # `ratio.py` is deliberately NOT here. It gates the Layer A speedup floors
    # against `certify_macro.csv` over gist's twelve probe classes, invoked
    # through the roster helpers in `dominance/races/field.sh` — every one of
    # those is a fact about what gist claims, not about how a claim is judged.
    # Vendored, it was a gate no sibling could ever pass: no baseline, no macro
    # CSV, no roster. A gate that cannot run is not a gate.
    "bench/certificate/guard/release.py",
    "bench/certificate/guard/test_release.py",
    "bench/certificate/ledger/ledger.py",
    "bench/certificate/ledger/test_ledger.py",
)

#: Packages that carry the vendored set, resolved as siblings of this checkout.
SIBLINGS: tuple[str, ...] = ("irregex", "gist", "relate", "blast")


def digest(path: Path) -> str:
    """sha256 of a file's bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observed() -> dict[str, str]:
    """Current digest of every shared file present in this checkout.

    Absence is not drift here — a package that mints no certificate has no
    `bench/certificate/` to hold the gates, and pinning files it was never meant
    to carry would make its gate permanently red. `verify` decides what a gap
    means; this only reports what is on disk.

    """
    return {name: digest(PKG / name) for name in SHARED if (PKG / name).is_file()}


def carried(name: str) -> bool:
    """Is this checkout supposed to hold ``name`` at all?

    The manifest is byte-identical everywhere, so it necessarily pins the union:
    a package that mints a certificate pins the gates, and `blast`, which mints
    nothing, inherits those lines with nowhere to put them. The enclosing
    directory settles it — a package states that it mints by having a
    `bench/certificate/guard/` to keep the gates in. That is the same rule
    `propagate` delivers by, so the two can never disagree about who carries
    what, and it stays a structural fact rather than a per-package exception
    list somebody has to remember to update.

    """
    return (PKG / name).parent.is_dir()


def pinned() -> dict[str, str]:
    """The manifest as written, `<sha256>  <path>` per line."""
    if not MANIFEST.is_file():
        return {}
    out = {}
    for line in MANIFEST.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        sha, _, name = line.partition("  ")
        out[name.strip()] = sha.strip()
    return out


def write_manifest(digests: dict[str, str]) -> None:
    """Rewrite the manifest from the given digests, sorted for a stable diff.

    Pins for groups this package does not carry are preserved as they stand.
    Re-pinning from a package holding a subset would otherwise *narrow* the
    manifest — and since the manifest is itself vendored, propagating that
    narrower file would quietly unpin the certificate gates everywhere.

    """
    digests = {n: sha for n, sha in pinned().items() if not carried(n)} | digests
    body = "".join(f"{digests[name]}  {name}\n" for name in sorted(digests))
    MANIFEST.write_text(
        "# Vendored shared apparatus — byte-identical across irregex/gist/relate/blast.\n"
        "# Paths are package-root-relative. Regenerate with\n"
        "# `python3 bench/apparatus/shared_drift.py --update`, then land the refreshed\n"
        "# manifest in EVERY package in the same change.\n" + body
    )


def verify() -> int:
    """Compare observed digests against the manifest; 0 clean, 1 drifted, 2 unusable.

    A pinned file this checkout lacks is drift **wherever this package holds the
    directory it belongs in** — see `carried`. Elsewhere it is simply a line for
    a group this package does not participate in.

    """
    want, have = pinned(), observed()
    if not want:
        print(f"shared_drift: no manifest at {MANIFEST} — run --update to mint one", file=sys.stderr)
        return 2

    missing = sorted(n for n in set(want) - set(have) if carried(n))
    extra = sorted(set(have) - set(want))
    drifted = sorted(n for n in set(want) & set(have) if want[n] != have[n])

    for name in missing:
        print(f"shared_drift: MISSING {name} — the manifest pins it, this checkout lacks it")
    for name in extra:
        print(f"shared_drift: UNPINNED {name} — present but not in the manifest")
    for name in drifted:
        print(f"shared_drift: DRIFTED {name}\n    pinned   {want[name]}\n    observed {have[name]}")

    if missing or extra or drifted:
        print(
            "\nA shared instrument differs from the pinned bytes. Either revert the edit, or —\n"
            "if the change was deliberate — run `--update` here and `--propagate` to the\n"
            "siblings, landing the same bytes and the same manifest in every package.",
            file=sys.stderr,
        )
        return 1

    skipped = len(set(want) - set(have))
    aside = f" ({skipped} pinned for groups this package does not carry)" if skipped else ""
    print(f"shared_drift: {len(have)} shared instruments byte-identical to the manifest{aside}")
    return 0


def sibling_roots() -> list[Path]:
    """Sibling checkouts that declare one of the ecosystem package names."""
    parent = PKG.parent
    found = []
    for cand in sorted(parent.iterdir()) if parent.is_dir() else []:
        zon = cand / "build.zig.zon"
        if not zon.is_file() or cand.resolve() == PKG.resolve():
            continue
        text = zon.read_text(errors="replace")
        if any(f".name = .{name}," in text for name in SIBLINGS):
            found.append(cand)
    return found


def propagate() -> int:
    """Copy this checkout's shared set into every sibling that already carries one.

    A sibling receives a file only where it already carries that file's GROUP —
    `bench/apparatus` for the measurement floor, `bench/certificate` for the
    gates that judge a minted bundle. Carrying the group is the package's own
    statement of what it does; pushing gates into a package that publishes
    nothing would hand it a red gate it has no way to satisfy.

    The test is the group, not the immediate parent, because a shared file in a
    subdirectory no sibling happens to have yet would otherwise propagate
    nowhere at all — silently, since each package verifies only its own copies.
    That is how `corpora/ecosystem.sh` reached `gist`, which had the directory,
    and not `relate`, which mints the same corpus and did not.
    """
    manifest_rel = str(MANIFEST.relative_to(PKG))
    pushed = 0
    for sib in sibling_roots():
        wrote = 0
        for name in (*SHARED, manifest_rel):
            src, dest = PKG / name, sib / name
            group = Path(*Path(name).parts[:2])  # bench/apparatus | bench/certificate
            if src.is_file() and (sib / group).is_dir():
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(src.read_bytes())
                wrote += 1
        if not wrote:
            print(f"shared_drift: skip {sib.name} — carries none of the shared set")
            continue
        print(f"shared_drift: pushed {wrote} files -> {sib.name}/")
        pushed += 1
    if not pushed:
        print("shared_drift: no sibling checkouts found beside this one", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="verify the vendored shared apparatus")
    ap.add_argument("--update", action="store_true", help="re-pin the manifest to current bytes")
    ap.add_argument("--propagate", action="store_true", help="copy the shared set to siblings")
    args = ap.parse_args(argv[1:])

    if args.update:
        # Self-referential by design: this file is in its own manifest, so the
        # digest is taken after any edit to it and before the manifest is written.
        write_manifest(observed())
        print(f"shared_drift: re-pinned {len(pinned())} instruments in {MANIFEST.name}")
        if not args.propagate:
            print("  next: --propagate, or copy the shared set into every sibling by hand")
    if args.propagate:
        return propagate()
    if args.update:
        return 0
    return verify()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
