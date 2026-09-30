- Test tooling: `tests/test_asan_gfx.sh` and `tests/test_leak_guard.sh` read `print-*` with `--no-print-directory`
  and fail on any word that is not a `.c` file, so `make -C <repo> test` passes [137] and [69] (#1340).
