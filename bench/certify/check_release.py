#!/usr/bin/env python3
"""Release readiness gate — the Certificate of Optimality on *every* machine.

A single-machine certificate proves gist is optimal on the box that minted it,
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
accounting internally agree), then this gate adds the two things that single
check cannot see — **platform coverage** (one Darwin bundle, one Linux bundle)
and **freshness** (each bundle's recorded commit belongs to the current line of
history, so the numbers describe the code being released, not a stale branch).

Layout (additive — the flat ``artifact/`` stays the current-machine mint):

    bench/certify/artifact/                 flat bundle (the Mac mint today)
    bench/certify/artifact/linux-x86_64/    the Linux mint, published with
                                            CERT_PUBLISH_DIR=…/linux-x86_64

An explicit ``artifact/<platform-id>/`` subdir always wins over the flat dir for
its platform, so the tree migrates cleanly to fully per-platform bundles without
a flag day.

Usage:
    check_release.py [--artifacts-root DIR] [--platforms darwin,linux]
                     [--require-head / --no-require-head] [--pin SHA]
                     [--max-age-commits N] [--json]

Exit 0 iff every required platform is present, valid, and fresh; 1 on a missing
/ stale / invalid platform; 2 when no bundles exist at all (release not yet set
up — mint them first).
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import subprocess
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]  # bench/certify -> bench -> irregex -> kernels -> libs -> repo
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from check_artifacts import check_artifacts  # noqa: E402

# Platform token (first word of machine.json ``os``, lowered) -> human label.
# The release requires a fresh, valid certificate for each of these.
DEFAULT_PLATFORMS: dict[str, str] = {"darwin": "Mac", "linux": "Linux"}


def _git(*args: str) -> str | None:
    """Stripped stdout of ``git -C REPO <args>`` or None on any failure."""
    try:
        return subprocess.check_output(
            ["git", "-C", str(REPO), *args], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


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
    """One-line cold-race verdict tally vs ripgrep, read from certify_macro.csv.

    This is the "current benchmark speeds" the release attaches — surfaced in the
    gate log so a human sees the numbers on each machine, not just a green check.
    """
    macro = bundle / "certify_macro.csv"
    if not macro.is_file():
        return "speeds unavailable (no certify_macro.csv)"
    tally = {"win": 0, "parity": 0, "loss": 0}
    classes: set[str] = set()
    try:
        with macro.open(newline="") as source:
            for row in csv.DictReader(source, delimiter="\t"):
                classes.add(row.get("class", ""))
                if row.get("tool") == "rg":
                    verdict = row.get("verdict", "")
                    if verdict in tally:
                        tally[verdict] += 1
    except (OSError, csv.Error) as error:
        return f"speeds unreadable ({error})"
    return (
        f"{tally['win']} win / {tally['parity']} parity / {tally['loss']} loss "
        f"vs rg across {len(classes)} classes"
    )


def _freshness(commit: str, *, pin: str | None, max_age: int | None) -> tuple[bool, str]:
    """Judge a bundle's recorded commit against the current history.

    Returns ``(fresh, note)``. With ``pin`` the commit must equal it exactly (a
    locked release). Otherwise the commit must be an ancestor of HEAD — it
    belongs to the line of history being released, not a stale or unrelated
    branch — and, when ``max_age`` is set, no further than that many commits
    behind HEAD.
    """
    if pin:
        ok = _git("rev-parse", "--verify", f"{commit}^{{commit}}") == _git(
            "rev-parse", "--verify", f"{pin}^{{commit}}"
        )
        return ok, f"pinned to {pin[:12]}" if ok else f"commit {commit[:12]} != pin {pin[:12]}"
    head = _git("rev-parse", "HEAD")
    if head is None:
        return False, "cannot resolve HEAD for freshness"
    is_ancestor = (
        subprocess.run(
            ["git", "-C", str(REPO), "merge-base", "--is-ancestor", commit, "HEAD"],
            capture_output=True,
        ).returncode
        == 0
    )
    if not is_ancestor:
        return False, f"commit {commit[:12]} is not in the history of HEAD (stale/foreign mint)"
    behind = _git("rev-list", "--count", f"{commit}..HEAD")
    distance = int(behind) if behind and behind.isdigit() else 0
    if max_age is not None and distance > max_age:
        return False, f"{distance} commits behind HEAD (> --max-age-commits {max_age})"
    return True, f"{distance} commit(s) behind HEAD"


def verify_release(
    root: Path,
    *,
    platforms: dict[str, str],
    require_head: bool,
    pin: str | None = None,
    max_age: int | None = None,
) -> tuple[bool, list[dict[str, object]]]:
    """Verify a fresh, valid certificate exists for every required platform.

    Returns ``(ok, rows)`` where each row reports one required platform's
    presence, structural validity, freshness, recorded commit, and speed tally.
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
        row["dir"] = str(bundle.relative_to(REPO) if bundle.is_relative_to(REPO) else bundle)
        problems = check_artifacts(bundle, require_head=False)
        if problems == ["__ABSENT__"]:
            problems = [f"{label} bundle is absent or pending regeneration"]
        row["valid"] = not problems
        meta = _read_machine(bundle) or {}
        commit = str(meta.get("git_commit", ""))
        row["commit"] = commit
        row["speeds"] = speeds_summary(bundle)
        if require_head and commit:
            fresh, note = _freshness(commit, pin=pin, max_age=max_age)
        else:
            fresh, note = (True, "freshness not required")
        row["fresh"] = fresh
        row["freshness"] = note
        if problems or not fresh:
            row["problems"] = [*problems] + ([] if fresh else [note])
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
    ap.add_argument("--artifacts-root", type=Path, default=HERE / "artifact")
    ap.add_argument(
        "--platforms",
        default=None,
        help="comma list of required platform tokens (default: darwin,linux)",
    )
    ap.add_argument(
        "--require-head",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="require each bundle's commit to belong to HEAD's history (default: on)",
    )
    ap.add_argument(
        "--pin", default=None, help="require every bundle's commit to equal this SHA exactly"
    )
    ap.add_argument(
        "--max-age-commits",
        type=int,
        default=None,
        help="reject a bundle more than N commits behind HEAD",
    )
    ap.add_argument("--json", action="store_true", help="machine-readable JSON on stdout")
    args = ap.parse_args(argv)

    platforms = _parse_platforms(args.platforms)
    root = args.artifacts_root.resolve()
    if not discover_bundles(root):
        message = (
            f"no certificate bundles under {root} — release not set up. "
            "Mint on each machine: CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify "
            "(Linux: CERT_PUBLISH_DIR=bench/certify/artifact/linux-x86_64 bash bench/certify/certify.sh)"
        )
        if args.json:
            print(json.dumps({"ok": False, "absent": True, "message": message}, indent=2))
        else:
            print(message, file=sys.stderr)
        return 2

    ok, rows = verify_release(
        root,
        platforms=platforms,
        require_head=args.require_head,
        pin=args.pin,
        max_age=args.max_age_commits,
    )

    if args.json:
        print(json.dumps({"ok": ok, "platforms": rows}, indent=2, sort_keys=True))
        return 0 if ok else 1

    for row in rows:
        mark = "✓" if row.get("present") and row.get("valid") and row.get("fresh") else "✗"
        label = row["machine"]
        if not row.get("present"):
            print(f"  {mark} {label}: missing — {row.get('problems', ['?'])[0]}", file=sys.stderr)
            continue
        print(f"  {mark} {label} [{row.get('dir')}] — {row.get('speeds')} ({row.get('freshness')})")
        for problem in row.get("problems", []):  # type: ignore[union-attr]
            print(f"      - {problem}", file=sys.stderr)
    if ok:
        print(f"OK: certificate attached, valid, and current on all {len(rows)} machine(s).")
        return 0
    print(
        "FAIL: release requires a fresh, valid Certificate of Optimality on every machine "
        "(Mac + Linux). Re-mint the missing/stale ones and commit them.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
