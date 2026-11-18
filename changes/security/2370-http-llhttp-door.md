- **Request framing no longer disagrees with a conforming proxy (#2370).** The server found a head's end by
  searching for CR LF CR LF, read `Content-Length` from the lines before it and scanned the request line for three
  words, so it served heads that every conforming server refuses (request smuggling's setting), ran routes with the
  chunk framing or the next request as the body, and held a head of up to 16 MiB. Every request is now read through
  llhttp v9.4.4 in its strict mode, the refusal is written at the byte that decides it, and one count bounds the head,
  chunk extensions and trailer fields of a request (the CVE-2024-22019 and CVE-2023-39326 class).
