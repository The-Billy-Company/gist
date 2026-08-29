- Write a character by its value in whichever spelling you already know:
  `\uHHHH`, `\u{H..H}`, `\UHHHHHHHH`, `\U{H..H}`, octal `\0oo` / `\ooo`, and
  `\N{NAME}` by Unicode name — in atom position, inside `[…]`, in byte or Unicode
  mode, at either end of a range (`[\u00ab-\u00bb]`).

  This is a superset of both incumbents, because the two disagree and each one's
  gap is the other's feature: ripgrep has the braced spellings Python's `re`
  rejects, and `re` has octal and `\N{NAME}`, which rg refuses outright (it reads
  `\007` as a backreference, says "backreferences are not supported", and points
  you at `-P`). Since each *refuses* what the other accepts, taking both
  reinterprets nothing — every pattern rg compiles keeps rg's meaning, and every
  pattern `re` compiles keeps `re`'s.

  Names are the whole Unicode set rather than a table of favorites: NameAliases
  resolve (`\N{NBSP}`, `\N{ALERT}`), and the algorithmic ranges are computed, so
  every CJK ideograph and Hangul syllable has its name without shipping one each.
  Over fifteen spellings on a fixture holding each target character, gist agrees
  with `re` on thirteen — the two exceptions being the braced forms `re` rejects
  and rg accepts — and rg cannot run eleven of the fifteen at all.

  They cost nothing, because an escape is resolved at parse time into the
  codepoint it names and then reaches the same DFA, prefilter, and SIMD kernels a
  literal does; nothing downstream can tell how `é` was typed. Over 50 MB, `-c`,
  minimum of 15 interleaved rounds with counts identical, the eight spellings rg
  can run finish 3.5–5.9× faster on wall clock and 1.1–3.9× on CPU.
