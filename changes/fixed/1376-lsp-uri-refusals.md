- `eigenlsp` now reports an error to the client instead of silently changing a
  document URI containing an escaped NUL or silently dropping the 65th open
  document when its 64-document table is full.
