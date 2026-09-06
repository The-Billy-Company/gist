We skip stdin admission when a query names a path, including resident queries.
Our stream contract now checks delayed and empty pipes, socket EOF, cancellation,
and explicit timeouts against the actual CLI with and without a resident daemon.
