//! In-process `Engine` / `Cursor` tests (ADR-352 pull-cursor surface, `native`).
//!
//! Proves the warm [`gist::Engine`] + pull [`gist::Cursor`] produce records
//! byte-identical to the certified cold subprocess (`SearchRequest::run`) — same
//! order, paths, line numbers, text, and submatch spans — so, transitively
//! through the cold path's own rg certification (`tests/search.rs`), Engine ≡ cold
//! ≡ rg. Then it pins the hosted invariants the subprocess API doesn't expose:
//! `batches()` is the same record stream chunked, a `max_results` budget stops at
//! a record boundary while still reporting `matched`, a pre-tripped `CancelToken`
//! yields a clean empty result, an unsupported pattern / unrepresentable option
//! raises a *catchable* typed error, and copied records outlive both handles.
//!
//! Compiled only under `--features native`; skips cleanly when no `gist` binary is
//! built (the cold oracle) — the native library is always present when this file
//! compiles, since `build.rs` linked it.
#![cfg(feature = "native")]

use std::path::Path;
use std::thread;

use gist::{Engine, Error, Match, SearchEngine, SearchRequest};

fn have_gist() -> bool {
    gist::binary().is_ok()
}

/// A throwaway corpus mirroring the Python + subprocess suites' fixtures.
fn corpus() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let p = dir.path();
    std::fs::write(
        p.join("a.py"),
        "def alpha():\n    return TODO\n# TODO trailing\n",
    )
    .unwrap();
    std::fs::write(p.join("b.py"), "class Beta:\n    pass  # TODO later\n").unwrap();
    std::fs::write(p.join("c.txt"), "no marker here\nplain text\n").unwrap();
    std::fs::create_dir(p.join("pkg")).unwrap();
    std::fs::write(
        p.join("pkg/d.py"),
        "x = 1  # todo lowercase\nTODO upper TODO twice\n",
    )
    .unwrap();
    dir
}

/// The cold oracle: run the same request over the certified subprocess. Roots are
/// an explicit path so its output paths carry the same prefix the warm engine's do.
fn cold(req: &SearchRequest) -> Vec<Match> {
    req.clone().run().expect("cold run")
}

/// A request rooted at `dir` (the warm engine ignores `paths`, but the cold oracle
/// needs them, and the shared prefix keeps the two comparable).
fn rooted(dir: &Path, pattern: &str) -> SearchRequest {
    SearchRequest::new(pattern).path(dir.to_str().unwrap())
}

fn warm(dir: &Path) -> Engine {
    Engine::open([dir.to_str().unwrap()]).expect("engine open")
}

fn drain(cursor: gist::Cursor) -> Vec<Match> {
    cursor.map(|m| m.expect("record")).collect()
}

#[test]
fn engine_search_equals_cold() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let cases = [
        rooted(dir.path(), "TODO"),
        rooted(dir.path(), "TODO").fixed(),
        rooted(dir.path(), "TODO").ignore_case(),
        rooted(dir.path(), r"def\s+\w+"),
        rooted(dir.path(), "absent_needle_xyzzy"),
        rooted(dir.path(), "TODO").before(1).after(1),
    ];
    let eng = warm(dir.path());
    for req in &cases {
        let got = drain(eng.search(req).expect("warm search"));
        assert_eq!(got, cold(req), "drift on {:?}", req.pattern);
    }
}

#[test]
fn batches_are_the_same_stream_chunked() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let req = rooted(dir.path(), "TODO");
    let eng = warm(dir.path());
    let one_at_a_time = drain(eng.search(&req).unwrap());
    let chunked: Vec<Match> = eng
        .search(&req)
        .unwrap()
        .batches(2)
        .flat_map(|b| b.expect("batch"))
        .collect();
    assert_eq!(chunked, one_at_a_time);
    assert_eq!(chunked, cold(&req));

    // Every batch but the last is full — proves the batch call actually fills.
    let sizes: Vec<usize> = eng
        .search(&req)
        .unwrap()
        .batches(2)
        .map(|b| b.unwrap().len())
        .collect();
    assert!(sizes.iter().rev().skip(1).all(|&n| n == 2));
    assert!((1..=2).contains(sizes.last().unwrap()));
}

#[test]
fn max_results_stops_at_a_boundary_but_still_matched() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let req = rooted(dir.path(), "TODO");
    let eng = warm(dir.path());
    let mut cur = eng.run(&req, gist::Run::default().max_results(1)).unwrap();
    let first = cur.next().unwrap().unwrap();
    assert!(
        cur.next().is_none(),
        "budget of 1 yields exactly one record"
    );
    assert!(cur.matched(), "matched reflects the corpus, not the budget");
    assert_eq!(first, cold(&req)[0], "the one record is cold's first");
}

#[test]
fn matched_flag_tracks_any_hit() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let eng = warm(dir.path());
    assert!(eng.search(&rooted(dir.path(), "TODO")).unwrap().matched());
    let mut empty = eng
        .search(&rooted(dir.path(), "absent_needle_xyzzy"))
        .unwrap();
    assert!(!empty.matched());
    assert_eq!(drain(empty), Vec::<Match>::new());
}

#[test]
fn pretripped_cancel_yields_clean_empty() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let req = rooted(dir.path(), "TODO");
    let eng = warm(dir.path());
    let token = eng.cancel_token().unwrap();
    token.cancel();
    let cur = eng.run(&req, gist::Run::default().cancel(&token)).unwrap();
    // A pre-tripped token collects nothing (the budget cuts at the first record
    // boundary); the engine stays healthy — an uncancelled search still returns all.
    assert_eq!(drain(cur), Vec::<Match>::new());
    assert_eq!(drain(eng.search(&req).unwrap()), cold(&req));
}

#[test]
fn cancel_from_another_thread_is_safe() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    // A concurrent cancel must never crash the host; on this tiny corpus the scan
    // usually finishes first, so we assert only the safety + subset property.
    let dir = corpus();
    let req = rooted(dir.path(), "TODO");
    let eng = warm(dir.path());
    let token = eng.cancel_token().unwrap();
    let full = cold(&req).len();
    thread::scope(|s| {
        s.spawn(|| token.cancel());
        let got = drain(eng.run(&req, gist::Run::default().cancel(&token)).unwrap());
        assert!(got.len() <= full);
    });
}

#[test]
fn unsupported_pattern_is_typed_error() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let eng = warm(dir.path());
    let err = eng.search(&rooted(dir.path(), r"(a)\1")).unwrap_err();
    assert!(matches!(err, Error::UnsupportedPattern(_)), "got {err:?}");
}

#[test]
fn unrepresentable_options_are_typed_errors() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let eng = warm(dir.path());
    let base = || rooted(dir.path(), "TODO");
    let cases = [
        base().type_("py"),
        base().glob("*.py"),
        base().multiline(),
        base().engine(SearchEngine::Pcre2),
        base().no_ignore(),
    ];
    for req in &cases {
        let err = eng.search(req).unwrap_err();
        assert!(
            matches!(err, Error::Unrepresentable(_)),
            "got {err:?} for {req:?}"
        );
    }
}

#[test]
fn records_outlive_engine_and_cursor() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let req = rooted(dir.path(), "TODO");
    let expected = cold(&req);
    let records = {
        let eng = warm(dir.path());
        let cursor = eng.search(&req).unwrap();
        drain(cursor) // cursor dropped here, engine dropped at block end
    };
    assert_eq!(records, expected);
}
