- Add `http_fetch`: a validated request dict produces the final HTTP status,
  headers and complete body through a runtime-loaded curl library. Requests
  support GET, HEAD, POST, PUT, PATCH and DELETE, bounded time and answer
  sizes (body bytes, header bytes, and at most 4,096 header lines, below the
  curl library's own 5,000 from release 8.14.0), verified HTTPS and
  deterministic answer/error replay. (#2375)
