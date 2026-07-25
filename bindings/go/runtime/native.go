//go:build cgo

package runtime

/*
#cgo CFLAGS:  -I${SRCDIR}/../../../zig-out/include
#cgo LDFLAGS: ${SRCDIR}/../../../zig-out/lib/libirregex.a
#include <stdlib.h>
#include <string.h>
#include <irregex.h>

// The analytic plane (ADR-377) is ADDITIVE, so a library built before it — or one
// where the exports are still landing — must still link. These weak definitions
// give every analytic symbol a fallback the linker resolves only when the archive
// has no strong one; when it does, the strong definition wins and this file's
// stubs disappear. irregex_schema_digest returning NULL is therefore the runtime
// probe for "this library has no analytic plane", which is an absence, never a
// failure.
__attribute__((weak)) const char *irregex_schema_digest(void) { return NULL; }
__attribute__((weak)) uint32_t irregex_schema_count(void) { return 0; }
__attribute__((weak)) int32_t irregex_schema_get(uint32_t id, irregex_schema *out) {
  (void)id; (void)out; return IRREGEX_INVALID;
}
__attribute__((weak)) int32_t irregex_analytic_run(irregex_engine *e, uint32_t op,
                                                  const void *params, irregex_cancel *c,
                                                  irregex_rows **out) {
  (void)e; (void)op; (void)params; (void)c; (void)out; return IRREGEX_INVALID;
}
__attribute__((weak)) int32_t irregex_rows_next(irregex_rows *r, irregex_row *out) {
  (void)r; (void)out; return IRREGEX_INVALID;
}
__attribute__((weak)) int32_t irregex_rows_next_batch(irregex_rows *r, irregex_row *out,
                                                     size_t cap, size_t *written) {
  (void)r; (void)out; (void)cap; (void)written; return IRREGEX_INVALID;
}
__attribute__((weak)) int32_t irregex_rows_stats(irregex_rows *r, irregex_stats *out) {
  (void)r; (void)out; return IRREGEX_INVALID;
}
__attribute__((weak)) void irregex_rows_close(irregex_rows *r) { (void)r; }
__attribute__((weak)) int32_t irregex_last_fault(irregex_fault *out) {
  (void)out; return IRREGEX_INVALID;
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	goruntime "runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	irregex "irregex/bindings/go"
)

// hasCGO reports that the in-process transport was compiled in.
const hasCGO = true

// Native is a warm in-process corpus over the pull-cursor ABI. Searches are
// serialized (the resident engine is single-writer); the cursors they return are
// independent and safe to iterate concurrently.
type Native struct {
	mu  sync.Mutex
	ptr *C.irregex_engine
}

// OpenNative stands up the in-process engine over roots (none = the rootless CWD
// walk a bare `gist <pattern>` scans).
func OpenNative(roots ...string) (*Native, error) {
	cRoots := make([]*C.char, len(roots))
	for i, r := range roots {
		cRoots[i] = C.CString(r)
	}
	defer func() {
		for _, p := range cRoots {
			C.free(unsafe.Pointer(p))
		}
	}()
	var head **C.char
	if len(cRoots) > 0 {
		head = (**C.char)(unsafe.Pointer(&cRoots[0]))
	}
	var out *C.irregex_engine
	if st := C.irregex_engine_open(head, C.size_t(len(roots)), &out); st != C.IRREGEX_OK {
		return nil, statusError(st, "engine open")
	}
	e := &Native{ptr: out}
	goruntime.SetFinalizer(e, (*Native).Close)
	return e, nil
}

// Close frees the warm corpus, index and I/O pool (idempotent). Cursors already
// materialized own their records and stay valid.
func (n *Native) Close() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.ptr != nil {
		C.irregex_engine_close(n.ptr)
		n.ptr = nil
		goruntime.SetFinalizer(n, nil)
	}
	return nil
}

// Search materializes a pull cursor for req. The ctx is honored at record
// boundaries: its deadline becomes the scan's wall-clock budget and its
// cancellation trips a cooperative stop.
func (n *Native) Search(ctx context.Context, req irregex.Request) (*NativeCursor, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	pat := C.CBytes([]byte(req.Pattern))
	defer C.free(pat)

	before, after := req.ContextLines()
	var creq C.irregex_search_request
	creq.struct_size = C.uint32_t(unsafe.Sizeof(creq))
	creq.flags = C.uint32_t(req.Flags())
	creq.max_count = C.uint64_t(req.MaxCount)
	creq.before_context = C.uint64_t(before)
	creq.after_context = C.uint64_t(after)
	creq.pattern = (*C.uint8_t)(pat)
	creq.pattern_len = C.size_t(len(req.Pattern))
	if dl, ok := ctx.Deadline(); ok {
		if d := time.Until(dl); d > 0 {
			creq.timeout_ns = C.uint64_t(d.Nanoseconds())
		}
	}

	tok, release, err := watchCancel(ctx)
	if err != nil {
		return nil, err
	}
	creq.cancel = tok

	var out *C.irregex_cursor
	n.mu.Lock()
	if n.ptr == nil {
		n.mu.Unlock()
		release()
		return nil, errors.New("irregex: engine is closed")
	}
	st := C.irregex_search_cursor(n.ptr, &creq, &out)
	n.mu.Unlock()
	release()

	if st != C.IRREGEX_OK {
		return nil, statusError(st, fmt.Sprintf("search %q", req.Pattern))
	}
	if err := ctx.Err(); err != nil {
		C.irregex_cursor_close(out)
		return nil, err
	}
	c := &NativeCursor{ptr: out}
	goruntime.SetFinalizer(c, (*NativeCursor).Close)
	return c, nil
}

// NativeCursor is one in-process search's record supply.
type NativeCursor struct {
	ptr   *C.irregex_cursor
	views []C.irregex_match
}

// NextBatch copies up to len(dst) records into dst and returns how many it wrote;
// 0 is a clean end of stream. The native views alias cursor scratch only until the
// next pull, so every field is copied out before returning.
func (c *NativeCursor) NextBatch(dst []irregex.Match) (int, error) {
	if c.ptr == nil || len(dst) == 0 {
		return 0, nil
	}
	if len(c.views) < len(dst) {
		c.views = make([]C.irregex_match, len(dst))
	}
	var written C.size_t
	st := C.irregex_cursor_next_batch(c.ptr, &c.views[0], C.size_t(len(dst)), &written)
	switch st {
	case C.IRREGEX_MATCH:
		n := int(written)
		for i := range n {
			dst[i] = goMatch(&c.views[i])
		}
		return n, nil
	case C.IRREGEX_OK:
		return 0, nil
	default:
		return 0, statusError(st, "cursor batch")
	}
}

// Matched reports whether any file matched (cold's exit-code boolean), even if a
// budget cut the scan short.
func (c *NativeCursor) Matched() bool {
	return c.ptr != nil && C.irregex_cursor_matched(c.ptr) != 0
}

// Close frees the native cursor (idempotent).
func (c *NativeCursor) Close() error {
	if c.ptr != nil {
		C.irregex_cursor_close(c.ptr)
		c.ptr = nil
		goruntime.SetFinalizer(c, nil)
	}
	return nil
}

// goMatch copies one borrowed view into a Go-owned record.
func goMatch(m *C.irregex_match) irregex.Match {
	// The line view excludes '\n' but may keep a trailing '\r'; strip it to match
	// the cold `--json` records exactly.
	text := strings.TrimSuffix(goBytes(unsafe.Pointer(m.line), m.line_len), "\r")
	var subs []irregex.Submatch
	if n := int(m.nsubmatches); n > 0 && m.submatches != nil {
		subs = make([]irregex.Submatch, n)
		for i, s := range unsafe.Slice(m.submatches, n) {
			subs[i] = irregex.Submatch{
				Text:  goBytes(unsafe.Pointer(s.text), s.len),
				Start: int(s.start),
				End:   int(s.end),
			}
		}
	}
	return irregex.Match{
		Path:       goBytes(unsafe.Pointer(m.path), m.path_len),
		LineNumber: uint64(m.line_number),
		Text:       text,
		Kind:       irregex.MatchKind(m.kind),
		Submatches: subs,
	}
}

func goBytes(p unsafe.Pointer, n C.size_t) string {
	if p == nil || n == 0 {
		return ""
	}
	return C.GoStringN((*C.char)(p), C.int(n))
}

// libraryDigest is the linked library's row-schema digest, "" when this library
// has no analytic plane, or a *DriftError when it has one this decoder was not
// generated from.
func libraryDigest() (string, error) {
	if C.irregex_schema_digest() == nil {
		return "", nil
	}
	return verifyDigest(C.GoString(C.irregex_schema_digest()), namedDrift)
}

// namedDrift walks the library's own schema table against this binding's to name
// the first divergence — a digest alone detects drift; irregex_schema_get says
// WHICH schema moved, which is the difference between a bug report and a mystery.
func namedDrift() string {
	if n := int(C.irregex_schema_count()); n != irregex.SchemaCount() {
		return fmt.Sprintf("library declares %d schemas, this decoder %d", n, irregex.SchemaCount())
	}
	for id := uint32(1); int(id) <= irregex.SchemaCount(); id++ {
		var cs C.irregex_schema
		cs.struct_size = C.uint32_t(unsafe.Sizeof(cs))
		if C.irregex_schema_get(C.uint32_t(id), &cs) != C.IRREGEX_OK {
			return fmt.Sprintf("library cannot describe schema %d", id)
		}
		mine, _ := irregex.Schema(id)
		if name := C.GoString(cs.name); name != mine.Name {
			return fmt.Sprintf("schema %d is %q in the library, %q here", id, name, mine.Name)
		}
		if int(cs.nfields) != len(mine.Fields) {
			return fmt.Sprintf("schema %q has %d fields in the library, %d here", mine.Name, int(cs.nfields), len(mine.Fields))
		}
		for i, f := range unsafe.Slice(cs.fields, int(cs.nfields)) {
			if got := C.GoString(f.name); got != mine.Fields[i].Name || uint32(f.tag) != mine.Fields[i].Tag {
				return fmt.Sprintf("schema %q field %d is %s:%s in the library, %s:%s here",
					mine.Name, i, got, irregex.Tag(f.tag), mine.Fields[i].Name, irregex.Tag(mine.Fields[i].Tag))
			}
		}
	}
	return "field-level tables agree; the digest covers more than names and tags"
}

// watchCancel allocates a cancellation token and a goroutine that trips it when
// ctx ends. release tears the watcher down before the token frees, so no
// goroutine can touch freed memory.
func watchCancel(ctx context.Context) (*C.irregex_cancel, func(), error) {
	var tok *C.irregex_cancel
	if C.irregex_cancel_new(&tok) != C.IRREGEX_OK {
		return nil, nil, errors.New("irregex: could not allocate a cancel token")
	}
	stop, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-ctx.Done():
			C.irregex_cancel_request(tok)
		case <-stop:
		}
	}()
	return tok, func() {
		close(stop)
		<-watched
		C.irregex_cancel_free(tok)
	}, nil
}

// statusError maps a fault status onto a typed error, enriched with this thread's
// last fault detail when the library can name the incident (ADR-373 law 7).
func statusError(st C.int32_t, what string) error {
	if irregex.Status(st).Declined() {
		return fmt.Errorf("%s: %w (use the gist binary with -P/--engine auto for lookaround)", what, ErrUnsupportedPattern)
	}
	msg := C.GoString(C.irregex_status_message(st))
	if detail := lastFault(); detail != "" {
		return fmt.Errorf("%s: %s (%s)", what, msg, detail)
	}
	return fmt.Errorf("%s: %s", what, msg)
}

func lastFault() string {
	var f C.irregex_fault
	f.struct_size = C.uint32_t(unsafe.Sizeof(f))
	if C.irregex_last_fault(&f) != C.IRREGEX_MATCH {
		return ""
	}
	out := C.GoString(f.name)
	if f.path != nil {
		out += " at " + goBytes(unsafe.Pointer(f.path), f.path_len)
		if f.has_at != 0 {
			out += fmt.Sprintf("+%d", uint64(f.at))
		}
	}
	return out
}
