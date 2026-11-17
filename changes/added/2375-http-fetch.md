- Add `http_fetch`: a validated request dict produces the final HTTP status,
  headers and complete body through a runtime-loaded curl library. Requests
  support GET, HEAD, POST, PUT, PATCH and DELETE, bounded time and answer
  sizes, verified HTTPS and deterministic answer/error replay. (#2375)
