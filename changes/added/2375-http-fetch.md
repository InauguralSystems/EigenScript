- Add `http_fetch`: a validated request dict produces the final HTTP status,
  headers and complete body through a runtime-loaded curl library. Requests
  support GET, HEAD, POST, PUT, PATCH and DELETE, bounded time and answer
  sizes (body bytes, header bytes, and at most 4,096 header lines, below the
  curl library's own 5,000 from release 8.14.0), verified HTTPS and
  deterministic answer/error replay. (#2375)
- `http_fetch` and `http_post` send `Connection: close` in every request and
  refuse a caller's `Connection`, `Keep-Alive`, `Proxy-Connection`, `TE` and
  `Upgrade` with `value`: the connection is the runtime's. Which response is
  final is the curl library's, and an answer is returned only when its status
  line says the status the library reports; otherwise the call raises
  `the answer ended early`. A trailer line that begins with `HTTP/` no longer
  ends the call early. (#2375, #2390)
