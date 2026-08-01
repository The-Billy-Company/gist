#!/usr/bin/env python3
"""Deterministic adversarial corpus generator (the `torture` corpus).

Builds a tree that concentrates every shape known to break file scanners —
read-cap edges, giant single lines, chunk-boundary straddles, encodings,
ignore-hierarchy corner cases, filesystem oddities — so `sweep.py` can
differential-test `gist rg` vs real ripgrep where the home monorepo has no
coverage at all. No randomness: two runs produce byte-identical trees, so a
divergence is always the engine, never the fixture.

Needles are UPPER_SNAKE tokens unique per trap; sweep.py greps for them by
name, so a false negative pinpoints its trap immediately.

Usage: python3 torture.py <dest-dir>
"""

import os
from pathlib import Path
import shutil
import sys


CAP = 4 << 20  # gist's per-file read-path shape boundary (corpus.per_file_cap)


def build(root: Path) -> None:
    """Materialize the full adversarial tree under `root`.

    Wipes any existing tree first — a stale file from an older generator
    would desync the rg oracle diff.
    """
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    w = lambda rel, data: _write(root / rel, data)

    # ── read-path size edges ─────────────────────────────────────────────────
    # Needle placed astride every interesting byte boundary of a 4 MiB cap:
    # just under, exactly at, spanning, and megabytes past it.
    filler = b"the quick brown fox jumps over the lazy dog padding line\n"
    w("size/under_cap.txt", _padded(filler, CAP - 128, b"NEEDLE_UNDER_CAP\n"))
    w("size/at_cap.txt", _exact(filler, CAP, b"NEEDLE_AT_CAP\n"))
    w("size/spans_cap.txt", _padded(filler, CAP - 8, b"NEEDLE_SPANS_CAP_BOUNDARY\n"))
    w("size/past_cap.txt", _padded(filler, CAP + (2 << 20), b"NEEDLE_PAST_CAP\n"))
    w("size/empty.txt", b"")
    w("size/one_byte.txt", b"x")
    w("size/only_newlines.txt", b"\n" * 4096)

    # ── line-shape edges ─────────────────────────────────────────────────────
    w("lines/giant_line.txt", b"x" * (5 << 20) + b"NEEDLE_GIANT_LINE\n")
    w("lines/giant_line_no_nl.txt", b"y" * (5 << 20) + b"NEEDLE_GIANT_NO_NL")
    w("lines/no_trailing_nl.txt", b"first\nlast NEEDLE_NO_TRAILING_NL")
    # A needle placed to straddle every 64 KiB block edge in a 1 MiB file.
    blk = bytearray()
    for _ in range(16):
        blk += b"z" * (65536 - 11) + b"STRADDLE_ME"
    w("lines/straddle_64k.txt", bytes(blk) + b"\n")
    w("lines/crlf.txt", b"alpha NEEDLE_CRLF\r\nbeta\r\ngamma\r\n")
    w("lines/mixed_terminators.txt", b"one\ntwo NEEDLE_MIXED\r\nthree\rfour\n")
    # CR exactly before a chunk-boundary LF (splits the \r\n pair across reads).
    w("lines/crlf_boundary.txt", b"a" * 65535 + b"\r\nNEEDLE_CRLF_BOUNDARY\r\n")

    # ── encodings ────────────────────────────────────────────────────────────
    text = "маленькая жизнь NEEDLE_UTF16 straße café\n"
    w("enc/utf16le_bom.txt", b"\xff\xfe" + text.encode("utf-16-le"))
    w("enc/utf16be_bom.txt", b"\xfe\xff" + text.encode("utf-16-be"))
    w("enc/utf8_bom.txt", b"\xef\xbb\xbf" + "NEEDLE_UTF8_BOM caf\u00e9\n".encode())
    w("enc/invalid_utf8.txt", b"ok NEEDLE_INVALID_UTF8 \xff\xfe\x80 tail\n")
    w("enc/latin1.txt", "NEEDLE_LATIN1 caf\u00e9 stra\u00dfe\n".encode("latin-1"))
    w("enc/nul_binary.dat", b"NEEDLE_BINARY\x00" + bytes(range(256)) * 16)
    w("enc/nul_after_8k.dat", b"NEEDLE_LATE_NUL\n" + b"t" * 9000 + b"\x00tail\n")
    # Multi-script fold orbits (Greek final sigma, Cyrillic, fullwidth digits).
    w(
        "enc/scripts.txt",
        (
            "ΣΊΣΥΦΟΣ σίσυφος Σίσυφος NEEDLE_SIGMA\n"
            "ЖИЗНЬ жизнь NEEDLE_CYRILLIC\n"
            "ＮＥＥＤＬＥ＿ＦＵＬＬＷＩＤＴＨ ０１２３\n"
            "İstanbul ıstanbul NEEDLE_DOTTED_I\n"
        ).encode()
    )

    # ── ignore-hierarchy corner cases ────────────────────────────────────────
    ig = root / "ignore"
    w("ignore/.gitignore", b"*.log\n!keep.log\nbuild_dir/\n/anchored.txt\nsub/**/deep.txt\n")
    w("ignore/dropped.log", b"NEEDLE_IGNORED_LOG\n")
    w("ignore/keep.log", b"NEEDLE_NEGATED_KEEP\n")
    w("ignore/build_dir/inside.txt", b"NEEDLE_IGNORED_DIR\n")
    w("ignore/anchored.txt", b"NEEDLE_ANCHORED_ROOT\n")
    w("ignore/sub/anchored.txt", b"NEEDLE_ANCHORED_SUB_SURVIVES\n")
    w("ignore/sub/a/b/deep.txt", b"NEEDLE_DOUBLESTAR_IGNORED\n")
    # Nested re-include: child .gitignore un-ignores what the parent dropped.
    w("ignore/nested/.gitignore", b"!*.log\n")
    w("ignore/nested/reincluded.log", b"NEEDLE_NESTED_REINCLUDE\n")
    # .ignore outranks .gitignore at the same level (ripgrep precedence).
    w("ignore/prec/.gitignore", b"!data.txt\n")
    w("ignore/prec/.ignore", b"data.txt\n")
    w("ignore/prec/data.txt", b"NEEDLE_IGNORE_OUTRANKS_GIT\n")
    w("ignore/.hidden_file.txt", b"NEEDLE_HIDDEN\n")
    w("ignore/.hidden_dir/inside.txt", b"NEEDLE_HIDDEN_DIR\n")
    _ = ig

    # ── filenames ────────────────────────────────────────────────────────────
    w("names/with space.txt", b"NEEDLE_SPACE_NAME\n")
    w("names/colon:name.txt", b"NEEDLE_COLON_NAME\n")
    w("names/-leading-dash.txt", b"NEEDLE_DASH_NAME\n")
    w("names/uni-\u00e9\u4e2d\u6587.txt", "NEEDLE_UNICODE_NAME\n".encode())
    w("names/" + "l" * 200 + ".txt", b"NEEDLE_LONG_NAME\n")
    w("names/CASE.TXT", b"NEEDLE_UPPER_EXT\n")

    # ── tree shape ───────────────────────────────────────────────────────────
    deep = root / "deep"
    for i in range(120):
        deep = deep / f"d{i:03d}"
    _write(deep / "needle.txt", b"NEEDLE_DEEP_NEST\n")
    fan = root / "fanout"
    fan.mkdir(parents=True, exist_ok=True)
    for i in range(3000):
        _write(fan / f"tiny{i:04d}.txt", b"tiny %d\n" % i)
    _write(fan / "hit.txt", b"NEEDLE_FANOUT\n")

    # ── links ────────────────────────────────────────────────────────────────
    links = root / "links"
    _write(links / "real.txt", b"NEEDLE_LINK_TARGET\n")
    _symlink(links / "to_file.txt", links / "real.txt")
    cyc = root / "links" / "cyc" / "a"
    _write(cyc / "f.txt", b"NEEDLE_CYCLE\n")
    _symlink(cyc / "loop", cyc.parent)
    # A deliberately dangling link, in its own subtree so `-L links` stays a
    # clean-walk case; `-L broken` pins rg's error-report + exit-2 contract.
    _symlink(root / "broken" / "dangling.txt", root / "broken" / "no_such_target")
    _write(root / "broken" / "real.txt", b"NEEDLE_BESIDE_DANGLING\n")


def _padded(unit: bytes, at_least: int, needle: bytes) -> bytes:
    """Filler of >= `at_least` bytes (whole units), then the needle."""
    reps = at_least // len(unit) + 1
    return unit * reps + needle


def _exact(unit: bytes, total: int, needle: bytes) -> bytes:
    """Exactly `total` bytes with the needle's line ending at byte `total`."""
    body_len = total - len(needle)
    reps = body_len // len(unit)
    pad = body_len - reps * len(unit)
    return unit * reps + b"#" * (pad - 1) + b"\n" + needle if pad else unit * reps + needle


def _write(p: Path, data: bytes) -> None:
    """Write `data` to `p`, creating parent directories as needed."""
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def _symlink(link: Path, target: Path) -> None:
    """Create `link` → `target` with a target path relative to the link's dir."""
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.exists():
        link.unlink()
    os.symlink(os.path.relpath(target, link.parent), link)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: torture.py <dest-dir>")
    build(Path(sys.argv[1]))
    print(f"torture corpus ready at {sys.argv[1]}")
