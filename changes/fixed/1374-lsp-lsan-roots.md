- Run the LSP sanitizer checks without stack or register roots so stale pointers
  cannot hide leaks from LeakSanitizer.
