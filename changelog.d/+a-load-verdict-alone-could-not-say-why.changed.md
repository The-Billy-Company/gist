The packaging gate now quotes the product library's own dependency table when it
fails. A load-time verdict cannot distinguish "imports the shared engine" from
"absorbed a private copy of it", which is the only thing that gate is asking, so
a red run used to leave the reader to go re-derive it by hand.
