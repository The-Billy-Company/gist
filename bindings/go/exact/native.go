//go:build cgo && irgx_ffi

package exact

/*
// Links libgist (and its libirgx dependency) so gist_search_cursor and
// gist_run are present in-process. The substrate engine handle comes from
// irregex/runtime; this file only speaks gist's search ABI over it.
#cgo CFLAGS:  -I${SRCDIR}/../../../zig-out/include
#cgo LDFLAGS: -L${SRCDIR}/../../../zig-out/lib -lgist -lirgx
#cgo LDFLAGS: -Wl,-rpath,${SRCDIR}/../../../zig-out/lib
#include <stdlib.h>
#include <gist.h>
*/
import "C"

import (
	"context"
	"fmt"
	goruntime "runtime"
	"strings"
	"time"
	"unsafe"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

// searchNative materializes a pull cursor for req against an already-open
// substrate corpus. The ctx is honored at record boundaries: its deadline
// becomes the scan's wall-clock budget and its cancellation trips a cooperative
// stop.
func searchNative(ctx context.Context, n *runtime.Native, req analytic.Request) (records, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	pat := C.CBytes([]byte(req.Pattern))
	defer C.free(pat)

	before, after := req.ContextLines()
	var creq C.gist_search_request
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

	var out *C.gist_cursor
	callErr := n.Do(func(eng unsafe.Pointer) error {
		st := C.gist_search_cursor((*C.irgx_engine)(eng), &creq, &out)
		if st != C.IRGX_OK {
			return statusError(st, fmt.Sprintf("search %q", req.Pattern))
		}
		return nil
	})
	release()
	if callErr != nil {
		return nil, callErr
	}
	if err := ctx.Err(); err != nil {
		C.gist_cursor_close(out)
		return nil, err
	}
	c := &nativeCursor{ptr: out}
	goruntime.SetFinalizer(c, (*nativeCursor).Close)
	return c, nil
}

// nativeCursor is one in-process search's record supply.
type nativeCursor struct {
	ptr   *C.gist_cursor
	views []C.gist_match
}

// NextBatch copies up to len(dst) records into dst and returns how many it wrote;
// 0 is a clean end of stream. The native views alias cursor scratch only until the
// next pull, so every field is copied out before returning.
func (c *nativeCursor) NextBatch(dst []analytic.Match) (int, error) {
	if c.ptr == nil || len(dst) == 0 {
		return 0, nil
	}
	if len(c.views) < len(dst) {
		c.views = make([]C.gist_match, len(dst))
	}
	var written C.size_t
	st := C.gist_cursor_next_batch(c.ptr, &c.views[0], C.size_t(len(dst)), &written)
	switch st {
	case C.IRGX_MATCH:
		n := int(written)
		for i := range n {
			dst[i] = goMatch(&c.views[i])
		}
		return n, nil
	case C.IRGX_OK:
		return 0, nil
	default:
		return 0, statusError(st, "cursor batch")
	}
}

// Matched reports whether any file matched (cold's exit-code boolean), even if a
// budget cut the scan short.
func (c *nativeCursor) Matched() bool {
	return c.ptr != nil && C.gist_cursor_matched(c.ptr) != 0
}

// Close frees the native cursor (idempotent).
func (c *nativeCursor) Close() error {
	if c.ptr != nil {
		C.gist_cursor_close(c.ptr)
		c.ptr = nil
		goruntime.SetFinalizer(c, nil)
	}
	return nil
}

func goMatch(m *C.gist_match) analytic.Match {
	// The line view excludes '\n' but may keep a trailing '\r'; strip it to match
	// the cold `--json` records exactly.
	text := strings.TrimSuffix(goBytes(unsafe.Pointer(m.line), m.line_len), "\r")
	var subs []analytic.Submatch
	if n := int(m.nsubmatches); n > 0 && m.submatches != nil {
		subs = make([]analytic.Submatch, n)
		for i, s := range unsafe.Slice(m.submatches, n) {
			subs[i] = analytic.Submatch{
				Text:  goBytes(unsafe.Pointer(s.text), s.len),
				Start: int(s.start),
				End:   int(s.end),
			}
		}
	}
	return analytic.Match{
		Path:       goBytes(unsafe.Pointer(m.path), m.path_len),
		LineNumber: uint64(m.line_number),
		Text:       text,
		Kind:       analytic.MatchKind(m.kind),
		Submatches: subs,
	}
}

func goBytes(p unsafe.Pointer, n C.size_t) string {
	if p == nil || n == 0 {
		return ""
	}
	return C.GoStringN((*C.char)(p), C.int(n))
}

func watchCancel(ctx context.Context) (*C.irgx_cancel, func(), error) {
	var tok *C.irgx_cancel
	if C.irgx_cancel_new(&tok) != C.IRGX_OK {
		return nil, nil, fmt.Errorf("irregex: could not allocate a cancel token")
	}
	stop, watched := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(watched)
		select {
		case <-ctx.Done():
			C.irgx_cancel_request(tok)
		case <-stop:
		}
	}()
	return tok, func() {
		close(stop)
		<-watched
		C.irgx_cancel_free(tok)
	}, nil
}

func statusError(st C.int32_t, what string) error {
	if analytic.Status(st).Declined() {
		return fmt.Errorf("%s: %w (use the gist binary with -P/--engine auto for lookaround)", what, runtime.ErrUnsupportedPattern)
	}
	msg := C.GoString(C.irgx_status_message(st))
	return fmt.Errorf("%s: %s", what, msg)
}
