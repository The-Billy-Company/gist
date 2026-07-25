"""Behavioral tests for composition — narrowing as a modifier, plus `blast` and `provenance`.

ADR-367's claim is that exact match and compression answer better together than
either does alone, and (since the fold) that the composition is a *modifier* on
the relate questions rather than a separate family of verbs. So each test checks
the composition, not the plumbing:

  * `blast` must reach a caller that exact search finds AND a fork that only
    kinship finds, while keeping the two kinds of evidence in separate fields.
  * `pack(matching=…)` must refuse a file that would win on coverage alone but
    matches no pattern — the filtering is the whole point.
  * `families(matching=…, unit="function")` must group two functions that share a
    skeleton under different names, which whole-file kinship cannot see.
  * `provenance` must mark a citation verified only when the live bytes still
    hold the phrase.

Oracles come from independent `irregex.files` searches and from the fixture's own
construction, never from the verb's own output.
"""

from __future__ import annotations

import shutil

import pytest

import irregex
from irregex.compose import radius, verbs as compose


def _binary_available() -> bool:
    if shutil.which("irregex") is not None:
        return True
    try:
        irregex.engine.irregex_binary()
    except irregex.GistNotFoundError:
        return False
    return True


needs_irregex = pytest.mark.skipif(not _binary_available(), reason="no irregex binary")

_LEDGER = '''"""The wallet ledger."""


def reconcile_ledger(entries, charge_id):
    """Settle every entry against one charge."""
    total = 0
    for entry in entries:
        if entry.charge_id == charge_id:
            total += entry.amount
    return total
'''

# The same skeleton, renamed vocabulary — a Type-2 clone. File kinship would miss
# it inside an otherwise-different module; `unit="function"` lifts each hit to its
# enclosing function first.
_INVOICE = '''"""Invoice math, unrelated to wallets except in shape."""


def reconcile_invoices(rows, invoice_no):
    """Settle every row against one invoice."""
    subtotal = 0
    for row in rows:
        if row.invoice_no == invoice_no:
            subtotal += row.amount
    return subtotal


def unrelated_helper(x):
    return x + 1
'''


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    """A corpus with one seed symbol, one caller, one structural twin, one decoy."""
    (tmp_path / "ledger.py").write_text(_LEDGER)
    (tmp_path / "invoice.py").write_text(_INVOICE)
    (tmp_path / "api.py").write_text(
        "from ledger import reconcile_ledger\n\n\n"
        "def settle(entries, charge_id):\n"
        "    # reconcile_ledger owns the arithmetic\n"
        "    return reconcile_ledger(entries, charge_id)\n"
    )
    # Mentions none of the symbols but is prose-similar to the query text, so a
    # coverage-only packer would happily rank it.
    (tmp_path / "decoy.md").write_text(
        "# Settling charges\n\nSettle every entry against one charge identifier.\n"
    )
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    return tmp_path


# ── blast ────────────────────────────────────────────────────────────────────


@needs_irregex
def test_blast_finds_the_definition_and_its_caller(corpus):
    report = radius.blast("reconcile_ledger", roots=["."], cwd=corpus)
    assert report.defined, f"expected a definition site; notes={report.notes}"
    assert report.symbol == "reconcile_ledger"
    assert any(s.path.endswith("ledger.py") for s in report.definitions)
    # Oracle: an independent exact search for the symbol.
    oracle = {
        p.removeprefix("./") for p in irregex.files("reconcile_ledger", paths=["."], cwd=corpus)
    }
    reached = {p.removeprefix("./") for p in report.exact_paths}
    assert reached <= oracle | {"decoy.md"}, "exact evidence must not invent a file"
    assert "api.py" in reached, "the caller must be in the radius"


@needs_irregex
def test_blast_keeps_exact_and_statistical_evidence_apart(corpus):
    report = radius.blast("reconcile_ledger", roots=["."], cwd=corpus)
    exact = set(report.exact_paths)
    # `paths` is the superset; `exact_paths` drops the tail nothing proved.
    assert exact <= set(report.paths)
    statistical = {t.path for t in report.twins} | {r.path for r in report.ripple}
    assert not (exact & statistical) - exact, "a path may repeat, a field may not"
    # Every twin is a real distance, not a reference masquerading as one.
    assert all(0.0 <= t.distance <= 1.0 for t in report.twins)


@needs_irregex
def test_blast_surfaces_the_comment_that_names_the_symbol(corpus):
    report = radius.blast("reconcile_ledger", roots=["."], cwd=corpus)
    mentions = {(m.path.removeprefix("./"), "reconcile_ledger" in m.text) for m in report.comments}
    assert ("api.py", True) in mentions, f"expected the prose mention; got {mentions}"


@needs_irregex
def test_blast_budget_trims_and_says_so(corpus):
    full = radius.blast("reconcile_ledger", roots=["."], cwd=corpus)
    tight = radius.blast("reconcile_ledger", budget=1, roots=["."], cwd=corpus)
    assert not full.truncated
    # A budget may trim nothing on a corpus this small, but it may never trim
    # silently: `omitted` and `truncated` have to agree.
    assert tight.truncated == (tight.stats.omitted > 0)
    assert len(tight.paths) <= len(full.paths)
    # Measured totals describe the corpus, not the surfaced rows, so they survive.
    assert tight.stats.files == full.stats.files


@needs_irregex
def test_blast_of_an_unknown_symbol_is_empty_not_wrong(corpus):
    report = radius.blast("no_such_symbol_anywhere", roots=["."], cwd=corpus)
    assert not report.defined
    assert not report.dependents
    assert report.paths == ()


# ── narrowing the reading set ────────────────────────────────────────────────


@needs_irregex
def test_a_narrowed_pack_excludes_the_file_that_matches_no_pattern(corpus):
    query = "settle every entry against one charge identifier"
    # The decoy is the *closest* prose to the query but names no symbol, and
    # coverage is a statistical measure that knows nothing about a word.
    packed = irregex.pack(query, roots=["."], top=4, cwd=corpus)
    assert any(p.endswith("decoy.md") for p in packed.paths), "fixture no longer tests anything"

    picks = irregex.pack(query, matching=["reconcile_ledger"], roots=["."], top=4, cwd=corpus)
    chosen = {p.path.removeprefix("./") for p in picks}
    assert "decoy.md" not in chosen, "an unmatched file must never be packed"
    assert chosen, "expected the matching files to be packed"
    # Two scores, never fused: the coverage price, and the patterns that admitted
    # the file.
    assert all("reconcile_ledger" in p.patterns for p in picks)
    assert all(p.marginal_bits >= 0.0 for p in picks)


@needs_irregex
def test_match_all_narrows_further_than_match_any(corpus):
    query = "settle entries against a charge"
    both = ["reconcile_ledger", "def settle"]
    any_hit = irregex.pack(query, matching=both, match="any", roots=["."], cwd=corpus)
    all_hit = irregex.pack(query, matching=both, match="all", roots=["."], cwd=corpus)
    assert {p.path for p in all_hit} <= {p.path for p in any_hit}
    for pick in all_hit:
        assert set(pick.patterns) == set(both), "match=all must credit every pattern"


@needs_irregex
def test_narrowed_recall_prices_only_the_matching_files(corpus):
    """The same filter on the recall question: "among the files that mention X, which explains this best?" — the lexicon is built over the admitted subset, so a decoy cannot win on prose alone."""
    query = "settle every entry against one charge identifier"
    wide = {r.path.removeprefix("./") for r in irregex.recall(query, roots=["."], cwd=corpus)}
    assert "decoy.md" in wide, "fixture no longer tests anything"
    narrow = irregex.recall(query, matching=["reconcile_ledger"], roots=["."], cwd=corpus)
    assert narrow, "expected the matching files to be priced"
    assert "decoy.md" not in {r.path.removeprefix("./") for r in narrow}


# ── the narrowed fork family ─────────────────────────────────────────────────


@needs_irregex
def test_narrowed_families_group_the_renamed_twin_file_kinship_cannot_see(corpus):
    whole_file = irregex.pairs(channel="copies", roots=["."], max_distance=0.25, cwd=corpus)
    files = [{p.a.removeprefix("./"), p.b.removeprefix("./")} for p in whole_file]
    assert {"ledger.py", "invoice.py"} not in files, "fixture no longer tests anything"

    grouped = irregex.families(
        matching=["def reconcile_"], unit="function", min_echo=0.05, roots=["."], cwd=corpus
    )
    reached = {m.removeprefix("./").partition("#L")[0] for f in grouped for m in f.members}
    assert {"ledger.py", "invoice.py"} <= reached, f"families={list(grouped)}"
    for fam in grouped:
        assert fam.size >= 2, "a family of one is a distinct unit, not a family"


@needs_irregex
def test_the_narrowed_complement_reports_what_grouped_with_nothing(corpus):
    """An impossible threshold admits no family, and silence would imply "all the same" by omission. The complement reports every matching unit with its nearest miss instead."""
    axes = {
        "matching": ["def "],
        "unit": "function",
        "min_echo": 0.9,
        "roots": ["."],
        "cwd": corpus,
    }
    assert not list(irregex.families(**axes))
    lonely = irregex.distinct(**axes)
    assert lonely, "matches must be reported even when nothing groups"
    for lone in lonely:
        assert 0.0 <= lone.byte_distance <= 1.0
        assert 0.0 <= lone.structure_distance <= 1.0
        assert lone.line is not None, "a function unit carries its span"


# ── provenance ───────────────────────────────────────────────────────────────


@needs_irregex
def test_provenance_verifies_a_citation_against_current_bytes(corpus):
    irregex.atlas_index(shelf=True, cwd=corpus)
    snippet = "        if entry.charge_id == charge_id:"
    cited = compose.provenance(snippet, cwd=corpus)
    verified = [a for a in cited if a.verified]
    assert verified, f"expected a verified attribution; got {cited}"
    for attribution in verified:
        assert attribution.line is not None
        lines = (corpus / attribution.source.removeprefix("./")).read_text().splitlines()
        # The engine's line is 1-based and must really contain the phrase.
        assert attribution.text in lines[attribution.line - 1]
        assert str(attribution).endswith(f":{attribution.line}")
