package irregex

// The closed vocabularies a row field may hold ([row_enums]) and the one
// calibration of what a kinship score is worth ([irregex.grades]).
//
// Ordinals are the ABI — variants are append-only and never reordered — so each
// type here is that ordinal, and its label comes from the generated table rather
// than from a second list spelled out in Go.

// Grade is the calibrated band a kinship score falls in, ordered weakest-first
// so a threshold test is `>=`. A ranking verb always returns rows, so the grade
// is what separates a finding from background.
type Grade uint32

// The five bands. GradeNone is background, not a result.
const (
	GradeNone Grade = iota
	GradeWeak
	GradeModerate
	GradeStrong
	GradeIdentical
)

func (g Grade) String() string {
	if s, ok := labelOf("grade", int64(g)); ok {
		return s
	}
	return "grade?"
}

// ParseGrade reads a grade label ("strong"), as `--min-grade` spells it.
func ParseGrade(label string) (Grade, bool) {
	o, ok := ordinalOf("grade", label)
	return Grade(o), ok
}

// AtLeast reports whether g is at least as strong as floor — the `--min-grade`
// admission test.
func (g Grade) AtLeast(floor Grade) bool { return g >= floor }

// Channel names which kinship signal produced a score. Two polarities live
// here: copies/shapes/any close toward zero, while twins is a GAP that grows,
// which is why a score never travels without its channel.
type Channel uint32

// The four channels. Their metric spellings (bytes/echo/structure/fused) parse
// as aliases, because they are spellings of one enum and not a second code path.
const (
	ChannelCopies Channel = iota
	ChannelTwins
	ChannelShapes
	ChannelAny
)

func (c Channel) String() string {
	if s, ok := labelOf("channel", int64(c)); ok {
		return s
	}
	return "channel?"
}

// ParseChannel reads a channel name or its metric alias.
func ParseChannel(name string) (Channel, bool) {
	switch name {
	case "bytes":
		return ChannelCopies, true
	case "echo":
		return ChannelTwins, true
	case "structure":
		return ChannelShapes, true
	case "fused":
		return ChannelAny, true
	}
	o, ok := ordinalOf("channel", name)
	return Channel(o), ok
}

// Gap reports whether this channel measures a widening gap rather than a
// closing distance — the difference between `--min-echo` and `--max-distance`.
func (c Channel) Gap() bool { return c == ChannelTwins }

// Quantity is the column the engine reports this channel's score in ("echo" for
// the gap channel, "distance" otherwise).
func (c Channel) Quantity() string {
	if c.Gap() {
		return "echo"
	}
	return "distance"
}

// Grade bands score on this channel's own polarity.
func (c Channel) Grade(score float64) Grade {
	if c.Gap() {
		return GradeGap(score)
	}
	return GradeDistance(score)
}

// Band cut points are the documented ones ([irregex.grades]): a distance's
// upper bound per band, a gap's lower bound. A gap is never `identical` — two
// byte-identical files have no gap at all, which is the weakest twin evidence
// there is.
var (
	distanceBands = [...]struct {
		upper float64
		grade Grade
	}{{0.05, GradeIdentical}, {0.25, GradeStrong}, {0.50, GradeModerate}, {0.75, GradeWeak}}

	gapBands = [...]struct {
		lower float64
		grade Grade
	}{{0.45, GradeStrong}, {0.30, GradeModerate}, {0.15, GradeWeak}}

	// Gain is measured over a ~20k-file corpus: a sentence lifted verbatim scored
	// 0.9496, an on-target descriptive query 0.63–0.82, a query whose subject the
	// scope does not contain 0.32–0.44. A one-word query is cheap to explain
	// anywhere, which is why 0.43 lands in the same band as "not really here".
	gainBands = [...]struct {
		lower float64
		grade Grade
	}{{0.90, GradeIdentical}, {0.60, GradeStrong}, {0.45, GradeModerate}, {0.30, GradeWeak}}
)

// GradeDistance bands a distance in [0,1] (lower is closer).
func GradeDistance(distance float64) Grade {
	for _, b := range distanceBands {
		if distance <= b.upper {
			return b.grade
		}
	}
	return GradeNone
}

// GradeGap bands a bytes−structure gap (higher is stronger).
func GradeGap(gap float64) Grade {
	for _, b := range gapBands {
		if gap >= b.lower {
			return b.grade
		}
	}
	return GradeNone
}

// GradeGain bands a retrieval coding gain (higher is closer). Recall is its own
// polarity: it prices text against the corpus rather than comparing two records,
// so it carries no Channel.
func GradeGain(gain float64) Grade {
	for _, b := range gainBands {
		if gain >= b.lower {
			return b.grade
		}
	}
	return GradeNone
}

// Unit is the comparison unit a kinship row was computed over. The function unit
// is what a file-level sweep cannot substitute for: a 12-line helper cloned into
// six modules shares ~3% of those files' bytes.
type Unit uint32

// The three comparison units.
const (
	UnitFile Unit = iota
	UnitFunction
	UnitMatch
)

func (u Unit) String() string {
	if s, ok := labelOf("unit", int64(u)); ok {
		return s
	}
	return "unit?"
}

// ParseUnit reads a unit name ("function").
func ParseUnit(name string) (Unit, bool) {
	o, ok := ordinalOf("unit", name)
	return Unit(o), ok
}

// RankKind is why `--rank` placed a row where it did.
type RankKind uint32

// The three ranked kinds; RankGenerated is codegen, demoted below authored code.
const (
	RankDefinition RankKind = iota
	RankUse
	RankGenerated
)

func (k RankKind) String() string {
	if s, ok := labelOf("rank_kind", int64(k)); ok {
		return s
	}
	return "rank_kind?"
}

// ParseRankKind reads a ranked-row kind ("definition").
func ParseRankKind(name string) (RankKind, bool) {
	o, ok := ordinalOf("rank_kind", name)
	return RankKind(o), ok
}
