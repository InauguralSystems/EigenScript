- `http_post` returns complete responses through the shared HTTP client instead
  of silently cutting them at 16,383 bytes; answers over the configured limit
  raise a catchable error. (#2353)
