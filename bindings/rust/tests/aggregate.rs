//! Result-side aggregation tests.
//!
//! Two layers. The pure layer builds [`Match`] records by hand and drives
//! [`gist::tally`] / [`gist::tally_by`] — no binary, so it pins the bucketing,
//! the count-descending/key-ascending order, and the context-line exclusion
//! exactly. The integration layer runs the real engine over a throwaway corpus
//! and asserts `gist::summary` distributes the true matches, skipping cleanly
//! where no binary is built.

use gist::{Axis, Match, MatchKind, SearchRequest, Submatch};

fn have_gist() -> bool {
    gist::binary().is_ok()
}

/// A match line with one submatch (`text` is the matched span).
fn hit(path: &str, line: u64, text: &str) -> Match {
    Match {
        path: path.to_owned(),
        line_number: line,
        text: format!("    {text} = 1"),
        kind: MatchKind::Match,
        submatches: vec![Submatch {
            text: text.to_owned(),
            start: 4,
            end: 4 + text.len(),
        }],
    }
}

/// A context line (no submatch) — must never inflate a tally.
fn context(path: &str, line: u64) -> Match {
    Match {
        path: path.to_owned(),
        line_number: line,
        text: "# neighbourhood".to_owned(),
        kind: MatchKind::Context,
        submatches: Vec::new(),
    }
}

fn sample() -> Vec<Match> {
    vec![
        hit("services/api/wallet.go", 10, "TODO"),
        hit("services/api/wallet.go", 20, "TODO"),
        hit("services/api/ledger.go", 5, "TODO"),
        hit("clients/web/app.ts", 3, "FIXME"),
        context("services/api/wallet.go", 21),
    ]
}

// ─────────────────────────── pure (no binary) ───────────────────────────

#[test]
fn by_file_counts_lines_and_ranks_desc() {
    let t = gist::tally(sample(), Axis::File);
    // wallet.go(2) ahead of ledger.go(1) & app.ts(1); ties broken by key asc.
    let keys: Vec<&str> = t.iter().map(|g| g.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            "services/api/wallet.go",
            "clients/web/app.ts",
            "services/api/ledger.go",
        ]
    );
    assert_eq!(t.top(1)[0].count(), 2);
    assert_eq!(t.total(), 4); // the context line is excluded
    assert_eq!(t.files(), 3);
}

#[test]
fn by_dir_groups_across_files() {
    let t = gist::tally(sample(), Axis::Dir);
    let top = &t.top(1)[0];
    assert_eq!(top.key, "services/api");
    assert_eq!(top.count(), 3); // 2 wallet + 1 ledger
    assert_eq!(top.files(), 2); // spanning two files
    assert_eq!(t.get("clients/web").unwrap().count(), 1);
}

#[test]
fn by_ext_buckets_by_suffix() {
    let t = gist::tally(sample(), Axis::Ext);
    assert_eq!(t.get(".go").unwrap().count(), 3);
    assert_eq!(t.get(".ts").unwrap().count(), 1);
}

#[test]
fn by_match_buckets_by_matched_text() {
    let t = gist::tally(sample(), Axis::Match);
    assert_eq!(t.get("TODO").unwrap().count(), 3);
    assert_eq!(t.get("FIXME").unwrap().count(), 1);
}

#[test]
fn custom_axis_via_tally_by() {
    // Bucket by first path segment — a grouping no named Axis covers.
    let t = gist::tally_by(sample(), |m| {
        m.path.split('/').next().unwrap_or("").to_owned()
    });
    assert_eq!(t.get("services").unwrap().count(), 3);
    assert_eq!(t.get("clients").unwrap().count(), 1);
}

#[test]
fn context_only_input_tallies_nothing() {
    let t = gist::tally(vec![context("a.go", 1), context("a.go", 2)], Axis::File);
    assert!(t.is_empty());
    assert_eq!(t.total(), 0);
}

#[test]
fn get_misses_are_none() {
    let t = gist::tally(sample(), Axis::File);
    assert!(t.get("no/such/file.go").is_none());
}

#[test]
fn top_zero_returns_all() {
    let t = gist::tally(sample(), Axis::File);
    assert_eq!(t.top(0).len(), t.len());
}

// ─────────────────────────── integration (real engine) ───────────────────────────

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
fn summary_distributes_real_matches_by_ext() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let t = gist::summary(SearchRequest::new("TODO").cwd(dir.path()), Axis::Ext).unwrap();
    // Three uppercase TODOs, all in .py files (lowercase 'todo' excluded).
    let py = t.get(".py").expect(".py bucket");
    assert_eq!(py.count(), 3);
    assert!(t.get(".txt").is_none());
}

#[test]
fn free_summary_matches_tally_of_run() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let req = SearchRequest::new("TODO").cwd(dir.path());
    let free = gist::summary(req.clone(), Axis::File).unwrap();
    let tallied = gist::tally(req.run().unwrap(), Axis::File);
    assert_eq!(free.total(), tallied.total());
    assert_eq!(free.len(), tallied.len());
}
