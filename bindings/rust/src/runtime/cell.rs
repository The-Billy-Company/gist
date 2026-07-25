//! The value model a row is made of — the same seven shapes in a borrowed and
//! an owned form.
//!
//! Both transports converge here. A native answer hands out [`Value`]s pointing
//! into the cursor's arena; the subprocess tier lowers CLI JSON into
//! [`OwnedValue`]s and hands out [`Value`]s pointing at *those*. A [`Row`] reads
//! either through one set of accessors, which is the whole reason a caller never
//! learns which tier answered.

use super::decode::{Row, schema_for};
use super::sys;
use crate::contract::Variant;

// ── borrowed ───────────────────────────────────────────────────────────────

/// One decoded field value, borrowed from whatever produced it.
#[derive(Debug, Clone, Copy)]
pub enum Value<'a> {
    /// UTF-8 text (`path`, `headline`, `symbol`, …).
    Text(&'a str),
    /// A signed integer (`line`, `occurrences`, `omitted`, …).
    Int(i64),
    /// A real (`distance`, `bits`, `coverage`, …).
    Real(f64),
    /// A boolean (`verified`, `defines`).
    Bool(bool),
    /// A closed-vocabulary ordinal, resolvable through [`Variant::name`].
    Enum(Variant),
    /// A string list (`paths`, `notes`, `patterns`).
    Texts(Texts<'a>),
    /// A nested row slice (`members`, `phrases`, `dependents`, …).
    Rows(RowSeq<'a>),
}

impl<'a> Value<'a> {
    /// The text, or `None` for any other tag.
    #[must_use]
    pub fn as_str(self) -> Option<&'a str> {
        match self {
            Self::Text(s) => Some(s),
            _ => None,
        }
    }

    /// The integer, or `None` for any other tag.
    #[must_use]
    pub fn as_i64(self) -> Option<i64> {
        match self {
            Self::Int(v) => Some(v),
            _ => None,
        }
    }

    /// The real, or `None` for any other tag.
    #[must_use]
    pub fn as_f64(self) -> Option<f64> {
        match self {
            Self::Real(v) => Some(v),
            _ => None,
        }
    }

    /// The boolean, or `None` for any other tag.
    #[must_use]
    pub fn as_bool(self) -> Option<bool> {
        match self {
            Self::Bool(v) => Some(v),
            _ => None,
        }
    }

    /// The enum ordinal, or `None` for any other tag.
    #[must_use]
    pub fn as_variant(self) -> Option<Variant> {
        match self {
            Self::Enum(v) => Some(v),
            _ => None,
        }
    }

    /// The string list, or `None` for any other tag.
    #[must_use]
    pub fn as_texts(self) -> Option<Texts<'a>> {
        match self {
            Self::Texts(t) => Some(t),
            _ => None,
        }
    }

    /// The nested rows, or `None` for any other tag.
    #[must_use]
    pub fn as_rows(self) -> Option<RowSeq<'a>> {
        match self {
            Self::Rows(r) => Some(r),
            _ => None,
        }
    }

    /// Copy out of the arena.
    #[must_use]
    pub fn to_owned(self) -> OwnedValue {
        match self {
            Self::Text(s) => OwnedValue::Text(s.to_owned()),
            Self::Int(v) => OwnedValue::Int(v),
            Self::Real(v) => OwnedValue::Real(v),
            Self::Bool(v) => OwnedValue::Bool(v),
            Self::Enum(v) => OwnedValue::Enum(v),
            Self::Texts(t) => OwnedValue::Texts(t.to_vec()),
            Self::Rows(r) => OwnedValue::Rows(r.iter().map(|row| row.to_owned()).collect()),
        }
    }
}

/// A borrowed string list, from either transport.
#[derive(Debug, Clone, Copy)]
pub struct Texts<'a>(TextsRepr<'a>);

#[derive(Debug, Clone, Copy)]
enum TextsRepr<'a> {
    Wire(&'a [sys::Text]),
    Owned(&'a [String]),
}

impl<'a> Texts<'a> {
    /// Number of entries.
    #[must_use]
    pub fn len(self) -> usize {
        match self.0 {
            TextsRepr::Wire(s) => s.len(),
            TextsRepr::Owned(s) => s.len(),
        }
    }

    /// Whether the list is empty.
    #[must_use]
    pub fn is_empty(self) -> bool {
        self.len() == 0
    }

    /// The entry at `i`.
    #[must_use]
    pub fn get(self, i: usize) -> Option<&'a str> {
        match self.0 {
            // Validated as UTF-8 when the parent row was constructed.
            TextsRepr::Wire(s) => s.get(i).map(|t| unsafe { text_unchecked(t.ptr, t.len) }),
            TextsRepr::Owned(s) => s.get(i).map(String::as_str),
        }
    }

    /// Iterate the entries.
    pub fn iter(self) -> impl ExactSizeIterator<Item = &'a str> {
        (0..self.len()).map(move |i| self.get(i).unwrap_or_default())
    }

    /// Copy the list out of the arena.
    #[must_use]
    pub fn to_vec(self) -> Vec<String> {
        self.iter().map(str::to_owned).collect()
    }
}

/// A borrowed nested-row slice, from either transport.
#[derive(Debug, Clone, Copy)]
pub struct RowSeq<'a>(RowSeqRepr<'a>);

#[derive(Debug, Clone, Copy)]
enum RowSeqRepr<'a> {
    Wire(&'a [sys::Row]),
    Owned(&'a [OwnedRow]),
}

impl<'a> RowSeq<'a> {
    /// Number of rows.
    #[must_use]
    pub fn len(self) -> usize {
        match self.0 {
            RowSeqRepr::Wire(s) => s.len(),
            RowSeqRepr::Owned(s) => s.len(),
        }
    }

    /// Whether the slice is empty.
    #[must_use]
    pub fn is_empty(self) -> bool {
        self.len() == 0
    }

    /// The row at `i`. Infallible: the parent row's construction already
    /// validated every nested row against its declared schema.
    #[must_use]
    pub fn get(self, i: usize) -> Option<Row<'a>> {
        match self.0 {
            RowSeqRepr::Wire(s) => s.get(i).map(Row::wire_unchecked),
            RowSeqRepr::Owned(s) => s.get(i).and_then(OwnedRow::view),
        }
    }

    /// Iterate the rows.
    pub fn iter(self) -> impl Iterator<Item = Row<'a>> {
        (0..self.len()).filter_map(move |i| self.get(i))
    }
}

// ── owned ──────────────────────────────────────────────────────────────────

/// A row copied out of its arena — what [`Row::to_owned`] produces, and the
/// shape the subprocess tier lowers CLI output into so both transports answer
/// through the same [`Row`] accessors.
#[derive(Debug, Clone, PartialEq)]
pub struct OwnedRow {
    /// The `[row_schemas]` id.
    pub schema_id: u32,
    /// One cell per declared field, positionally; `None` is *absent*.
    pub values: Vec<Option<OwnedValue>>,
}

/// An owned field value. Mirrors [`Value`] arm for arm.
#[derive(Debug, Clone, PartialEq)]
pub enum OwnedValue {
    /// UTF-8 text.
    Text(String),
    /// A signed integer.
    Int(i64),
    /// A real.
    Real(f64),
    /// A boolean.
    Bool(bool),
    /// A closed-vocabulary ordinal.
    Enum(Variant),
    /// A string list.
    Texts(Vec<String>),
    /// Nested rows.
    Rows(Vec<OwnedRow>),
}

impl OwnedRow {
    /// An empty row of `schema_id`, every field absent.
    #[must_use]
    pub fn new(schema_id: u32) -> Self {
        let n = schema_for(schema_id).map_or(0, |s| s.fields.len());
        Self {
            schema_id,
            values: vec![None; n],
        }
    }

    /// Set the declared field named `name`, ignoring a name this schema does
    /// not declare (the CLI emits diagnostic keys the row model has no slot for).
    pub fn set(&mut self, name: &str, value: OwnedValue) {
        let Some(i) =
            schema_for(self.schema_id).and_then(|s| s.fields.iter().position(|f| f.name == name))
        else {
            return;
        };
        if i < self.values.len() {
            self.values[i] = Some(value);
        }
    }

    /// Borrow the row through the same accessors a native row uses. `None` when
    /// the id names a schema this build does not declare.
    #[must_use]
    pub fn view(&self) -> Option<Row<'_>> {
        Row::over(self.schema_id, &self.values)
    }
}

// ── raw reads ──────────────────────────────────────────────────────────────

/// Read one already-validated wire value under its declared field.
pub(super) fn read<'a>(field: &crate::contract::schema::FieldDef, v: &'a sys::Value) -> Value<'a> {
    match field.tag {
        sys::VAL_I64 => Value::Int(v.integer),
        sys::VAL_F64 => Value::Real(v.real),
        sys::VAL_BOOL => Value::Bool(v.integer != 0),
        sys::VAL_ENUM => Value::Enum(Variant {
            enum_id: field.nested,
            ordinal: v.integer,
        }),
        sys::VAL_TEXTS => Value::Texts(Texts(TextsRepr::Wire(unsafe {
            slice(v.ptr.cast::<sys::Text>(), v.len)
        }))),
        sys::VAL_ROWS => Value::Rows(RowSeq(RowSeqRepr::Wire(unsafe {
            slice(v.ptr.cast::<sys::Row>(), v.len)
        }))),
        // VAL_TEXT, and any tag a newer engine adds that the declaration still
        // calls text — validation already proved the bytes are UTF-8.
        _ => Value::Text(unsafe { text_unchecked(v.ptr.cast::<u8>(), v.len) }),
    }
}

/// Borrow one owned cell.
pub(super) fn borrow(v: &OwnedValue) -> Value<'_> {
    match v {
        OwnedValue::Text(s) => Value::Text(s),
        OwnedValue::Int(i) => Value::Int(*i),
        OwnedValue::Real(f) => Value::Real(*f),
        OwnedValue::Bool(b) => Value::Bool(*b),
        OwnedValue::Enum(e) => Value::Enum(*e),
        OwnedValue::Texts(t) => Value::Texts(Texts(TextsRepr::Owned(t))),
        OwnedValue::Rows(r) => Value::Rows(RowSeq(RowSeqRepr::Owned(r))),
    }
}

/// A slice over `len` elements at `ptr`, empty when the pointer is null — the
/// null/zero pair the C ABI uses for "no elements", and the one input
/// `from_raw_parts` calls undefined behavior.
///
/// # Safety
/// `ptr` must be valid for `len` elements of `T` for `'a`.
pub(super) unsafe fn slice<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

/// Read arena bytes already proven UTF-8 by the row's validation pass.
///
/// # Safety
/// `ptr` must be valid for `len` bytes for `'a`.
pub(super) unsafe fn text_unchecked<'a>(ptr: *const u8, len: usize) -> &'a str {
    let bytes = unsafe { slice(ptr, len) };
    // Falls back rather than panicking: a decoder must never abort a host.
    std::str::from_utf8(bytes).unwrap_or_default()
}
