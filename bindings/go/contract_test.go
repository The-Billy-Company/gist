package irregex

import (
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// contractTOML is the single source of truth both this binding and the kernel
// are generated from, read here so a calibration test cannot be satisfied by
// copying this package's own numbers back into the assertion.
func contractTOML(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("cwd: %v", err)
	}
	path := filepath.Join(dir, "..", "..", "contract", "search_api.toml")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("contract unreadable at %s: %v", path, err)
	}
	return string(body)
}

// bands reads one [irregex.grades] row as label → cut point.
func bands(t *testing.T, toml, row string) map[string]float64 {
	t.Helper()
	line := regexp.MustCompile(`(?m)^` + row + ` = \{([^}]*)\}`).FindStringSubmatch(toml)
	if line == nil {
		t.Fatalf("contract declares no %q band row", row)
	}
	out := map[string]float64{}
	for _, m := range regexp.MustCompile(`(\w+) = (\d+\.\d+)`).FindAllStringSubmatch(line[1], -1) {
		f, err := strconv.ParseFloat(m[2], 64)
		if err != nil {
			t.Fatalf("%s.%s = %q: %v", row, m[1], m[2], err)
		}
		out[m[1]] = f
	}
	if len(out) == 0 {
		t.Fatalf("%s row declares no cut points", row)
	}
	return out
}

// TestBandCutPointsMatchTheContract holds the calibration to the contract's own
// numbers, on both polarities. A cut point is an inclusive bound, so the edge
// value itself belongs to the band it names — and one step past it does not.
func TestBandCutPointsMatchTheContract(t *testing.T) {
	toml := contractTOML(t)
	const eps = 1e-9

	for label, cut := range bands(t, toml, "distance") {
		want, ok := ParseGrade(label)
		if !ok {
			t.Errorf("distance band %q is not a grade label", label)
			continue
		}
		if got := GradeDistance(cut); got != want {
			t.Errorf("GradeDistance(%v) = %v, contract says %v (upper bound, inclusive)", cut, got, want)
		}
		if got := GradeDistance(cut + eps); got.AtLeast(want) {
			t.Errorf("GradeDistance(%v) = %v, want weaker than %v just past the bound", cut+eps, got, want)
		}
	}

	for _, row := range []struct {
		name  string
		grade func(float64) Grade
	}{{"gap", GradeGap}, {"gain", GradeGain}} {
		for label, cut := range bands(t, toml, row.name) {
			want, ok := ParseGrade(label)
			if !ok {
				t.Errorf("%s band %q is not a grade label", row.name, label)
				continue
			}
			if got := row.grade(cut); got != want {
				t.Errorf("Grade%s(%v) = %v, contract says %v (lower bound, inclusive)", strings.ToUpper(row.name[:1])+row.name[1:], cut, got, want)
			}
			if got := row.grade(cut - eps); got.AtLeast(want) {
				t.Errorf("%s(%v) = %v, want weaker than %v just under the bound", row.name, cut-eps, got, want)
			}
		}
	}

	// The gap channel is deliberately missing the top band: two byte-identical
	// files have a zero gap, which is the weakest twin evidence there is.
	if _, declared := bands(t, toml, "gap")["identical"]; declared {
		t.Error("the contract now declares an identical gap band — this mirror withholds one")
	}
	if got := GradeGap(1.0); got == GradeIdentical {
		t.Error("GradeGap graded a maximal gap identical")
	}
}

// TestChannelPolarityFollowsTheContract pins the one distinction a bare score
// cannot carry: twins is a gap that grows while every other channel is a
// distance that closes, so grading the same number both ways must disagree.
func TestChannelPolarityFollowsTheContract(t *testing.T) {
	for _, c := range []Channel{ChannelCopies, ChannelShapes, ChannelAny} {
		if c.Gap() {
			t.Errorf("%v reported gap polarity", c)
		}
		if got, want := c.Quantity(), "distance"; got != want {
			t.Errorf("%v reports its score as %q, want %q", c, got, want)
		}
		if got := c.Grade(0.0); got != GradeIdentical {
			t.Errorf("%v.Grade(0.0) = %v, want identical", c, got)
		}
	}
	if !ChannelTwins.Gap() || ChannelTwins.Quantity() != "echo" {
		t.Errorf("twins = gap:%v quantity:%q, want gap:true quantity:%q", ChannelTwins.Gap(), ChannelTwins.Quantity(), "echo")
	}
	if got := ChannelTwins.Grade(0.0); got != GradeNone {
		t.Errorf("twins.Grade(0.0) = %v, want none — a zero gap is no evidence", got)
	}
}

// TestEnumLabelsRoundTrip pins the generated table as the only spelling
// authority: every declared variant parses back to its own ordinal, and a label
// the contract does not declare is refused rather than folded onto ordinal 0.
func TestEnumLabelsRoundTrip(t *testing.T) {
	for id := range uint32(8) {
		variants, ok := EnumVariants(id)
		if !ok {
			continue
		}
		for want, label := range variants {
			got, ok := EnumOrdinal(id, label)
			if !ok {
				t.Errorf("enum %d: label %q does not resolve", id, label)
				continue
			}
			if got != int64(want) {
				t.Errorf("enum %d: %q = ordinal %d, want %d", id, label, got, want)
			}
		}
		if _, ok := EnumOrdinal(id, "definitely_not_a_variant"); ok {
			t.Errorf("enum %d accepted an undeclared label", id)
		}
	}
	for _, parse := range []struct {
		name string
		fn   func(string) (bool, bool)
	}{
		{"grade", func(s string) (bool, bool) { g, ok := ParseGrade(s); return g != GradeNone, ok }},
		{"channel", func(s string) (bool, bool) { c, ok := ParseChannel(s); return c != ChannelCopies, ok }},
		{"unit", func(s string) (bool, bool) { u, ok := ParseUnit(s); return u != UnitFile, ok }},
		{"rank_kind", func(s string) (bool, bool) { k, ok := ParseRankKind(s); return k != RankDefinition, ok }},
	} {
		if _, ok := parse.fn("nonsense"); ok {
			t.Errorf("Parse%s accepted a label the contract does not declare", parse.name)
		}
	}
	// The metric spellings are aliases of one enum, not a second code path.
	for alias, want := range map[string]Channel{"bytes": ChannelCopies, "echo": ChannelTwins, "structure": ChannelShapes, "fused": ChannelAny} {
		if got, ok := ParseChannel(alias); !ok || got != want {
			t.Errorf("ParseChannel(%q) = (%v, %v), want (%v, true)", alias, got, ok, want)
		}
	}
}

// TestVerbTableIsWellFormed pins the generated dispatch table's internal
// agreement: every op resolves, names a live schema, and declares one of the
// five params families the ABI has a struct for.
func TestVerbTableIsWellFormed(t *testing.T) {
	families := map[string]bool{"kinship": true, "retrieval": true, "sweep": true, "compose": true, "rank": true}
	if VerbCount() == 0 {
		t.Fatal("the generated verb table is empty")
	}
	for op := 1; op <= VerbCount(); op++ {
		verb, ok := Verb(Op(op))
		if !ok {
			t.Fatalf("op %d does not resolve, though the table declares %d", op, VerbCount())
		}
		if verb.Name == "" {
			t.Errorf("op %d has no name", op)
		}
		if !families[verb.Params] {
			t.Errorf("%s declares params family %q, which the ABI has no struct for", verb.Name, verb.Params)
		}
		schema, ok := Schema(verb.Schema)
		if !ok {
			t.Errorf("%s names row schema %d, which this binding does not declare", verb.Name, verb.Schema)
			continue
		}
		if len(schema.Fields) == 0 {
			t.Errorf("%s rows on schema %s, which declares no fields", verb.Name, schema.Name)
		}
	}
	if _, ok := Verb(Op(VerbCount() + 1)); ok {
		t.Error("an op past the table's end resolved")
	}
}

// TestRequestLowersOnlyWhatItWasAsked pins the argv lowering: an option the
// caller left alone must not appear, since a flag the engine reads as a default
// change would silently answer a different question.
func TestRequestLowersOnlyWhatItWasAsked(t *testing.T) {
	bare := Request{Pattern: `func\s+\w+`}.Argv("libs", "services")
	if bare[0] != "--json" {
		t.Errorf("argv[0] = %q, want the record-stream flag first", bare[0])
	}
	for _, unwanted := range []string{"-i", "-F", "-w", "-v", "-S", "-U", "-A", "-B", "-C", "-m"} {
		if slices.Contains(bare, unwanted) {
			t.Errorf("a bare request lowered %q", unwanted)
		}
	}
	if got := bare[len(bare)-2:]; got[0] != "libs" || got[1] != "services" {
		t.Errorf("roots lowered as %q, want them last and in order", got)
	}

	full := Request{Pattern: "x", Fixed: true, IgnoreCase: true, Word: true, Invert: true, MaxCount: 3, Context: 2}.Argv()
	// Context lowers as the two sides it resolves to, which is the shape the ABI
	// carries and what -C means on the CLI.
	for _, want := range []string{"-F", "-i", "-w", "-v", "-B", "-A", "-m"} {
		if !slices.Contains(full, want) {
			t.Errorf("argv %q omits %q", full, want)
		}
	}
	if !slices.Contains(full, "3") || !slices.Contains(full, "2") {
		t.Errorf("argv %q dropped a numeric option's value", full)
	}
	// The pattern is passed with -e, so a pattern beginning with a dash cannot be
	// read as a flag.
	if got := full[len(full)-2:]; got[0] != "-e" || got[1] != "x" {
		t.Errorf("pattern lowered as %q, want it behind -e", got)
	}
}
