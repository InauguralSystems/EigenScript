- A bare `while cond:` (the Python/JS loop habit) is now one parse error at the
  `while` token that names the fix, `loops are written 'loop while cond:'`, in
  both the run diagnostic and `--lint --json` (`E002`). Its indented body is
  parsed as the loop body, so the old "unexpected indent" follow-on error is
  gone, and real errors inside the condition or body are still reported (#2194).
