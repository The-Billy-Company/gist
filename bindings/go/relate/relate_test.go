package relate

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	irregex "irregex/bindings/go"
	"irregex/bindings/go/runtime"
)

// planted is the corpus every kinship expectation below is derived from: alpha
// and beta are the same eleven functions (beta with one extra comment line), and
// gamma shares nothing with either. The files are substantial on purpose — a
// three-line file carries too few phrases for the candidate stage to band, so a
// toy corpus yields a vacuous answer rather than a wrong one.
func planted(t *testing.T) *Corpus {
	t.Helper()
	root := t.TempDir()
	var body strings.Builder
	body.WriteString("package sample\n\n")
	for i := 1; i <= 11; i++ {
		fmt.Fprintf(&body, "// Stanza %d: the reticulation of splines, a matter of some delicacy.\n"+
			"func Reticulate%d(splines []int) int {\n\ttotal := 0\n\tfor _, s := range splines {\n\t\ttotal += s * %d\n\t}\n\treturn total\n}\n\n", i, i, i)
	}
	for name, text := range map[string]string{
		"alpha.go": body.String(),
		"beta.go":  body.String() + "// a trailing remark, so the pair is near rather than exact\n",
		"gamma.go": "package sample\n\n" + strings.Repeat("// Wholly unrelated prose about tunnels, weather, and the price of tin.\n", 30),
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return Over(root).In(root)
}

func requireEngine(t *testing.T) {
	t.Helper()
	if _, err := runtime.Binary(runtime.ToolRelate); err != nil {
		t.Skipf("no relate binary: %v", err)
	}
}

// TestDupsFindsThePlantedPair pins the copy-paste channel on a corpus whose one
// true answer is known in advance, and pins the grade band with it: a pair this
// close must not come back as background.
func TestDupsFindsThePlantedPair(t *testing.T) {
	requireEngine(t)
	pairs, err := planted(t).Dups(t.Context(), irregex.Kinship{MaxDistance: new(0.6), Top: 10})
	if err != nil {
		t.Fatalf("dups: %v", err)
	}
	if len(pairs) != 1 {
		t.Fatalf("dups = %+v, want exactly the alpha/beta pair", pairs)
	}
	got := []string{filepath.Base(pairs[0].A), filepath.Base(pairs[0].B)}
	slices.Sort(got)
	if want := []string{"alpha.go", "beta.go"}; !slices.Equal(got, want) {
		t.Errorf("pair = %v, want %v", got, want)
	}
	if pairs[0].Distance > 0.6 {
		t.Errorf("distance %v exceeds the threshold the query asked for", pairs[0].Distance)
	}
	if !pairs[0].Grade.AtLeast(irregex.GradeStrong) {
		t.Errorf("grade = %s, want strong or better for a near-identical pair", pairs[0].Grade)
	}
}

// TestClustersGroupsThePair pins the family shape: the same evidence as a pair
// list, already closed over, which is the unit a restructure acts on.
func TestClustersGroupsThePair(t *testing.T) {
	requireEngine(t)
	clusters, err := planted(t).Clusters(t.Context(), irregex.Kinship{MaxDistance: new(0.6)})
	if err != nil {
		t.Fatalf("clusters: %v", err)
	}
	if len(clusters) != 1 || len(clusters[0].Paths) != 2 {
		t.Fatalf("clusters = %+v, want one family of two", clusters)
	}
	members := []string{filepath.Base(clusters[0].Paths[0]), filepath.Base(clusters[0].Paths[1])}
	slices.Sort(members)
	if want := []string{"alpha.go", "beta.go"}; !slices.Equal(members, want) {
		t.Errorf("family = %v, want %v", members, want)
	}
	if clusters[0].MaxDistance > 0.6 {
		t.Errorf("max distance %v exceeds the family's own floor", clusters[0].MaxDistance)
	}
}

// TestSimilarWithholdsBackground pins the calibration promise: a floor withholds
// weak rows in the engine rather than leaving the caller to filter, and an answer
// made only of background is empty rather than misleading.
func TestSimilarWithholdsBackground(t *testing.T) {
	requireEngine(t)
	c := planted(t)
	near, err := c.Similar(t.Context(), irregex.Kinship{Target: "alpha.go", Top: 5})
	if err != nil {
		t.Fatalf("similar: %v", err)
	}
	if len(near) == 0 || filepath.Base(near[0].Path) != "beta.go" {
		t.Fatalf("nearest = %+v, want beta.go first", near)
	}
	if near[0].Channel != irregex.ChannelCopies {
		t.Errorf("channel = %s, want the default copies channel", near[0].Channel)
	}

	strict, err := c.Similar(t.Context(), irregex.Kinship{Target: "gamma.go", MinGrade: irregex.GradeStrong, Top: 5})
	if err != nil {
		t.Fatalf("similar with floor: %v", err)
	}
	for _, n := range strict {
		if !n.Grade.AtLeast(irregex.GradeStrong) {
			t.Errorf("%s came back at grade %s under a strong floor", n.Path, n.Grade)
		}
	}
}

// TestConceptsKeepUnmeasuredChannelsAbsent is the end-to-end presence-mask proof:
// the planted twins hold eleven structurally identical functions, so the shape
// family is real, its structure distance is a measured 0.0 (identical), and its
// byte kinship was never measured at all. Those two must not read the same.
func TestConceptsKeepUnmeasuredChannelsAbsent(t *testing.T) {
	requireEngine(t)
	concepts, err := planted(t).Concepts(t.Context(), irregex.Kinship{Top: 3})
	if err != nil {
		t.Fatalf("concepts: %v", err)
	}
	if len(concepts) == 0 {
		t.Fatal("no shape family for eleven copies of the same function body")
	}
	c := concepts[0]
	if c.Structure != 0 {
		t.Errorf("structure distance = %v, want 0 for identical shapes", c.Structure)
	}
	if c.Bytes != nil {
		t.Errorf("byte distance = %v, want absent — the shapes channel does not measure bytes", *c.Bytes)
	}
	if c.RepeatedLines <= 0 {
		t.Errorf("repeated lines = %d, want the lines the family shares", c.RepeatedLines)
	}
	if len(c.Members) < 2 {
		t.Fatalf("family has %d member(s), want at least the two that made it one", len(c.Members))
	}
	for _, m := range c.Members {
		if base := filepath.Base(m.Path); base != "alpha.go" && base != "beta.go" {
			t.Errorf("member %s is not one of the twins", m.Path)
		}
		if m.LineStart <= 0 {
			t.Errorf("member %s carries no line span", m.Path)
		}
	}
}

// TestRecallAndPack pins the two retrieval shapes against each other: recall
// ranks files by how much of the query they explain, pack picks the set, and a
// pack pick's coverage must be monotone because each is priced against the picks
// before it.
func TestRecallAndPack(t *testing.T) {
	requireEngine(t)
	c := planted(t)
	query := irregex.Retrieval{Query: "reticulation of splines, a matter of some delicacy", Top: 3}

	found, err := c.Recall(t.Context(), query)
	if err != nil {
		t.Fatalf("recall: %v", err)
	}
	if len(found) == 0 {
		t.Fatal("recall found nothing for text lifted out of the corpus itself")
	}
	if found[0].Gain <= 0 {
		t.Errorf("top gain = %v, want a positive coding gain", found[0].Gain)
	}
	for i := 1; i < len(found); i++ {
		if found[i].Gain > found[i-1].Gain {
			t.Errorf("recall row %d outranks row %d (%v > %v)", i, i-1, found[i].Gain, found[i-1].Gain)
		}
	}

	picks, err := c.Pack(t.Context(), query)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}
	if len(picks) == 0 {
		t.Fatal("pack assembled no reading set")
	}
	last := 0.0
	for i, p := range picks {
		if p.Rank != int64(i+1) {
			t.Errorf("pick %d reports rank %d", i, p.Rank)
		}
		if p.Coverage < last {
			t.Errorf("coverage fell from %v to %v — picks are priced cumulatively", last, p.Coverage)
		}
		last = p.Coverage
	}
}

// TestPatternsAttributesEveryHit pins the one-walk sweep: the planted corpus puts
// Reticulate3 in exactly the two twin files, so both the hits and the engine-side
// tally are known without running the sweep to find out.
func TestPatternsAttributesEveryHit(t *testing.T) {
	requireEngine(t)
	c := planted(t)
	hits, err := c.Patterns(t.Context(), irregex.Sweep{Patterns: []string{"Reticulate3", "tunnels"}})
	if err != nil {
		t.Fatalf("patterns: %v", err)
	}
	perPattern := map[int64][]string{}
	for _, h := range hits {
		perPattern[h.PatternID] = append(perPattern[h.PatternID], filepath.Base(h.Path))
		if h.Line <= 0 {
			t.Errorf("hit in %s carries no line number", h.Path)
		}
	}
	first := perPattern[0]
	slices.Sort(first)
	if want := []string{"alpha.go", "beta.go"}; !slices.Equal(first, want) {
		t.Errorf("Reticulate3 attributed to %v, want %v", first, want)
	}
	for _, path := range perPattern[1] {
		if path != "gamma.go" {
			t.Errorf("tunnels attributed to %s, which does not contain it", path)
		}
	}

	counts, err := c.Counts(t.Context(), irregex.Sweep{Patterns: []string{"Reticulate3"}, ByPattern: true})
	if err != nil {
		t.Fatalf("counts: %v", err)
	}
	if len(counts) != 1 || counts[0].Label != "Reticulate3" || counts[0].Count != 2 {
		t.Fatalf("counts = %+v, want Reticulate3 twice (once per twin)", counts)
	}
}

// TestRowsEscapeHatchCarriesStats pins that the undecoded cursor is reachable and
// reports the answer-level counters, which no typed row can carry.
func TestRowsEscapeHatchCarriesStats(t *testing.T) {
	requireEngine(t)
	rows, err := planted(t).Rows(t.Context(), irregex.OpDups, irregex.Kinship{MaxDistance: new(0.6)})
	if err != nil {
		t.Fatalf("rows: %v", err)
	}
	defer rows.Close()
	found, err := rows.Collect()
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	if len(found) == 0 {
		t.Fatal("no rows for the planted pair")
	}
	if schema := found[0].Schema().Name; schema != "dup_pair" {
		t.Errorf("row schema = %s, want dup_pair", schema)
	}
	if stats := rows.Stats(); stats.Rows == 0 {
		t.Errorf("stats = %+v, want a row count", stats)
	}
}

// TestVerbFamilyMismatchIsRefused pins the seam: a verb handed the wrong params
// family fails before any tier runs, rather than being reinterpreted.
func TestVerbFamilyMismatchIsRefused(t *testing.T) {
	if _, err := planted(t).Rows(t.Context(), irregex.OpDups, irregex.Retrieval{Query: "x"}); err == nil {
		t.Fatal("a retrieval params struct was accepted for a kinship verb")
	}
}
