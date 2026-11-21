- Code routes can read a request header by name with `http_request_header`,
  receiving all matching values in order, with ASCII case ignored and only
  surrounding spaces and tabs trimmed. `http_request_headers` now returns
  the request head without its body. Header lookups read the server-framed
  head and record their returned lists on the trace tape. (#2373)
- Content-Length line scanning uses bounded searches to avoid the sanitizer's
  per-line suffix scans, preserving the existing framing decisions.
