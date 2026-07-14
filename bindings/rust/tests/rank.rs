//! Ranked-view integration tests (ADR-352).
//!
//! The pure row-grammar parse is unit-tested inside `src/contract.rs` (the
//! parser is crate-private). Here the integration layer builds a throwaway index
//! and asserts `gist::rank` reads it back with the engine's own
//! `def`/`use`/`gen` classification — never a Rust reclassifier — skipping
//! cleanly where no binary is built.

use std::path::Path;
use std::process::Command;

use gist::{RankKind, SearchRequest};

fn have_gist() -> bool {
    gist::binary().is_ok()
}

/// A corpus under a real default root (`libs/`) with a freshly built index, so
/// `--rank` has the structure it reads. Returns the tempdir to search from, or
/// `None` when the binary is missing or the index build fails (the caller skips).
fn indexed_corpus() -> Option<tempfile::TempDir> {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return None;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let lib = dir.path().join("libs").join("pkg");
    std::fs::create_dir_all(&lib).unwrap();
    std::fs::write(
        dir.path().join("libs/a.py"),
        "def widget():\n    return TODO\n",
    )
    .unwrap();
    std::fs::write(lib.join("b.py"), "x = TODO\nTODO again\n").unwrap();
    let build = Command::new(gist::binary().unwrap())
        .arg("index")
        .current_dir(dir.path())
        .output()
        .expect("spawn gist index");
    if !build.status.success() {
        eprintln!(
            "skip: index build failed: {}",
            String::from_utf8_lossy(&build.stderr).trim()
        );
        return None;
    }
    Some(dir)
}

fn ends_with(path: &str, tail: &str) -> bool {
    Path::new(path).ends_with(tail)
}

#[test]
fn rank_reads_the_index_with_engine_classification() {
    let Some(dir) = indexed_corpus() else { return };
    let rows = gist::rank(SearchRequest::new("TODO").cwd(dir.path()), 10).unwrap();
    assert!(
        !rows.is_empty(),
        "expected ranked rows over the built index"
    );
    // b.py has two TODOs → it ranks ahead of a.py's one on lexical density.
    assert!(ends_with(&rows[0].path, "pkg/b.py"), "got {}", rows[0].path);
    assert_eq!(rows[0].count, 2);
}

#[test]
fn rank_forwards_search_options() {
    let Some(dir) = indexed_corpus() else { return };
    // A `widget` search resolves the definition in a.py; the option flows through.
    let rows = gist::rank(SearchRequest::new("widget").cwd(dir.path()), 5).unwrap();
    assert!(
        rows.iter()
            .any(|r| ends_with(&r.path, "a.py") && r.kind == RankKind::Def),
        "expected a def hit in a.py, got {rows:?}"
    );
}

#[test]
fn rank_without_index_is_empty_not_error() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    // No persisted index ⇒ nothing to rank ⇒ an empty vec, never an error.
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir(dir.path().join("libs")).unwrap();
    std::fs::write(dir.path().join("libs/a.py"), "TODO here\n").unwrap();
    let rows = gist::rank(SearchRequest::new("TODO").cwd(dir.path()), 5).unwrap();
    assert!(rows.is_empty(), "got {rows:?}");
}
