The in-process `count` and `files` faces dropped the context window before
searching, which undercounts when `-m` is also in play.

Dropping the window is normally free: a context row is not a match, so a face
that only wants matching lines saves itself the callbacks by asking for none.
The exception is an after-window under a cap. rg stops *selecting* at the cap
but keeps searching that match's after-context window, and a match found inside
it counts - so `-c -m1 -A1` over a file with two adjacent hits is 2, not 1.
Zeroing the window meant the second line was never looked at.

The window now survives when the request carries a cap, and the two faces read
`kind` to tell a match row from a context row instead of counting every row
that arrives. Before-context is still dropped unconditionally: a line behind a
match was already offered to the matcher on its own account, so it can never
add a match.

The C header said context and inverted selections carry zero submatches. That
stopped being true when the record stream started painting spans from each
line's own content, which is what rg does. It now says to read `kind`, never
the submatch count, to classify a row.
