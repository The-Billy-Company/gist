//! The subprocess engine adapter (ADR-352).
//!
//! Locates the certified `gist` binary, lowers a [`SearchRequest`] into its
//! rg-parity argv, runs it under a wall-clock guard, and parses the result. All
//! faces of the unified API funnel through here, so results are produced by the
//! *same* engine the CLI uses — never a second matcher. Subprocess is the
//! authoritative transport today: a bad pattern exits the child (code 2),
//! surfaced as a typed error, and never terminates the host the way an
//! in-process `die()`/exit would.

use std::env;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use crate::contract::{self, EXIT_ERROR, EXIT_MATCHED, EXIT_NO_MATCH, Match};
use crate::error::{Error, Result};
use crate::request::SearchRequest;

/// Default wall-clock ceiling for a single engine invocation.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

// stderr phrases the engine prints when a pattern/flag is outside its
// linear-time syntax (see src/commands/ripgrep/{args,run}.zig `die` messages).
const UNSUPPORTED_MARKERS: &[&str] = &[
    "unsupported",
    "use ripgrep",
    "use rg for this",
    "linear-time syntax",
    "not yet implemented",
];

static BINARY: OnceLock<PathBuf> = OnceLock::new();

/// Absolute path to the `gist` binary. Resolution order: env `GIST_BIN`, then
/// `gist` on `PATH`, then the repo's built `zig-out/bin/gist`. The success is
/// cached; a failure re-resolves on the next call.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves.
pub fn binary() -> Result<PathBuf> {
    if let Some(b) = BINARY.get() {
        return Ok(b.clone());
    }
    let resolved = resolve()?;
    let _ = BINARY.set(resolved.clone());
    Ok(resolved)
}

fn resolve() -> Result<PathBuf> {
    if let Some(raw) = env::var_os("GIST_BIN") {
        let p = expand_tilde(&raw);
        if p.is_file() {
            return Ok(p);
        }
        return Err(Error::NotFound(format!(
            "GIST_BIN={} is not a file",
            p.display()
        )));
    }
    if let Some(p) = which("gist") {
        return Ok(p);
    }
    // src/engine.rs → CARGO_MANIFEST_DIR is bindings/rust; the kernel root is ../..
    let built = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../zig-out/bin/gist");
    if built.is_file() {
        return Ok(built);
    }
    Err(Error::NotFound(
        "no `gist` binary — set GIST_BIN, put `gist` on PATH, or build it with `make install-gist`"
            .to_owned(),
    ))
}

fn expand_tilde(raw: &std::ffi::OsStr) -> PathBuf {
    raw.to_string_lossy()
        .strip_prefix("~/")
        .and_then(|rest| env::var_os("HOME").map(|home| PathBuf::from(home).join(rest)))
        .unwrap_or_else(|| PathBuf::from(raw))
}

fn which(name: &str) -> Option<PathBuf> {
    let paths = env::var_os("PATH")?;
    env::split_paths(&paths)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
}

/// Outcome of one child invocation: the exit code plus captured streams.
struct Output {
    code: i32,
    stdout: String,
    stderr: String,
}

/// Run `gist rg <flags> <tail> --regexp <pattern> [paths]` under the request's
/// timeout. `--regexp` carries the pattern so it can never be mistaken for a
/// flag or a path.
fn invoke(tail: &[&str], request: &SearchRequest) -> Result<Output> {
    let bin = binary()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("rg");
    cmd.args(request.to_argv());
    cmd.args(tail);
    cmd.arg("--regexp").arg(&request.pattern);
    cmd.args(&request.paths);
    if let Some(dir) = &request.cwd {
        cmd.current_dir(dir);
    }
    let out = spawn_with_timeout(cmd, request.timeout)?;
    if out.code == EXIT_ERROR {
        let stderr = out.stderr.trim();
        let low = stderr.to_lowercase();
        if UNSUPPORTED_MARKERS.iter().any(|m| low.contains(m)) {
            return Err(Error::UnsupportedPattern(nonempty(
                stderr,
                "unsupported pattern",
            )));
        }
        return Err(Error::Failed(nonempty(stderr, "gist exited 2")));
    }
    if out.code != EXIT_MATCHED && out.code != EXIT_NO_MATCH {
        return Err(Error::Failed(format!(
            "gist exited {}: {}",
            out.code,
            out.stderr.trim()
        )));
    }
    Ok(out)
}

fn nonempty(s: &str, fallback: &str) -> String {
    if s.is_empty() {
        fallback.to_owned()
    } else {
        s.to_owned()
    }
}

/// Spawn `cmd`, draining stdout/stderr on reader threads so a full pipe can
/// never deadlock the wait, and kill the child if it outlives `timeout`.
/// stdin is detached (`/dev/null`) so the engine always walks the tree rather
/// than reading stdin when no path args are given.
fn spawn_with_timeout(mut cmd: Command, timeout: Duration) -> Result<Output> {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    let mut out_pipe = child.stdout.take().expect("piped stdout");
    let mut err_pipe = child.stderr.take().expect("piped stderr");
    let out_reader = thread::spawn(move || {
        let mut s = String::new();
        let _ = out_pipe.read_to_string(&mut s);
        s
    });
    let err_reader = thread::spawn(move || {
        let mut s = String::new();
        let _ = err_pipe.read_to_string(&mut s);
        s
    });

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = out_reader.join();
            let _ = err_reader.join();
            return Err(Error::Failed(format!(
                "gist timed out after {}s",
                timeout.as_secs()
            )));
        }
        thread::sleep(Duration::from_millis(5));
    };

    let stdout = out_reader.join().unwrap_or_default();
    let stderr = err_reader.join().unwrap_or_default();
    Ok(Output {
        code: status.code().unwrap_or(EXIT_ERROR),
        stdout,
        stderr,
    })
}

/// Execute a request and return structured matches.
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn run(request: &SearchRequest) -> Result<Vec<Match>> {
    Ok(contract::parse_json(&invoke(&["--json"], request)?.stdout))
}

/// Paths of files with ≥1 matching line (`-l`), sorted.
///
/// # Errors
/// See [`SearchRequest::files`].
pub fn files(request: &SearchRequest) -> Result<Vec<String>> {
    let out = invoke(&["-l"], request)?;
    let mut paths: Vec<String> = out
        .stdout
        .lines()
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect();
    paths.sort();
    Ok(paths)
}

/// Total matching lines across the searched tree (`--count-matches`).
///
/// # Errors
/// See [`SearchRequest::count`].
pub fn count(request: &SearchRequest) -> Result<usize> {
    let out = invoke(&["--count-matches", "--no-filename"], request)?;
    Ok(out
        .stdout
        .lines()
        .filter_map(|l| l.trim().parse::<usize>().ok())
        .sum())
}

/// The persisted-index report (`gist status`) — is an index ready, how fresh,
/// how big. Read-only; safe to call blind.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn status() -> Result<String> {
    let bin = binary()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("status");
    Ok(spawn_with_timeout(cmd, DEFAULT_TIMEOUT)?.stdout)
}

/// The driven binary's semver (from `gist --version`).
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn version() -> Result<String> {
    let bin = binary()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("--version");
    let out = spawn_with_timeout(cmd, DEFAULT_TIMEOUT)?;
    // `gist 0.1.0` → `0.1.0`. The banner may print via Zig `std.debug.print`
    // (stderr), so read whichever stream carries it.
    let banner = if out.stdout.trim().is_empty() {
        out.stderr
    } else {
        out.stdout
    };
    Ok(banner
        .split_whitespace()
        .last()
        .unwrap_or_default()
        .to_owned())
}
