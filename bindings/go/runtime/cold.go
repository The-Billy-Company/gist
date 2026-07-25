package runtime

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	irregex "irregex/bindings/go"
)

// ErrNoBinary reports that none of the certified binaries could be found, which
// is the one way an answer is genuinely unavailable: with no library and no
// child, there is no engine. Fail closed — a second matcher would be a different
// answer wearing this API's name.
var ErrNoBinary = errors.New("irregex: no gist/relate/irregex binary found")

// The three product faces of one kernel, each with an env override so a host can
// pin an exact build ([transports]).
const (
	ToolGist    = "gist"
	ToolRelate  = "relate"
	ToolIrregex = "irregex"
)

var envOverride = map[string]string{
	ToolGist:    "GIST_BIN",
	ToolRelate:  "RELATE_BIN",
	ToolIrregex: "IRREGEX_BIN",
}

// coldTimeout bounds one child. A corpus-wide kinship sweep on a large tree is
// seconds, not minutes; a caller wanting longer passes a ctx with its own
// deadline, which wins.
const coldTimeout = 60 * time.Second

var (
	resolvedMu sync.Mutex
	resolved   = map[string]resolvedPath{}
)

type resolvedPath struct {
	path string
	err  error
}

// Binary is the absolute path to one of the kernel's product binaries.
// Resolution order is the env override, this checkout's built
// zig-out/bin/<name>, then PATH — checkout-local ahead of PATH so a worktree
// never drives a stale globally installed build. Cached per process, negative
// answers included: a host with no binary asks once, not once per query.
func Binary(name string) (string, error) {
	resolvedMu.Lock()
	defer resolvedMu.Unlock()
	if r, ok := resolved[name]; ok {
		return r.path, r.err
	}
	var r resolvedPath
	r.path, r.err = locate(name)
	resolved[name] = r
	return r.path, r.err
}

func locate(name string) (string, error) {
	if env := os.Getenv(envOverride[name]); env != "" {
		if info, err := os.Stat(env); err == nil && !info.IsDir() {
			return env, nil
		}
		return "", fmt.Errorf("%w: %s=%q is not a file", ErrNoBinary, envOverride[name], env)
	}
	if built := checkoutBuild(name); built != "" {
		return built, nil
	}
	if onPath, err := exec.LookPath(name); err == nil {
		return onPath, nil
	}
	return "", fmt.Errorf("%w: set %s, put %s on PATH, or run `make install-gist`", ErrNoBinary, envOverride[name], name)
}

// checkoutBuild finds `zig-out/bin/<name>` for the kernel this process is
// running inside, by ascending from the working directory. A Go package has no
// __file__, so the tree is discovered rather than baked in — which also means a
// consumer outside the monorepo simply falls through to PATH.
func checkoutBuild(name string) string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for range 16 {
		for _, base := range []string{
			filepath.Join(dir, "zig-out", "bin", name),
			filepath.Join(dir, "libs", "kernels", "irregex", "zig-out", "bin", name),
		} {
			if info, err := os.Stat(base); err == nil && !info.IsDir() {
				return base
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
	return ""
}

// Output is one child's two streams: rows on stdout, diagnostics on stderr, so a
// caller reads results from one and provenance from the other without either
// contaminating the other.
type Output struct {
	Stdout, Stderr string
	Code           int
}

// Spawn runs one verb of one face. ctx cancellation kills the child, so a Go caller's
// cancellation reaches this tier exactly as it reaches the in-process one. Exit
// code 2 is a fault about the query and is raised; 0 and 1 are both answers
// (ExitNoMatch means the verb ran and emitted no row).
func Spawn(ctx context.Context, tool string, argv []string, dir string) (Output, error) {
	bin, err := Binary(tool)
	if err != nil {
		return Output{}, err
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, coldTimeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, bin, argv...)
	cmd.Dir = dir
	cmd.Env = uncapped()
	cmd.Stdin = nil // a readable stdin would make the engine read it instead of walking
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	runErr := cmd.Run()
	res := Output{Stdout: out.String(), Stderr: errb.String(), Code: cmd.ProcessState.ExitCode()}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return res, ctxErr
	}
	var exitErr *exec.ExitError
	switch {
	case runErr == nil, errors.As(runErr, &exitErr) && res.Code == irregex.ExitNoMatch:
		return res, nil
	case errors.As(runErr, &exitErr):
		detail := complaint(res.Stderr)
		if unsupported(res.Stderr) {
			return res, fmt.Errorf("%s %s: %s: %w", tool, argv[0], detail, ErrUnsupportedPattern)
		}
		if detail == "" {
			detail = fmt.Sprintf("exited %d", res.Code)
		}
		return res, fmt.Errorf("%s %s: %s", tool, argv[0], detail)
	default:
		return res, fmt.Errorf("%s %s: %w", tool, argv[0], runErr)
	}
}

// unsupportedMarkers are the phrases the engine prints when a pattern or flag is
// outside its linear-time syntax — the cold spelling of IRREGEX_STALE.
var unsupportedMarkers = [...]string{"unsupported", "use ripgrep", "use rg for this", "linear-time syntax", "not yet implemented"}

func unsupported(stderr string) bool {
	low := strings.ToLower(stderr)
	for _, m := range unsupportedMarkers {
		if strings.Contains(low, m) {
			return true
		}
	}
	return false
}

// uncapped lifts the CLI's agent output budget for this child: truncating a
// structured answer would silently break a program, and the engine keeps its own
// hard memory ceiling regardless.
func uncapped() []string {
	env := make([]string, 0, len(os.Environ())+1)
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "GIST_MAX_OUTPUT_BYTES=") || strings.HasPrefix(kv, "GIST_MAX_OUTPUT_TOKENS=") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "GIST_UNCAP=1")
}

// complaint is the child's own account of the fault. The engine prints the
// incident on its first `error:` line and then coaching on the lines after it, so
// the last line is the advice, not the diagnosis.
func complaint(stderr string) string {
	lines := strings.Split(strings.TrimRight(stderr, "\n"), "\n")
	for _, line := range lines {
		if strings.Contains(line, "error:") {
			return strings.TrimSpace(line)
		}
	}
	return strings.TrimSpace(lines[len(lines)-1])
}

// cold answers q by running the certified binary and decoding its NDJSON. This
// is the fail-open tier: it needs no cgo, no shared library, and no analytic
// plane, so a CGO_ENABLED=0 host reaches all seventeen verbs through it.
func cold(ctx context.Context, q Query) (*Rows, error) {
	p, err := planVerb(q)
	if err != nil {
		return nil, err
	}
	out, err := Spawn(ctx, p.tool, p.argv, q.Dir)
	if err != nil {
		return nil, err
	}
	rows, err := p.decode(out.Stdout)
	if err != nil {
		return nil, err
	}
	return newRows(&coldRows{rows: rows, facts: coldStats(out, len(rows))}), nil
}

// coldRows serves an answer the child already materialized. A child's stdout is
// read whole because its exit code is part of the answer, so there is nothing to
// stream past that point.
type coldRows struct {
	rows  []Row
	facts Stats
}

func (c *coldRows) fill(dst []Row) (int, error) {
	n := copy(dst, c.rows)
	c.rows = c.rows[n:]
	return n, nil
}

func (c *coldRows) stats() Stats { return c.facts }
func (c *coldRows) close() error { return nil }

// coldStats reads the verb's own summary record — the machine-readable twin of
// the line the CLI prints for a human to glance at, and the only place the cold
// tier can learn what a row cannot carry (how large a population the answer was
// drawn from, how much of the query was foreign, what a budget trimmed).
// Best-effort by design: an absent record yields the row count alone rather than
// failing a query that already produced its rows.
func coldStats(out Output, rows int) Stats {
	s := Stats{Rows: uint64(rows)}
	diag := summary(out.Stdout, out.Stderr)
	if diag == nil {
		return s
	}
	s.Source = sourceOrdinal(text(diag["source"]))
	s.FilesConsidered = counter(diag, "files", "units", "indexed_files", "read_files", "total_files", "shelf_files")
	s.Refreshed = counter(diag, "refreshed")
	s.Foreign = counter(diag, "foreign")
	s.Omitted = counter(diag, "omitted")
	if n := counter(diag, "rows", "picks", "hits", "located"); s.Rows == 0 {
		s.Rows = n
	}
	s.Elapsed = elapsed(diag)
	return s
}

// elapsed totals every millisecond counter the summary reports. A verb spells its
// phases separately (index_ms + query_ms, load_ms + compute_ms), and their sum is
// the wall clock the caller actually waited.
func elapsed(diag map[string]any) time.Duration {
	var ms float64
	for key, raw := range diag {
		if key != "ms" && !strings.HasSuffix(key, "_ms") {
			continue
		}
		if v, ok := number(raw); ok {
			ms += v
		}
	}
	return time.Duration(ms * float64(time.Millisecond))
}

func sourceOrdinal(name string) uint32 {
	switch name {
	case "atlas":
		return irregex.SourceAtlas
	case "shelf":
		return irregex.SourceShelf
	default:
		return irregex.SourceLive
	}
}

func counter(diag map[string]any, keys ...string) uint64 {
	for _, k := range keys {
		if n, ok := number(diag[k]); ok && n >= 0 {
			return uint64(n)
		}
	}
	return 0
}
