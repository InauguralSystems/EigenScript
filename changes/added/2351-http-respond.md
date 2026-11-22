- Code routes can call `http_respond` to set a response's status, headers and
  cookies while keeping their final value as its body. Calls merge within one
  request, validation failures leave it unchanged, and route errors discard
  settings before the existing 500 response. Header text is validated and the
  current route headers and cookies are bounded to 65,536 bytes. (#2351)
