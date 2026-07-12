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

#[test]
fn engine_version_matches_contract() {
    // Skips cleanly where no gist binary is built.
    let Ok(v) = gist::version() else {
        eprintln!("skip: no gist binary");
        return;
    };
    assert_eq!(v, contract::ENGINE_VERSION);
}
