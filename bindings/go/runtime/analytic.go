package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	irregex "irregex/bindings/go"
)

// ErrUnsupportedPattern wraps a pattern the linear-time engine cannot express (a
// lookaround or backreference needing PCRE2). It is a value, never a dead
// process — test for it with [errors.Is].
var ErrUnsupportedPattern = errors.New("irregex: pattern outside the linear-time engine")

// ErrNoCGO reports that this build has no in-process tier at all (CGO_ENABLED=0).
// Every verb still answers through the subprocess transport, so callers see this
// only when they ask for the native tier by name.
var ErrNoCGO = errors.New("irregex: built without cgo")

// DriftError is a live library whose row-schema table is NOT the one this
// binding's decoder was generated from. Decoding its rows would silently
// mis-read fields, so the analytic tier refuses instead — loudly, naming the
// first schema that differs. Force the subprocess tier with IRREGEX_NO_FFI=1
// while the library is rebuilt.
type DriftError struct {
	Want, Got string // the contract digest and the library's
	Detail    string // the first divergence, named via irregex_schema_get
}

func (d *DriftError) Error() string {
	return fmt.Sprintf("irregex: row-schema drift — decoder built for digest %s, library reports %s (%s)", d.Want, d.Got, d.Detail)
}

// verifyDigest is the acceptance policy for a library's row-schema table, held
// apart from the cgo call that reads it so the rule is one place and testable in
// either build. An empty digest is a library with no analytic plane — an absence,
// not a mismatch — and detail is consulted only when there is drift to explain.
func verifyDigest(got string, detail func() string) (string, error) {
	switch got {
	case "":
		return "", nil
	case irregex.Digest:
		return got, nil
	}
	return got, &DriftError{Want: irregex.Digest, Got: got, Detail: detail()}
}

// Query is one analytic verb invocation: an op code, its declared params family,
// and the corpus scope. Dir is the working directory the subprocess tier runs in
// and the base the engine's roots resolve against ("" = the process CWD).
type Query struct {
	Op     irregex.Op
	Params irregex.Params
	Roots  []string
	Dir    string
}

func (q Query) validate() error {
	verb, ok := irregex.Verb(q.Op)
	if !ok {
		return fmt.Errorf("irregex: unknown analytic op %d", q.Op)
	}
	if q.Params == nil {
		return fmt.Errorf("irregex: %s needs %s params", verb.Name, verb.Params)
	}
	if got := q.Params.Family(); got != verb.Params {
		return fmt.Errorf("irregex: %s takes %s params, got %s", verb.Name, verb.Params, got)
	}
	return nil
}

// Run answers one analytic verb through the best tier that can.
//
// The in-process plane goes first when this build has it, the library exports it,
// and its schema digest matches. A tier that DECLINES (IRREGEX_STALE) is not a
// failure — the query re-runs against the certified binary and the rows are
// identical — so a declinature never reaches the caller as an error. Only a fault
// about the query itself, or a drifted schema table, does.
func Run(ctx context.Context, q Query) (*Rows, error) {
	if err := q.validate(); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	rows, err := native(ctx, q)
	if rows != nil || err != nil {
		return rows, err
	}
	return cold(ctx, q)
}

// Scope resolves roots against the directory a caller declared its query in — the
// one rule both transports must share. The C ABI has no working directory of its
// own, so a relative root handed to it straight would be read against the PROCESS's
// directory and quietly answer over a different tree than the child would.
func Scope(dir string, roots []string) []string {
	if dir == "" || len(roots) == 0 {
		return roots
	}
	out := make([]string, len(roots))
	for i, root := range roots {
		if filepath.IsAbs(root) {
			out[i] = root
			continue
		}
		out[i] = filepath.Join(dir, root)
	}
	return out
}

func (q Query) scope() []string { return Scope(q.Dir, q.Roots) }

// noFFI is the operator escape hatch: IRREGEX_NO_FFI=1 forces every verb through
// the subprocess tier, which is how a host keeps working while a drifted library
// is rebuilt.
func noFFI() bool {
	v := os.Getenv("IRREGEX_NO_FFI")
	return v != "" && v != "0"
}

// Tier is what this build and this machine can actually do — the answer to "why
// did that verb spawn a child?".
type Tier struct {
	// CGO is whether the in-process transport was compiled in at all.
	CGO bool
	// Analytic is whether the linked library exports the ADR-377 plane AND its
	// schema table matches this decoder.
	Analytic bool
	// ContractDigest is the table this binding decodes; LibraryDigest is the
	// live library's, empty when there is no plane to ask.
	ContractDigest, LibraryDigest string
	// Err is the reason Analytic is false when the reason is a defect (schema
	// drift) rather than an absence.
	Err error
}

// Probe reports the transports available right now. It is the introspection a
// host logs at startup; it never fails, because an absent tier is not an error.
func Probe() Tier {
	t := Tier{CGO: hasCGO, ContractDigest: irregex.Digest}
	if noFFI() {
		return t
	}
	t.LibraryDigest, t.Err = libraryDigest()
	t.Analytic = t.Err == nil && t.LibraryDigest != ""
	return t
}
