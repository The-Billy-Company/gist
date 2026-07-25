"""Behavioral tests for compression retrieval — `recall` / `pack` / `quote`.

These drive the real `relate` binary over a throwaway corpus with its artifact
home redirected into `tmp_path`, so the tests never read or write the developer's
index and `quote` gets a shelf of its own to attribute against.

The oracles are properties the *engine* is claiming, not restatements of its
output: a file that contains the query text must be recalled above one that does
not; `pack` must never pick a near-duplicate of an earlier pick; a quoted phrase
must actually occur in the file it is attributed to.
"""

from __future__ import annotations

from itertools import pairwise
import shutil

import pytest

import irregex
from irregex import retrieval


def _binary_available() -> bool:
    if shutil.which("relate") is not None:
        return True
    try:
        irregex.engine.relate_binary()
    except irregex.GistNotFoundError:
        return False
    return True


needs_relate = pytest.mark.skipif(not _binary_available(), reason="no relate binary")

# One distinctive sentence, planted in exactly one file. Long enough that its
# phrases survive the minimum-phrase floors both verbs apply.
PLANTED = "the wallet ledger reconciles every credit against the stripe charge identifier"


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    """A four-file corpus, plus a private artifact home so nothing global is touched."""
    (tmp_path / "wallet.py").write_text(
        f'"""{PLANTED}."""\n\n\ndef reconcile(ledger, charge_id):\n    return ledger.get(charge_id)\n'
    )
    # A near-copy of wallet.py: `pack` must not spend a pick on it once wallet.py
    # is chosen, because it adds almost no bits the first pick did not.
    (tmp_path / "wallet_copy.py").write_text(
        f'"""{PLANTED}."""\n\n\ndef reconcile(ledger, charge_id):\n    return ledger.get(charge_id)\n'
    )
    (tmp_path / "unrelated.py").write_text(
        "\n".join(f"def render_widget_{i}(canvas):\n    canvas.blit({i})" for i in range(30))
    )
    (tmp_path / "notes.md").write_text("# Notes\n\nA charge identifier is not a ledger entry.\n")
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    return tmp_path


@needs_relate
def test_recall_ranks_the_planting_above_the_unrelated(corpus):
    hits = retrieval.recall(PLANTED, roots=["."], top=4, cwd=corpus)
    assert hits, "expected at least one recalled file"
    ranked = [h.path.removeprefix("./") for h in hits]
    assert ranked[0] in {"wallet.py", "wallet_copy.py"}
    # Coding gain descends, and the file that shares no vocabulary must not
    # outrank the one that contains the sentence verbatim.
    assert all(x.gain >= y.gain for x, y in pairwise(hits))
    if "unrelated.py" in ranked:
        assert ranked.index("unrelated.py") > ranked.index(ranked[0])


@needs_relate
def test_recall_prices_every_row_in_bits(corpus):
    hits = retrieval.recall(PLANTED, roots=["."], top=2, cwd=corpus)
    for hit in hits:
        assert hit.cost_bits > 0.0, "a described file must cost something to describe"
        assert hit.factors + hit.literals > 0, "a parse with no factors and no literals is empty"


@needs_relate
def test_pack_refuses_to_spend_a_pick_on_a_near_duplicate(corpus):
    packed = retrieval.pack(PLANTED, roots=["."], top=4, cwd=corpus)
    picks = [p.removeprefix("./") for p in packed.paths]
    assert picks, "expected a reading set"
    # The whole claim of marginal pricing: both twins can never be worth reading.
    assert not {"wallet.py", "wallet_copy.py"} <= set(picks)
    assert picks[0] in {"wallet.py", "wallet_copy.py"}


@needs_relate
def test_pack_reports_coverage_and_marginal_order(corpus):
    packed = retrieval.pack(PLANTED, roots=["."], top=4, cwd=corpus)
    assert 0.0 <= packed.coverage <= 1.0
    assert len(packed) == len(packed.paths)
    assert [p.rank for p in packed] == sorted(p.rank for p in packed)
    # Coverage is cumulative through each pick, so it can only climb.
    assert all(x.coverage <= y.coverage for x, y in pairwise(packed))
    assert repr(packed).startswith("Packed(")


@needs_relate
def test_pack_reports_foreign_chunks_for_text_the_corpus_never_saw(corpus):
    alien = "quantum flux capacitor recalibration schedule for tuesday afternoons"
    packed = retrieval.pack(alien, roots=["."], top=3, cwd=corpus)
    # The honest verdict: this text is not in this repository. A ranking alone
    # would have handed back three files and said nothing.
    assert packed.foreign > 0


@needs_relate
def test_quote_attributes_phrases_that_really_occur(corpus):
    irregex.atlas_index(shelf=True, cwd=corpus)
    quoted = retrieval.quote(PLANTED, cwd=corpus)
    assert quoted.phrases, "expected the shelf to quote a planted sentence"
    assert quoted.query_bytes == len(PLANTED)
    for phrase in quoted.phrases:
        if not phrase.source:
            continue
        body = (corpus / phrase.source.removeprefix("./")).read_text()
        assert phrase.text in body, f"attributed {phrase.text!r} to a file that lacks it"
    # A sentence lifted verbatim out of the corpus is almost entirely quotable.
    assert quoted.novelty < 0.5
    assert set(quoted.sources) <= {"./wallet.py", "wallet.py", "./wallet_copy.py", "wallet_copy.py"}


@needs_relate
def test_absent_text_costs_far_more_per_byte_than_planted_text(corpus):
    """The load-bearing signal is price, not coverage.

    Any two-character run occurs *somewhere*, so a short unseen string still gets
    partly "quoted" and its `novelty` stays low — which is why the rate matters:
    a corpus that already knows a sentence describes it in a fraction of a bit per
    byte, and one that does not pays close to raw entropy.
    """
    irregex.atlas_index(shelf=True, cwd=corpus)
    known = retrieval.quote(PLANTED, cwd=corpus)
    alien = retrieval.quote("zzqx vlorp thnk gwibble", cwd=corpus)
    assert alien.bits_per_byte > 2 * known.bits_per_byte
    # Bytes the shelf could not quote at all have to be escaped literally.
    assert alien.escapes > known.escapes
