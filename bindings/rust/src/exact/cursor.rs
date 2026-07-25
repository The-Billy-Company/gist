//! The in-process `Engine` / `Cursor` surface over the pull-cursor C ABI
//! (ADR-352), compiled only under the `native` feature.
//!
//! The crate's top-level [`crate::search`] helpers answer a *one-shot* query over
//! the certified subprocess. This module is the other shape a host wants: a **warm
//! [`Engine`] held open** across many queries, each producing a **pull [`Cursor`]**
//! the caller drives at its own pace — the callback-free sibling of the push
//! session, so no C-to-Rust trampoline runs during a scan.
//!
//! Ownership is RAII end to end. [`Engine`] owns the warm corpus + index + I/O
//! pool and serializes [`search`](Engine::search) (the resident engine is
//! single-writer), but a materialized [`Cursor`] owns its records in a private
//! arena and is fully independent of the engine — cursors outlive it and iterate
//! without the engine lock. [`CancelToken`] is an explicit, thread-safe stop one
//! thread trips while another is blocked in `search`. Every handle frees on
//! `Drop`; failures are the crate's typed [`Error`], never a terminated host.

use std::ffi::CString;
use std::mem::MaybeUninit;
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

use crate::contract::{Match, MatchKind, Submatch};
use crate::error::{Error, Result};
use crate::request::{SearchEngine, SearchRequest};
use crate::sys;

/// Records-per-native-call default for [`Cursor::batches`]: enough to amortize the
/// FFI crossing without holding a large transient view buffer.
pub const DEFAULT_BATCH: usize = 64;

/// A thread-safe cooperative stop shared into [`Engine`] searches via [`Run::cancel`].
///
/// One thread may [`cancel`](Self::cancel) while another is blocked in
/// [`Engine::search`] (the native scan holds no Rust lock the canceler needs);
/// the scan stops at its next record boundary, keeping whatever it gathered. A
/// token is reusable across searches until dropped.
pub struct CancelToken {
    inner: *mut sys::irregex_cancel,
}

// The token is a bare atomic flag behind the pointer; sharing `&CancelToken`
// across threads (to cancel a scan another thread runs) is the whole point.
unsafe impl Send for CancelToken {}
unsafe impl Sync for CancelToken {}

impl CancelToken {
    /// Allocate a fresh (unset) token.
    ///
    /// # Errors
    /// [`Error::Failed`] if the native allocation fails (out of memory).
    pub fn new() -> Result<Self> {
        let mut out: *mut sys::irregex_cancel = std::ptr::null_mut();
        let status = unsafe { sys::irregex_cancel_new(&mut out) };
        if status != sys::OK {
            return Err(status_error(status, "allocate cancel token"));
        }
        Ok(Self { inner: out })
    }

    /// Request cancellation of any in-flight search using this token.
    pub fn cancel(&self) {
        unsafe { sys::irregex_cancel_request(self.inner) };
    }
}

impl Drop for CancelToken {
    fn drop(&mut self) {
        unsafe { sys::irregex_cancel_free(self.inner) };
    }
}

/// Per-operation budgets for one [`Engine::search`], each honored at a record
/// boundary (never a torn record). All absent = run to completion.
#[derive(Default)]
pub struct Run<'a> {
    /// A stop another thread may trip mid-scan.
    pub cancel: Option<&'a CancelToken>,
    /// Wall-clock ceiling measured from the start of the search.
    pub timeout: Option<Duration>,
    /// Stop after this many records land.
    pub max_results: Option<usize>,
}

impl<'a> Run<'a> {
    /// Attach a cancellation token.
    #[must_use]
    pub fn cancel(mut self, token: &'a CancelToken) -> Self {
        self.cancel = Some(token);
        self
    }

    /// Set a wall-clock budget.
    #[must_use]
    pub fn timeout(mut self, d: Duration) -> Self {
        self.timeout = Some(d);
        self
    }

    /// Set a result-count budget.
    #[must_use]
    pub fn max_results(mut self, n: usize) -> Self {
        self.max_results = Some(n);
        self
    }
}

/// A pull result handle over one search: an iterator of owned [`Match`] records.
///
/// Iterate it directly ([`Iterator`]) for record-at-a-time consumption, or call
/// [`batches`](Self::batches) to amortize the native crossing. Records are copied
/// into owned values, so they outlive the cursor (and the engine); the native
/// record buffer frees on [`Drop`].
#[derive(Debug)]
pub struct Cursor {
    inner: *mut sys::irregex_cursor,
    matched: Option<bool>,
    done: bool,
}

// A cursor is a self-contained owned buffer; it may move between threads, but a
// single cursor is a single iterator (no `Sync`).
unsafe impl Send for Cursor {}

impl Cursor {
    /// Whether any file matched (cold's exit-code boolean), even if a budget cut
    /// the scan short. Stable for the cursor's lifetime.
    pub fn matched(&mut self) -> bool {
        *self
            .matched
            .get_or_insert_with(|| unsafe { sys::irregex_cursor_matched(self.inner) } != 0)
    }

    /// Yield lists of up to `size` records, each filled by one native call — the
    /// same records [`Iterator::next`] yields, chunked to trade per-record call
    /// overhead for a larger transient view buffer.
    ///
    /// # Panics
    /// If `size` is zero.
    pub fn batches(self, size: usize) -> Batches {
        assert!(size >= 1, "batch size must be >= 1");
        Batches {
            cursor: self,
            buf: (0..size).map(|_| MaybeUninit::uninit()).collect(),
        }
    }
}

impl Iterator for Cursor {
    type Item = Result<Match>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let mut view = MaybeUninit::<sys::MatchView>::uninit();
        let status = unsafe { sys::irregex_cursor_next(self.inner, view.as_mut_ptr()) };
        match status {
            sys::MATCH => Some(Ok(to_match(unsafe { view.assume_init_ref() }))),
            sys::OK => {
                self.done = true;
                None
            }
            other => {
                self.done = true;
                Some(Err(status_error(other, "cursor advance")))
            }
        }
    }
}

impl Drop for Cursor {
    fn drop(&mut self) {
        unsafe { sys::irregex_cursor_close(self.inner) };
    }
}

/// The chunked view of a [`Cursor`] returned by [`Cursor::batches`]: an iterator
/// of owned record lists, each filled by a single native `next_batch` call.
pub struct Batches {
    cursor: Cursor,
    buf: Vec<MaybeUninit<sys::MatchView>>,
}

impl Iterator for Batches {
    type Item = Result<Vec<Match>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.cursor.done {
            return None;
        }
        let mut written: usize = 0;
        let status = unsafe {
            sys::irregex_cursor_next_batch(
                self.cursor.inner,
                self.buf.as_mut_ptr().cast::<sys::MatchView>(),
                self.buf.len(),
                &mut written,
            )
        };
        match status {
            sys::MATCH => {
                let views = &self.buf[..written];
                Some(Ok(views
                    .iter()
                    .map(|v| to_match(unsafe { v.assume_init_ref() }))
                    .collect()))
            }
            sys::OK => {
                self.cursor.done = true;
                None
            }
            other => {
                self.cursor.done = true;
                Some(Err(status_error(other, "cursor batch")))
            }
        }
    }
}

/// A warm in-process corpus queried many times, each yielding a pull [`Cursor`].
///
/// Open it over zero or more roots ([`open`](Self::open); no roots = the rootless
/// CWD walk a bare `gist <pattern>` scans). [`search`](Self::search) is serialized
/// (the resident engine is single-writer), but the cursors it returns are
/// independent and iterable in parallel. The corpus frees on [`Drop`].
pub struct Engine {
    inner: *mut sys::irregex_engine,
    lock: Mutex<()>,
}

// The pointer is only touched under `lock`; a materialized cursor never reaches
// back into the engine, so `&Engine` is safe to share across threads.
unsafe impl Send for Engine {}
unsafe impl Sync for Engine {}

impl Engine {
    /// Open a warm engine over `roots` (each an absolute or CWD-relative path;
    /// none = the rootless CWD walk).
    ///
    /// # Errors
    /// [`Error::Failed`] if the corpus cannot be stood up (bad root, out of memory).
    pub fn open<I, P>(roots: I) -> Result<Self>
    where
        I: IntoIterator<Item = P>,
        P: AsRef<Path>,
    {
        let owned: Vec<CString> = roots
            .into_iter()
            .map(|p| cstring(p.as_ref()))
            .collect::<Result<_>>()?;
        let ptrs: Vec<*const std::os::raw::c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        let root_ptr = if ptrs.is_empty() {
            std::ptr::null()
        } else {
            ptrs.as_ptr()
        };
        let mut out: *mut sys::irregex_engine = std::ptr::null_mut();
        let status = unsafe { sys::irregex_engine_open(root_ptr, ptrs.len(), &mut out) };
        if status != sys::OK {
            return Err(status_error(status, "engine open"));
        }
        Ok(Self {
            inner: out,
            lock: Mutex::new(()),
        })
    }

    /// A fresh cancellation token for use with [`Run::cancel`].
    ///
    /// # Errors
    /// [`Error::Failed`] if the native allocation fails.
    pub fn cancel_token(&self) -> Result<CancelToken> {
        CancelToken::new()
    }

    /// Search over the warm corpus, returning a pull [`Cursor`], with default
    /// (unbounded) budgets. `request.paths` and its subprocess-only `timeout` are
    /// ignored — roots belong to the engine ([`open`](Self::open)).
    ///
    /// # Errors
    /// [`Error::UnsupportedPattern`] for a pattern outside the linear engine,
    /// [`Error::Unrepresentable`] for an option the in-process ABI cannot honor,
    /// [`Error::Failed`] on a native failure.
    pub fn search(&self, request: &SearchRequest) -> Result<Cursor> {
        self.run(request, Run::default())
    }

    /// Search with explicit per-operation budgets ([`Run`]).
    ///
    /// # Errors
    /// See [`search`](Self::search).
    pub fn run(&self, request: &SearchRequest, run: Run<'_>) -> Result<Cursor> {
        reject_unrepresentable(request)?;
        let pattern = request.pattern.as_bytes();
        let (before, after) = if request.before != 0 || request.after != 0 {
            (u64::from(request.before), u64::from(request.after))
        } else {
            (u64::from(request.context), u64::from(request.context))
        };
        let req = sys::SearchRequest {
            struct_size: u32::try_from(std::mem::size_of::<sys::SearchRequest>())
                .expect("request struct fits u32"),
            flags: flags(request),
            max_count: u64::from(request.max_count),
            before_context: before,
            after_context: after,
            pattern: pattern.as_ptr(),
            pattern_len: pattern.len(),
            timeout_ns: run
                .timeout
                .map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX)),
            max_results: run.max_results.unwrap_or(0),
            cancel: run.cancel.map_or(std::ptr::null_mut(), |t| t.inner),
        };
        let mut out: *mut sys::irregex_cursor = std::ptr::null_mut();
        let status = {
            let _guard = self.lock.lock().expect("engine lock poisoned");
            unsafe { sys::irregex_search_cursor(self.inner, &req, &mut out) }
        };
        if status != sys::OK {
            return Err(status_error(status, "search"));
        }
        Ok(Cursor {
            inner: out,
            matched: None,
            done: false,
        })
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        unsafe { sys::irregex_engine_close(self.inner) };
    }
}

/// The `irregex_search_request.flags` bitset for the representable option subset.
fn flags(r: &SearchRequest) -> u32 {
    let mut f = 0;
    if r.fixed {
        f |= sys::FLAG_FIXED;
    }
    if r.ignore_case {
        f |= sys::FLAG_IGNORE_CASE;
    }
    if r.smart_case {
        f |= sys::FLAG_SMART_CASE;
    }
    if r.word {
        f |= sys::FLAG_WORD;
    }
    if r.invert {
        f |= sys::FLAG_INVERT;
    }
    if r.quiet {
        f |= sys::FLAG_QUIET;
    }
    if r.unicode == Some(false) {
        f |= sys::FLAG_NO_UNICODE;
    }
    if r.max_count > 0 {
        f |= sys::FLAG_MAX_COUNT;
    }
    f
}

/// Fail loud for any option the cursor ABI has no field for — the mirror of the
/// engine's own fail-closed `IRREGEX_INVALID` posture, so the in-process face
/// never silently answers a subtly different query than the caller asked.
fn reject_unrepresentable(r: &SearchRequest) -> Result<()> {
    let mut bad: Vec<&str> = Vec::new();
    let flag = |on: bool, name: &'static str, v: &mut Vec<&'static str>| {
        if on {
            v.push(name);
        }
    };
    flag(r.hidden, "hidden", &mut bad);
    flag(r.no_ignore, "no_ignore", &mut bad);
    flag(r.follow, "follow", &mut bad);
    flag(r.no_index, "no_index", &mut bad);
    flag(r.multiline, "multiline", &mut bad);
    flag(r.multiline_dotall, "multiline_dotall", &mut bad);
    flag(r.max_depth != 0, "max_depth", &mut bad);
    flag(
        !r.globs.is_empty()
            || !r.iglobs.is_empty()
            || !r.types.is_empty()
            || !r.not_types.is_empty(),
        "glob/type scoping",
        &mut bad,
    );
    flag(!r.extra_flags.is_empty(), "extra_flags", &mut bad);
    if r.engine != SearchEngine::Linear {
        bad.push("engine=pcre2/auto");
    }
    if bad.is_empty() {
        return Ok(());
    }
    Err(Error::Unrepresentable(format!(
        "the in-process cursor cannot honor {}; use SearchRequest::run for the full CLI surface",
        bad.join(", ")
    )))
}

/// Copy one borrowed [`sys::MatchView`] into an owned [`Match`].
fn to_match(v: &sys::MatchView) -> Match {
    let mut text = decode(v.line, v.line_len);
    // The engine's line view excludes '\n' but may retain a trailing '\r'; strip
    // it to match the cold `--json` parser exactly.
    if text.ends_with('\r') {
        text.pop();
    }
    let subs = if v.submatches.is_null() {
        Vec::new()
    } else {
        let views = unsafe { std::slice::from_raw_parts(v.submatches, v.nsubmatches) };
        views
            .iter()
            .map(|s| Submatch {
                text: decode(s.text, s.len),
                start: s.start,
                end: s.end,
            })
            .collect()
    };
    Match {
        path: decode(v.path, v.path_len),
        line_number: v.line_number,
        text,
        kind: if v.kind == 1 {
            MatchKind::Context
        } else {
            MatchKind::Match
        },
        submatches: subs,
    }
}

/// Decode aliased engine bytes as UTF-8 (lossily — invalid bytes become U+FFFD,
/// matching the JSON transport's `String` records).
fn decode(ptr: *const u8, len: usize) -> String {
    if ptr.is_null() || len == 0 {
        return String::new();
    }
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) }).into_owned()
}

/// A NUL-checked path → `CString` (a path with an interior NUL is unrepresentable).
fn cstring(p: &Path) -> Result<CString> {
    #[cfg(unix)]
    let bytes = {
        use std::os::unix::ffi::OsStrExt;
        p.as_os_str().as_bytes().to_vec()
    };
    #[cfg(not(unix))]
    let bytes = p.to_string_lossy().into_owned().into_bytes();
    CString::new(bytes).map_err(|_| Error::Unrepresentable(format!("root path has interior NUL: {p:?}")))
}

/// Map a negative native status to the crate's typed error.
fn status_error(status: i32, what: &str) -> Error {
    match status {
        sys::STALE => Error::UnsupportedPattern(format!(
            "{what}: pattern is outside the linear-time engine \
             (use SearchRequest with engine=auto/pcre2 for lookaround)"
        )),
        sys::OOM => Error::Failed(format!("{what}: native out of memory")),
        sys::OPEN_FAILED => Error::Failed(format!("{what}: could not stand up the warm corpus")),
        sys::INVALID => Error::Failed(format!("{what}: invalid or wrongly-sized request")),
        other => Error::Failed(format!("{what}: native status {other}")),
    }
}
