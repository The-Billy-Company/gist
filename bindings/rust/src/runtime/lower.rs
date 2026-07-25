//! JSON → row, by the same schema table the wire decoder walks.
//!
//! The subprocess tier's half of the one decoder. It is deliberately laxer than
//! the wire decoder: the C ABI states exactly which fields a row carries,
//! whereas CLI JSON predates the schema table and was never shaped by it. What
//! it will not do is invent — an unparseable value stays absent rather than
//! becoming a zero that reads like a measurement.

use serde_json::{Map, Value as Json};

use super::cell::{OwnedRow, OwnedValue};
use super::decode::schema_for;
use crate::contract::Variant;
use crate::contract::schema::{ENUMS, FieldDef};

/// Where a declared field reads from when the CLI spells it differently:
/// `(schema id, declared field, JSON key)`.
///
/// The rename is **exclusive** — once a schema claims a key for one field, the
/// field that happens to share that key's name reads nothing rather than
/// silently decoding the neighboring value (on `distinct`, `unit` is a path in
/// the JSON and an enum in the schema, and conflating them would be worse than
/// leaving the enum absent).
const RENAMES: &[(u32, &str, &str)] = &[
    (3, "path", "unit"),           // similar
    (6, "byte_distance", "bytes"), // echo
    (6, "structure_distance", "structure"),
    (7, "byte_distance", "bytes"), // concept
    (7, "structure_distance", "structure"),
    (8, "edge", "distance"), // family
    (9, "member", "unit"),   // distinct
    (9, "byte_distance", "bytes"),
    (9, "structure_distance", "structure"),
    (17, "enclosing", "in"), // reference
    (17, "defines", "use"),
];

/// Lower one JSON object into `schema`, by declared field.
///
/// A key the schema does not declare is ignored (the CLIs emit diagnostic
/// fields the row model has no slot for), and a declared field the object omits
/// stays **absent** — not zero.
pub(super) fn lower(schema: u32, obj: &Map<String, Json>) -> OwnedRow {
    let renamed = |field: &str| {
        RENAMES
            .iter()
            .find(|(id, declared, _)| *id == schema && *declared == field)
            .map(|(_, _, key)| *key)
    };
    let mut row = OwnedRow::new(schema);
    for field in schema_for(schema).map_or(&[][..], |s| s.fields) {
        let key = match renamed(field.name) {
            Some(key) => key,
            // Claimed by another field of this schema under a rename.
            None if RENAMES
                .iter()
                .any(|(id, _, key)| *id == schema && *key == field.name) =>
            {
                continue;
            },
            None => field.name,
        };
        if let Some(value) = obj.get(key).and_then(|json| coerce(field, json)) {
            row.set(field.name, value);
        }
    }
    row
}

fn coerce(field: &FieldDef, json: &Json) -> Option<OwnedValue> {
    use super::sys::{VAL_BOOL, VAL_ENUM, VAL_F64, VAL_I64, VAL_ROWS, VAL_TEXT, VAL_TEXTS};
    match field.tag {
        VAL_TEXT => Some(OwnedValue::Text(json.as_str()?.to_owned())),
        VAL_I64 => Some(OwnedValue::Int(
            json.as_i64()
                .or_else(|| json.as_f64().map(|f| f.trunc() as i64))?,
        )),
        // `nan` is what the CLIs print for "this channel does not apply here",
        // which is absence, not a number.
        VAL_F64 => json
            .as_f64()
            .filter(|f| f.is_finite())
            .map(OwnedValue::Real),
        // Some boolean axes are spelled as the tag that set them (`def`/`use`).
        VAL_BOOL => Some(OwnedValue::Bool(
            json.as_bool()
                .or_else(|| json.as_str().map(|s| s == "def"))?,
        )),
        VAL_ENUM => {
            let name = json.as_str()?;
            Some(OwnedValue::Enum(Variant {
                enum_id: field.nested,
                ordinal: ordinal(field.nested, name),
            }))
        },
        VAL_TEXTS => Some(OwnedValue::Texts(
            json.as_array()?
                .iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect(),
        )),
        VAL_ROWS => Some(OwnedValue::Rows(match json {
            Json::Array(items) => items.iter().map(|v| nested(field.nested, v)).collect(),
            other => vec![nested(field.nested, other)],
        })),
        _ => None,
    }
}

/// A nested row, from either a real object or the `path#Lnnn` locator the CLIs
/// use where the schema wants a whole row. The locator lowers into the nested
/// schema's first text field plus its first integer field, which is exactly the
/// `region` shape every such field points at.
fn nested(schema: u32, json: &Json) -> OwnedRow {
    if let Some(obj) = json.as_object() {
        return lower(schema, obj);
    }
    let mut row = OwnedRow::new(schema);
    let Some(text) = json.as_str() else {
        return row;
    };
    let fields = schema_for(schema).map_or(&[][..], |s| s.fields);
    let (path, line) = match text.rsplit_once("#L") {
        Some((path, n)) => (path, n.parse::<i64>().ok()),
        None => (text, None),
    };
    if let Some(f) = fields.iter().find(|f| f.tag == super::sys::VAL_TEXT) {
        row.set(f.name, OwnedValue::Text(path.to_owned()));
    }
    if let (Some(f), Some(n)) = (fields.iter().find(|f| f.tag == super::sys::VAL_I64), line) {
        row.set(f.name, OwnedValue::Int(n));
    }
    row
}

/// Resolve a spelling to its ordinal, or `-1` for a name this build's table does
/// not carry — surfaced as an unknown [`Variant`] rather than guessed at.
fn ordinal(enum_id: u32, name: &str) -> i64 {
    ENUMS
        .get(enum_id.saturating_sub(1) as usize)
        .and_then(|(_, variants)| variants.iter().position(|v| *v == name))
        .map_or(-1, |i| i as i64)
}

/// The same resolution, for a caller that knows the vocabulary by name rather
/// than by id (the ranked text parser, which has no field to read it from).
pub(super) fn ordinal_in(enum_name: &str, variant: &str) -> i64 {
    ENUMS
        .iter()
        .position(|(name, _)| *name == enum_name)
        .and_then(|i| u32::try_from(i + 1).ok())
        .map_or(-1, |id| ordinal(id, variant))
}

#[cfg(test)]
mod tests {
    //! The inputs are lines the certified CLIs actually print; the expectations
    //! come from the schema the line lowers into. A row that decodes here must
    //! read *identically* to one that came off the wire — that equivalence is
    //! what makes the subprocess tier a fallback rather than a second answer.

    use super::*;
    use crate::contract::schema::SCHEMAS;
    use crate::contract::{Channel, Grade};

    fn schema_id(name: &str) -> u32 {
        SCHEMAS.iter().find(|s| s.name == name).map_or(0, |s| s.id)
    }

    fn one(schema: &str, line: &str) -> OwnedRow {
        let Ok(Json::Object(obj)) = serde_json::from_str::<Json>(line) else {
            panic!("test input is not a JSON object")
        };
        lower(schema_id(schema), &obj)
    }

    #[test]
    fn a_similar_line_lowers_into_the_similar_schema() {
        let row = one(
            "similar",
            r#"{"unit":"src/a.rs","distance":0.0,"grade":"identical","channel":"copies"}"#,
        );
        let view = row.view().expect("known schema");
        // `path` reads from the CLI's `unit` key; the rename is the contract's,
        // not a guess about which key looks closest.
        assert_eq!(view.text("path"), Some("src/a.rs"));
        assert_eq!(view.real("distance"), Some(0.0));
        assert_eq!(
            view.variant("grade").and_then(Grade::from_variant),
            Some(Grade::Identical)
        );
        assert_eq!(
            view.variant("channel").and_then(Channel::from_variant),
            Some(Channel::Copies)
        );
    }

    #[test]
    fn a_key_the_schema_does_not_declare_is_ignored() {
        let row = one(
            "similar",
            r#"{"unit":"a.rs","distance":0.5,"trace_ms":12,"note":"hi"}"#,
        );
        let view = row.view().expect("known schema");
        assert_eq!(view.text("path"), Some("a.rs"));
        assert_eq!(view.iter().count(), 2, "only declared fields land");
    }

    #[test]
    fn an_omitted_field_stays_absent_rather_than_zero() {
        // The whole point of the presence model, exercised on the tier that has
        // no presence mask to copy: a missing key is `None`, not `0.0`.
        let row = one("similar", r#"{"unit":"a.rs","grade":"strong"}"#);
        assert_eq!(row.view().and_then(|v| v.real("distance")), None);
    }

    #[test]
    fn nan_is_absence_not_a_number() {
        // The CLIs print `nan` for "this channel does not apply here". Decoding
        // it as a float would make every threshold comparison silently false.
        let row = one(
            "echo",
            r#"{"a":"x.rs","b":"y.rs","echo":0.3,"bytes":null,"structure":0.1,"grade":"moderate"}"#,
        );
        let view = row.view().expect("known schema");
        assert_eq!(view.real("byte_distance"), None);
        assert_eq!(view.real("structure_distance"), Some(0.1));
    }

    #[test]
    fn a_renamed_key_is_exclusive() {
        // On `distinct`, `unit` is a path in the JSON and an enum in the schema.
        // Reading the enum from that key would label every row `file?-1`; the
        // right answer is to leave it absent.
        let row = one(
            "distinct",
            r#"{"unit":"a.rs#L4","bytes":0.2,"structure":0.1}"#,
        );
        let view = row.view().expect("known schema");
        assert_eq!(view.variant("unit"), None);
        let member = view.rows("member").and_then(|r| r.get(0)).expect("member");
        assert_eq!(member.text("path"), Some("a.rs"));
        assert_eq!(member.int("line_start"), Some(4));
    }

    #[test]
    fn an_enum_spelling_this_build_lacks_lands_as_unknown() {
        let row = one(
            "similar",
            r#"{"unit":"a.rs","distance":0.1,"grade":"uncanny"}"#,
        );
        let grade = row
            .view()
            .and_then(|v| v.variant("grade"))
            .expect("present");
        assert_eq!(grade.ordinal, -1);
        assert_eq!(grade.name(), None);
        assert_eq!(Grade::from_variant(grade), None);
    }

    #[test]
    fn a_vocabulary_is_resolved_by_name_the_same_way_it_is_by_id() {
        // The ranked text parser has no field to read an enum id from, so it
        // names the vocabulary instead; both paths must agree or `--rank` rows
        // would carry a different `kind` than every other row.
        let (name, variants) = ENUMS
            .iter()
            .find(|(name, _)| *name == "rank_kind")
            .expect("rank_kind is declared");
        for (i, variant) in variants.iter().enumerate() {
            assert_eq!(ordinal_in(name, variant), i as i64);
        }
        assert_eq!(ordinal_in(name, "not-a-kind"), -1);
        assert_eq!(ordinal_in("not-a-vocabulary", "def"), -1);
    }
}
