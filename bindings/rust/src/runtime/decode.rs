//! The one analytic row decoder (ADR-377), driven by the generated schema table.
//!
//! Seventeen verbs return the same self-describing row, so there is exactly one
//! decoder here rather than seventeen result structs drifting independently.
//! It walks `SCHEMAS[schema_id - 1]` *positionally* over the value array, which
//! is what makes a verb that reuses an existing schema cost zero new code.
//!
//! Three properties the row model exists to preserve:
//!
//! * **Absent is not zero.** `distance = 0.0` means *identical*, so a cleared
//!   presence bit becomes `None`, never a sentinel.
//! * **Unknown stays unknown.** `[row_enums]` is append-only; an ordinal past
//!   this build's table is carried verbatim in a [`Variant`] whose `name()` is
//!   `None`, rather than clamped to the nearest variant we happen to know.
//! * **A row that exists is valid.** Construction runs the recursive check in
//!   [`super::verify`], so every accessor below is infallible.
//!
//! # Lifetimes
//!
//! A [`Row`] is a borrowed view: it holds the row header by value (four words)
//! and a `PhantomData` tying it to the arena its texts and nested rows live in.
//! For a native answer that arena is the `irregex_rows` cursor, which the C ABI
//! guarantees stays valid until close — so batches may be held alongside each
//! other without copying. [`Row::to_owned`] is the explicit exit from the
//! borrow into an [`OwnedRow`] that outlives the cursor.

use std::marker::PhantomData;

use super::cell::{OwnedRow, OwnedValue, RowSeq, Texts, Value, borrow, read};
use super::{Result, sys};
use crate::contract::Variant;
use crate::contract::schema::{FieldDef, SCHEMAS, SchemaDef};

/// The declared schema for a wire id, or `None` for one this build predates.
#[must_use]
pub fn schema_for(id: u32) -> Option<&'static SchemaDef> {
    SCHEMAS.get(usize::try_from(id).ok()?.checked_sub(1)?)
}

/// One analytic result row, borrowed from the arena it was materialized into.
///
/// The row is four words plus a lifetime marker, so it is [`Copy`] and cheap to
/// pass around; everything it points at lives in the arena, which is why the
/// lifetime is not decorative.
#[derive(Debug, Clone, Copy)]
pub struct Row<'a> {
    schema: &'static SchemaDef,
    cells: Cells<'a>,
}

#[derive(Debug, Clone, Copy)]
enum Cells<'a> {
    /// A native answer: the raw value array plus the presence mask.
    Wire {
        present: u64,
        values: *const sys::Value,
        nvalues: usize,
        arena: PhantomData<&'a ()>,
    },
    /// A subprocess answer, already lowered into owned cells.
    Owned(&'a [Option<OwnedValue>]),
}

impl<'a> Row<'a> {
    /// Decode and validate one wire row.
    ///
    /// # Errors
    /// [`super::Error::Decode`] for an unknown `schema_id`, a value whose tag
    /// disagrees with its declaration, or text that is not UTF-8 — each named
    /// with the schema and field so a drift is diagnosable, never silent.
    ///
    /// # Safety
    /// `raw` and everything it points at must be valid for `'a`.
    pub(crate) unsafe fn from_wire(raw: &sys::Row) -> Result<Self> {
        let row = Self::wire_unchecked(raw);
        row.validate()?;
        Ok(row)
    }

    /// The same view without the check — for a row whose parent already
    /// validated it recursively.
    pub(super) fn wire_unchecked(raw: &sys::Row) -> Self {
        Self {
            // A row past this build's table validates as unknown before any
            // accessor runs; the placeholder keeps the type total meanwhile.
            schema: schema_for(raw.schema_id).unwrap_or(UNKNOWN_SCHEMA),
            cells: Cells::Wire {
                present: raw.present,
                values: raw.values,
                nvalues: raw.nvalues as usize,
                arena: PhantomData,
            },
        }
    }

    /// Borrow already-owned cells through the wire accessors. `None` when the
    /// id names a schema this build does not declare.
    pub(super) fn over(schema_id: u32, cells: &'a [Option<OwnedValue>]) -> Option<Self> {
        Some(Self {
            schema: schema_for(schema_id)?,
            cells: Cells::Owned(cells),
        })
    }

    /// The wire mask, pointer, and arity — `None` for an owned row, whose cells
    /// were validated positionally when they were built.
    pub(super) fn wire_cells(self) -> Option<(u64, *const sys::Value, usize)> {
        match self.cells {
            Cells::Wire {
                present,
                values,
                nvalues,
                ..
            } => Some((present, values, nvalues)),
            Cells::Owned(_) => None,
        }
    }

    /// The `[row_schemas]` id this row was decoded against.
    #[must_use]
    pub fn schema_id(self) -> u32 {
        self.schema.id
    }

    /// The `[row_schemas]` key (`"similar"`, `"blast"`, …).
    #[must_use]
    pub fn schema_name(self) -> &'static str {
        self.schema.name
    }

    /// The declared field list, in wire order.
    #[must_use]
    pub fn fields(self) -> &'static [FieldDef] {
        self.schema.fields
    }

    /// The value of declared field `i`, or `None` when the presence mask says
    /// it is absent (which is *not* the same as zero).
    #[must_use]
    pub fn get(self, i: usize) -> Option<Value<'a>> {
        let field = self.schema.fields.get(i)?;
        match self.cells {
            Cells::Wire {
                present,
                values,
                nvalues,
                ..
            } => {
                if i >= nvalues || present & (1u64 << i) == 0 {
                    return None;
                }
                Some(read(field, unsafe { &*values.add(i) }))
            },
            Cells::Owned(cells) => cells.get(i)?.as_ref().map(borrow),
        }
    }

    /// The value of the declared field named `name`.
    #[must_use]
    pub fn field(self, name: &str) -> Option<Value<'a>> {
        let i = self.schema.fields.iter().position(|f| f.name == name)?;
        self.get(i)
    }

    /// Field `name` as text.
    #[must_use]
    pub fn text(self, name: &str) -> Option<&'a str> {
        self.field(name)?.as_str()
    }

    /// Field `name` as an integer.
    #[must_use]
    pub fn int(self, name: &str) -> Option<i64> {
        self.field(name)?.as_i64()
    }

    /// Field `name` as a real.
    #[must_use]
    pub fn real(self, name: &str) -> Option<f64> {
        self.field(name)?.as_f64()
    }

    /// Field `name` as a boolean.
    #[must_use]
    pub fn flag(self, name: &str) -> Option<bool> {
        self.field(name)?.as_bool()
    }

    /// Field `name` as an enum ordinal (unresolved — see [`Variant::name`]).
    #[must_use]
    pub fn variant(self, name: &str) -> Option<Variant> {
        self.field(name)?.as_variant()
    }

    /// Field `name` as a string list.
    #[must_use]
    pub fn texts(self, name: &str) -> Option<Texts<'a>> {
        self.field(name)?.as_texts()
    }

    /// Field `name` as nested rows.
    #[must_use]
    pub fn rows(self, name: &str) -> Option<RowSeq<'a>> {
        self.field(name)?.as_rows()
    }

    /// Iterate `(declared name, value)` for every present field.
    pub fn iter(self) -> impl Iterator<Item = (&'static str, Value<'a>)> {
        self.schema
            .fields
            .iter()
            .enumerate()
            .filter_map(move |(i, f)| self.get(i).map(|v| (f.name, v)))
    }

    /// Copy the row out of the arena so it can outlive the cursor.
    #[must_use]
    pub fn to_owned(self) -> OwnedRow {
        OwnedRow {
            schema_id: self.schema.id,
            values: (0..self.schema.fields.len())
                .map(|i| self.get(i).map(Value::to_owned))
                .collect(),
        }
    }
}

/// Stand-in for a row whose schema this build predates; validation rejects it
/// before any accessor can read a field it cannot name.
static UNKNOWN_SCHEMA: &SchemaDef = &SchemaDef {
    id: 0,
    name: "unknown",
    fields: &[],
};

#[cfg(test)]
mod tests {
    //! Expectations come from the contract — `SCHEMAS`, `ENUMS`, and the field
    //! positions read out of them — never from a run of this decoder.

    use super::super::fixture::{
        self, all, enumeration, field_at, int, real, row, schema_id, text,
    };
    use super::*;
    use crate::contract::{Channel, Grade};

    #[test]
    fn absent_is_not_zero() {
        // `similar.distance` is 0.0 for a byte-identical file, so the decoder
        // must distinguish "no distance reported" from "distance is zero" — the
        // single reason the presence mask exists.
        let id = schema_id("similar");
        let d = field_at(id, "distance");
        let values = [text("a.rs"), real(0.0), enumeration(0), enumeration(0)];

        let full = unsafe { Row::from_wire(&row(id, all(values.len()), &values)) };
        assert_eq!(full.expect("valid row").real("distance"), Some(0.0));

        let masked = unsafe { Row::from_wire(&row(id, all(values.len()) & !(1 << d), &values)) }
            .expect("valid row");
        assert_eq!(masked.real("distance"), None);
        // Absence is per field: the neighbors still read.
        assert_eq!(masked.text("path"), Some("a.rs"));
    }

    #[test]
    fn unknown_enum_ordinal_stays_unknown() {
        // `[row_enums]` is append-only, so a newer engine can report an ordinal
        // past this build's table. It must survive verbatim rather than being
        // clamped to the nearest variant we happen to know.
        let id = schema_id("similar");
        let beyond = i64::try_from(Grade::ALL.len()).unwrap_or(i64::MAX) + 3;
        let values = [text("a.rs"), real(0.5), enumeration(beyond), enumeration(0)];
        let decoded =
            unsafe { Row::from_wire(&row(id, all(values.len()), &values)) }.expect("valid row");

        let grade = decoded.variant("grade").expect("present");
        assert_eq!(grade.ordinal, beyond);
        assert_eq!(grade.name(), None, "an unnameable ordinal is not guessable");
        assert_eq!(Grade::from_variant(grade), None);
        assert_eq!(grade.to_string(), format!("grade?{beyond}"));
        // The neighboring enum, in range, still resolves.
        assert_eq!(
            decoded.variant("channel").and_then(Channel::from_variant),
            Some(Channel::Copies)
        );
    }

    #[test]
    fn an_enum_resolves_against_its_own_vocabulary_not_its_position() {
        // `similar` carries two enums back to back; reading either against the
        // other's table would silently mislabel every kinship row.
        let id = schema_id("similar");
        let values = [text("a.rs"), real(0.0), enumeration(3), enumeration(1)];
        let decoded = unsafe { Row::from_wire(&row(id, all(4), &values)) }.expect("valid row");
        assert_eq!(
            decoded.variant("grade").and_then(Grade::from_variant),
            Some(Grade::Strong)
        );
        assert_eq!(
            decoded.variant("channel").and_then(Channel::from_variant),
            Some(Channel::Twins)
        );
        // A grade ordinal read as a channel is refused, not coerced.
        let grade = decoded.variant("grade").expect("present");
        assert_eq!(Channel::from_variant(grade), None);
    }

    #[test]
    fn nested_rows_recurse_and_carry_their_own_mask() {
        let region = schema_id("region");
        let family = schema_id("family");
        let head = field_at(region, "headline");

        let member_values = [text("a.rs"), int(10), int(20), text("fn a")];
        let members = [
            row(region, all(member_values.len()), &member_values),
            // The second member withholds the optional headline.
            row(
                region,
                all(member_values.len()) & !(1 << head),
                &member_values,
            ),
        ];
        let values = [
            int(1),
            enumeration(0),
            enumeration(0),
            real(0.2),
            int(80),
            real(0.9),
            fixture::rows(&members),
        ];
        let decoded =
            unsafe { Row::from_wire(&row(family, all(values.len()), &values)) }.expect("valid row");

        let nested = decoded.rows("members").expect("members present");
        assert_eq!(nested.len(), 2);
        let first = nested.get(0).expect("first member");
        assert_eq!(first.schema_name(), "region");
        assert_eq!(first.text("path"), Some("a.rs"));
        assert_eq!(first.int("line_start"), Some(10));
        assert_eq!(first.text("headline"), Some("fn a"));
        assert_eq!(
            nested.get(1).and_then(|r| r.text("headline")),
            None,
            "the nested presence mask is honored per nested row"
        );
    }

    #[test]
    fn a_string_list_reads_as_many_borrowed_strs() {
        let id = schema_id("cluster");
        let paths = [
            sys::Text {
                ptr: "a.rs".as_ptr(),
                len: 4,
            },
            sys::Text {
                ptr: "b.rs".as_ptr(),
                len: 4,
            },
        ];
        let values = [fixture::texts(&paths), real(0.1), enumeration(3)];
        let decoded = unsafe { Row::from_wire(&row(id, all(3), &values)) }.expect("valid row");
        let list = decoded.texts("paths").expect("paths present");
        assert_eq!(list.len(), 2);
        assert_eq!(list.iter().collect::<Vec<_>>(), ["a.rs", "b.rs"]);
    }

    #[test]
    fn a_short_value_array_reads_as_absent_rather_than_out_of_bounds() {
        // An older engine may stop short of a field a newer contract appends.
        // Only the overlap is ours to read, and the tail is absent, not zero.
        let id = schema_id("similar");
        let values = [text("a.rs"), real(0.25)];
        let decoded =
            unsafe { Row::from_wire(&row(id, all(4), &values)) }.expect("a prefix is decodable");
        assert_eq!(decoded.real("distance"), Some(0.25));
        assert_eq!(decoded.variant("grade"), None);
    }

    #[test]
    fn iter_yields_exactly_the_present_fields_in_declared_order() {
        let id = schema_id("similar");
        let values = [text("a.rs"), real(0.25), enumeration(3), enumeration(0)];
        let decoded = unsafe { Row::from_wire(&row(id, 0b0101, &values)) }.expect("valid row");
        let names: Vec<&str> = decoded.iter().map(|(n, _)| n).collect();
        assert_eq!(names, ["path", "grade"]);
    }

    #[test]
    fn owned_rows_read_through_the_same_accessors() {
        let id = schema_id("similar");
        let values = [text("a.rs"), real(0.0), enumeration(3), enumeration(1)];
        let borrowed = unsafe { Row::from_wire(&row(id, 0b1111, &values)) }.expect("valid row");
        let owned = borrowed.to_owned();
        let view = owned.view().expect("known schema");
        assert_eq!(view.text("path"), borrowed.text("path"));
        assert_eq!(view.real("distance"), Some(0.0));
        assert_eq!(
            view.variant("grade").and_then(Grade::from_variant),
            Some(Grade::Strong)
        );
    }

    #[test]
    fn an_owned_row_keeps_absence_through_the_round_trip() {
        let id = schema_id("similar");
        let d = field_at(id, "distance");
        let values = [text("a.rs"), real(0.0), enumeration(0), enumeration(0)];
        let borrowed = unsafe { Row::from_wire(&row(id, all(values.len()) & !(1 << d), &values)) }
            .expect("valid row");
        let owned = borrowed.to_owned();
        assert_eq!(owned.values[d], None);
        assert_eq!(owned.view().and_then(|v| v.real("distance")), None);
    }

    #[test]
    fn owning_a_nested_row_copies_the_whole_tree() {
        let region = schema_id("region");
        let family = schema_id("family");
        let member_values = [text("a.rs"), int(10), int(20), text("fn a")];
        let members = [row(region, all(member_values.len()), &member_values)];
        let values = [
            int(1),
            enumeration(0),
            enumeration(0),
            real(0.2),
            int(80),
            real(0.9),
            fixture::rows(&members),
        ];
        let owned = unsafe { Row::from_wire(&row(family, all(values.len()), &values)) }
            .expect("valid row")
            .to_owned();
        let nested = owned
            .view()
            .and_then(|r| r.rows("members"))
            .expect("members survive the copy");
        assert_eq!(nested.get(0).and_then(|r| r.text("headline")), Some("fn a"));
    }
}
