- `src/lint.c` joins the W024 spelling by length instead of `snprintf`, so the `-O1` ASan LSP build has no
  `-Wformat-truncation` warning; the message is byte-identical (#1367).
