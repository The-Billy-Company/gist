//! Persistent resident-session client (ADR-352 rung 2.5) — Unix only.
//!
//! Long-lived Unix-socket connection to a `gist serve` daemon. Same wire
//! protocol as `src/runtime/session/protocol.zig` / Zig CLI / Python. Fail-open:
//! connect miss, ineligible request, or `decline` → cold
//! ([`SearchRequest::files`] / [`SearchRequest::count`]).

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use crate::error::Result;
use crate::request::SearchRequest;

const PROTOCOL_VERSION: u8 = 2; // must match `protocol.protocol_version`
const DEFAULT_OUT_DIR: &str = ".local/gist-verify"; // `$GIST_DIR` default
const MAX_FRAME: u32 = 16 << 20; // `protocol.max_frame`

// Mirror `protocol.zig::Opcode` / `request.Mode` / `flag_*`.
const OP_HELLO: u8 = 1;
const OP_READY: u8 = 2;
const OP_QUERY: u8 = 3;
const OP_RESULT: u8 = 4;
const MODE_FILES: u8 = 0;
const MODE_COUNT: u8 = 1;
// `smart_case` ships raw; Zig resolves via `effectiveIgnoreCase`. `quiet` is the
// existence early-halt; `max_count` sets bit 7 AND writes a `u64 LE` after the
// flags byte (the only flag carrying a payload — mirror `protocol.zig`).
const FLAG_FIXED: u8 = 1 << 0;
const FLAG_IGNORE_CASE: u8 = 1 << 1;
const FLAG_WORD: u8 = 1 << 3;
const FLAG_INVERT: u8 = 1 << 4;
const FLAG_SMART_CASE: u8 = 1 << 5;
const FLAG_QUIET: u8 = 1 << 6;
const FLAG_MAX_COUNT: u8 = 1 << 7;

/// `$GIST_SESSION_SOCK`, else the per-repo default beside the index
/// (`$GIST_DIR`-relocatable, matching the Zig CLI).
#[must_use]
pub fn default_socket_path() -> String {
    if let Ok(p) = env::var("GIST_SESSION_SOCK") {
        return p;
    }
    let out_dir = env::var("GIST_DIR")
        .ok()
        .map(|d| d.trim_end_matches('/').to_owned())
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| DEFAULT_OUT_DIR.to_owned());
    format!("{out_dir}/gistd.sock")
}

/// True iff the resident daemon can answer `request` byte-identically to cold:
/// default roots, no rich flags, no extra argv, no glob/type scoping — ±case
/// including `smart_case` (sent raw; the Zig session resolves it), ±`word` (the
/// session applies cold's exact post-match word rule), ±`invert` (lane 3b: the
/// session answers `-v` by the `lines(f) − matches(f)` set-complement, sound
/// under the trigram index), ±`quiet` (the existence early-halt) and
/// ±`max_count` (the per-file cap; `0` is the crate's "unlimited", so the cap is
/// simply unconstrained). Mirrors `session/request.zig::classify` and the Python
/// `warm_eligible`.
#[must_use]
pub fn warm_eligible(r: &SearchRequest) -> bool {
    r.paths.is_empty()
        && r.globs.is_empty()
        && r.iglobs.is_empty()
        && r.types.is_empty()
        && r.not_types.is_empty()
        && r.extra_flags.is_empty()
        && !r.hidden
        && !r.no_ignore
        && !r.follow
        && !r.no_index
        && r.before == 0
        && r.after == 0
        && r.context == 0
        && r.max_depth == 0
}

/// One reusable daemon connection. Not `Sync`: give each thread its own
/// `Session` (the connection carries one in-flight request at a time).
pub struct Session {
    path: PathBuf,
    stream: Option<UnixStream>,
}

impl Session {
    /// A session dialing `socket_path` (relative paths resolve against the CWD).
    #[must_use]
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            path: socket_path.into(),
            stream: None,
        }
    }

    /// A session dialing the default socket (`$GIST_SESSION_SOCK` or the per-repo default).
    #[must_use]
    pub fn default_socket() -> Self {
        Self::new(default_socket_path())
    }

    fn resolved_path(&self) -> PathBuf {
        if self.path.is_absolute() {
            self.path.clone()
        } else {
            env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(&self.path)
        }
    }

    /// Open + handshake, or `None` if no daemon / a version mismatch (→ cold).
    fn connect(&self) -> Option<UnixStream> {
        let mut s = UnixStream::connect(self.resolved_path()).ok()?;
        send(&mut s, OP_HELLO, &[PROTOCOL_VERSION]).ok()?;
        let (op, payload) = recv(&mut s).ok()?;
        if op != OP_READY || payload.first() != Some(&PROTOCOL_VERSION) {
            return None;
        }
        Some(s)
    }

    /// Files with ≥1 matching line (`-l`), sorted — warm if the daemon serves
    /// it, else the byte-identical cold answer.
    ///
    /// # Errors
    /// Only the cold path errors (see [`SearchRequest::files`]); a warm miss
    /// silently falls back rather than surfacing a transport error.
    pub fn files(&mut self, request: &SearchRequest) -> Result<Vec<String>> {
        if let Some(Answer::Files(mut v)) = self.query(request, MODE_FILES) {
            v.sort();
            return Ok(v);
        }
        request.files()
    }

    /// Total matching lines across the tree — warm if served, else cold.
    ///
    /// # Errors
    /// As [`files`](Session::files).
    pub fn count(&mut self, request: &SearchRequest) -> Result<usize> {
        if let Some(Answer::Count(n)) = self.query(request, MODE_COUNT) {
            return Ok(n);
        }
        request.count()
    }

    /// One request/response over the (reconnecting) connection. `None` on any
    /// miss — an ineligible request, no daemon, `decline`/`err`, or a wire
    /// hiccup — so the caller runs cold. A dropped connection is retried once
    /// (a daemon may have restarted).
    fn query(&mut self, request: &SearchRequest, mode: u8) -> Option<Answer> {
        if !warm_eligible(request) {
            return None;
        }
        for _ in 0..2 {
            if self.stream.is_none() {
                self.stream = self.connect();
            }
            let s = self.stream.as_mut()?;
            let mut flags = 0u8;
            if request.fixed {
                flags |= FLAG_FIXED;
            }
            if request.ignore_case {
                flags |= FLAG_IGNORE_CASE;
            }
            if request.word {
                flags |= FLAG_WORD;
            }
            if request.invert {
                flags |= FLAG_INVERT;
            }
            if request.smart_case {
                flags |= FLAG_SMART_CASE;
            }
            if request.quiet {
                flags |= FLAG_QUIET;
            }
            if request.max_count > 0 {
                flags |= FLAG_MAX_COUNT;
            }
            let mut body = vec![mode, flags];
            if request.max_count > 0 {
                body.extend_from_slice(&u64::from(request.max_count).to_le_bytes());
            }
            body.extend_from_slice(request.pattern.as_bytes());
            let exchange = send(s, OP_QUERY, &body).and_then(|()| recv(s));
            match exchange {
                Ok((OP_RESULT, payload)) => return decode_result(&payload, mode),
                Ok(_) => return None, // decline / err → cold
                Err(_) => {
                    self.stream = None; // stale connection → reconnect + retry once
                }
            }
        }
        None
    }
}

/// A decoded warm answer.
enum Answer {
    Files(Vec<String>),
    Count(usize),
}

// ───────────────────────────── wire codec ─────────────────────────────

fn send(s: &mut UnixStream, opcode: u8, payload: &[u8]) -> io::Result<()> {
    let len = u32::try_from(1 + payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame too large"))?;
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.extend_from_slice(&len.to_le_bytes());
    frame.push(opcode);
    frame.extend_from_slice(payload);
    s.write_all(&frame)
}

fn recv(s: &mut UnixStream) -> io::Result<(u8, Vec<u8>)> {
    let mut len_buf = [0u8; 4];
    s.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf);
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bad frame length",
        ));
    }
    let mut body = vec![0u8; len as usize];
    s.read_exact(&mut body)?;
    let op = body[0];
    Ok((op, body[1..].to_vec()))
}

fn decode_result(payload: &[u8], expect_mode: u8) -> Option<Answer> {
    if payload.first() != Some(&expect_mode) {
        return None;
    }
    if expect_mode == MODE_COUNT {
        let n = payload.get(1..9)?;
        return Some(Answer::Count(u64::from_le_bytes(n.try_into().ok()?) as usize));
    }
    // files: [u8 mode][u32 n][ per file: u32 len + bytes ]
    let count = u32::from_le_bytes(payload.get(1..5)?.try_into().ok()?);
    let mut out = Vec::with_capacity(count as usize);
    let mut off = 5usize;
    for _ in 0..count {
        let plen = u32::from_le_bytes(payload.get(off..off + 4)?.try_into().ok()?) as usize;
        off += 4;
        let bytes = payload.get(off..off + plen)?;
        out.push(String::from_utf8_lossy(bytes).into_owned());
        off += plen;
    }
    Some(Answer::Files(out))
}
