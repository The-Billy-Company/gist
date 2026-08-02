//go:build !cgo || !irgx_ffi

package exact

import (
	"context"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

func searchNative(context.Context, *runtime.Native, analytic.Request) (records, error) {
	return nil, runtime.ErrNoCGO
}
