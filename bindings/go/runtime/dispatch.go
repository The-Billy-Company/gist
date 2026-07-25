//go:build cgo

package runtime

/*
#include <stdlib.h>
#include <irregex.h>
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"time"
	"unsafe"

	irregex "irregex/bindings/go"
)

// native answers q in-process. A nil cursor with a nil error means this tier
// declined or is absent — the caller answers through the next one, unchanged.
func native(ctx context.Context, q Query) (*Rows, error) {
	if noFFI() {
		return nil, nil
	}
	digest, err := libraryDigest()
	if err != nil {
		return nil, err
	}
	if digest == "" {
		return nil, nil
	}
	eng, warm := openCorpus(q)
	if !warm {
		return nil, nil // the corpus would not stand up in-process; the child re-reads it
	}
	rows, err := dispatch(ctx, eng, q)
	if rows == nil {
		// Nothing took ownership of the engine, so the failure and the release of
		// the corpus it half-opened are one event.
		return nil, errors.Join(err, eng.Close())
	}
	return rows, nil
}

// openCorpus stands the tree up in-process, or reports that it could not — which
// is a declinature rather than a failure, since the child reads the same bytes.
func openCorpus(q Query) (*Native, bool) {
	eng, err := OpenNative(q.scope()...)
	if err != nil {
		return nil, false
	}
	return eng, true
}

// dispatch runs one analytic op against an already-open corpus. A nil cursor and
// nil error is this tier declining; on any return but a live cursor the caller
// still owns eng.
func dispatch(ctx context.Context, eng *Native, q Query) (*Rows, error) {
	params, free := lowerParams(q)
	defer free()
	if params == nil {
		return nil, nil // a params shape this transport cannot lower; the child can
	}
	tok, release, err := watchCancel(ctx)
	if err != nil {
		return nil, err
	}

	var cur *C.irregex_rows
	st := C.irregex_analytic_run(eng.ptr, C.uint32_t(q.Op), params, tok, &cur)
	release()
	if st != C.IRREGEX_OK {
		if irregex.Status(st).Declined() || st == C.IRREGEX_INVALID {
			// A declinature is routine; INVALID here means this library predates
			// the op or the params shape, which the child answers correctly.
			return nil, nil
		}
		return nil, statusError(st, q.Op.String())
	}
	return newRows(&nativeRows{engine: eng, ptr: cur}), nil
}

// lowerParams builds the C params struct for q's family, plus the release for
// every buffer it borrowed. A nil pointer means "this transport cannot express
// these params" — a declinature, since the child answers the same query.
//
// The struct is Go memory holding only C pointers, which cgo passes as-is; the
// buffers behind those pointers are C-allocated because the callee may hold them
// for the length of the call and Go memory may not contain Go pointers here.
func lowerParams(q Query) (unsafe.Pointer, func()) {
	var owned []unsafe.Pointer
	free := func() {
		for _, p := range owned {
			C.free(p)
		}
	}
	span := func(s string) (*C.uint8_t, C.size_t) {
		if s == "" {
			return nil, 0
		}
		p := C.CBytes([]byte(s))
		owned = append(owned, p)
		return (*C.uint8_t)(p), C.size_t(len(s))
	}
	spans := func(ss []string) (*C.irregex_text, C.size_t) {
		if len(ss) == 0 {
			return nil, 0
		}
		arr := C.calloc(C.size_t(len(ss)), C.size_t(unsafe.Sizeof(C.irregex_text{})))
		if arr == nil {
			return nil, 0
		}
		owned = append(owned, arr)
		view := unsafe.Slice((*C.irregex_text)(arr), len(ss))
		for i, s := range ss {
			view[i].ptr, view[i].len = span(s)
		}
		return (*C.irregex_text)(arr), C.size_t(len(ss))
	}

	switch p := q.Params.(type) {
	case irregex.Kinship:
		c := C.irregex_kinship_params{
			flags:     C.uint32_t(p.Flags()),
			channel:   C.uint32_t(p.Channel),
			unit:      C.uint32_t(p.Unit),
			min_grade: C.uint32_t(p.MinGrade),
			min_size:  count(p.MinSize),
			min_lines: count(p.MinLines),
			top:       count(p.Top),
		}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		if q.Op == irregex.OpDistinct {
			c.flags |= C.IRREGEX_AN_DISTINCT // the polarity is the op, not a caller field
		}
		c.target, c.target_len = span(p.Target)
		if p.MaxDistance != nil {
			c.max_distance = C.double(*p.MaxDistance)
		}
		if p.MinEcho != nil {
			c.min_echo = C.double(*p.MinEcho)
		}
		return unsafe.Pointer(&c), free

	case irregex.Retrieval:
		c := C.irregex_retrieval_params{flags: C.uint32_t(p.Flags()), top: count(p.Top)}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.query, c.query_len = span(p.Query)
		return unsafe.Pointer(&c), free

	case irregex.Sweep:
		c := C.irregex_sweep_params{flags: C.uint32_t(p.Flags()), top: count(p.Top)}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.patterns, c.npatterns = spans(p.Patterns)
		c.under, c.under_len = span(p.Under)
		return unsafe.Pointer(&c), free

	case irregex.Compose:
		c := C.irregex_compose_params{
			flags:  C.uint32_t(p.Flags()),
			budget: count(p.Budget),
			top:    count(p.Top),
		}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.text, c.text_len = span(p.Text)
		c.patterns, c.npatterns = spans(p.Patterns)
		if p.MaxDistance != nil {
			c.max_distance = C.double(*p.MaxDistance)
		}
		if p.MinEcho != nil {
			c.min_echo = C.double(*p.MinEcho)
		}
		return unsafe.Pointer(&c), free

	case irregex.Rank:
		c := C.irregex_rank_params{flags: C.uint32_t(p.Flags()), top: count(p.Top)}
		c.struct_size = C.uint32_t(unsafe.Sizeof(c))
		c.pattern, c.pattern_len = span(p.Pattern)
		return unsafe.Pointer(&c), free
	}
	return nil, free
}

// count clamps a caller's budget into the ABI's unsigned slot; a negative budget
// is the same request as none.
func count(n int) C.uint32_t {
	if n <= 0 {
		return 0
	}
	return C.uint32_t(n)
}

// nativeRows pulls decoded rows straight out of the cursor arena.
type nativeRows struct {
	engine *Native
	ptr    *C.irregex_rows
	views  []C.irregex_row
	done   bool
}

func (n *nativeRows) fill(dst []Row) (int, error) {
	if n.ptr == nil || n.done || len(dst) == 0 {
		return 0, nil
	}
	if len(n.views) < len(dst) {
		n.views = make([]C.irregex_row, len(dst))
	}
	var written C.size_t
	st := C.irregex_rows_next_batch(n.ptr, &n.views[0], C.size_t(len(dst)), &written)
	switch st {
	case C.IRREGEX_MATCH:
		for i := range int(written) {
			row, err := goRow(&n.views[i])
			if err != nil {
				return i, err
			}
			dst[i] = row
		}
		return int(written), nil
	case C.IRREGEX_OK:
		n.done = true
		return 0, nil
	default:
		return 0, statusError(st, "rows batch")
	}
}

func (n *nativeRows) stats() Stats {
	if n.ptr == nil {
		return Stats{}
	}
	var cs C.irregex_stats
	cs.struct_size = C.uint32_t(unsafe.Sizeof(cs))
	if C.irregex_rows_stats(n.ptr, &cs) != C.IRREGEX_OK {
		return Stats{}
	}
	return Stats{
		Source:          uint32(cs.source),
		Elapsed:         time.Duration(cs.elapsed_ns),
		FilesConsidered: uint64(cs.files_considered),
		Refreshed:       uint64(cs.refreshed),
		Foreign:         uint64(cs.foreign),
		Omitted:         uint64(cs.omitted),
		Rows:            uint64(cs.rows),
	}
}

func (n *nativeRows) close() error {
	if n.ptr != nil {
		C.irregex_rows_close(n.ptr)
		n.ptr = nil
	}
	return n.engine.Close()
}

// goRow decodes one borrowed native row, copying every text out of the arena so
// the result outlives the cursor.
func goRow(cr *C.irregex_row) (Row, error) {
	schema, ok := irregex.Schema(uint32(cr.schema_id))
	if !ok {
		return Row{}, fmt.Errorf("irregex: library returned unknown schema id %d", uint32(cr.schema_id))
	}
	n := int(cr.nvalues)
	values := make([]Value, n)
	if n > 0 && cr.values != nil {
		for i, cv := range unsafe.Slice(cr.values, n) {
			var nested uint32
			if i < len(schema.Fields) {
				nested = schema.Fields[i].Nested
			}
			v, err := goValue(cv, nested)
			if err != nil {
				return Row{}, err
			}
			values[i] = v
		}
	}
	return Assemble(uint32(cr.schema_id), values, uint64(cr.present))
}

func goValue(cv C.irregex_value, nested uint32) (Value, error) {
	switch irregex.Tag(cv.tag) {
	case irregex.TagText:
		return Text(goBytes(cv.ptr, cv.len)), nil
	case irregex.TagInt:
		return Int(int64(cv.integer)), nil
	case irregex.TagFloat:
		return Float(float64(cv.real)), nil
	case irregex.TagBool:
		return Bool(cv.integer != 0), nil
	case irregex.TagEnum:
		return EnumOf(nested, int64(cv.integer)), nil
	case irregex.TagTexts:
		n := int(cv.len)
		out := make([]string, n)
		if n > 0 && cv.ptr != nil {
			for i, t := range unsafe.Slice((*C.irregex_text)(cv.ptr), n) {
				out[i] = goBytes(unsafe.Pointer(t.ptr), t.len)
			}
		}
		return Texts(out), nil
	case irregex.TagRows:
		n := int(cv.len)
		out := make([]Row, n)
		if n > 0 && cv.ptr != nil {
			for i, cr := range unsafe.Slice((*C.irregex_row)(cv.ptr), n) {
				child, err := goRow(&cr)
				if err != nil {
					return Value{}, err
				}
				out[i] = child
			}
		}
		return Nested(out), nil
	default:
		return Value{}, fmt.Errorf("irregex: library returned unknown value tag %d", uint32(cv.tag))
	}
}
