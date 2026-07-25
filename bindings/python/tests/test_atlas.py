"""The compression tier's lifecycle — `atlas_status` / `atlas_index`.

Warmth is an optimization, never a dependency: every kinship verb answers
correctly with no artifact at all. What a *program* needs on top of that is the
ability to see the tier and decide once — build before a batch of queries, or
preflight the shelf that `quote`/`provenance` genuinely require.

So the claims under test are: the report decodes truthfully (including the
missing-artifact case, where `relate status` exits 1 and that is a report rather
than a failure), a build makes the atlas ready, and warm answers equal cold ones.
"""

from __future__ import annotations

import shutil

import pytest

import irregex
from irregex.index.lifecycle import IndexState, parse_atlas_status


def _binary_available() -> bool:
    if shutil.which("relate") is not None:
        return True
    try:
        irregex.engine.relate_binary()
    except irregex.GistNotFoundError:
        return False
    return True


needs_relate = pytest.mark.skipif(not _binary_available(), reason="no relate binary")


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    """A small corpus with a private artifact home, so no global state is touched."""
    body = "\n".join(f"def step_{i}(ctx):\n    return ctx.advance({i})" for i in range(20))
    (tmp_path / "a.py").write_text(body)
    (tmp_path / "b.py").write_text(body.replace("advance", "retreat"))
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    return tmp_path


def test_parse_reports_each_artifact_independently() -> None:
    """Three artifacts, three states — a ready atlas says nothing about the shelf."""
    status = parse_atlas_status(
        '{"schema_version":1,'
        '"atlas":{"state":"ready","files":20242,"bytes":63478837,'
        '"stale_files":4550,"built_unix_ns":1784522595557546000},'
        '"frag":{"state":"ready","fragments":165698,"bytes":35047225,'
        '"stale_files":4550,"built_unix_ns":1784522595557546000},'
        '"shelf":{"state":"unavailable","bytes":0}}'
    )
    assert status.ready, "a ready atlas is what makes kinship warm"
    assert not status.can_quote, "no shelf means quotation is unavailable, not slow"
    assert status.atlas.files == 20242
    assert status.atlas.staleness == pytest.approx(4550 / 20242)
    assert status.fragments.fragments == 165698
    assert status.atlas.age_seconds is not None
    assert status.atlas.age_seconds > 0


def test_an_artifact_without_a_file_population_declines_to_invent_a_ratio() -> None:
    """The shelf counts bytes and the fragment index counts fragments, so neither can express staleness as a share of files. `stale_files` stays the raw truth."""
    status = parse_atlas_status(
        '{"schema_version":1,"frag":{"state":"ready","fragments":9,"stale_files":4}}'
    )
    assert status.fragments.staleness is None
    assert status.fragments.stale_files == 4
    # An absent section is unavailable rather than a crash.
    assert status.atlas.state is IndexState.UNAVAILABLE
    assert status.atlas.age_seconds is None
    assert not status.ready


@needs_relate
def test_a_missing_atlas_is_a_report_not_a_failure(corpus) -> None:
    before = irregex.atlas_status(cwd=corpus)
    assert not before.ready
    assert before.atlas.state is IndexState.UNAVAILABLE
    # And the verbs still answer, live, with no artifact whatsoever.
    cold = irregex.similar("a.py", roots=["."], top=2, cwd=corpus)
    assert cold, "kinship must never depend on the warm tier"
    assert not cold.warm


@needs_relate
def test_building_the_atlas_makes_kinship_warm_without_changing_it(corpus) -> None:
    cold = irregex.similar("a.py", roots=["."], top=2, cwd=corpus)
    after = irregex.atlas_index(cwd=corpus)
    assert after.ready
    assert after.atlas.files > 0
    assert after.atlas.stale_files == 0, "a fresh build has nothing to fold in"

    warm = irregex.similar("a.py", roots=["."], top=2, cwd=corpus)
    # The whole promise of the tier: identical answers, cheaper.
    assert [(r.path, r.distance, r.grade) for r in warm] == [
        (r.path, r.distance, r.grade) for r in cold
    ]


@needs_relate
def test_the_shelf_is_opt_in_and_gates_quotation(corpus) -> None:
    plain = irregex.atlas_index(cwd=corpus)
    assert plain.ready
    with_shelf = irregex.atlas_index(shelf=True, cwd=corpus)
    assert with_shelf.can_quote, "--shelf is the only way quotation becomes available"
    assert with_shelf.shelf.bytes > 0
    quoted = irregex.quote("return ctx.advance(3)", cwd=corpus)
    assert quoted.phrases, "a shelf built over this corpus must quote its own text"
