//! Synthesized `irregex_row` buffers, for tests only.
//!
//! The decoder's hard cases are wire shapes a healthy engine never emits — a
//! cleared presence bit, an ordinal past the enum table, a tag that contradicts
//! the declaration — and this crate cannot link a `libirregex` to ask for them.
//! Building the bytes by hand is therefore the only way to test the boundary,
//! and it keeps the *expectations* on the contract side: a test names a schema
//! and a field, and this module turns that into the layout `[row_schemas]` says
//! the engine would produce.
//!
//! Every buffer here borrows the caller's stack, so a `sys::Row` must not
//! outlive the arrays it points at — which is exactly the invariant the real
//! cursor upholds, expressed as an ordinary Rust borrow.

use super::sys;
use crate::contract::schema::SCHEMAS;

/// The wire id of a `[row_schemas]` table, by name.
pub(super) fn schema_id(name: &str) -> u32 {
    SCHEMAS.iter().find(|s| s.name == name).map_or(0, |s| s.id)
}

/// The declared position of a field, so no test hardcodes a wire index.
pub(super) fn field_at(schema: u32, name: &str) -> usize {
    SCHEMAS
        .get(schema as usize - 1)
        .and_then(|s| s.fields.iter().position(|f| f.name == name))
        .unwrap_or_else(|| panic!("the contract has no {schema}.{name}"))
}

/// A presence mask with every one of `n` fields present.
pub(super) fn all(n: usize) -> u64 {
    (1u64 << n) - 1
}

fn value(
    tag: u32,
    integer: i64,
    real: f64,
    ptr: *const std::ffi::c_void,
    len: usize,
) -> sys::Value {
    sys::Value {
        tag,
        reserved: 0,
        integer,
        real,
        ptr,
        len,
    }
}

pub(super) fn text(s: &str) -> sys::Value {
    value(sys::VAL_TEXT, 0, 0.0, s.as_ptr().cast(), s.len())
}

pub(super) fn int(v: i64) -> sys::Value {
    value(sys::VAL_I64, v, 0.0, std::ptr::null(), 0)
}

pub(super) fn real(v: f64) -> sys::Value {
    value(sys::VAL_F64, 0, v, std::ptr::null(), 0)
}

/// An enum cell carrying `ordinal` verbatim — including one past the table.
pub(super) fn enumeration(ordinal: i64) -> sys::Value {
    value(sys::VAL_ENUM, ordinal, 0.0, std::ptr::null(), 0)
}

pub(super) fn texts(list: &[sys::Text]) -> sys::Value {
    value(sys::VAL_TEXTS, 0, 0.0, list.as_ptr().cast(), list.len())
}

pub(super) fn rows(list: &[sys::Row]) -> sys::Value {
    value(sys::VAL_ROWS, 0, 0.0, list.as_ptr().cast(), list.len())
}

/// One row header over `values`, with `present` as its mask.
pub(super) fn row(schema: u32, present: u64, values: &[sys::Value]) -> sys::Row {
    sys::Row {
        schema_id: schema,
        nvalues: u32::try_from(values.len()).unwrap_or(u32::MAX),
        present,
        values: values.as_ptr(),
    }
}
