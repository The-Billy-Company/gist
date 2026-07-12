//! Behavioral + rg-parity tests for the importable search API (ADR-352).
//!
//! These drive the real `gist` binary over a throwaway corpus, so they skip
//! cleanly where no binary is built. The parity test additionally requires `rg`
//! on `PATH` and asserts GIST's discovery set is byte-equivalent to ripgrep's —
//! the correctness contract the whole kernel rests on.

use std::path::{Path, PathBuf};
use std::process::Command;

use gist::{Error, MatchKind, SearchRequest};

fn have_gist() -> bool {
    gist::binary().is_ok()
}

fn which(name: &str) -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
}

/// A throwaway corpus mirroring the Python suite's fixtures.
fn corpus() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let p = dir.path();
    std::fs::write(p.join("a.py"), "def alpha():\n    return TODO\n").unwrap();
    std::fs::write(p.join("b.py"), "class Beta:\n    pass  # TODO later\n").unwrap();
    std::fs::write(p.join("c.txt"), "no marker here\nplain text\n").unwrap();
    std::fs::create_dir(p.join("pkg")).unwrap();
    std::fs::write(p.join("pkg/d.py"), "x = 1  # todo lowercase\nTODO upper\n").unwrap();
    dir
}

#[test]
fn search_returns_structured_matches() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let matches = SearchRequest::new("TODO").cwd(dir.path()).run().unwrap();
    assert!(!matches.is_empty(), "expected TODO matches");
    assert!(matches.iter().all(|m| m.kind == MatchKind::Match));
    let hit = matches
        .iter()
        .find(|m| m.path.ends_with("a.py"))
        .expect("a.py hit");
    assert_eq!(hit.line_number, 2);
    assert!(hit.text.contains("TODO"));
    assert!(hit.column() >= 1);
    assert_eq!(hit.submatches.first().unwrap().text, "TODO");
}

#[test]
fn files_lists_matching_paths() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let hits = gist::files(SearchRequest::new("TODO").cwd(dir.path())).unwrap();
    assert!(hits.iter().any(|p| p.ends_with("a.py")));
    assert!(!hits.iter().any(|p| p.ends_with("c.txt")));
}

#[test]
fn count_sums_matching_lines() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    // a.py:1, b.py:1, pkg/d.py:1 (uppercase TODO) — lowercase 'todo' excluded.
    assert_eq!(
        gist::count(SearchRequest::new("TODO").cwd(dir.path())).unwrap(),
        3
    );
}

#[test]
fn ignore_case_widens() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    assert_eq!(
        gist::count(SearchRequest::new("TODO").ignore_case().cwd(dir.path())).unwrap(),
        4
    );
}

#[test]
fn no_match_is_empty_not_error() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    assert!(
        SearchRequest::new("zzz_no_such_token_zzz")
            .cwd(dir.path())
            .run()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn unsupported_pattern_errors_not_kills() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    // PCRE2 lookaround is outside GIST's linear-time engine → typed error,
    // never a dead host process.
    let err = SearchRequest::new("foo")
        .flag("-P")
        .cwd(dir.path())
        .run()
        .unwrap_err();
    assert!(matches!(err, Error::UnsupportedPattern(_)), "got {err:?}");
}

#[test]
fn context_lines_are_context_kind() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let matches = SearchRequest::new("alpha")
        .before(1)
        .after(1)
        .cwd(dir.path())
        .run()
        .unwrap();
    assert!(matches.iter().any(|m| m.kind == MatchKind::Context));
}

#[test]
fn files_parity_with_ripgrep() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let Some(rg) = which("rg") else {
        eprintln!("skip: no rg on PATH");
        return;
    };
    let dir = corpus();
    for pattern in [r"TODO", r"def\s+\w+", r"class"] {
        let gist_hits: std::collections::BTreeSet<String> =
            gist::files(SearchRequest::new(pattern).cwd(dir.path()))
                .unwrap()
                .into_iter()
                .map(|p| normalize(&p, dir.path()))
                .collect();
        let out = Command::new(&rg)
            .args(["-l", "-e", pattern, "."])
            .current_dir(dir.path())
            .output()
            .unwrap();
        let rg_hits: std::collections::BTreeSet<String> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.trim_start_matches("./").to_owned())
            .collect();
        assert_eq!(gist_hits, rg_hits, "discovery drift on {pattern:?}");
    }
}

/// Normalize a gist file path (which may be absolute or `./`-prefixed) to the
/// same repo-relative shape rg prints, so the two sets compare directly.
fn normalize(p: &str, root: &Path) -> String {
    let stripped = p.trim_start_matches("./");
    Path::new(stripped)
        .strip_prefix(root)
        .map(|r| r.to_string_lossy().into_owned())
        .unwrap_or_else(|_| stripped.to_owned())
}
