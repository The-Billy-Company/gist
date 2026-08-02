package index

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

// fixture is a corpus with its own artifact home, so a lifecycle test never
// rebuilds the shared index the rest of this machine's tools are riding.
func fixture(t *testing.T) *Corpus {
	t.Helper()
	// Fatal rather than Skip, the policy `exact/engine_test.go` already states:
	// this module answers every verb by running the binary, so a missing one is a
	// broken environment, not an absent optional capability. Skipping turned that
	// into a green tick over a suite that had exercised nothing — the failure mode
	// worth fearing on CI, where a `zig build` that silently produced no binary
	// would read as a passing lifecycle suite.
	if _, err := runtime.Binary(runtime.ToolGist); err != nil {
		t.Fatalf("gist binary required (build with `zig build` or set GIST_BIN): %v", err)
	}
	root := t.TempDir()
	t.Setenv("GIST_DIR", t.TempDir())
	// A private artifact home is only half of the isolation: a resident session
	// left over from another tree is still reachable, and this suite is about what
	// a lifecycle verb writes to disk in ITS home, not about warm dispatch. Stand
	// the daemon down so the subject is the artifacts.
	t.Setenv("GIST_NO_AUTOSERVE", "1")
	var body strings.Builder
	body.WriteString("package sample\n\n")
	for i := 1; i <= 11; i++ {
		fmt.Fprintf(&body, "// Stanza %d: the reticulation of splines.\nfunc Reticulate%d(s []int) int { return len(s) * %d }\n\n", i, i, i)
	}
	for name, text := range map[string]string{
		"alpha.go": body.String(),
		"beta.go":  body.String() + "// a trailing remark\n",
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return Over(".").In(root)
}

// TestRefreshBuildsAndReportsTheIndex pins the lifecycle end to end: an artifact
// home with nothing in it reports unready, a refresh makes it ready and bound to
// this tree, and the reported size matches the corpus that was indexed.
func TestRefreshBuildsAndReportsTheIndex(t *testing.T) {
	c := fixture(t)
	before, err := c.Status(t.Context())
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if before.Ready() {
		t.Fatalf("a fresh artifact home reported ready: %+v", before)
	}

	after, err := c.Refresh(t.Context())
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if !after.Ready() {
		t.Fatalf("after a refresh the index is %+v, want ready and bound here", after)
	}
	if after.Files != 2 {
		t.Errorf("indexed %d file(s), want the 2 in the fixture", after.Files)
	}
	if after.Distinct == 0 || after.Postings == 0 || after.IndexBytes == 0 {
		t.Errorf("index reports no content: %+v", after)
	}
	if after.Path == "" || !strings.HasSuffix(after.Path, ".gist") {
		t.Errorf("index path = %q", after.Path)
	}
	if after.Age < 0 {
		t.Errorf("age = %v", after.Age)
	}
}

// TestAtlasReportsEveryArtifact pins that all three compression artifacts are
// reported separately: quote needs the shelf specifically, so "the atlas is ready"
// must not stand in for "the shelf is ready". The unbuilt read is the first half —
// a fresh artifact home must report every artifact absent rather than defaulting
// one to ready — and the built read is the second.
//
// The one skip left in this package, and the only one that survives scrutiny.
// Every other missing-binary arm here became fatal, because this module answers
// by running `gist` and a missing one is a broken environment. This is different
// in kind: [Corpus.Atlas] reads `relate status --json`, so relate is not merely
// the producer of the artifacts — it is the producer of the *readiness document*
// under test. Neither half runs without it.
//
// It is also not relocatable the way irregex's ladder tests were. Those needed
// only *a* producer, so they moved to the public one. Moving this would mean
// relate's Go module requiring gist's, inverting the dependency edge permanently
// in go.mod to serve a test. So it stays where the API lives and skips where the
// binary cannot exist — and relate's CI, which can build both, runs this suite
// against a real binary so the assertion is genuinely exercised somewhere.
func TestAtlasReportsEveryArtifact(t *testing.T) {
	c := fixture(t)
	if _, err := runtime.Binary(runtime.ToolRelate); err != nil {
		t.Skipf("no relate binary, and relate both writes these artifacts and reports their readiness: %v", err)
	}
	empty, err := c.Atlas(t.Context())
	if err != nil {
		t.Fatalf("atlas: %v", err)
	}
	for name, a := range map[string]Artifact{"kinship": empty.Kinship, "fragments": empty.Fragments, "shelf": empty.Shelf} {
		if a.Ready() {
			t.Errorf("%s reported ready in a fresh artifact home: %+v", name, a)
		}
	}
	built, err := c.RefreshAtlas(t.Context(), false)
	if err != nil {
		t.Fatalf("refresh atlas: %v", err)
	}
	if !built.Kinship.Ready() {
		t.Fatalf("kinship atlas = %+v, want ready after a build", built.Kinship)
	}
	if built.Kinship.Files == 0 || built.Kinship.Bytes == 0 {
		t.Errorf("kinship atlas reports no content: %+v", built.Kinship)
	}
	if built.Kinship.Built.IsZero() {
		t.Error("kinship atlas reports no build time, so staleness cannot be judged")
	}
	if built.Shelf.Ready() {
		t.Errorf("shelf = %+v, want unbuilt — it is opt-in", built.Shelf)
	}
}
