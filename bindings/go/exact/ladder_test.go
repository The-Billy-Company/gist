// What the shared cold tier reports when this package's binary answers it.
//
// The tier under test belongs to the substrate — `runtime` spawns the child,
// frames the request, and decodes rows back — but exercising it needs a real
// producer, and this repository is where one is built. The assertion lived in
// the substrate's own suite until the packages split, which meant a public
// library's tests could not run without a clone of a consumer beside them.
//
// Driven through `rank`, the one analytic verb gist owns. The verb is incidental:
// what is being pinned is that an answer can say how much work it did and which
// tier did it, rather than merely handing back rows.
package exact

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

func TestColdSurfacesStats(t *testing.T) {
	requireBin(t)
	// Force the subprocess tier: with an FFI-capable build this would otherwise
	// answer in-process and prove nothing about the child.
	t.Setenv("IRGX_NO_FFI", "1")
	root := rankCorpus(t)
	rows, err := runtime.Run(t.Context(), runtime.Query{
		Op:     analytic.OpRank,
		Params: analytic.Rank{Pattern: "Reticulate", Top: 3},
		Roots:  []string{root},
		Dir:    root,
	})
	if err != nil {
		t.Fatalf("rank: %v", err)
	}
	defer rows.Close()
	found, err := rows.Collect()
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	if len(found) == 0 {
		t.Fatal("the fixture corpus matched nothing, so this proves no decode happened")
	}
	stats := rows.Stats()
	if stats.Elapsed <= 0 {
		t.Errorf("stats reported no elapsed time: %+v", stats)
	}
	if stats.Rows != uint64(len(found)) {
		t.Errorf("stats.Rows = %d, decoded %d", stats.Rows, len(found))
	}
	if stats.SourceName() == "" {
		t.Error("stats named no tier")
	}
}

// rankCorpus writes a small tree with one deliberate near-duplicate pair and one
// unrelated file, so a ranking verb has something true to find without depending
// on the repository around it. The files are deliberately substantial: a sketch of
// a three-line file carries too few phrases for the candidate stage to band, so a
// toy corpus produces a vacuous answer rather than a wrong one.
//
// Distinct from this package's `corpus`, which plants the TODO fixture the exact
// search oracle compares over.
func rankCorpus(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	var body strings.Builder
	body.WriteString("package sample\n\n")
	for i := 1; i <= 11; i++ {
		fmt.Fprintf(&body, "// Stanza %d: the reticulation of splines, a matter of some delicacy.\n"+
			"func Reticulate%d(splines []int) int {\n\ttotal := 0\n\tfor _, s := range splines {\n\t\ttotal += s * %d\n\t}\n\treturn total\n}\n\n", i, i, i)
	}
	files := map[string]string{
		"alpha.go": body.String(),
		"beta.go":  body.String() + "// a trailing remark, so the pair is near rather than exact\n",
		"gamma.go": "package sample\n\n" + strings.Repeat("// Wholly unrelated prose about tunnels, weather, and the price of tin.\n", 30),
	}
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return root
}
