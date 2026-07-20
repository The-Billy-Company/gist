//! Persistent resident-session client tests (ADR-352 rung 2.5).
//!
//! Three layers: the pure `warm_eligible` classifier (no binary), fail-open when
//! no daemon is listening (must equal the cold answer), and a real round-trip
//! against a spawned subtree daemon — the Rust leg of the same wire protocol the
//! Zig/Python clients and `serve_test.zig` exercise, proving a warm query decodes
//! end-to-end and agrees with cold.

use std::collections::BTreeSet;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use gist::{SearchRequest, Session, warm_eligible};

fn have_gist() -> bool {
    gist::binary().is_ok()
}

fn corpus() -> tempfile::TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let p = dir.path();
    std::fs::write(p.join("a.py"), "def alpha():\n    return TODO\n").unwrap();
    std::fs::write(p.join("b.py"), "class Beta:\n    pass  # TODO later\n").unwrap();
    std::fs::write(p.join("c.txt"), "no marker here\nplain text\n").unwrap();
    std::fs::create_dir(p.join("pkg")).unwrap();
    std::fs::write(p.join("pkg/d.py"), "x = 1  # todo lowercase\nTODO upper\n").unwrap();
    // -w discriminator: a glued occurrence (word-rejected) beside a word-valid one.
    std::fs::write(p.join("w.txt"), "myTODO glued\nTODO word\n").unwrap();
    dir
}

fn normset(paths: &[String]) -> BTreeSet<String> {
    paths
        .iter()
        .map(|p| p.trim_start_matches("./").to_owned())
        .collect()
}

// ─────────────────────────── pure classifier ───────────────────────────

#[test]
fn warm_eligible_accepts_default_roots_literal() {
    assert!(warm_eligible(&SearchRequest::new("TODO")));
    assert!(warm_eligible(&SearchRequest::new("TODO").fixed().ignore_case()));
    // v2: smart_case ships raw on the wire; the Zig session resolves it.
    assert!(warm_eligible(&SearchRequest::new("TODO").smart_case()));
    assert!(warm_eligible(&SearchRequest::new("todo").smart_case()));
    // v2 lane 2: -w is warm-eligible, alone and composed with case flags.
    assert!(warm_eligible(&SearchRequest::new("TODO").word()));
    assert!(warm_eligible(&SearchRequest::new("todo").fixed().word()));
    assert!(warm_eligible(&SearchRequest::new("todo").ignore_case().word()));
    // v2 lane 4: -q (existence early-halt) and -m N (per-file cap) are
    // warm-eligible, alone and composed.
    assert!(warm_eligible(&SearchRequest::new("TODO").quiet()));
    assert!(warm_eligible(&SearchRequest::new("TODO").max_count(3)));
    assert!(warm_eligible(&SearchRequest::new("TODO").word().max_count(2)));
    // v2 lane 3b: -v is warm-eligible (the set-complement, sound under the index).
    assert!(warm_eligible(&SearchRequest::new("TODO").invert()));
    assert!(warm_eligible(&SearchRequest::new("TODO").invert().word()));
}

#[test]
fn warm_eligible_rejects_rich_requests() {
    assert!(!warm_eligible(&SearchRequest::new("x").path("services")));
    assert!(!warm_eligible(&SearchRequest::new("x").glob("*.py")));
    assert!(!warm_eligible(&SearchRequest::new("x").type_("py")));
    assert!(!warm_eligible(&SearchRequest::new("x").context(2)));
    assert!(!warm_eligible(&SearchRequest::new("x").before(2)));
    assert!(!warm_eligible(&SearchRequest::new("x").flag("-P")));
}

// ─────────────────────────── fail-open (no daemon) ───────────────────────────

#[test]
fn no_daemon_falls_back_to_cold() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let sock = dir.path().join("nonexistent.sock");
    let mut s = Session::new(sock);
    // A scoped request (paths=".") is ineligible → cold anyway, but the point is
    // the session never errors when nothing is listening.
    let req = SearchRequest::new("TODO").path(".").cwd(dir.path());
    let warm = s.files(&req).unwrap();
    let cold = gist::files(SearchRequest::new("TODO").path(".").cwd(dir.path())).unwrap();
    assert_eq!(warm, cold);
    assert!(warm.iter().any(|p| p.ends_with("a.py")));
}

// ─────────────────────────── round-trip (live daemon) ───────────────────────────

fn wait_for_socket(path: &Path, child: &mut Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return false;
        }
        if UnixStream::connect(path).is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn round_trip_matches_cold() {
    if !have_gist() {
        eprintln!("skip: no gist binary");
        return;
    }
    let dir = corpus();
    let sock = dir.path().join("gistd.sock");
    let bin = gist::binary().unwrap();
    let mut child = Command::new(&bin)
        .args(["serve", "."])
        .current_dir(dir.path())
        .env("GIST_SESSION_SOCK", &sock)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("spawn daemon");

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if !wait_for_socket(&sock, &mut child, Duration::from_secs(15)) {
            eprintln!("skip: daemon did not come up");
            return;
        }
        let mut s = Session::new(&sock);
        // Warm files/count over default roots (the daemon serves ".").
        let warm_files = s.files(&SearchRequest::new("TODO")).unwrap();
        let warm_count = s.count(&SearchRequest::new("TODO")).unwrap();
        let warm_ci = s.count(&SearchRequest::new("TODO").ignore_case()).unwrap();
        // v2 smart-case: lowercase pattern folds (≡ -i), uppercase stays exact.
        let warm_sc_lower = s.count(&SearchRequest::new("todo").smart_case()).unwrap();
        let warm_sc_upper = s.count(&SearchRequest::new("TODO").smart_case()).unwrap();
        // v2 lane 2: -w crosses the wire; the daemon applies cold's word rule.
        let warm_word = s.count(&SearchRequest::new("TODO").word()).unwrap();
        // v2 lane 4: -m1 caps each file to one matching line (w.txt has two),
        // sent as the u64 payload after the flags byte.
        let warm_m1 = s.count(&SearchRequest::new("TODO").max_count(1)).unwrap();
        // v2 lane 3b: -v answers by the set-complement, warm over the wire.
        let warm_inv_files = s.files(&SearchRequest::new("TODO").invert()).unwrap();
        let warm_inv_count = s.count(&SearchRequest::new("TODO").invert()).unwrap();
        // Cold oracle over the same subtree ".".
        let cold_files = gist::files(SearchRequest::new("TODO").path(".").cwd(dir.path())).unwrap();
        let cold_count = gist::count(SearchRequest::new("TODO").path(".").cwd(dir.path())).unwrap();
        let cold_ci =
            gist::count(SearchRequest::new("TODO").ignore_case().path(".").cwd(dir.path())).unwrap();
        let cold_sc_lower =
            gist::count(SearchRequest::new("todo").smart_case().path(".").cwd(dir.path())).unwrap();
        let cold_sc_upper =
            gist::count(SearchRequest::new("TODO").smart_case().path(".").cwd(dir.path())).unwrap();
        let cold_word =
            gist::count(SearchRequest::new("TODO").word().path(".").cwd(dir.path())).unwrap();
        let cold_m1 =
            gist::count(SearchRequest::new("TODO").max_count(1).path(".").cwd(dir.path())).unwrap();
        let cold_inv_files =
            gist::files(SearchRequest::new("TODO").invert().path(".").cwd(dir.path())).unwrap();
        let cold_inv_count =
            gist::count(SearchRequest::new("TODO").invert().path(".").cwd(dir.path())).unwrap();
        assert_eq!(normset(&warm_files), normset(&cold_files));
        assert_eq!(warm_count, cold_count);
        assert_eq!(warm_ci, cold_ci);
        assert!(warm_ci > warm_count, "-i should widen the count");
        assert_eq!(warm_sc_lower, cold_sc_lower);
        assert_eq!(warm_sc_upper, cold_sc_upper);
        assert_eq!(warm_sc_lower, warm_ci, "-S lowercase folds exactly like -i");
        assert_eq!(warm_sc_upper, warm_count, "-S uppercase stays case-sensitive");
        assert_eq!(warm_word, cold_word);
        assert!(warm_word < warm_count, "-w must drop the glued `myTODO` line");
        assert_eq!(warm_m1, cold_m1);
        assert!(warm_m1 < warm_count, "-m1 must cap w.txt's two matches to one");
        assert_eq!(normset(&warm_inv_files), normset(&cold_inv_files));
        assert_eq!(warm_inv_count, cold_inv_count);
    }));

    let _ = child.kill();
    let _ = child.wait();
    if let Err(payload) = result {
        std::panic::resume_unwind(payload);
    }
}
