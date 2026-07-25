package irregex

import "strconv"

// Search flag bits (irregex.h IRREGEX_*). An unknown bit fails closed at the C
// seam rather than being silently dropped, so this set is the whole vocabulary.
const (
	FlagFixed      uint32 = 1 << 0
	FlagIgnoreCase uint32 = 1 << 1
	FlagWord       uint32 = 1 << 2
	FlagQuiet      uint32 = 1 << 3
	FlagMaxCount   uint32 = 1 << 4
	FlagSmartCase  uint32 = 1 << 5
	FlagNoUnicode  uint32 = 1 << 6
	FlagInvert     uint32 = 1 << 7
)

// MatchKind distinguishes a match line from a context neighbor (-A/-B/-C).
type MatchKind uint32

// The two record kinds ([match_kinds]).
const (
	KindMatch MatchKind = iota
	KindContext
)

// Submatch is one matched span within a line: its text and byte offsets [Start,End).
type Submatch struct {
	Text  string
	Start int
	End   int
}

// Match is one Go-owned result record. Every transport copies the engine's
// borrowed view into this before returning, so a record outlives the cursor,
// the engine, and the child process that produced it.
type Match struct {
	Path       string
	LineNumber uint64
	Text       string
	Kind       MatchKind
	Submatches []Submatch
}

// Column is the 1-based column of the first submatch (0 for a context line).
func (m Match) Column() int {
	if len(m.Submatches) == 0 {
		return 0
	}
	return m.Submatches[0].Start + 1
}

// Request is one match-finding intent — the representable subset of
// [request_options] every transport carries. Presentation, replace, and stdin
// stay CLI-only; glob/type scoping and multiline are not on the in-process ABI,
// so a query needing them uses the `gist` binary directly.
type Request struct {
	// Pattern is the regex (or literal, with Fixed) to find.
	Pattern string
	// Fixed treats Pattern as a literal string (-F).
	Fixed bool
	// IgnoreCase folds case (-i); SmartCase folds only when Pattern has no
	// uppercase (-S); Unicode, when set, forces Unicode (true) or ASCII (false)
	// class/fold/boundary semantics (nil keeps the engine default, rg-on).
	IgnoreCase bool
	SmartCase  bool
	Unicode    *bool
	// Word bounds matches to whole words (-w); Invert selects non-matching lines
	// (-v); Quiet halts at the first match (-q).
	Word   bool
	Invert bool
	Quiet  bool
	// Before/After add context lines (-B/-A); Context sets both when they are 0.
	Before  uint
	After   uint
	Context uint
	// MaxCount caps matching lines per file (-m); 0 = unlimited.
	MaxCount uint
}

// Flags is the request's IRREGEX_* bitset.
func (r Request) Flags() uint32 {
	var f uint32
	set := func(on bool, bit uint32) {
		if on {
			f |= bit
		}
	}
	set(r.Fixed, FlagFixed)
	set(r.IgnoreCase, FlagIgnoreCase)
	set(r.SmartCase, FlagSmartCase)
	set(r.Word, FlagWord)
	set(r.Invert, FlagInvert)
	set(r.Quiet, FlagQuiet)
	set(r.Unicode != nil && !*r.Unicode, FlagNoUnicode)
	set(r.MaxCount > 0, FlagMaxCount)
	return f
}

// ContextLines resolves Before/After, letting Context stand in for both.
func (r Request) ContextLines() (before, after uint) {
	if r.Before == 0 && r.After == 0 {
		return r.Context, r.Context
	}
	return r.Before, r.After
}

// Argv lowers the request into the `gist --json` argv the subprocess transport
// runs — exactly the rg-parity flags the engine already honors, so the child and
// the in-process engine answer the same question. Quiet is deliberately absent:
// it suppresses the record stream the caller asked for, and a transport halts at
// the first record instead.
func (r Request) Argv(roots ...string) []string {
	argv := []string{"--json"}
	add := func(on bool, flag string) {
		if on {
			argv = append(argv, flag)
		}
	}
	add(r.Fixed, "-F")
	add(r.IgnoreCase, "-i")
	add(r.SmartCase, "-S")
	add(r.Word, "-w")
	add(r.Invert, "-v")
	add(r.Unicode != nil && !*r.Unicode, "--no-unicode")
	add(r.Unicode != nil && *r.Unicode, "--unicode")
	before, after := r.ContextLines()
	for _, opt := range []struct {
		flag  string
		value uint
	}{{"-B", before}, {"-A", after}, {"-m", r.MaxCount}} {
		if opt.value > 0 {
			argv = append(argv, opt.flag, strconv.FormatUint(uint64(opt.value), 10))
		}
	}
	argv = append(argv, "-e", r.Pattern)
	return append(argv, roots...)
}
