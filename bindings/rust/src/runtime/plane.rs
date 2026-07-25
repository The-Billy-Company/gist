//! The in-process analytic plane (ADR-377): the symbol probe, the warm engine
//! cache, and the dispatch that turns a [`Query`] into a cursor.
//!
//! ## Why the symbols are probed, not linked
//!
//! Declaring `irregex_analytic_run` as an `extern` would make the crate
//! *unlinkable* against an engine that predates ADR-377 — the strictly worse
//! failure, because the subprocess tier can answer every one of these questions
//! already. So the plane is resolved with `dlsym` over the symbols already in
//! the process: present means in-process, absent means the ladder walks on. The
//! probe runs once, behind a [`OnceLock`], and its last step is the schema
//! handshake in [`super::handshake`] — a library whose row tables have moved is
//! refused loudly rather than decoded wrongly.

use std::cell::Cell;
use std::collections::HashMap;
use std::ffi::CStr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use super::answer::{Native, Rows};
use super::{Error, Query, Result, handshake, sys};

// ── the probed plane ───────────────────────────────────────────────────────

/// The analytic entry points, resolved once.
pub(super) struct Vtable {
    run: sys::AnalyticRunFn,
    pub(super) next: sys::RowsNextFn,
    pub(super) next_batch: sys::RowsNextBatchFn,
    pub(super) stats: sys::RowsStatsFn,
    pub(super) close: sys::RowsCloseFn,
    engine_open: sys::EngineOpenFn,
    engine_close: sys::EngineCloseFn,
    /// ADR-373's last-fault pull. Optional: it enriches a failure message, it is
    /// never load-bearing for correctness.
    last_fault: Option<sys::LastFaultFn>,
}

enum State {
    /// No analytic symbols in this process — the ladder walks on.
    Absent,
    /// The library's row tables disagree with this build's decoder.
    Drifted(String),
    Ready(Vtable),
}

/// Resolve `name` (NUL-terminated) into a typed function pointer.
fn resolve<F: Copy>(name: &'static str) -> Option<F> {
    const { assert!(size_of::<F>() == size_of::<*mut std::ffi::c_void>()) };
    let p = sys::symbol(name)?;
    // A dlsym result is a code address; the typed shapes live in `sys` and are
    // checked against `include/irregex.h` by review, exactly as an `extern`
    // block is.
    Some(unsafe { std::mem::transmute_copy::<*mut std::ffi::c_void, F>(&p) })
}

fn probe() -> State {
    let (Some(run), Some(next), Some(next_batch), Some(stats), Some(close)) = (
        resolve::<sys::AnalyticRunFn>("irregex_analytic_run\0"),
        resolve::<sys::RowsNextFn>("irregex_rows_next\0"),
        resolve::<sys::RowsNextBatchFn>("irregex_rows_next_batch\0"),
        resolve::<sys::RowsStatsFn>("irregex_rows_stats\0"),
        resolve::<sys::RowsCloseFn>("irregex_rows_close\0"),
    ) else {
        return State::Absent;
    };
    let (Some(engine_open), Some(engine_close)) = (
        resolve::<sys::EngineOpenFn>("irregex_engine_open\0"),
        resolve::<sys::EngineCloseFn>("irregex_engine_close\0"),
    ) else {
        return State::Absent;
    };
    // No digest entry point at all is an older plane, not a drifted one.
    if let Some(digest) = resolve::<sys::SchemaDigestFn>("irregex_schema_digest\0") {
        let introspect =
            resolve::<sys::SchemaCountFn>("irregex_schema_count\0")
                .zip(resolve::<sys::SchemaGetFn>("irregex_schema_get\0"));
        if let Some(why) = handshake::drift(digest, introspect) {
            return State::Drifted(why);
        }
    }
    State::Ready(Vtable {
        run,
        next,
        next_batch,
        stats,
        close,
        engine_open,
        engine_close,
        last_fault: resolve::<sys::LastFaultFn>("irregex_last_fault\0"),
    })
}

fn state() -> &'static State {
    static STATE: OnceLock<State> = OnceLock::new();
    STATE.get_or_init(probe)
}

/// Whether an in-process analytic plane answered this process's last probe.
/// Diagnostic only — no behavior branches on it, the ladder does that itself.
#[must_use]
pub fn available() -> bool {
    matches!(state(), State::Ready(_))
}

// ── the engine cache ───────────────────────────────────────────────────────

/// A warm engine, freed once every cursor that borrows its corpus is gone.
pub(super) struct EngineHandle {
    ptr: *mut sys::irregex_engine,
    close: sys::EngineCloseFn,
}

// The pointer is handed to the engine's own thread-safe entry points and never
// dereferenced on the Rust side.
unsafe impl Send for EngineHandle {}
unsafe impl Sync for EngineHandle {}

impl Drop for EngineHandle {
    fn drop(&mut self) {
        unsafe { (self.close)(self.ptr) };
    }
}

/// Open (or reuse) the warm engine for `roots`.
///
/// The analytic corpus, atlas, and codex shelf load lazily on first analytic use
/// and are expensive to stand up, so an agent asking six questions about the
/// same tree should pay for it once. Keyed by the root set exactly as given: two
/// spellings of the same tree are two engines, which costs memory but can never
/// answer over the wrong corpus.
fn engine(vt: &Vtable, roots: &[PathBuf]) -> Result<Arc<EngineHandle>> {
    static CACHE: OnceLock<Mutex<HashMap<Vec<PathBuf>, Arc<EngineHandle>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let Ok(mut map) = cache.lock() else {
        return Err(Error::Failed("engine cache poisoned".to_owned()));
    };
    if let Some(found) = map.get(roots) {
        return Ok(Arc::clone(found));
    }
    let owned = roots
        .iter()
        .map(|p| cstring(p))
        .collect::<Result<Vec<_>>>()?;
    let ptrs: Vec<*const std::os::raw::c_char> = owned.iter().map(|c| c.as_ptr()).collect();
    let mut out: *mut sys::irregex_engine = std::ptr::null_mut();
    let status = unsafe {
        (vt.engine_open)(
            if ptrs.is_empty() {
                std::ptr::null()
            } else {
                ptrs.as_ptr()
            },
            ptrs.len(),
            &raw mut out,
        )
    };
    if status != sys::OK {
        return Err(fault(vt, status, "analytic engine open"));
    }
    let handle = Arc::new(EngineHandle {
        ptr: out,
        close: vt.engine_close,
    });
    map.insert(roots.to_vec(), Arc::clone(&handle));
    Ok(handle)
}

/// A NUL-checked path → `CString` (a path with an interior NUL is unrepresentable).
fn cstring(p: &Path) -> Result<std::ffi::CString> {
    #[cfg(unix)]
    let bytes = {
        use std::os::unix::ffi::OsStrExt;
        p.as_os_str().as_bytes().to_vec()
    };
    #[cfg(not(unix))]
    let bytes = p.to_string_lossy().into_owned().into_bytes();
    std::ffi::CString::new(bytes)
        .map_err(|_| Error::Unrepresentable(format!("root path has interior NUL: {p:?}")))
}

/// Map a negative status to a typed error, enriched with ADR-373's last-fault
/// detail when the engine exposes it — a status code names a *class*, the fault
/// names the incident (which file, which byte).
pub(super) fn fault(vt: &Vtable, status: i32, what: &str) -> Error {
    let detail = vt.last_fault.and_then(|pull| {
        let mut f = sys::Fault {
            struct_size: super::struct_size::<sys::Fault>(),
            status: 0,
            has_at: 0,
            name: std::ptr::null(),
            path: std::ptr::null(),
            path_len: 0,
            at: 0,
        };
        if unsafe { pull(&raw mut f) } != sys::OK || f.name.is_null() {
            return None;
        }
        let mut msg = unsafe { CStr::from_ptr(f.name) }
            .to_string_lossy()
            .into_owned();
        if !f.path.is_null() {
            let path = unsafe { super::cell::slice(f.path, f.path_len) };
            msg.push_str(&format!(" at {}", String::from_utf8_lossy(path)));
            if f.has_at != 0 {
                msg.push_str(&format!("+{}", f.at));
            }
        }
        Some(msg)
    });
    match detail {
        Some(d) => Error::Failed(format!("{what}: {d} (status {status})")),
        None => Error::Failed(format!("{what}: native status {status}")),
    }
}

// ── dispatch ───────────────────────────────────────────────────────────────

/// Run `query` in process.
///
/// `Ok(None)` is the **declinature**: no plane, or the engine returned
/// `IRREGEX_STALE` because it cannot serve this question warm. The caller falls
/// through to the subprocess tier and gets the identical answer.
///
/// # Errors
/// [`Error::SchemaDrift`] when the loaded library's row tables disagree with
/// this build, or [`Error::Failed`] for a genuine native fault.
pub(crate) fn run(query: &impl Query) -> Result<Option<Rows>> {
    let vt = match state() {
        State::Absent => return Ok(None),
        State::Drifted(why) => return Err(Error::SchemaDrift(why.clone())),
        State::Ready(vt) => vt,
    };
    let engine = engine(vt, query.roots())?;
    // The pattern array has to outlive the params struct that points at it, and
    // this call is the only frame that outlives both.
    let patterns = query.texts();
    let views: Vec<sys::Text> = patterns
        .iter()
        .map(|p| sys::Text {
            ptr: p.as_ptr(),
            len: p.len(),
        })
        .collect();
    let mut wire = query.wire();
    wire.bind(&views);
    let mut out: *mut sys::irregex_rows = std::ptr::null_mut();
    let status = unsafe {
        (vt.run)(
            engine.ptr,
            query.op(),
            wire.as_ptr(),
            std::ptr::null_mut(),
            &raw mut out,
        )
    };
    match status {
        sys::OK | sys::MATCH => Ok(Some(Rows::native(Native {
            ptr: out,
            vt,
            done: Cell::new(false),
            _engine: engine,
        }))),
        sys::STALE => Ok(None),
        other => Err(fault(vt, other, "analytic run")),
    }
}
