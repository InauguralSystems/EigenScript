- `http_static` drops trailing slashes from prefixes at registration. Empty,
root-only, and relative prefixes raise `value` with the reason instead of
silently serving the wrong paths or no paths (#2356).
