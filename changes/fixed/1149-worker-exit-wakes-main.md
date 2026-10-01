- Make `exit of N` from a spawned worker stop all VM threads and wake main-thread
  concurrency waits, instead of leaving the process hung in `recv` or another blocker.
