- Include lazily loaded graphics in the hosted release, introduce `server`
  (HTTP + raw TCP + models) and `server-db` profiles, and retain the former build
  targets and full executable spelling as compatibility aliases. Consolidate
  HTTP/gfx/net CI coverage in the server lane, preserve model sanitizer coverage,
  and route consumer server inputs separately; former gfx calls can use release
  after a binding probe. Unresolved omitted HTTP/net/DB/model names report the unavailable
  capability and required profile at first VM/native-JIT reference, before call
  arguments, without allocating placeholder bindings. Shadow bindings win.
  Discovery retains the language surface; direct host lookup reports actual
  absence. Direct AOT adoption remains deferred. Refs #1415 and #1159;
  capability registry, host grants,
  reserved imports, package requires checks, and measured profile evidence remain
  open.
