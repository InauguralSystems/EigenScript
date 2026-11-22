- `http_post` now raises catchable errors for failed exchanges, incomplete or
  over-limit answers, NUL in an answer body, invalid HTTP URLs and invalid
  header/body arguments. Argument refusals write no tape record and replay
  raises the same error. Calls no longer read curl configuration files or
  `.netrc`; certificate environment settings remain supported. The library's
  `SSLKEYLOGFILE` and `OPENSSL_CONF` behavior is preserved, and the runtime
  leaves library environment settings untouched. (#2375)
