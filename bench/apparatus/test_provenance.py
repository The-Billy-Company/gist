#!/usr/bin/env python3
"""Hermetic tests for the vendored provenance emitter (provenance.py).

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

Four contracts, each of which fails by looking like success if it breaks:

  * a **moving corpus is fatal** on a clean tree and *reported* on a coworked
    one — never silently hashed to whatever the file happened to be;
  * churn past the ceiling refuses the whole mint rather than publishing a
    partial manifest that reads complete;
  * the manifest is **byte-exact** — a path is written as bytes, so a filename
    that is not valid UTF-8 is still auditable;
  * a tool is pinned to the binary that would actually run, past a version
    manager's shim, which is the failure that made every rival hash identically.

No real corpus, no network, no benchmark tools.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

import provenance


def _corpus(root: Path, files: dict[str, bytes]) -> Path:
    """Write a corpus and its NUL-separated path list; return the list."""
    for name, body in files.items():
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
    listing = root / "paths.list"
    listing.write_bytes(b"\0".join(name.encode() for name in files))
    return listing


class ManifestTests(unittest.TestCase):
    def test_a_stable_corpus_hashes_to_exact_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {"a.txt": b"abc", "sub/b.txt": b"de"})
            corpus = provenance.write_manifest(
                root / "m.tsv", root, listing, allow_dirty=False
            )
            rows = (root / "m.tsv").read_text().splitlines()
        assert (corpus.files, corpus.total, corpus.unstable) == (2, 5, [])
        assert rows[0] == "path\tsize_bytes\tsha256"
        assert [row.split("\t")[:2] for row in rows[1:]] == [["a.txt", "3"], ["sub/b.txt", "2"]]

    def test_rows_are_sorted_regardless_of_walk_order(self) -> None:
        """Walk order is the walker's business; a manifest that changes without the
        corpus changing cannot be diffed, and makes the digest below meaningless."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = root / "paths.list"
            for name in ("b.txt", "a.txt", "c.txt"):
                (root / name).write_bytes(b"x")
            listing.write_bytes(b"c.txt\0a.txt\0b.txt")
            provenance.write_manifest(root / "m.tsv", root, listing, allow_dirty=False)
            rows = (root / "m.tsv").read_text().splitlines()[1:]
        assert [row.split("\t")[0] for row in rows] == ["a.txt", "b.txt", "c.txt"]

    def test_the_corpus_digest_is_the_one_the_recipes_pin(self) -> None:
        """`publish.py` compares this against `corpus.toml`'s `sha256`, and the recipes
        that mint that number define it as sha256(path‖bytes …) in sorted path order
        (`corpus.py: digest_of`, `corpora/ecosystem.sh`). Two definitions of one
        pinned value is a gate that always fails, so compute it here independently."""
        import hashlib

        want = hashlib.sha256()
        for rel, body in (("a.txt", b"abc"), ("sub/b.txt", b"de")):
            want.update(rel.encode())
            want.update(body)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {"sub/b.txt": b"de", "a.txt": b"abc"})
            corpus = provenance.write_manifest(
                root / "m.tsv", root, listing, allow_dirty=False
            )
        assert corpus.sha256 == want.hexdigest()

    def test_a_churned_file_leaves_the_digest_too(self) -> None:
        """A dirty-tree mint must not be able to match a pinned digest: it measured
        a tree that is not the declared corpus, and the digest is how that is caught."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {f"f{i}.txt": b"x" * 8 for i in range(300)})
            whole = provenance.write_manifest(root / "m.tsv", root, listing, allow_dirty=False)
            (root / "f7.txt").unlink()
            churned = provenance.write_manifest(root / "m2.tsv", root, listing, allow_dirty=True)
        assert churned.unstable == ["f7.txt"]
        assert churned.sha256 != whole.sha256

    def test_the_recorded_digest_is_the_files_own(self) -> None:
        """A row is a promise about bytes; the wrong digest is the whole failure."""
        import hashlib

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {"a.txt": b"abc"})
            provenance.write_manifest(root / "m.tsv", root, listing, allow_dirty=False)
            row = (root / "m.tsv").read_text().splitlines()[1]
        assert row.split("\t")[2] == hashlib.sha256(b"abc").hexdigest()

    def test_a_vanished_file_is_fatal_on_a_clean_tree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {"a.txt": b"abc"})
            (root / "a.txt").unlink()
            with self.assertRaises(SystemExit) as caught:
                provenance.write_manifest(root / "m.tsv", root, listing, allow_dirty=False)
        assert "vanished" in str(caught.exception)

    def test_a_vanished_file_is_dropped_and_named_on_a_coworked_tree(self) -> None:
        """~10 agents edit continuously; losing a valid measurement to someone else's rm
        is brittleness, not integrity — but the bundle must say what it dropped."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {f"f{i}.txt": b"x" * 8 for i in range(300)})
            (root / "f7.txt").unlink()
            corpus = provenance.write_manifest(
                root / "m.tsv", root, listing, allow_dirty=True
            )
            rows = (root / "m.tsv").read_text().splitlines()[1:]
        assert corpus.unstable == ["f7.txt"]
        assert corpus.files == 299 and len(rows) == 299
        assert not any(row.startswith("f7.txt\t") for row in rows)

    def test_churn_past_the_ceiling_refuses_the_whole_mint(self) -> None:
        """A partial manifest reads exactly like a complete one, so it must not be written."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = _corpus(root, {f"f{i}.txt": b"x" for i in range(20)})
            for i in range(5):
                (root / f"f{i}.txt").unlink()
            with self.assertRaises(SystemExit) as caught:
                provenance.write_manifest(root / "m.tsv", root, listing, allow_dirty=True)
        assert "churned past the ceiling" in str(caught.exception)
        assert not (root / "m.tsv").exists()

    def test_a_path_holding_a_tab_is_refused_rather_than_written(self) -> None:
        """TSV cannot encode it, so writing the row would silently shift every column."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            listing = root / "paths.list"
            listing.write_bytes(b"we\tird.txt")
            with self.assertRaises(SystemExit) as caught:
                provenance.write_manifest(root / "m.tsv", root, listing, allow_dirty=False)
        assert "control character" in str(caught.exception)

    def test_an_undecodable_filename_is_still_auditable(self) -> None:
        """A tree with one non-UTF-8 name must not take the whole certificate down.

        APFS rejects such a name at creation, so this can only be exercised where
        the filesystem permits it (ext4, xfs) — the emitter writes paths as bytes
        precisely so a Linux mint over a real corpus does not lose one file.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = b"caf\xe9.txt"
            try:
                with open(os.path.join(os.fsencode(root), raw), "wb") as sink:
                    sink.write(b"x")
            except OSError:
                self.skipTest("this filesystem refuses non-UTF-8 filenames")
            listing = root / "paths.list"
            listing.write_bytes(raw)
            corpus = provenance.write_manifest(
                root / "m.tsv", root, listing, allow_dirty=False
            )
            written = (root / "m.tsv").read_bytes()
        assert corpus.files == 1
        assert raw + b"\t1\t" in written


class ToolIdentityTests(unittest.TestCase):
    def test_a_tool_is_pinned_to_the_bytes_that_would_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "faketool"
            binary.write_text("#!/bin/sh\necho 'faketool 1.2.3'\n")
            binary.chmod(0o755)
            line = provenance.tool_identity("faketool", str(binary))
            name, reported, digest = line.split()
            assert digest == f"sha256:{provenance.sha256(binary)}"
        assert name == "faketool"
        assert reported == "1.2.3"

    def test_a_shim_does_not_pass_as_a_pin(self) -> None:
        """A manager's multiplexer keeps its OWN basename after symlinks, so the
        resolver must not accept it as the tool — that is how three rivals once
        recorded one identical digest while each line still read like a pin."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manager = root / "bin" / "mise"
            manager.parent.mkdir()
            manager.write_text("#!/bin/sh\nexit 0\n")
            manager.chmod(0o755)
            shims = root / "shims"
            shims.mkdir()
            (shims / "csearch").symlink_to(manager)
            real = root / "real"
            real.mkdir()
            (real / "csearch").write_text("#!/bin/sh\nexit 0\n")
            (real / "csearch").chmod(0o755)
            previous = os.environ.get("PATH", "")
            os.environ["PATH"] = f"{real}{os.pathsep}{previous}"
            try:
                found = provenance.real_binary(str(shims / "csearch"))
            finally:
                os.environ["PATH"] = previous
            # The resolver returns a realpath, and a macOS temp dir is itself a
            # symlink, so the expectation has to be resolved the same way.
            assert found == os.path.realpath(real / "csearch")

    def test_an_unrunnable_tool_is_refused_rather_than_recorded_as_absent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nope"
            with self.assertRaises(SystemExit) as caught:
                provenance.tool_identity("nope", str(missing))
        assert "no executable identity" in str(caught.exception)


class MachineTests(unittest.TestCase):
    def _record(self, **over) -> dict[str, object]:
        unstable = over.pop("unstable", [])
        base = dict(corpus_id="probe-v1", roots="src bench", runs=20, warmup=3)
        corpus = provenance.Corpus(3, 9, "d" * 64, unstable)
        return provenance.machine(Path("."), corpus=corpus, **(base | over))

    def test_a_clean_mint_omits_the_churn_fields_entirely(self) -> None:
        """An empty churn list and no churn key mean different things to a reader."""
        record = self._record()
        assert "corpus_unstable" not in record and "corpus_unstable_files" not in record

    def test_the_digest_the_publish_gate_reads_is_present(self) -> None:
        """`publish.py` compares `corpus_sha256` against the charter's pin. While
        nothing emitted the key, any charter that pinned a digest failed its own
        mint with `(absent)` — a fail-closed gate reading a field nobody wrote."""
        assert self._record()["corpus_sha256"] == "d" * 64

    def test_a_churned_mint_records_the_count_exactly_and_caps_the_list(self) -> None:
        record = self._record(unstable=[f"f{i}" for i in range(200)])
        assert record["corpus_unstable_files"] == 200
        assert len(record["corpus_unstable"]) == 64

    def test_every_key_the_charter_requires_is_emitted(self) -> None:
        """The gate that consumes this is vendored, so the producer must be too.

        Loaded by path rather than by import: `profile` is a stdlib module name,
        and a package that mints nothing has no guard directory to shadow it with
        — an unqualified import there silently reads the standard library instead
        of failing, which is exactly the shape of pass this test must not give.
        """
        guard = Path(__file__).resolve().parents[1] / "certificate" / "guard" / "profile.py"
        if not guard.is_file():
            self.skipTest("this package mints no certificate, so it declares no charter")
        sys.path.insert(0, str(guard.parent))  # profile.py imports its own `charter`
        self.addCleanup(sys.path.remove, str(guard.parent))
        spec = importlib.util.spec_from_file_location("_cert_profile", guard)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        assert set(module.CHARTER.required_machine_keys) <= set(self._record())

    def test_the_record_round_trips_as_json(self) -> None:
        assert json.loads(json.dumps(self._record()))["corpus_id"] == "probe-v1"

    def test_the_manifest_hashes_the_corpus_while_the_commit_names_the_source(self) -> None:
        """A snapshot corpus is not a checkout, and one --root cannot mean both.

        Hashing relative to the package while the path list is relative to the
        corpus produces a manifest of files nothing searched — and it reads as a
        complete bundle, because every row is a real file with a real digest.
        """
        with tempfile.TemporaryDirectory() as tmp:
            corpus = Path(tmp) / "snapshot"
            listing = _corpus(corpus, {"only-here.txt": b"xyz"})
            source = Path(tmp) / "checkout"
            (source / "pkg").mkdir(parents=True)
            out = Path(tmp) / "bundle"
            code = provenance.main(
                [
                    "--out", str(out),
                    "--root", str(corpus),
                    "--source-root", str(source),
                    "--corpus-id", "probe-v1",
                    "--paths-list", str(listing),
                ]
            )
            assert code == 0
            rows = (out / "corpus-manifest.tsv").read_text().splitlines()
            assert [row.split("\t")[0] for row in rows[1:]] == ["only-here.txt"]
            assert json.loads((out / "machine.json").read_text())["corpus_file_count"] == 1


if __name__ == "__main__":
    unittest.main(verbosity=1)
