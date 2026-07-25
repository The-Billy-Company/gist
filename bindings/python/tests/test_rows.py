"""The analytic row plane, decoded (ADR-377).

No binary and no library: the plane's contract is `contract/search_api.toml`
lowered into `schema.gen.py`, so every expectation here is read off that table
rather than off a captured answer. Synthesized value arrays stand in for the
`irregex_value` blocks a cursor would hand over, which is the only way to test
absence, an unknown ordinal, and batch boundaries deliberately.

The properties under test are the ones a mis-decode would quietly violate:

  * **absent is not zero** — `distance = 0.0` means *identical*, so a cleared
    presence bit has to arrive as something else entirely;
  * **an unnamed ordinal stays unnamed** — a library ahead of this table must not
    be rounded down to the nearest label it does happen to know;
  * **nested rows recurse** — a quotation carries its phrases;
  * **a drifted schema table is fatal**, because the alternative is a plausible
    lie in every later row;
  * **decoded records outlive the cursor**, since the native rows they came from
    borrow an arena that is freed underneath them.
"""

from __future__ import annotations

import pytest

from irregex.contract import table
from irregex.contract.grades import Grade
from irregex.runtime import cold
from irregex.runtime.analytic import Rows, Stats, rows_of, verify
from irregex.runtime.decode import ABSENT, Row, Unknown, record, row_type
from irregex.runtime.errors import RowDecodeError, SchemaDriftError


def _schema(name: str) -> int:
    sid = table.SCHEMA_ID.get(name)
    if sid is None:  # a contract rename must fail the suite — soft-skip hides drift
        pytest.fail(f"contract has no row schema {name!r}")
    return sid


def _full(name: str, **values: object) -> Row:
    """A row of `name` with every declared field present, defaults filled per tag."""
    blanks: dict[int, object] = {0: "", 1: 0, 2: 0.0, 3: False, 4: 0, 5: (), 6: ()}
    return Row(
        sid := _schema(name),
        tuple(values.get(f.name, blanks[f.tag]) for f in table.fields(sid)),
    )


# ─────────────────────────── absence is not a zero ───────────────────────────


def test_a_cleared_presence_bit_is_absence_not_a_measurement() -> None:
    """`distance = 0.0` is the *identical* verdict, so an unmeasured distance cannot decode as 0.0. `Row.masked` is where the engine's mask becomes that distinction."""
    sid = _schema("similar")
    names = [f.name for f in table.fields(sid)]
    measured = Row.masked(sid, ("a.py", 0.0, 0, 0), present=0b1111)
    unmeasured = Row.masked(sid, ("a.py", 0.0, 0, 0), present=0b0001)

    assert record(measured).distance == 0.0
    assert unmeasured.values[names.index("distance")] is ABSENT


def test_no_absent_optional_field_anywhere_decodes_as_a_measurement() -> None:
    """Swept over every schema the contract declares: an optional field the engine did not measure must arrive as a non-measurement (`None`, or the empty value a collection/published string type uses) — never as a 0, a 0.0, or a label."""
    blanks: dict[int, object] = {0: "", 1: 0, 2: 0.0, 3: False, 4: 0, 5: (), 6: ()}
    swept = 0
    for sid, (name, _fields) in table.SCHEMAS.items():
        spec = table.fields(sid)
        if not any(f.optional for f in spec):
            continue
        swept += 1
        row = Row(sid, tuple(ABSENT if f.optional else blanks[f.tag] for f in spec))
        decoded = record(row)
        for f in (f for f in spec if f.optional):
            value = getattr(decoded, f.name)
            assert value is None or value == () or value == "", (
                f"{name}.{f.name} decoded absence as {value!r}"
            )
    assert swept, "the contract declares no optional fields — this property moved"


def test_an_absent_required_field_is_a_loud_decode_failure() -> None:
    """A mask that clears a required field contradicts the contract; guessing a value there would be the mis-decode this plane exists to prevent."""
    sid = _schema("similar")
    with pytest.raises(RowDecodeError, match="presence mask contradicts"):
        record(Row.masked(sid, ("a.py", 0.25, 0, 0), present=0b0000))


def test_a_row_of_the_wrong_width_never_decodes() -> None:
    """Values are read positionally, so a width disagreement means every field after it would be read out of the wrong slot."""
    sid = _schema("similar")
    with pytest.raises(RowDecodeError, match="declares"):
        record(Row(sid, ("a.py", 0.25)))


# ─────────────────────────── enums ───────────────────────────


def test_an_enum_ordinal_resolves_through_the_contract_table() -> None:
    """Ordinals are the contract's declaration order — the label is never inferred from the value's position in some other list."""
    sid = _schema("similar")
    labels = table.ENUMS["grade"]
    fields = [f.name for f in table.fields(sid)]
    idx = fields.index("grade")
    for ordinal, label in enumerate(labels):
        values = ["a.py", 0.25, 0, 0]
        values[idx] = ordinal
        assert record(Row(sid, tuple(values))).grade == label


def test_the_calibrated_types_carry_the_contract_labels() -> None:
    """A decoded grade is comparable (`meets`), which is only sound if this side's enum spells the contract's labels exactly."""
    assert {g.value for g in Grade} == set(table.ENUMS["grade"])


def test_an_ordinal_this_table_does_not_name_stays_unknown() -> None:
    """A newer library may name a variant this generated table does not. Rounding it to a known label would invent a verdict; `Unknown` keeps the gap visible and refuses every floor."""
    sid = _schema("similar")
    fields = [f.name for f in table.fields(sid)]
    values: list[object] = ["a.py", 0.25, 0, 0]
    values[fields.index("grade")] = len(table.ENUMS["grade"])  # one past the last
    decoded = record(Row(sid, tuple(values)))

    assert isinstance(decoded.grade, Unknown)
    assert decoded.grade.ordinal == len(table.ENUMS["grade"])
    assert not decoded.grade.meets("weak"), "an unnamed grade cannot clear a floor"
    assert str(decoded.grade) == f"grade#{len(table.ENUMS['grade'])}"


# ─────────────────────────── nesting ───────────────────────────


def test_a_nested_rows_field_decodes_its_own_schema() -> None:
    """`quotation.phrases` is declared as rows of another schema; the decoder must recurse into that schema rather than hand back the raw block."""
    quotation, phrase = _schema("quotation"), _schema("phrase")
    nested = [f for f in table.fields(quotation) if f.tag is table.Tag.ROWS]
    assert nested, "quotation must declare a nested rows field"
    assert nested[0].nested == phrase

    row = _full(
        "quotation",
        bits=12.0,
        query_bytes=10,
        quoted_bytes=8,
        phrases=[_full("phrase", text="std.posix", occurrences=3, bits=4.0, source="a.zig")],
    )
    decoded = record(row)
    assert [p.text for p in decoded.phrases] == ["std.posix"]
    assert type(decoded.phrases[0]).__name__ == "Phrase"


def test_every_schema_in_the_contract_decodes() -> None:
    """A schema nobody has wired yet still has to decode — the table is the contract, not a list of the verbs this binding happens to call today."""
    for sid, (name, _fields) in table.SCHEMAS.items():
        decoded = record(_full(name))
        assert type(decoded) is row_type(sid)


def test_every_verb_names_a_schema_that_exists() -> None:
    for verb, (_op, _family, sid, _many) in table.VERBS.items():
        assert sid in table.SCHEMAS, f"{verb} names row schema {sid}, which the table lacks"


# ─────────────────────────── batching + borrow semantics ───────────────────────────


def _counted(sid: int, n: int) -> tuple[Rows, list[int]]:
    """`n` rows behind a pull that records the size of every request it served."""
    pending = [_full(table.schema_name(sid), path=f"f{i}.py", rank=i) for i in range(n)]
    seen: list[int] = []

    def pull(cap: int) -> list[Row]:
        seen.append(cap)
        taken, pending[:cap] = pending[:cap], []
        return taken

    return Rows(pull, lambda: Stats(source="test", rows=n)), seen


def test_batches_pull_at_the_requested_width() -> None:
    """The batch API exists to trade call overhead for a wider window, so the width has to reach the transport rather than being re-chunked in Python."""
    rows, seen = _counted(_schema("pick"), 7)
    sizes = [len(batch) for batch in rows.batches(3)]
    assert sizes == [3, 3, 1]
    assert seen[:3] == [3, 3, 3]


def test_iteration_is_lazy_and_ends_without_a_trailing_pull() -> None:
    rows, seen = _counted(_schema("pick"), 2)
    it = iter(rows)
    next(it)
    assert seen == [1], "a single record must not have drained the stream"
    assert len(list(it)) == 1


def test_batch_size_must_be_positive() -> None:
    rows, _ = _counted(_schema("pick"), 1)
    with pytest.raises(ValueError, match="batch size"):
        next(rows.batches(0))


def test_records_outlive_the_cursor_they_came_from() -> None:
    """Native rows borrow the cursor arena and die at the next pull, so the decoder must materialize before yielding: a record read after close is still readable."""
    rows, _ = _counted(_schema("pick"), 3)
    kept = rows.drain()
    assert rows.closed
    assert [k.path for k in kept] == ["f0.py", "f1.py", "f2.py"]


def test_draining_closes_and_freezes_the_stats() -> None:
    """Stats live in the arena the cursor frees, so they are snapshotted at close — reading them afterwards must not reach back into freed memory."""
    counter = iter((Stats(source="a", rows=1), Stats(source="b", rows=99)))
    rows = Rows(lambda cap: [], lambda: next(counter))
    rows.drain()
    assert rows.stats.source == "a"
    assert rows.stats.source == "a", "stats must be a snapshot, not a re-read"


def test_stats_carry_the_facts_no_row_can() -> None:
    """`foreign` separates "your text is not in this corpus" from "no results", and `omitted` says a budget truncated the answer. Dropping either turns an honest empty answer into a mystery."""
    stats = Stats(source="native", foreign=12, omitted=3, rows=0)
    assert (stats.foreign, stats.omitted) == (12, 3)
    assert not rows_of((), stats).drain()


# ─────────────────────────── the subprocess tier lifts the same rows ───────────────────────────


def test_a_missing_json_key_is_absence_not_zero() -> None:
    """The fallback tier reconstructs the presence mask from which keys an object carries, or `distance = 0.0` would read as *identical* on that tier alone."""
    sid = _schema("similar")
    names = [f.name for f in table.fields(sid)]
    (lifted,) = cold.rows(sid, [{"path": "a.py"}])
    assert lifted.values[names.index("distance")] is ABSENT


def test_a_missing_json_collection_reads_as_empty() -> None:
    """JSON cannot say "unmeasured list": `pack` prints no `patterns` because nothing narrowed the pick, and empty is the true reading."""
    sid = _schema("pick")
    (lifted,) = cold.rows(sid, [{"rank": 1, "path": "a.py", "marginal_bits": 1.0, "coverage": 0.5}])
    assert record(lifted).patterns == ()


def test_an_unmodelled_json_label_surfaces_as_unknown() -> None:
    """Same treatment as a newer library's ordinal: the wire's unknown label must not be silently dropped or mapped to a neighbor."""
    sid = _schema("similar")
    (lifted,) = cold.rows(
        sid, [{"path": "a.py", "distance": 0.1, "grade": "transcendent", "channel": "copies"}]
    )
    assert isinstance(record(lifted).grade, Unknown)


def test_the_cli_spelling_map_only_renames() -> None:
    """Every entry in the fallback tier's key map must name a real (schema, field) pair — a stale rename would silently read absence forever."""
    for (schema, field), key in cold._KEYS.items():
        sid = _schema(schema)
        assert field in {f.name for f in table.fields(sid)}, f"{schema}.{field} left the contract"
        assert key != field, f"{schema}.{field} maps to itself"


# ─────────────────────────── digest ───────────────────────────


class _Fake:
    """The two symbols the digest check needs, with a library digest of our choosing."""

    def __init__(self, digest: str) -> None:
        self._digest = digest.encode()

    def irregex_schema_digest(self) -> bytes:
        return self._digest


class _FakeFFI:
    @staticmethod
    def string(raw: bytes) -> bytes:
        return raw


def test_the_handshake_accepts_only_byte_equality() -> None:
    """The digest gates every native decode, so agreement must be exact: the generated fingerprint passes silently, and perturbing one character of it does not (a prefix or length comparison would let a drifted table through)."""
    assert verify(_FakeFFI(), _Fake(table.DIGEST)) is None, (
        "agreement is silent — no news is the pass"
    )
    tail = "0" if table.DIGEST[-1] != "0" else "1"
    with pytest.raises(SchemaDriftError):
        verify(_FakeFFI(), _Fake(table.DIGEST[:-1] + tail))


def test_a_drifted_digest_is_a_named_failure() -> None:
    """A digest mismatch means every row would decode into a plausible lie — a distance read out of a grade's slot — so it can never be a warning."""
    with pytest.raises(SchemaDriftError) as caught:
        verify(_FakeFFI(), _Fake("0" * len(table.DIGEST)))
    message = str(caught.value)
    assert table.DIGEST in message
    assert "make gen" in message, "the failure must say how to reconcile the two sides"


def test_the_digest_is_pinned_by_the_generated_table() -> None:
    """The digest is the contract's fingerprint; a hand-edited table would be exactly the drift the check catches."""
    assert len(table.DIGEST) == 32, "the contract's digest is a 128-bit hex fingerprint"
    assert set(table.DIGEST) <= set("0123456789abcdef"), "lowercase hex, as the generator writes it"
