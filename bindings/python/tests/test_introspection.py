"""Typed lifecycle and capability introspection."""

from __future__ import annotations

import shutil

import pytest

import irregex
from irregex.introspection import IndexState, IndexStatus, parse_status


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        irregex.binary()
    except irregex.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")


def test_parse_status_returns_every_structured_field() -> None:
    report = """{"schema_version":1,"state":"ready","index":{"path":".local/gist-verify/index.gist","paths_file":".local/gist-verify/paths.list","files_indexed":28194,"distinct_trigrams":518707,"postings":35129882,"index_bytes":44564480,"paths_bytes":1677722},"freshness":{"anchor_unix_ns":1234,"age_seconds":96.0},"roots":["services","libs","clients"]}"""
    assert parse_status(report) == IndexStatus(
        schema_version=1,
        state=IndexState.READY,
        path=".local/gist-verify/index.gist",
        paths_file=".local/gist-verify/paths.list",
        files=28194,
        trigrams=518707,
        postings=35129882,
        index_bytes=44564480,
        paths_bytes=1677722,
        anchor_unix_ns=1234,
        age_seconds=96.0,
        roots=("services", "libs", "clients"),
    )
    unavailable = parse_status(
        '{"schema_version":1,"state":"unavailable","index":null,'
        '"freshness":{"anchor_unix_ns":null,"age_seconds":null},"roots":["libs"]}'
    )
    assert not unavailable.ready
    assert unavailable.path is None


@needs_gist
def test_capability_schema_is_typed_and_queryable() -> None:
    schema = irregex.capabilities()
    assert schema.tool == "gist"
    assert schema.version == irregex.version()
    assert schema.supports("-P")
    assert schema.supports("--multiline")
    assert schema.supports("--no-unicode")
    assert schema.compatibility("--definitely-unknown") is None
    assert irregex.schema() == schema


@needs_gist
def test_index_lifecycle_returns_observed_status(tmp_path) -> None:
    (tmp_path / "libs").mkdir()
    (tmp_path / "libs" / "sample.py").write_text("needle\n")
    assert not irregex.status(cwd=tmp_path).ready
    state = irregex.index(cwd=tmp_path)
    assert state.ready
    assert state.files == 1
    assert state.freshness_anchor
    # No tree layout is assumed: a bare `gist index` resolves to `.` (the
    # whole tree) unless GIST_ROOTS or positional roots say otherwise.
    assert state.roots == (".",)
    assert irregex.status(cwd=tmp_path).path == state.path
