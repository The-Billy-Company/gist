Captured Windows searches return as soon as the query finishes. Detached daemons
inherit only their NUL streams, so they cannot keep PowerShell capture pipes open
until the ten-minute idle timeout.
