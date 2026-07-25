//! The mirror in `gist::contract` must not drift from the canonical
//! `contract/search_api.toml`, nor from the driven binary (ADR-352).

use std::collections::BTreeSet;
use std::path::PathBuf;

use gist::contract;

fn load_toml() -> Option<toml::Table> {
    // tests/contract.rs → CARGO_MANIFEST_DIR is bindings/rust; the contract is ../../contract.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../contract/search_api.toml");
    let text = std::fs::read_to_string(path).ok()?;
    text.parse::<toml::Table>().ok()
}

fn keys(table: &toml::Table, section: &str) -> BTreeSet<String> {
    table[section]
        .as_table()
        .expect("section is a table")
        .keys()
        .cloned()
        .collect()
}

#[test]
fn meta_mirror_matches_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let meta = t["meta"].as_table().unwrap();
    assert_eq!(
        meta["abi_version"].as_integer().unwrap(),
        i64::from(contract::ABI_VERSION)
    );
    assert_eq!(
        meta["engine_version"].as_str().unwrap(),
        contract::ENGINE_VERSION
    );
    assert_eq!(
        meta["package_dist"].as_str().unwrap(),
        contract::PACKAGE_DIST
    );
    assert_eq!(
        meta["package_import"].as_str().unwrap(),
        contract::PACKAGE_IMPORT
    );
}

#[test]
fn request_options_mirror_matches_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let mirror: BTreeSet<String> = contract::REQUEST_OPTIONS
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    assert_eq!(
        keys(&t, "request_options"),
        mirror,
        "REQUEST_OPTIONS drifted from the contract"
    );
}

#[test]
fn match_kinds_and_exit_codes_mirror_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let mirror: BTreeSet<String> = contract::MATCH_KINDS
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    assert_eq!(keys(&t, "match_kinds"), mirror);

    let codes = t["exit_codes"].as_table().unwrap();
    assert_eq!(
        codes["matched"]["code"].as_integer().unwrap(),
        i64::from(contract::EXIT_MATCHED)
    );
    assert_eq!(
        codes["no_match"]["code"].as_integer().unwrap(),
        i64::from(contract::EXIT_NO_MATCH)
    );
    assert_eq!(
        codes["error"]["code"].as_integer().unwrap(),
        i64::from(contract::EXIT_ERROR)
    );
}

#[test]
fn tool_boundary_mirror_matches_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let boundary = t["tool_boundary"].as_table().unwrap();
    let aliases = boundary["aliases"].as_table().unwrap();
    for (from, to) in contract::ALIASES {
        assert_eq!(
            aliases[*from].as_str().unwrap(),
            *to,
            "alias {from} drifted"
        );
    }
    assert_eq!(
        aliases.len(),
        contract::ALIASES.len(),
        "alias count drifted"
    );

    let routing: BTreeSet<String> = contract::ROUTING_KEYS
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    let toml_routing: BTreeSet<String> = boundary["routing_keys"]
        .as_table()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(toml_routing, routing);
}

// ── the generated analytic tables (ADR-377) ─────────────────────────────────
// `schema.gen.rs` is produced from this same TOML, so these are drift gates on
// the generator's output — the one thing standing between a moved contract and
// a decoder that reads the right bytes under the wrong names.

/// `[analytic].value_tags` is ordered; its index *is* the wire tag.
fn tag_of(declared: &str, tags: &[String]) -> u32 {
    let name = declared.split(':').next().unwrap_or(declared);
    let at = tags
        .iter()
        .position(|t| t == name)
        .unwrap_or_else(|| panic!("`{declared}` names no [analytic].value_tags entry"));
    u32::try_from(at).expect("seven tags")
}

#[test]
fn row_enums_mirror_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let declared = t["row_enums"].as_table().unwrap();
    assert_eq!(declared.len(), contract::schema::ENUMS.len());
    for (name, spec) in declared {
        let id = spec["id"].as_integer().unwrap();
        let at = usize::try_from(id - 1).unwrap();
        let (gen_name, gen_variants) = contract::schema::ENUMS[at];
        assert_eq!(gen_name, name, "enum {id} drifted");
        let variants: Vec<&str> = spec["variants"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(gen_variants, variants, "enum `{name}` variants drifted");
    }
}

#[test]
fn calibration_enums_mirror_their_row_enums() {
    // The hand-written enums are the *typed* face of the generated ordinals;
    // a reordered variant here would silently relabel every kinship row.
    for (name, variants) in contract::schema::ENUMS {
        let mirror: Option<Vec<&str>> = match *name {
            "grade" => Some(contract::Grade::ALL.iter().map(|g| g.as_str()).collect()),
            "channel" => Some(contract::Channel::ALL.iter().map(|c| c.as_str()).collect()),
            "unit" => Some(contract::Unit::ALL.iter().map(|u| u.as_str()).collect()),
            _ => None,
        };
        if let Some(mirror) = mirror {
            assert_eq!(*variants, mirror.as_slice(), "`{name}` drifted");
        }
    }
}

#[test]
fn row_schemas_mirror_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let tags: Vec<String> = t["analytic"]["value_tags"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect();
    let declared = t["row_schemas"].as_table().unwrap();
    assert_eq!(declared.len(), contract::schema::SCHEMAS.len());
    assert_eq!(
        t["analytic"]["max_fields"].as_integer().unwrap(),
        i64::try_from(contract::schema::MAX_FIELDS).unwrap()
    );

    for (name, spec) in declared {
        let id = spec["id"].as_integer().unwrap();
        let generated = contract::schema::SCHEMAS[usize::try_from(id - 1).unwrap()];
        assert_eq!(generated.id, u32::try_from(id).unwrap());
        assert_eq!(generated.name, name, "schema {id} drifted");

        let fields = spec["fields"].as_array().unwrap();
        assert_eq!(
            generated.fields.len(),
            fields.len(),
            "`{name}` field count drifted"
        );
        for (mirror, field) in generated.fields.iter().zip(fields) {
            let declared_type = field["type"].as_str().unwrap();
            assert_eq!(mirror.name, field["name"].as_str().unwrap());
            assert_eq!(
                mirror.tag,
                tag_of(declared_type, &tags),
                "`{name}.{}`",
                mirror.name
            );
            assert_eq!(
                mirror.optional,
                field.get("optional").and_then(toml::Value::as_bool) == Some(true),
                "`{name}.{}` optionality drifted",
                mirror.name
            );
            // `enum:x` / `rows:x` carry the id of the table they point at, and a
            // wrong one is exactly the mis-decode `nested` exists to prevent.
            match declared_type.split_once(':') {
                Some(("enum", target)) => {
                    let want = t["row_enums"][target]["id"].as_integer().unwrap();
                    assert_eq!(i64::from(mirror.nested), want, "`{name}.{}`", mirror.name);
                },
                Some(("rows", target)) => {
                    let want = t["row_schemas"][target]["id"].as_integer().unwrap();
                    assert_eq!(i64::from(mirror.nested), want, "`{name}.{}`", mirror.name);
                },
                _ => assert_eq!(mirror.nested, 0, "`{name}.{}` should not nest", mirror.name),
            }
        }
    }
}

#[test]
fn analytic_verbs_mirror_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let declared = t["analytic"]["verbs"].as_table().unwrap();
    assert_eq!(declared.len(), contract::schema::VERBS.len());
    for (name, spec) in declared {
        let op = spec["op"].as_integer().unwrap();
        let generated = contract::schema::VERBS[usize::try_from(op - 1).unwrap()];
        assert_eq!(generated.op, u32::try_from(op).unwrap());
        assert_eq!(generated.name, name, "op {op} drifted");
        assert_eq!(generated.params, spec["params"].as_str().unwrap());
        let schema = spec["schema"].as_str().unwrap();
        assert_eq!(
            contract::schema::SCHEMAS[usize::try_from(generated.schema - 1).unwrap()].name,
            schema,
            "`{name}` returns the wrong schema"
        );
        // `stream` is what tells a caller whether batching is worth reaching for.
        assert_eq!(
            generated.many,
            spec["stream"].as_str().unwrap() == "many",
            "`{name}` streaming drifted"
        );
    }
}

#[test]
fn grade_bands_mirror_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let grades = &t["irregex"]["grades"];
    for (grade, bound) in contract::calibration::DISTANCE_BANDS {
        let want = grades["distance"][grade.as_str()].as_float().unwrap();
        assert!(
            (want - bound).abs() < f64::EPSILON,
            "distance band `{grade}` drifted"
        );
    }
    for (grade, bound) in contract::calibration::GAP_BANDS {
        let want = grades["gap"][grade.as_str()].as_float().unwrap();
        assert!(
            (want - bound).abs() < f64::EPSILON,
            "gap band `{grade}` drifted"
        );
    }
    // A gap is never `identical` — two byte-identical files have a zero gap.
    assert!(grades["gap"].get("identical").is_none());
    assert!(
        contract::calibration::GAP_BANDS
            .iter()
            .all(|(g, _)| *g != contract::Grade::Identical)
    );
}

#[test]
fn banding_lands_a_score_in_the_tightest_band_that_holds_it() {
    use contract::{Channel, Grade};

    // Every band's own bound must band as that grade, and a hair past it must
    // fall to the next weaker one. A distance of 0.0 is the case that matters
    // most: it means *identical*, and grading it as background would make
    // `min_grade` filter out the only exact match in the answer.
    let mut floor = 0.0;
    for (grade, hi) in contract::calibration::DISTANCE_BANDS {
        assert_eq!(Grade::band(floor, Channel::Copies), *grade);
        assert_eq!(Grade::band(*hi, Channel::Copies), *grade);
        floor = hi + 1e-9;
    }
    assert_eq!(Grade::band(1.0, Channel::Copies), Grade::None);

    // Gaps invert: bigger is stronger, and `twins` is the channel that carries
    // one, so the same 0.20 grades differently on each.
    let mut ceiling = 1.0;
    for (grade, lo) in contract::calibration::GAP_BANDS {
        assert_eq!(Grade::band(ceiling, Channel::Twins), *grade);
        assert_eq!(Grade::band(*lo, Channel::Twins), *grade);
        ceiling = lo - 1e-9;
    }
    assert_eq!(Grade::band(0.0, Channel::Twins), Grade::None);
    assert_ne!(
        Grade::band(0.20, Channel::Copies),
        Grade::band(0.20, Channel::Twins),
        "reading a score without its channel is the mistake calibration prevents"
    );
}

#[test]
fn channel_polarity_mirrors_toml() {
    let Some(t) = load_toml() else {
        eprintln!("skip: canonical contract TOML not present");
        return;
    };
    let channels = t["irregex"]["channels"].as_table().unwrap();
    for channel in contract::Channel::ALL {
        let spec = &channels[channel.as_str()];
        assert_eq!(channel.metric(), spec["metric"].as_str().unwrap());
        assert_eq!(channel.admits(), spec["admits"].as_str().unwrap());
        let polarity = match spec["polarity"].as_str().unwrap() {
            "gap" => contract::Polarity::Gap,
            _ => contract::Polarity::Distance,
        };
        assert_eq!(channel.polarity(), polarity, "`{channel}` polarity drifted");
    }
}

#[test]
fn engine_version_matches_contract() {
    // Skips cleanly where no gist binary is built.
    let Ok(v) = gist::version() else {
        eprintln!("skip: no gist binary");
        return;
    };
    assert_eq!(v, contract::ENGINE_VERSION);
}
