- `(?-u)` no longer truncates a character to one byte. Turning Unicode off changes
  what a class, a fold, and a boundary mean; it cannot change what a character IS,
  and rg draws the line in the same place. Two spellings were on the wrong side.

  `(?-u)\x{e9}` looked for a raw 0xE9, which a UTF-8 file does not contain — so it
  found nothing where rg found `é`, and found a match where rg found none. Above
  0xFF it refused outright, making `(?-u)\x{2603}` a parse error against rg's three
  bytes. Both now match the character's UTF-8 sequence. Bare `\xNN` and octal are
  byte syntax and still name the raw byte (`(?-u)\xe9` is 0xE9), as they do in rg.

  A quantifier bound a character's last byte instead of the character: `(?-u)é+`
  over `éé` answered `é`, and `(?-u)é{2}` matched nothing. Both now answer what rg
  answers. And a byte-mode `[…]` now refuses a character above ASCII rather than
  matching one byte of it, which is rg's judgment too (`(?-u)[\x{e9}]` is a parse
  error there).
