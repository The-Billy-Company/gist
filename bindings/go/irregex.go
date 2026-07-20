// Package irregex is the Go binding for Billy's code-search kernel over the
// pull-cursor C ABI (ADR-352).
//
// A host opens a warm [Engine] over some roots, then runs many [Engine.Search]
// queries, each materializing a pull [Cursor] it drives at its own pace. This is
// the callback-free sibling of the engine's push session: no C-to-Go trampoline
// runs during a scan (cgo forbids one cheaply anyway), so cancellation is a
// pull-side concern the binding wires straight to a [context.Context].
//
// Records are copied into Go-owned values as the cursor yields them, so a [Match]
// outlives the cursor and the engine. Every handle has an idempotent Close and a
// GC finalizer safety net, but callers should Close explicitly (the native arena
// is not visible to the Go GC's sizing).
//
// Requires `make build-gist` to have produced
// `pkg/kernels/irregex/zig-out/{lib/libirregex.a,include/irregex.h}`; the cgo
// directives below resolve both relative to this file.
package irregex

/*
#cgo CFLAGS:  -I${SRCDIR}/../../zig-out/include
#cgo LDFLAGS: ${SRCDIR}/../../zig-out/lib/libirregex.a
#include <stdlib.h>
#include <irregex.h>
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"iter"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"
)

// defaultBatch is the records-per-native-call [Cursor.Next] pulls under the hood
// — enough to amortize the cgo crossing without holding a large transient buffer.
const defaultBatch = 64

// Status codes mirror the C ABI's `contract.Status` (negative = declined safely).
const (
	stOK      = 0
	stMatch   = 1
	stStale   = -1
	stOOM     = -2
	stOpenErr = -3
	stInvalid = -4
)

// ErrUnsupportedPattern wraps a pattern the linear-time engine declines (a
// lookaround/backreference needing PCRE2). It is a value, never a dead process —
// test for it with [errors.Is].
var ErrUnsupportedPattern = errors.New("irregex: pattern outside the linear-time engine")

// MatchKind distinguishes a match line from a context neighbor (-A/-B/-C).
type MatchKind uint32

const (
	// KindMatch is a line carrying at least one submatch.
	KindMatch MatchKind = C.IRREGEX_KIND_MATCH
	// KindContext is a leading/trailing context line (no submatches).
	KindContext MatchKind = C.IRREGEX_KIND_CONTEXT
)

// Submatch is one matched span within a line: its text and byte offsets [Start,End).
type Submatch struct {
	Text  string
	Start int
	End   int
}

// Match is one Go-owned result record, copied off the cursor's arena.
type Match struct {
	Path       string
	LineNumber uint64
	Text       string
	Kind       MatchKind
	Submatches []Submatch
}

// Column is the 1-based column of the first submatch (0 for a context line).
func (m Match) Column() int {
	if len(m.Submatches) == 0 {
		return 0
	}
	return m.Submatches[0].Start + 1
}

// Request is one match-finding intent — the representable subset of the unified
// search contract the pull-cursor ABI carries. Presentation, ranking, glob/type
// scoping, and multiline stay CLI-only; a query needing them uses the `gist`
// binary, not this in-process engine.
type Request struct {
	// Pattern is the regex (or literal, with Fixed) to find.
	Pattern string
	// Fixed treats Pattern as a literal string (-F).
	Fixed bool
	// IgnoreCase folds case (-i); SmartCase folds only when Pattern has no
	// uppercase (-S); Unicode, when set, forces Unicode (true) or ASCII (false)
	// class/fold/boundary semantics (nil keeps the engine default, rg-on).
	IgnoreCase bool
	SmartCase  bool
	Unicode    *bool
	// Word bounds matches to whole words (-w); Invert selects non-matching lines
	// (-v); Quiet halts at the first match (-q).
	Word   bool
	Invert bool
	Quiet  bool
	// Before/After add context lines (-B/-A); Context sets both when they are 0.
	Before  uint
	After   uint
	Context uint
	// MaxCount caps matching lines per file (-m); 0 = unlimited.
	MaxCount uint
}

func (r Request) flags() C.uint32_t {
	var f C.uint32_t
	set := func(on bool, bit C.uint) {
		if on {
			f |= C.uint32_t(bit)
		}
	}
	set(r.Fixed, C.IRREGEX_FIXED)
	set(r.IgnoreCase, C.IRREGEX_IGNORE_CASE)
	set(r.SmartCase, C.IRREGEX_SMART_CASE)
	set(r.Word, C.IRREGEX_WORD)
	set(r.Invert, C.IRREGEX_INVERT)
	set(r.Quiet, C.IRREGEX_QUIET)
	set(r.Unicode != nil && !*r.Unicode, C.IRREGEX_NO_UNICODE)
	set(r.MaxCount > 0, C.IRREGEX_MAX_COUNT)
	return f
}

// Engine is a warm in-process corpus queried many times, each yielding a pull
// [Cursor]. Open it with [Open]; Search is serialized (the resident engine is
// single-writer), but the cursors it returns are independent and safe to iterate
// concurrently. Free it with [Engine.Close].
type Engine struct {
	mu  sync.Mutex
	ptr *C.irregex_engine
}

// Open stands up a warm engine over roots (each an absolute or CWD-relative path;
// none = the rootless CWD walk a bare `gist <pattern>` scans).
func Open(roots ...string) (*Engine, error) {
	cRoots := make([]*C.char, len(roots))
	for i, r := range roots {
		cRoots[i] = C.CString(r)
	}
	defer func() {
		for _, p := range cRoots {
			C.free(unsafe.Pointer(p))
		}
	}()
	var rootPtr **C.char
	if len(cRoots) > 0 {
		rootPtr = (**C.char)(unsafe.Pointer(&cRoots[0]))
	}
	var out *C.irregex_engine
	status := C.irregex_engine_open(rootPtr, C.size_t(len(roots)), &out)
	if status != stOK {
		return nil, statusError(status, "engine open")
	}
	e := &Engine{ptr: out}
	runtime.SetFinalizer(e, (*Engine).Close)
	return e, nil
}

// Close frees the warm corpus, index, and I/O pool (idempotent). Cursors already
// materialized own their records and stay valid.
func (e *Engine) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.ptr != nil {
		C.irregex_engine_close(e.ptr)
		e.ptr = nil
		runtime.SetFinalizer(e, nil)
	}
	return nil
}

// Search runs req over the warm corpus and returns a pull [Cursor]. The ctx is
// honored at record boundaries: its deadline becomes the scan's wall-clock budget
// and its cancellation trips a cooperative stop, so a long scan is abortable from
// another goroutine. A canceled ctx surfaces as ctx.Err().
func (e *Engine) Search(ctx context.Context, req Request) (*Cursor, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	pat := []byte(req.Pattern)
	patC := C.CBytes(pat)
	defer C.free(patC)

	before, after := C.uint64_t(req.Before), C.uint64_t(req.After)
	if req.Before == 0 && req.After == 0 {
		before, after = C.uint64_t(req.Context), C.uint64_t(req.Context)
	}
	var creq C.irregex_search_request
	creq.struct_size = C.uint32_t(unsafe.Sizeof(creq))
	creq.flags = req.flags()
	creq.max_count = C.uint64_t(req.MaxCount)
	creq.before_context = before
	creq.after_context = after
	creq.pattern = (*C.uint8_t)(patC)
	creq.pattern_len = C.size_t(len(pat))
	if dl, ok := ctx.Deadline(); ok {
		if d := time.Until(dl); d > 0 {
			creq.timeout_ns = C.uint64_t(d.Nanoseconds())
		}
	}

	// A token the ctx watcher trips; the engine observes it at the next record
	// boundary. The watcher is torn down before the token frees, so no goroutine
	// can touch freed memory.
	var tok *C.irregex_cancel
	if C.irregex_cancel_new(&tok) != stOK {
		return nil, errors.New("irregex: could not allocate a cancel token")
	}
	defer C.irregex_cancel_free(tok)
	stop := make(chan struct{})
	watched := make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-ctx.Done():
			C.irregex_cancel_request(tok)
		case <-stop:
		}
	}()
	creq.cancel = tok

	var out *C.irregex_cursor
	e.mu.Lock()
	if e.ptr == nil {
		e.mu.Unlock()
		close(stop)
		<-watched
		return nil, errors.New("irregex: engine is closed")
	}
	status := C.irregex_search_cursor(e.ptr, &creq, &out)
	e.mu.Unlock()
	close(stop)
	<-watched

	if status != stOK {
		return nil, statusError(status, fmt.Sprintf("search %q", req.Pattern))
	}
	if err := ctx.Err(); err != nil {
		C.irregex_cursor_close(out)
		return nil, err
	}
	c := &Cursor{ptr: out}
	runtime.SetFinalizer(c, (*Cursor).Close)
	return c, nil
}

// Cursor is a pull result handle over one search. Drive it scanner-style —
// [Cursor.Next] advances, [Cursor.Match] reads the current record, [Cursor.Err]
// reports a mid-stream failure — or range over [Cursor.All]. Records are copied,
// so they outlive the cursor. Free it with [Cursor.Close].
type Cursor struct {
	ptr  *C.irregex_cursor
	buf  []Match
	pos  int
	cur  Match
	err  error
	done bool
}

// Next advances to the next record, returning false at end of stream or on error
// (check [Cursor.Err]). It refills an internal batch under the hood, so it pays
// the cgo crossing once per defaultBatch records, not once per record.
func (c *Cursor) Next() bool {
	if c.pos < len(c.buf) {
		c.cur = c.buf[c.pos]
		c.pos++
		return true
	}
	if c.done || c.err != nil || c.ptr == nil {
		return false
	}
	n, err := c.fill()
	if err != nil {
		c.err = err
		return false
	}
	if n == 0 {
		c.done = true
		return false
	}
	c.cur = c.buf[0]
	c.pos = 1
	return true
}

// Match is the record the last [Cursor.Next] landed on.
func (c *Cursor) Match() Match { return c.cur }

// Err is the failure that stopped iteration, or nil at a clean end of stream.
func (c *Cursor) Err() error { return c.err }

// Matched reports whether any file matched (cold's exit-code boolean), even if a
// budget cut the scan short.
func (c *Cursor) Matched() bool {
	if c.ptr == nil {
		return false
	}
	return C.irregex_cursor_matched(c.ptr) != 0
}

// All returns a range-over-func iterator of the remaining records. The final
// yield carries any error (with a zero Match); a clean end yields nothing extra.
func (c *Cursor) All() iter.Seq2[Match, error] {
	return func(yield func(Match, error) bool) {
		for c.Next() {
			if !yield(c.Match(), nil) {
				return
			}
		}
		if c.err != nil {
			yield(Match{}, c.err)
		}
	}
}

// Close frees the native cursor and its record buffer (idempotent).
func (c *Cursor) Close() error {
	if c.ptr != nil {
		C.irregex_cursor_close(c.ptr)
		c.ptr = nil
		runtime.SetFinalizer(c, nil)
	}
	return nil
}

// fill pulls up to defaultBatch records in one native call, copying each into a
// Go-owned Match. The C views alias the cursor's scratch only until the next
// call, so every field is copied out before returning.
func (c *Cursor) fill() (int, error) {
	views := make([]C.irregex_match, defaultBatch)
	var written C.size_t
	status := C.irregex_cursor_next_batch(c.ptr, &views[0], C.size_t(defaultBatch), &written)
	switch status {
	case stMatch:
		n := int(written)
		c.buf = c.buf[:0]
		for i := range n {
			c.buf = append(c.buf, goMatch(&views[i]))
		}
		c.pos = 0
		return n, nil
	case stOK:
		return 0, nil
	default:
		return 0, statusError(status, "cursor batch")
	}
}

// goMatch copies one borrowed C view into a Go-owned Match. C.GoStringN copies the
// bytes, so nothing aliases the cursor arena after this returns.
func goMatch(m *C.irregex_match) Match {
	text := C.GoStringN((*C.char)(unsafe.Pointer(m.line)), C.int(m.line_len))
	// The line view excludes '\n' but may keep a trailing '\r'; strip it to match
	// the cold `--json` parser exactly.
	text = strings.TrimSuffix(text, "\r")
	var subs []Submatch
	if n := int(m.nsubmatches); n > 0 && m.submatches != nil {
		sl := unsafe.Slice(m.submatches, n)
		subs = make([]Submatch, n)
		for i, s := range sl {
			subs[i] = Submatch{
				Text:  C.GoStringN((*C.char)(unsafe.Pointer(s.text)), C.int(s.len)),
				Start: int(s.start),
				End:   int(s.end),
			}
		}
	}
	return Match{
		Path:       C.GoStringN((*C.char)(unsafe.Pointer(m.path)), C.int(m.path_len)),
		LineNumber: uint64(m.line_number),
		Text:       text,
		Kind:       MatchKind(m.kind),
		Submatches: subs,
	}
}

func statusError(status C.int32_t, what string) error {
	switch int(status) {
	case stStale:
		return fmt.Errorf("%s: %w (use the gist binary with -P/--engine auto for lookaround)", what, ErrUnsupportedPattern)
	case stOOM:
		return fmt.Errorf("%s: native out of memory", what)
	case stOpenErr:
		return fmt.Errorf("%s: could not stand up the warm corpus", what)
	case stInvalid:
		return fmt.Errorf("%s: invalid or wrongly-sized request", what)
	default:
		return fmt.Errorf("%s: native status %d", what, int(status))
	}
}
