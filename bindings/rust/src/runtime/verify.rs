//! The one pass that makes every accessor on a [`Row`] infallible.
//!
//! A wire row is checked once, recursively, at construction: the schema id must
//! be one this build declares, each value's tag must be the tag the contract
//! declares for that position, text must be UTF-8, and a nested row must be the
//! schema its parent field points at. Checking here rather than per-accessor is
//! what lets a failure say *which* field drifted — after the boundary there is
//! no caller left who knows the question being asked.
//!
//! The two directions of version skew are deliberately **not** failures. A newer
//! engine may append fields this build has no slot for, and an older one may
//! stop short of a field the contract has since added; only the overlap is ours
//! to read, and the tail reads as absent.

use super::cell::slice;
use super::decode::Row;
use super::{Error, Result, sys};
use crate::contract::schema::FieldDef;

impl Row<'_> {
    /// Recursively check this row against its declaration.
    pub(super) fn validate(self) -> Result<()> {
        let Some((present, values, nvalues)) = self.wire_cells() else {
            // Owned cells were validated when they were built, positionally.
            return Ok(());
        };
        if self.schema_id() == 0 {
            return Err(Error::Decode(
                "row names a schema this build does not declare (rebuild the bindings against \
                 the engine's contract)"
                    .to_owned(),
            ));
        }
        if nvalues != 0 && values.is_null() {
            return Err(self.drift("row", "declares values but carries a null array"));
        }
        let raw = unsafe { slice(values, nvalues) };
        for (i, field) in self.fields().iter().enumerate().take(nvalues) {
            if present & (1u64 << i) == 0 {
                continue;
            }
            let value = &raw[i];
            if value.tag != field.tag {
                return Err(self.drift(
                    field.name,
                    &format!(
                        "wire tag {} disagrees with the declared {}",
                        value.tag, field.tag
                    ),
                ));
            }
            self.reachable(field, value)?;
        }
        Ok(())
    }

    /// Check what a value *points at*: the tag alone proves nothing about the
    /// bytes or rows behind a pointer.
    fn reachable(self, field: &FieldDef, value: &sys::Value) -> Result<()> {
        match field.tag {
            sys::VAL_TEXT => {
                utf8(value.ptr.cast::<u8>(), value.len).map_err(|e| self.drift(field.name, &e))?;
            },
            sys::VAL_TEXTS => {
                for t in unsafe { slice(value.ptr.cast::<sys::Text>(), value.len) } {
                    utf8(t.ptr, t.len).map_err(|e| self.drift(field.name, &e))?;
                }
            },
            sys::VAL_ROWS => {
                for r in unsafe { slice(value.ptr.cast::<sys::Row>(), value.len) } {
                    if r.schema_id != field.nested {
                        return Err(self.drift(
                            field.name,
                            &format!(
                                "nested row is schema {} where {} is declared",
                                r.schema_id, field.nested
                            ),
                        ));
                    }
                    Row::wire_unchecked(r).validate()?;
                }
            },
            _ => {},
        }
        Ok(())
    }

    fn drift(self, field: &str, what: &str) -> Error {
        Error::Decode(format!("{}.{field}: {what}", self.schema_name()))
    }
}

/// Validate arena bytes as UTF-8, naming the problem for the row's error.
fn utf8<'a>(ptr: *const u8, len: usize) -> std::result::Result<&'a str, String> {
    let bytes = unsafe { slice(ptr, len) };
    std::str::from_utf8(bytes).map_err(|e| format!("text is not UTF-8 ({e})"))
}

#[cfg(test)]
mod tests {
    //! Every buffer here is synthesized, because the shapes under test are ones
    //! a healthy engine never emits — a tag that lies, a nested row of the wrong
    //! schema, bytes that are not UTF-8. What they are checked *against* is the
    //! contract: the field's declared tag and nested id, read out of `SCHEMAS`.

    use super::super::fixture::{self, all, enumeration, int, real, row, schema_id, text};
    use super::*;

    #[test]
    fn a_tag_that_contradicts_the_declaration_is_rejected() {
        // Without this the decoder would read 8 bytes of integer as a float and
        // hand back a confident, wrong distance.
        let id = schema_id("similar");
        let values = [text("a.rs"), int(3), enumeration(0), enumeration(0)];
        let err = unsafe { Row::from_wire(&row(id, all(values.len()), &values)) }
            .expect_err("a tag disagreement must not decode");
        let msg = err.to_string();
        assert!(msg.contains("similar.distance"), "{msg}");
        assert!(msg.contains("disagrees"), "{msg}");
    }

    #[test]
    fn a_nested_row_of_the_wrong_schema_is_rejected() {
        // `family.members` declares `region`; a `site` in that slot would decode
        // two of region's four fields under the wrong names.
        let family = schema_id("family");
        let site_values = [text("a.rs"), int(1)];
        let wrong = [row(schema_id("site"), 0b11, &site_values)];
        let values = [
            int(1),
            enumeration(0),
            enumeration(0),
            real(0.2),
            int(80),
            real(0.9),
            fixture::rows(&wrong),
        ];
        let err = unsafe { Row::from_wire(&row(family, all(values.len()), &values)) }
            .expect_err("a mis-schema'd nested row must not decode");
        assert!(err.to_string().contains("family.members"), "{err}");
    }

    #[test]
    fn a_nested_row_is_checked_as_deeply_as_its_parent() {
        let region = schema_id("region");
        let family = schema_id("family");
        // Right schema, wrong tag one level down.
        let member_values = [text("a.rs"), real(1.0), int(20)];
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
        let err = unsafe { Row::from_wire(&row(family, all(values.len()), &values)) }
            .expect_err("recursion must reach the nested field");
        assert!(err.to_string().contains("region.line_start"), "{err}");
    }

    #[test]
    fn non_utf8_text_is_a_failure_not_a_silent_replacement() {
        let id = schema_id("region");
        let bad = [0x66u8, 0xff, 0x66];
        let values = [
            sys::Value {
                tag: sys::VAL_TEXT,
                reserved: 0,
                integer: 0,
                real: 0.0,
                ptr: bad.as_ptr().cast(),
                len: bad.len(),
            },
            int(1),
            int(2),
        ];
        let err = unsafe { Row::from_wire(&row(id, 0b111, &values)) }
            .expect_err("invalid UTF-8 must not decode");
        assert!(err.to_string().contains("region.path"), "{err}");
    }

    #[test]
    fn a_schema_this_build_does_not_declare_is_named_not_guessed() {
        let beyond = u32::try_from(crate::contract::schema::SCHEMAS.len()).unwrap_or(u32::MAX) + 1;
        let err = unsafe { Row::from_wire(&row(beyond, 0, &[])) }
            .expect_err("an unknown schema id must not decode");
        assert!(err.to_string().contains("does not declare"), "{err}");
    }

    #[test]
    fn an_absent_field_is_not_validated_at_all() {
        // The mask says the cell is meaningless, so whatever bytes sit there
        // must not be read — including a tag that would otherwise be rejected.
        let id = schema_id("similar");
        let values = [text("a.rs"), int(3), enumeration(0), enumeration(0)];
        let decoded = unsafe { Row::from_wire(&row(id, all(values.len()) & !0b10, &values)) }
            .expect("an absent cell is never inspected");
        assert_eq!(decoded.real("distance"), None);
    }
}
