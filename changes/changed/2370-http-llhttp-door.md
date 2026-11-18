- **The HTTP server reads every request through llhttp (#2370).** A request is served only when the parser (llhttp
  v9.4.4, the parser of Node's `http`, vendored unchanged under `src/vendor/llhttp/` and compiled into the HTTP
  builds) has found it complete. What changes for a request that was served before: a malformed head (a line with
  no colon, whitespace before a colon, a folded line, a lone CR or LF inside a line, a control byte, a bare-LF line
  end), an unknown or lower-case method, a bad target, two `Content-Length` lines, or a malformed chunked body is
  answered `400` before any route; `HTTP/2.0`, `HTTP/0.9` and the opening bytes of HTTP/2 are answered `505`;
  `Transfer-Encoding` other than the one coding `chunked` is `501` when the parser accepts it; an announced body over
  `EIGS_HTTP_MAX_BODY` is `413` (it was `400`); a chunked body reaches a route as its data, with no chunk sizes,
  extensions or trailer fields, and a `CONNECT` has an empty body; bytes after a request are dropped. The head's limit
  is 65,536 bytes (`EIGS_HTTP_MAX_HEAD`, one to nine digits), counted with the chunk extensions, trailer fields and
  size digits past the sixteenth of a chunked body; past it the answer is `431` (it was the body limit plus 64 KiB).
  A request that is not complete when 5 seconds pass without a byte, or 30 seconds in all, is answered `408`.
  A connection is charged against `EIGS_HTTP_MAX_BODY_TOTAL` for the 16,384 bytes it reads into and a room for its
  head and one for its body, which start at 1,024 bytes and double as they fill; the body's room is cut at the body's
  limit and one byte, the head's at the head's limit and one byte when that is more than 1,024.
