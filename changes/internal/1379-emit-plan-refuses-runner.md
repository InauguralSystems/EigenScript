- Tooling: `--emit-*` refuses an OUT that is the runner or a tracked file, and `make test` / `make test-changed`
  run the suite label floor first, so an emptied runner fails (#1379).
