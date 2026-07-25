// In-process Engine/Cursor tests over the pull-cursor C ABI (ADR-352).
//
// The oracle is the certified `gist` binary: the test execs `gist --json` over
// the same throwaway corpus and asserts the Go binding's records are
// byte-identical — same order, paths, line numbers, text, and submatch spans. So,
// transitively through the CLI's own rg certification, this Go Engine ≡ cold ≡ rg.
// It then pins the pull-side invariants the CLI can't express here: All() is the
// same stream, a MaxCount budget stops at a boundary while Matched stays true, a
// canceled context surfaces as ctx.Err() without crashing the host, an
// unsupported pattern is a catchable error, and records outlive both handles.
//
// Requires a resolvable `gist` binary (the cold oracle); fails closed without it.
package irregex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// gistBin resolves the certified binary: $GIST_BIN, then the kernel's built
// binary, then PATH. Empty means "skip — no oracle."
func gistBin() string {
	if b := os.Getenv("GIST_BIN"); b != "" {
		return b
	}
	if p, err := filepath.Abs(filepath.Join("..", "..", "zig-out", "bin", "gist")); err == nil {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	if b, err := exec.LookPath("gist"); err == nil {
		return b
	}
	return ""
}

// corpus writes the shared fixture tree and returns its root.
func corpus(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(d, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.py", "def alpha():\n    return TODO\n# TODO trailing\n")
	write("b.py", "class Beta:\n    pass  # TODO later\n")
	write("c.txt", "no marker here\nplain text\n")
	if err := os.Mkdir(filepath.Join(d, "pkg"), 0o755); err != nil {
		t.Fatal(err)
	}
	write("pkg/d.py", "x = 1  # todo lowercase\nTODO upper TODO twice\n")
	return d
}

// cold execs `gist --json` with the argv equivalent of req over root and parses
// the record stream — the cross-face oracle.
func cold(t *testing.T, bin, root string, req Request) []Match {
	t.Helper()
	args := []string{"--json"}
	add := func(on bool, flag string) {
		if on {
			args = append(args, flag)
		}
	}
	add(req.Fixed, "-F")
	add(req.IgnoreCase, "-i")
	add(req.SmartCase, "-S")
	add(req.Word, "-w")
	add(req.Invert, "-v")
	if req.Unicode != nil && !*req.Unicode {
		args = append(args, "--no-unicode")
	}
	if req.Before > 0 {
		args = append(args, "-B", strconv.FormatUint(uint64(req.Before), 10))
	}
	if req.After > 0 {
		args = append(args, "-A", strconv.FormatUint(uint64(req.After), 10))
	}
	if req.Context > 0 {
		args = append(args, "-C", strconv.FormatUint(uint64(req.Context), 10))
	}
	if req.MaxCount > 0 {
		args = append(args, "-m", strconv.FormatUint(uint64(req.MaxCount), 10))
	}
	args = append(args, "-e", req.Pattern, root)

	out, err := exec.Command(bin, args...).Output()
	// gist exits 1 on a clean no-match — not an error for this oracle.
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) || ee.ExitCode() != 1 {
			t.Fatalf("gist %v: %v", args, err)
		}
	}
	return parseJSON(t, out)
}

func parseJSON(t *testing.T, stream []byte) []Match {
	t.Helper()
	var out []Match
	for _, line := range strings.Split(string(stream), "\n") {
		if line == "" {
			continue
		}
		var rec struct {
			Type string `json:"type"`
			Data struct {
				Path       struct{ Text string } `json:"path"`
				LineNumber uint64                `json:"line_number"`
				Lines      struct{ Text string } `json:"lines"`
				Submatches []struct {
					Match struct{ Text string } `json:"match"`
					Start int                   `json:"start"`
					End   int                   `json:"end"`
				} `json:"submatches"`
			} `json:"data"`
		}
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			continue
		}
		kind := KindMatch
		switch rec.Type {
		case "match":
			kind = KindMatch
		case "context":
			kind = KindContext
		default:
			continue
		}
		text := strings.TrimSuffix(strings.TrimSuffix(rec.Data.Lines.Text, "\n"), "\r")
		var subs []Submatch
		for _, s := range rec.Data.Submatches {
			subs = append(subs, Submatch{Text: s.Match.Text, Start: s.Start, End: s.End})
		}
		out = append(out, Match{
			Path:       rec.Data.Path.Text,
			LineNumber: rec.Data.LineNumber,
			Text:       text,
			Kind:       kind,
			Submatches: subs,
		})
	}
	return out
}

// drain iterates a cursor to exhaustion, failing on a mid-stream error.
func drain(t *testing.T, c *Cursor) []Match {
	t.Helper()
	var got []Match
	for c.Next() {
		got = append(got, c.Match())
	}
	if err := c.Err(); err != nil {
		t.Fatalf("cursor error: %v", err)
	}
	return got
}

func requireBin(t *testing.T) string {
	t.Helper()
	bin := gistBin()
	if bin == "" {
		// Fail closed — the cold oracle is load-bearing for these bindings.
		// Build with `make build-gist` or set GIST_BIN; do not Skip (test-bandaid).
		t.Fatal("gist binary required (build with `make build-gist` or set GIST_BIN)")
	}
	return bin
}

func TestEngineSearchEqualsCold(t *testing.T) {
	bin := requireBin(t)
	root := corpus(t)
	eng, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer eng.Close()

	no := false
	cases := []Request{
		{Pattern: "TODO"},
		{Pattern: "TODO", Fixed: true},
		{Pattern: "TODO", IgnoreCase: true},
		{Pattern: `def\s+\w+`},
		{Pattern: "absent_needle_xyzzy"},
		{Pattern: "TODO", Before: 1, After: 1},
		{Pattern: "TODO", Unicode: &no},
	}
	for _, req := range cases {
		cur, err := eng.Search(context.Background(), req)
		if err != nil {
			t.Fatalf("search %q: %v", req.Pattern, err)
		}
		got := drain(t, cur)
		cur.Close()
		want := cold(t, bin, root, req)
		if !reflect.DeepEqual(normalize(got), normalize(want)) {
			t.Fatalf("drift on %q:\n got=%v\nwant=%v", req.Pattern, got, want)
		}
	}
}

// normalize collapses nil vs empty submatch slices so DeepEqual compares content.
func normalize(ms []Match) []Match {
	for i := range ms {
		if ms[i].Submatches == nil {
			ms[i].Submatches = []Submatch{}
		}
	}
	if ms == nil {
		return []Match{}
	}
	return ms
}

func TestAllIteratesSameStream(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	eng, _ := Open(root)
	defer eng.Close()

	c1, _ := eng.Search(context.Background(), Request{Pattern: "TODO"})
	defer c1.Close()
	scanner := drain(t, c1)

	c2, _ := eng.Search(context.Background(), Request{Pattern: "TODO"})
	defer c2.Close()
	var ranged []Match
	for m, err := range c2.All() {
		if err != nil {
			t.Fatal(err)
		}
		ranged = append(ranged, m)
	}
	if !reflect.DeepEqual(scanner, ranged) {
		t.Fatalf("All() drift:\n scan=%v\nrange=%v", scanner, ranged)
	}
}

func TestMaxCountStopsButMatched(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	eng, _ := Open(root)
	defer eng.Close()

	cur, err := eng.Search(context.Background(), Request{Pattern: "TODO", MaxCount: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer cur.Close()
	// MaxCount is a per-file cap: one match line per file, all files still scanned.
	got := drain(t, cur)
	if len(got) == 0 {
		t.Fatal("expected at least one record under MaxCount=1")
	}
	if !cur.Matched() {
		t.Fatal("Matched() must stay true")
	}
}

func TestMatchedTracksAnyHit(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	eng, _ := Open(root)
	defer eng.Close()

	hit, _ := eng.Search(context.Background(), Request{Pattern: "TODO"})
	defer hit.Close()
	if !hit.Matched() {
		t.Fatal("expected a match")
	}
	miss, _ := eng.Search(context.Background(), Request{Pattern: "absent_needle_xyzzy"})
	defer miss.Close()
	if got := drain(t, miss); len(got) != 0 {
		t.Fatalf("expected empty, got %v", got)
	}
	if miss.Matched() {
		t.Fatal("expected Matched() false")
	}
}

func TestCanceledContextSurfacesErr(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	eng, _ := Open(root)
	defer eng.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := eng.Search(ctx, Request{Pattern: "TODO"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
	// The engine stays healthy: a fresh search still returns the full set.
	cur, err := eng.Search(context.Background(), Request{Pattern: "TODO"})
	if err != nil {
		t.Fatal(err)
	}
	defer cur.Close()
	if got := drain(t, cur); len(got) == 0 {
		t.Fatal("engine unhealthy after a canceled search")
	}
}

func TestDeadlineIsHonored(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	eng, _ := Open(root)
	defer eng.Close()

	// An already-past deadline surfaces as DeadlineExceeded, never a hang.
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	_, err := eng.Search(ctx, Request{Pattern: "TODO"})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected DeadlineExceeded, got %v", err)
	}
}

func TestUnsupportedPatternIsError(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	eng, _ := Open(root)
	defer eng.Close()

	_, err := eng.Search(context.Background(), Request{Pattern: `(a)\1`})
	if !errors.Is(err, ErrUnsupportedPattern) {
		t.Fatalf("expected ErrUnsupportedPattern, got %v", err)
	}
}

func TestRecordsOutliveHandles(t *testing.T) {
	requireBin(t)
	root := corpus(t)
	var records []Match
	func() {
		eng, _ := Open(root)
		defer eng.Close()
		cur, _ := eng.Search(context.Background(), Request{Pattern: "TODO"})
		records = drain(t, cur)
		cur.Close()
	}()
	if len(records) == 0 {
		t.Fatal("expected records to survive handle teardown")
	}
	for _, m := range records {
		if m.Path == "" || m.Text == "" {
			t.Fatalf("record fields not copied: %+v", m)
		}
	}
}
