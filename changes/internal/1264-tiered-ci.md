- CI: pull requests run the build/release/self-test/precheck/LSP/docs tier while sanitizer, TSan, extension, macOS,
  valgrind, and benchmark checks report `deferred to merge queue`; merge-queue and main-push candidates still run
  every heavy suite, guarded by a planted tier-check regression (#1264).
