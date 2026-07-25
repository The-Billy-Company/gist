//! The analytic verbs, end to end against the certified binaries (ADR-377).
//!
//! The unit tests decode synthesized buffers; these run the real thing over a
//! planted corpus, so what is under test is the part synthesis cannot reach: the
//! argv a verb lowers into, the tier that answers, and whether the rows that
//! come back are the rows `[row_schemas]` says that verb returns.
//!
//! Expectations come from the contract, never from a previous run: a row must
//! carry the schema `[analytic.verbs]` declares, every field it carries must be
//! declared by that schema, and a reported grade must equal the band
//! `[irregex.grades]` puts that score in. Kinship distances themselves are the
//! engine's business — asserting a particular number here would be testing the
//! compressor, not the binding.

use std::process::Command;

use gist::contract::schema::{SCHEMAS, VERBS};
use gist::{Channel, Grade, Row, Rows};

/// Skip cleanly where the compression face is not installed
/// (`make install-gist`) — the same convention the other suites use.
fn have_relate() -> bool {
    Command::new(std::env::var("RELATE_BIN").unwrap_or_else(|_| "relate".into()))
        .arg("--schema")
        .output()
        .is_ok_and(|o| o.status.success())
}

/// Two identical files plus an unrelated one, so kinship has something true to
/// find and something true to reject.
///
/// The files are repetitive on purpose: a compression sketch of a three-line
/// file is mostly noise, and the engine declines to score at that size — which
/// would make this suite a test of the corpus rather than of the binding.
fn corpus() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let pkg = dir.path().join("pkg");
    std::fs::create_dir_all(&pkg).expect("mkdir");
    let twin: String = (0..30)
        .map(|i| {
            format!(
                "def widget_{i}(request, session):\n    \
                 payload = request.get('payload', {{}})\n    \
                 total = sum(payload.get('values', []))\n    \
                 session.record('widget_{i}', total)\n    \
                 return {{'ok': True, 'total': total}}\n\n"
            )
        })
        .collect();
    let other: String = std::iter::once("import json\n\n".to_owned())
        .chain((0..30).map(|i| {
            format!("def load_{i}(path):\n    with open(path) as fh:\n        return json.loads(fh.read())\n\n")
        }))
        .collect();
    std::fs::write(pkg.join("a.py"), &twin).expect("write");
    std::fs::write(pkg.join("b.py"), &twin).expect("write");
    std::fs::write(pkg.join("c.py"), other).expect("write");
    dir
}

fn schema_of(verb: &str) -> u32 {
    VERBS
        .iter()
        .find(|v| v.name == verb)
        .map_or(0, |v| v.schema)
}

/// Every invariant a decoded row owes the contract, regardless of verb.
fn holds_to_contract(row: Row<'_>, verb: &str) {
    assert_eq!(
        row.schema_id(),
        schema_of(verb),
        "`{verb}` must answer in the schema `[analytic.verbs]` declares for it"
    );
    let declared = SCHEMAS
        .iter()
        .find(|s| s.id == row.schema_id())
        .expect("a decoded row names a schema this build declares");
    for (name, _) in row.iter() {
        assert!(
            declared.fields.iter().any(|f| f.name == name),
            "`{name}` is not a field of `{}`",
            declared.name
        );
    }
}

/// A graded row's band must be the one the contract puts that score in — the
/// engine and this crate reading `[irregex.grades]` the same way is what makes
/// `min_grade` mean anything.
fn grade_agrees(row: Row<'_>, score_field: &str) {
    let (Some(score), Some(grade), Some(channel)) = (
        row.real(score_field),
        row.variant("grade").and_then(Grade::from_variant),
        row.variant("channel").and_then(Channel::from_variant),
    ) else {
        return; // an ungraded or unscored row has nothing to disagree about
    };
    assert_eq!(
        grade,
        Grade::band(score, channel),
        "engine graded {score} on `{channel}` as {grade:?}"
    );
}

fn collect(rows: &Rows, verb: &str) -> usize {
    let mut n = 0;
    for row in rows.iter() {
        let row = row.expect("a row the engine emitted decodes");
        holds_to_contract(row, verb);
        n += 1;
    }
    assert!(
        rows.stats().tier.is_some(),
        "every answer names the tier that produced it"
    );
    n
}

#[test]
fn similar_finds_the_twin_and_grades_it_by_the_contract() {
    if !have_relate() {
        eprintln!("skip: no relate binary");
        return;
    }
    let dir = corpus();
    let rows = gist::relate::similar(dir.path().join("pkg/a.py").display().to_string())
        .root(dir.path())
        .no_index()
        .rows()
        .expect("similar answers");
    let mut saw_twin = false;
    for row in rows.iter() {
        let row = row.expect("decodes");
        holds_to_contract(row, "similar");
        grade_agrees(row, "distance");
        saw_twin |= row.text("path").is_some_and(|p| p.ends_with("b.py"));
    }
    assert!(saw_twin, "an exact copy of the probe must surface as kin");
}

#[test]
fn a_grade_floor_withholds_rather_than_reranks() {
    if !have_relate() {
        eprintln!("skip: no relate binary");
        return;
    }
    let dir = corpus();
    let probe = dir.path().join("pkg/a.py").display().to_string();
    let all = gist::relate::similar(&probe)
        .root(dir.path())
        .no_index()
        .rows()
        .expect("similar answers");
    let strong = gist::relate::similar(&probe)
        .root(dir.path())
        .no_index()
        .min_grade(Grade::Identical)
        .rows()
        .expect("similar answers");
    // The floor is a filter, not a re-ranking: what survives is a subset, and
    // everything in it clears the floor.
    assert!(strong.to_vec().expect("decodes").len() <= all.to_vec().expect("decodes").len());
    for row in strong.iter() {
        let row = row.expect("decodes");
        let grade = row.variant("grade").and_then(Grade::from_variant);
        assert!(
            grade.is_none_or(|g| g.admits(Grade::Identical)),
            "a withheld grade leaked through the floor"
        );
    }
}

#[test]
fn clusters_answers_in_the_family_schema_not_the_pair_schema() {
    if !have_relate() {
        eprintln!("skip: no relate binary");
        return;
    }
    let dir = corpus();
    let rows = gist::relate::clusters()
        .root(dir.path())
        .no_index()
        .rows()
        .expect("clusters answers");
    // Two identical files are one family; the assertion that matters is that
    // whatever comes back is shaped like a family, since `dups` and `clusters`
    // ride the same CLI verb and differ only by `--shape`.
    assert!(
        collect(&rows, "clusters") >= 1,
        "two identical planted files must form at least one family"
    );
}

#[test]
fn a_sweep_attributes_each_pattern_in_one_walk() {
    if !have_relate() {
        eprintln!("skip: no relate binary");
        return;
    }
    let dir = corpus();
    let rows = gist::relate::patterns(["widget", "json"])
        .root(dir.path())
        .rows()
        .expect("patterns answers");
    // Attribution is by the caller's own pattern index, not by echoing the
    // pattern text back — so a hit is traceable without string-matching it.
    let hits: Vec<_> = rows
        .iter()
        .map(|r| r.expect("decodes"))
        .filter_map(|r| {
            holds_to_contract(r, "patterns");
            Some((r.int("pattern_id")?, r.text("path")?.to_owned()))
        })
        .collect();
    for (id, tail) in [(0, "a.py"), (1, "c.py")] {
        assert!(
            hits.iter()
                .any(|(hit, path)| *hit == id && path.ends_with(tail)),
            "pattern {id} matches {tail} in this corpus but was not attributed: {hits:?}"
        );
    }
}

#[test]
fn pack_prices_a_query_the_corpus_has_never_seen_as_foreign() {
    if !have_relate() {
        eprintln!("skip: no relate binary");
        return;
    }
    let dir = corpus();
    // `foreign` is the fact that separates "your text isn't in this repo" from
    // "no results", so a query of pure nonsense is the case it exists for.
    let rows = gist::relate::pack("zzqxv wnkfjd plorbunt zzqxv")
        .root(dir.path())
        .rows()
        .expect("pack answers");
    collect(&rows, "pack");
    assert!(
        rows.stats().foreign > 0,
        "a query built from nothing in the corpus must report foreign fingerprints"
    );
}
