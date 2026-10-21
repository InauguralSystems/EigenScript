- `read_text`, `read_bytes`, and `read_bytes_buf` now raise catchable `io`
  errors containing the path and operating-system reason instead of returning
  an empty failure sentinel.
- File writes, removal, rename, directory creation, and directory listing now
  follow the same contract; fixed-cap text/list readers also raise with the
  observed size and cap instead of returning an empty value.
