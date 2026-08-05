#!/usr/bin/env python3
"""Release readiness gate — the Dominance-and-Fit Certificate on *every* machine.

A single-machine certificate proves gist is dominant on the box that minted it,
and nothing more (cold-CLI dominance is machine-specific — an M2 mint once
showed 0 wins where an M4 Max shows 11). So a release is only allowed to claim
optimality once the certificate has been *freshly re-minted on each supported
architecture* and attached. This gate is what Town Crier (``changelog build``)
runs before it will cut an irregex release: it refuses unless a valid,
current-to-this-history certificate bundle exists for **both** the Mac and the
Linux machine.

It composes the single-bundle reproducibility gate rather than re-implementing
it: each platform bundle must pass ``check_artifacts.check_artifacts`` (every
required file present, corpus hashes + tool identities + raw-cell matrix + size
accounting internally agree), then this gate adds the one thing that single
check cannot see — **platform coverage**: one Darwin bundle and one Linux
bundle, each carrying its own measured numbers.

**A commit is a reference, never a requirement.** This gate used to also demand
that each bundle's recorded commit be an ancestor of HEAD, on the theory that it
proved the numbers described the code being released. It did not: the mint
rewrites the tracked bundle, so the tree is necessarily dirty by the time a
certificate exists, and every real caller therefore ran with the check disabled.
A gate that can only fire falsely is worse than no gate. What actually answers
"did the certificate change, and how" is the mint ledger (``ledger.py``), which
records every published certificate's layers and headline numbers. The recorded
commit is surfaced here as provenance for a human, and nothing fails without it.

Layout (additive — the flat ``artifact/`` stays the current-machine mint):

    bench/certificate/artifact/              flat bundle (the Mac mint today)
    bench/certificate/artifact/linux-x86_64/ the Linux mint, published with
                                            CERT_PUBLISH_DIR=…/linux-x86_64

An explicit ``artifact/<platform-id>/`` subdir always wins over the flat dir for
its platform, so the tree migrates cleanly to fully per-platform bundles without
a flag day.

Usage:
    check_release.py [--artifacts-root DIR] [--platforms darwin,linux] [--json]

Exit 0 iff every required platform is present and valid; 1 on a missing or
invalid platform; 2 when no bundles exist at all (release not yet set up — mint
them first).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]  # guard → certificate → bench → package root
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from profile import CHARTER  # noqa: E402

from artifacts import check_artifacts  # noqa: E402

# Platform token (first word of machine.json ``os``, lowered) -> human label.
# The release requires a fresh, valid certificate for each of these.
DEFAULT_PLATFORMS: dict[str, str] = {"darwin": "Mac", "linux": "Linux"}


def _read_machine(bundle: Path) -> dict[str, object] | None:
    path = bundle / "machine.json"
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def platform_of(machine: dict[str, object] | None) -> str | None:
    """Classify a bundle's machine.json as 'darwin' / 'linux' / … (or None).

    Keyed on the first token of ``os`` (e.g. ``"Darwin 25.5.0"`` -> ``darwin``),
    which is the one field both the macro mint and the layer mints agree on.
    """
    if not machine:
        return None
    os_field = str(machine.get("os", "")).strip()
    return os_field.split()[0].lower() if os_field else None


def discover_bundles(root: Path) -> dict[str, Path]:
    """Map platform -> certificate bundle dir under ``root``.

    Explicit ``root/<platform-id>/`` subdirs (each carrying a ``machine.json``)
    win over the flat ``root`` bundle for their platform, so a partially- or
    fully-migrated tree resolves deterministically.
    """
    bundles: dict[str, Path] = {}
    if root.is_dir():
        for child in sorted(root.iterdir()):
            if child.is_dir() and (plat := platform_of(_read_machine(child))):
                bundles.setdefault(plat, child)
    if plat := platform_of(_read_machine(root)):
        bundles.setdefault(plat, root)
    return bundles


def speeds_summary(bundle: Path) -> str:
    """This bundle's headline numbers on one line, as the package's charter defines them.

    This is the "current benchmark numbers" the release attaches — surfaced in
    the gate log so a human sees what each machine actually measured, not just a
    green check. Read through the same charter hook the ledger uses, so the
    release note and the recorded history can never disagree.
    """
    certificate = bundle / "CERTIFICATE.md"
    if not certificate.is_file():
        return "numbers unavailable (no CERTIFICATE.md)"
    if not CHARTER.headlines:
        return f"{CHARTER.package} tracks no headline number"
    try:
        measured = CHARTER.measure(bundle, certificate.read_text(errors="replace"))
    except OSError as error:
        return f"numbers unreadable ({error})"
    return (
        " / ".join(
            f"{value:g}{spec.unit} {spec.column}"
            for spec in CHARTER.headlines
            if (value := measured.get(spec.key)) is not None
        )
        or "numbers unavailable (this mint claimed none)"
    )


def verify_release(
    root: Path, *, platforms: dict[str, str]
) -> tuple[bool, list[dict[str, object]]]:
    """Verify a valid certificate exists for every required platform.

    Returns ``(ok, rows)`` where each row reports one required platform's
    presence, structural validity, speed tally, and recorded commit (reference
    only — a bundle without one is judged exactly like a bundle with one).
    """
    bundles = discover_bundles(root)
    rows: list[dict[str, object]] = []
    ok = True
    for token, label in platforms.items():
        bundle = bundles.get(token)
        row: dict[str, object] = {
            "platform": token,
            "machine": label,
            "present": bundle is not None,
        }
        if bundle is None:
            row["problems"] = [f"no {label} certificate under {root}"]
            ok = False
            rows.append(row)
            continue
        row["dir"] = str(bundle.relative_to(KERNEL) if bundle.is_relative_to(KERNEL) else bundle)
        problems = check_artifacts(bundle)
        if problems == ["__ABSENT__"]:
            problems = [f"{label} bundle is absent or pending regeneration"]
        row["valid"] = not problems
        meta = _read_machine(bundle) or {}
        row["commit"] = str(meta.get("git_commit", ""))
        row["speeds"] = speeds_summary(bundle)
        if problems:
            row["problems"] = problems
            ok = False
        rows.append(row)
    return ok, rows


def _parse_platforms(spec: str | None) -> dict[str, str]:
    if not spec:
        return dict(DEFAULT_PLATFORMS)
    return {
        tok.strip().lower(): DEFAULT_PLATFORMS.get(tok.strip().lower(), tok.strip().title())
        for tok in spec.split(",")
        if tok.strip()
    }


def main(argv: list[str] | None = None) -> int:
    """Verify the release certificate coverage across machines."""
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--artifacts-root", type=Path, default=HERE.parent / "artifact")
    ap.add_argument(
        "--platforms",
        default=None,
        help="comma list of required platform tokens (default: darwin,linux)",
    )
    ap.add_argument("--json", action="store_true", help="machine-readable JSON on stdout")
    args = ap.parse_args(argv)

    platforms = _parse_platforms(args.platforms)
    root = args.artifacts_root.resolve()
    if not discover_bundles(root):
        message = (
            f"no certificate bundles under {root} — release not set up. "
            "Mint on each machine: CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 bash bench/certificate/mint/mint.sh "
            "(Linux: CERT_PUBLISH_DIR=bench/certificate/artifact/linux-x86_64 "
            "bash bench/certificate/mint/mint.sh)"
        )
        if args.json:
            print(json.dumps({"ok": False, "absent": True, "message": message}, indent=2))
        else:
            print(message, file=sys.stderr)
        return 2

    ok, rows = verify_release(root, platforms=platforms)

    if args.json:
        print(json.dumps({"ok": ok, "platforms": rows}, indent=2, sort_keys=True))
        return 0 if ok else 1

    for row in rows:
        mark = "✓" if row.get("present") and row.get("valid") else "✗"
        label = row["machine"]
        found = row.get("problems")
        problems = [str(p) for p in found] if isinstance(found, list) else []
        if not row.get("present"):
            print(
                f"  {mark} {label}: missing — {problems[0] if problems else '?'}", file=sys.stderr
            )
            continue
        commit = str(row.get("commit") or "")
        ref = f" · minted at {commit[:12]}" if commit else ""
        print(f"  {mark} {label} [{row.get('dir')}] — {row.get('speeds')}{ref}")
        for problem in problems:
            print(f"      - {problem}", file=sys.stderr)
    if ok:
        print(f"OK: certificate attached and valid on all {len(rows)} machine(s).")
        return 0
    print(
        "FAIL: release requires a valid Dominance-and-Fit Certificate on every machine "
        "(Mac + Linux). Re-mint the missing/invalid ones and commit them.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
