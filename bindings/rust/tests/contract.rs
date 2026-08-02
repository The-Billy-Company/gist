//! The mirror in `gist::contract` must not drift from `contract/surface.toml`.
//!
//! Two claims, both about names this repository authors: what the published
//! artifacts are called, and what a tool driving this package by name may say.
//! They were asserted in the engine's crate until the packages split, which
//! made the engine's suite unrunnable without a gist checkout beside it. Here
//! the contract and its mirror are in the same repository, so the gate needs
//! nothing it does not ship.
//!
//! Reading the TOML **fails closed**. The engine's suite learned this the hard
//! way: when its locator silently resolved to a path that stopped existing
//! after the split, every assertion stopped running and the mirror drifted for
//! months behind a green suite. A missing contract is an error that names the
//! file it wanted.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::OnceLock;

use gist::contract;

/// Path to `contract/surface.toml`.
///
/// `GIST_SURFACE_CONTRACT` overrides, for a caller running the suite against a
/// contract somewhere else. Otherwise it is looked for at every ancestor rather
/// than at a counted depth, so the test survives the crate moving a level.
/// Failing that, the path this layout would have used is returned anyway, so
/// the miss names somewhere real.
fn contract_path() -> PathBuf {
    if let Ok(p) = std::env::var("GIST_SURFACE_CONTRACT") {
        return PathBuf::from(p);
    }
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for base in here.ancestors() {
        let candidate = base.join("contract/surface.toml");
        if candidate.is_file() {
            return candidate;
        }
    }
    // `bindings/rust` → the checkout root.
    here.ancestors()
        .nth(2)
        .unwrap_or(&here)
        .join("contract/surface.toml")
}

fn surface() -> &'static toml::Table {
    static SURFACE: OnceLock<toml::Table> = OnceLock::new();
    SURFACE.get_or_init(|| {
        let path = contract_path();
        let text = std::fs::read_to_string(&path).unwrap_or_else(|err| {
            panic!(
                "contract/surface.toml not found at {}. The parity gate cannot run \
                 without it. ({err})",
                path.display()
            );
        });
        text.parse::<toml::Table>().unwrap_or_else(|err| {
            panic!(
                "contract/surface.toml at {} is not valid TOML: {err}",
                path.display()
            );
        })
    })
}

#[test]
fn the_contract_is_readable() {
    // The gate's own precondition, asserted once and by name. Without it, a
    // missing contract surfaces as an unrelated-looking failure in whichever
    // test happened to read it first.
    assert!(!surface().is_empty(), "surface.toml parsed empty");
}

#[test]
fn package_names_mirror_toml() {
    // The published artifact names are this repo's to declare, so they live in
    // its own contract rather than the kernel's.
    let package = surface()["package"].as_table().unwrap();
    assert_eq!(package["dist"].as_str().unwrap(), contract::PACKAGE_DIST);
    assert_eq!(
        package["import"].as_str().unwrap(),
        contract::PACKAGE_IMPORT
    );
}

#[test]
fn tool_boundary_mirror_matches_toml() {
    let boundary = surface()["tool_boundary"].as_table().unwrap();
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
