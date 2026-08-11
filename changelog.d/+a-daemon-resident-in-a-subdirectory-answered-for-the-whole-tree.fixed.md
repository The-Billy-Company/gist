The socket lives in the artifact home, and the artifact home is now one per
checkout rather than one per directory. That is what lets a search from
`services/ai` reach the tree's index - and it also means every subdirectory of
one tree dials the same rendezvous. A session that went resident in the subtree
was therefore handed queries from the tree root, and it answered them: real
rows, correctly rendered, from a walk that had only ever seen a fraction of the
tree. Nothing in the output looks wrong. You just get less of it.

What the two sides were proving to each other was the tree, which used to be the
same fact as the directory and no longer is. A persisted artifact and a resident
session are bound to different things: an index is written in checkout
coordinates so any directory under the checkout may ride it, while a mirror is a
corpus walked from wherever the daemon started, and its answers are that walk's
output. So the daemon publishes its STANDING beside its socket now - the working
directory, resolved - and the client and the answer keep both prove that instead.
A client standing elsewhere reads the rendezvous as not its own and answers cold,
which is correct and merely slower.

`station_parity.sh` is the permanent guard, and it earns the name by failing:
with the old binding restored it reports the tree-root query routing warm and
coming back empty over a tree holding two matches. It asserts the routing tier
by name rather than only diffing bytes, because a daemon that quietly declined
would make a warm-versus-cold comparison green without either arm ever being
warm. Its corpus is deliberately large for the same reason - the elide oracle
loads concurrently with the walk, and over a few dozen files the walk always
wins, so a small corpus proves only that the live read works and passes just as
happily with the rebase deleted.
