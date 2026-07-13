//! Persistent resident-session client (ADR-352 rung 2.5) — Unix only.
//!
//! A long-lived Unix-socket connection to a `gist serve` daemon, reused across
//! many queries so an eligible request answers warm — without re-paying the cold
//! subprocess's process + index-mmap + candidate-read startup on every call. This
//! is the Rust leg of the same wire protocol `src/session/protocol.zig` defines
//! and the Zig CLI + Python clients speak; the daemon is the single source of
//! truth, so all three clients frame-match by construction.
//!
//! Fail-open, always: a [`Session`] that cannot connect, whose request is
//! ineligible, or that receives a `decline` transparently falls back to the
//! certified cold subprocess ([`SearchRequest::files`]/[`SearchRequest::count`])
//! and returns the byte-identical answer. The daemon is a pure accelerator — it
//! never adds a failure mode a caller must handle, only removes latency when one
//! is listening.

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use crate::error::Result;
use crate::request::SearchRequest;

const PROTOCOL_VERSION: u8 = 1;
const DEFAULT_SOCKET: &str = ".local/gist-verify/gistd.sock";
const MAX_FRAME: u32 = 16 << 20; // matches `protocol.max_frame`; a hostile/looping-peer cap.

// Opcodes — mirror `protocol.zig::Opcode`.
const OP_HELLO: u8 = 1;
const OP_READY: u8 = 2;
const OP_QUERY: u8 = 3;
const OP_RESULT: u8 = 4;

// Mode bytes — `request.Mode` enum order (files, count).
const MODE_FILES: u8 = 0;
const MODE_COUNT: u8 = 1;
// Query flag bits — `protocol.zig::flag_*`.
const FLAG_FIXED: u8 = 1 << 0;
const FLAG_IGNORE_CASE: u8 = 1 << 1;

/// `$GIST_SESSION_SOCK`, else the per-repo default beside the index.
#[must_use]
pub fn default_socket_path() -> String {
    env::var("GIST_SESSION_SOCK").unwrap_or_else(|_| DEFAULT_SOCKET.to_owned())
}

/// True iff the resident daemon can answer `request` byte-identically to cold:
/// default roots, no rich flags, no extra argv, no glob/type scoping. Mirrors
/// `session/request.zig::classify` and the Python `warm_eligible`.
#[must_use]
pub fn warm_eligible(r: &SearchRequest) -> bool {
    r.paths.is_empty()
        && r.globs.is_empty()
        && r.iglobs.is_empty()
        && r.types.is_empty()
        && r.not_types.is_empty()
        && r.extra_flags.is_empty()
        && !r.smart_case
        && !r.word
        && !r.invert
        && !r.hidden
        && !r.no_ignore
        && !r.follow
        && !r.no_index
        && r.before == 0
        && r.after == 0
        && r.context == 0
        && r.max_count == 0
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
            let mut body = vec![mode, flags];
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
