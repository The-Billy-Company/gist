package irregex

// The five analytic request families ([analytic.params]) — five shapes rather
// than seventeen, so a caller learns one struct per KIND of question. Each
// mirrors its C struct field for field; the transports size-check and lower
// them, and never reinterpret one family as another.
//
// Thresholds are pointers where 0.0 is a meaningful value (max_distance 0.0
// admits byte-identical only), which is the same reason the C structs carry
// presence bits for exactly those two fields.

// Params is one of the five families. Family names the [analytic.params] table
// it is, so a verb dispatched with the wrong shape fails at the seam instead of
// having its bytes reinterpreted.
type Params interface {
	Family() string
	// Flags is the IRREGEX_AN_* bitset this request carries.
	Flags() uint32
}

// Kinship asks what resembles what: similar, dups, clusters, echoes, concepts,
// fragments, distinct. An empty Target is the corpus-wide sweep.
type Kinship struct {
	Target      string
	Channel     Channel
	Unit        Unit
	MaxDistance *float64
	MinEcho     *float64
	MinGrade    Grade
	MinSize     int
	MinLines    int
	Top         int
	NoIndex     bool
}

// Family implements [Params].
func (Kinship) Family() string { return "kinship" }

// Flags implements [Params].
func (k Kinship) Flags() uint32 {
	var f uint32
	if k.MaxDistance != nil {
		f |= AnMaxDistance
	}
	if k.MinEcho != nil {
		f |= AnMinEcho
	}
	if k.NoIndex {
		f |= AnNoIndex
	}
	return f
}

// Retrieval prices free text against the corpus: recall, pack, quote.
type Retrieval struct {
	Query   string
	Top     int
	NoIndex bool
}

// Family implements [Params].
func (Retrieval) Family() string { return "retrieval" }

// Flags implements [Params].
func (r Retrieval) Flags() uint32 {
	if r.NoIndex {
		return AnNoIndex
	}
	return 0
}

// Sweep is N patterns in one walk with exact per-pattern attribution: patterns
// and pattern_counts. By selects what a tally groups on; leaving both false is
// row-per-hit.
type Sweep struct {
	Patterns   []string
	Under      string
	Top        int
	Fixed      bool
	IgnoreCase bool
	ByPattern  bool
	ByFile     bool
}

// Family implements [Params].
func (Sweep) Family() string { return "sweep" }

// Flags implements [Params].
func (s Sweep) Flags() uint32 {
	var f uint32
	for _, on := range []struct {
		set bool
		bit uint32
	}{{s.Fixed, AnFixed}, {s.IgnoreCase, AnIgnoreCase}, {s.ByPattern, AnByPattern}, {s.ByFile, AnByFile}} {
		if on.set {
			f |= on.bit
		}
	}
	return f
}

// Compose runs both engines over one candidate set: context, family,
// provenance, blast. Patterns are the exact intents that narrow the corpus, Text
// is the task text, the pasted snippet, or the symbol. Budget trims blast's
// low-priority tail into the answer's omitted count.
type Compose struct {
	Text        string
	Patterns    []string
	MatchAll    bool
	Unit        Unit
	MaxDistance *float64
	MinEcho     *float64
	Budget      int
	Top         int
	Fixed       bool
	IgnoreCase  bool
}

// Family implements [Params].
func (Compose) Family() string { return "compose" }

// Flags implements [Params].
func (c Compose) Flags() uint32 {
	var f uint32
	for _, on := range []struct {
		set bool
		bit uint32
	}{
		{c.MaxDistance != nil, AnMaxDistance},
		{c.MinEcho != nil, AnMinEcho},
		{c.MatchAll, AnMatchAll},
		{c.Fixed, AnFixed},
		{c.IgnoreCase, AnIgnoreCase},
	} {
		if on.set {
			f |= on.bit
		}
	}
	return f
}

// Rank is the definition-first view of an exact query — the one exact-plane verb
// whose answer is analytic rows rather than [Match] records.
type Rank struct {
	Pattern    string
	Top        int
	Fixed      bool
	IgnoreCase bool
}

// Family implements [Params].
func (Rank) Family() string { return "rank" }

// Flags implements [Params].
func (r Rank) Flags() uint32 {
	var f uint32
	if r.Fixed {
		f |= AnFixed
	}
	if r.IgnoreCase {
		f |= AnIgnoreCase
	}
	return f
}
