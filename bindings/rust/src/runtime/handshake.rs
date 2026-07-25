//! The schema handshake that has to pass before a single native row is decoded.
//!
//! A row is a schema id plus a flat value array, so a library whose
//! `[row_schemas]` table has moved would be decoded *confidently and wrongly* by
//! a stale generated table — the failure mode with no symptom. Comparing
//! `irregex_schema_digest()` to [`schema::DIGEST`] costs one string compare and
//! converts that class of bug into a named refusal.
//!
//! Refusing is not enough on its own, because "the digests differ" tells an
//! operator nothing about which side to rebuild. So a mismatch walks the
//! engine's own `irregex_schema_count`/`irregex_schema_get` and reports the
//! first schema, arity, or field tag that disagrees, in the contract's own
//! vocabulary. When the engine exposes no introspection the failure stays loud,
//! just unnamed.

use std::ffi::CStr;

use super::cell::slice;
use super::sys;
use crate::contract::schema::{self, SCHEMAS};

/// Compare the engine's schema digest to the generated one, naming the first
/// schema that disagrees. `None` means the tables match.
///
/// `introspect` is optional because `irregex_schema_count`/`_get` are a
/// diagnostic luxury: without them the mismatch is still refused, it just
/// cannot say which schema moved.
pub(super) fn drift(
    digest: sys::SchemaDigestFn,
    introspect: Option<(sys::SchemaCountFn, sys::SchemaGetFn)>,
) -> Option<String> {
    let live = cstr(unsafe { digest() });
    if live == schema::DIGEST {
        return None;
    }
    let table = introspect.and_then(|(count, get)| engine_table(count, get));
    Some(message(&live, table.as_deref()))
}

/// One schema as the *engine* declares it, lifted out of the C ABI so the
/// comparison below is ordinary Rust that a test can drive.
pub(super) struct Declared {
    pub(super) name: String,
    pub(super) fields: Vec<(String, u32, u32)>,
}

/// Read the engine's whole schema table; `None` if any row refuses to answer.
fn engine_table(count: sys::SchemaCountFn, get: sys::SchemaGetFn) -> Option<Vec<Declared>> {
    (1..=unsafe { count() })
        .map(|id| {
            let mut out = sys::Schema {
                struct_size: super::struct_size::<sys::Schema>(),
                id: 0,
                name: std::ptr::null(),
                nfields: 0,
                reserved: 0,
                fields: std::ptr::null(),
            };
            if unsafe { get(id, &raw mut out) } != sys::OK || out.name.is_null() {
                return None;
            }
            let fields = unsafe { slice(out.fields, out.nfields as usize) }
                .iter()
                .map(|f| (cstr(f.name), f.tag, f.nested))
                .collect();
            Some(Declared {
                name: cstr(out.name),
                fields,
            })
        })
        .collect()
}

fn cstr(p: *const std::os::raw::c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// The loud failure, spelled so an operator knows which side to rebuild.
pub(super) fn message(live_digest: &str, engine: Option<&[Declared]>) -> String {
    let named = engine
        .and_then(first_disagreement)
        .unwrap_or_else(|| "no schema-level detail available".to_owned());
    format!(
        "engine digest {live_digest} != generated {generated}; {named}. Regenerate the bindings \
         (`python3 pkg/kernels/irregex/tools/build_schema_tables.py`) or rebuild libirregex \
         so both sides speak the same [row_schemas].",
        generated = schema::DIGEST
    )
}

/// Describe the first disagreement between the engine's table and this build's.
/// `None` means they agree field for field — which, given a digest mismatch, is
/// itself worth reporting as unexplained.
pub(super) fn first_disagreement(engine: &[Declared]) -> Option<String> {
    if engine.len() != SCHEMAS.len() {
        return Some(format!(
            "engine declares {} schemas, this build knows {}",
            engine.len(),
            SCHEMAS.len()
        ));
    }
    for (live, known) in engine.iter().zip(SCHEMAS) {
        if live.name != known.name {
            return Some(format!(
                "schema {} is `{}` in the engine, `{}` here",
                known.id, live.name, known.name
            ));
        }
        if live.fields.len() != known.fields.len() {
            return Some(format!(
                "schema `{}` has {} fields in the engine, {} here",
                known.name,
                live.fields.len(),
                known.fields.len()
            ));
        }
        for ((lname, ltag, lnested), k) in live.fields.iter().zip(known.fields) {
            if lname != k.name || *ltag != k.tag || *lnested != k.nested {
                return Some(format!(
                    "schema `{}` field `{lname}` (tag {ltag}, nested {lnested}) where `{}` \
                     (tag {}, nested {}) is declared",
                    known.name, k.name, k.tag, k.nested
                ));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    //! These synthesize the *engine's* side of the handshake, because the
    //! failure they guard is the one no library on this machine can be made to
    //! produce on demand: a `libirregex` whose `[row_schemas]` moved. What the
    //! synthesized table is compared against is the contract itself.

    use super::*;

    fn agreeing() -> Vec<Declared> {
        SCHEMAS
            .iter()
            .map(|s| Declared {
                name: s.name.to_owned(),
                fields: s
                    .fields
                    .iter()
                    .map(|f| (f.name.to_owned(), f.tag, f.nested))
                    .collect(),
            })
            .collect()
    }

    #[test]
    fn a_renamed_schema_is_named_in_the_failure() {
        let mut table = agreeing();
        let victim = SCHEMAS.first().expect("the contract declares schemas");
        table[0].name = "regions".to_owned();

        let msg = message("deadbeef", Some(&table));
        assert!(msg.contains("deadbeef"), "{msg}");
        assert!(msg.contains(schema::DIGEST), "{msg}");
        assert!(msg.contains("`regions`"), "{msg}");
        assert!(msg.contains(victim.name), "{msg}");
    }

    #[test]
    fn a_retyped_field_is_named_with_both_tags() {
        // The exact drift the digest exists to catch: same names, same arity,
        // one field silently reinterpreted — a mis-decode no accessor could see.
        let at = SCHEMAS
            .iter()
            .position(|s| s.name == "similar")
            .expect("the contract declares `similar`");
        let declared = SCHEMAS[at]
            .fields
            .iter()
            .find(|f| f.name == "distance")
            .expect("the contract declares similar.distance");
        let mut table = agreeing();
        for cell in &mut table[at].fields {
            if cell.0 == declared.name {
                cell.1 = sys::VAL_I64;
            }
        }

        let msg = message("deadbeef", Some(&table));
        assert!(msg.contains("similar"), "{msg}");
        assert!(msg.contains("distance"), "{msg}");
        assert!(msg.contains(&format!("tag {}", sys::VAL_I64)), "{msg}");
        assert!(msg.contains(&format!("tag {}", declared.tag)), "{msg}");
    }

    #[test]
    fn a_truncated_engine_table_is_counted_not_zipped_past() {
        let mut table = agreeing();
        table.pop();
        let msg = message("deadbeef", Some(&table));
        assert!(
            msg.contains(&format!("this build knows {}", SCHEMAS.len())),
            "{msg}"
        );
    }

    #[test]
    fn an_unexplainable_digest_mismatch_still_fails_loud() {
        // Tables agree field for field yet the digests differ — something
        // outside `[row_schemas]` moved. Silence here would be the worst answer.
        for engine in [None, Some(agreeing())] {
            let msg = message("deadbeef", engine.as_deref());
            assert!(msg.contains("deadbeef"), "{msg}");
            assert!(msg.contains("Regenerate the bindings"), "{msg}");
        }
        assert!(first_disagreement(&agreeing()).is_none());
    }

    #[test]
    fn the_generated_digest_is_a_real_fingerprint() {
        // Guards the handshake's premise: an empty or placeholder constant would
        // make every comparison above vacuous.
        assert_eq!(schema::DIGEST.len(), 32, "the digest is an md5 hex string");
        assert!(schema::DIGEST.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
