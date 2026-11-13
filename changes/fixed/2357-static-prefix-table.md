- Each `http_static` adds a folder instead of replacing the previous one.
The longest prefix matching at a path-segment boundary serves the request.
Duplicate normalized prefixes raise `value`; registering more than 16
prefixes raises `limit`. Every folder retains static-file confinement (#2357).
