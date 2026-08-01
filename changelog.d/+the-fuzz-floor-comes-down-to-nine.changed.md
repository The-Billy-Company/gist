The differential-fuzz residual floor drops from 13 divergences to 9, and one
whole class disappears from it.

Seed 20260727 at 6000 iterations, against ripgrep 15.2.0. `line-count+exit` goes
to zero (the `--files-without-match` exit code), and `line-count` falls 5 -> 2
(the `--crlf` dot eating a carriage return, the `-w` arm that was never retried,
and the binary file this mode listed twice over). `line-content` (4),
`timeout-rg` (2), and `trailing-bytes` (1) are unchanged, and each is a case I
have not fixed rather than a number I have moved: the two timeouts are the oracle
giving up on a pathological pattern over the `giant` corpus and were never
ratcheted, and the rest are reported in the fix's own fragments in irregex.

Every fix is in irregex; this file only moves the floor those fixes lowered, and
it was republished by the command the contract in the baseline names rather than
hand-edited.
