//go:build !cgo

package runtime

import (
	"context"

	irregex "irregex/bindings/go"
)

// A CGO_ENABLED=0 build has no in-process tier: there is no library to link and
// no analytic plane to probe. That is an absence, not a failure — every verb
// still answers through the subprocess transport, byte for byte, so this file
// exists to make the ladder's first rung a no-op rather than to reimplement it.

const hasCGO = false

// Native is the in-process engine, which this build does not have.
type Native struct{}

// OpenNative always reports [ErrNoCGO] here; callers fall through to the child.
func OpenNative(...string) (*Native, error) { return nil, ErrNoCGO }

// Close is a no-op on a handle that was never opened.
func (*Native) Close() error { return nil }

// Search always reports [ErrNoCGO] here.
func (*Native) Search(context.Context, irregex.Request) (*NativeCursor, error) {
	return nil, ErrNoCGO
}

// NativeCursor is the in-process record supply, which this build does not have.
type NativeCursor struct{}

// NextBatch reads no records.
func (*NativeCursor) NextBatch([]irregex.Match) (int, error) { return 0, ErrNoCGO }

// Matched is false: no in-process search ran.
func (*NativeCursor) Matched() bool { return false }

// Close is a no-op.
func (*NativeCursor) Close() error { return nil }

func native(context.Context, Query) (*Rows, error) { return nil, nil }

func libraryDigest() (string, error) { return "", nil }
