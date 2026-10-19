- `read_text`, `read_bytes`, and `read_bytes_buf` now raise catchable `io`
  errors containing the path and operating-system reason instead of returning
  an empty failure sentinel.
