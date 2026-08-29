- `(?x)` verbose mode works, so a long pattern can be written the way a long
  pattern wants to be written — whitespace to group it, `#` comments to explain
  it — without leaving the linear-time engine. `gist '(?x) \b [A-Z] \w{9,} \b'`
  and `gist '(?x) alpha \s+ \d+  # the count'` both answer.

  Ripgrep accepts `(?x)` too, so this is not a spelling it refuses; it is a
  spelling where gist is a strict superset in the two places verbose is *not*
  supposed to reach:

  - **A pattern may end inside a comment.** rg wraps every pattern in `(?:…)`,
    including a lone one, so a trailing `#` comment eats the `)` and rg reports
    "unclosed group" for a pattern its own engine accepts. gist closes each wrap
    with a newline — insignificant whitespace under verbose, and a comment
    terminator — so a commented pattern composes with `-e` and `-x`.
  - **A class is not trivia.** `re` and PCRE2 both stop applying verbose inside
    `[…]`: a space there is a member, `#` is a literal. rg does not, so `[a b]`
    is `[ab]` to it, `[ ]` is an empty class it rejects, and `[#]` opens a
    comment that eats the class. gist follows `re`.

  Both are pinned in `bench/conformance/rgsuite/records.py` as the `rg_wrapper`
  and `class_trivia` boundaries, each a predicate that re-proves its own
  mechanism per run rather than a name someone decided to forgive: rg must ANSWER
  the same pattern with a newline appended (which is what separates a broken
  wrapper from a missing grammar), rg must answer identically for rg's own
  claimed reading of the class, and gist must equal `re` either way. 154 new
  cells, zero unjustified divergences. If rg fixes either, the lane fails and the
  boundary gets deleted instead of refreshed.

  The mode is free at match time — it changes which bytes are a token, never what
  a token means — and the corpus-scale numbers are the engine's, not the mode's.
  Over a frozen 11,902-file / 124 MiB tree, both tools walking the identical file
  set: 18–24× wall and 35–52× CPU against rg on selective verbose patterns with
  the index, 2.3–2.7× wall and 3.8–6.7× CPU with `--no-index` (engine against
  engine, every byte read), and 1.5× wall / 3.6× CPU on `\b [A-Z] \w{9,} \b`,
  which matches almost everywhere and so leaves nothing to skip. The three
  patterns rg exits 2 on answer in 22–27 ms.
