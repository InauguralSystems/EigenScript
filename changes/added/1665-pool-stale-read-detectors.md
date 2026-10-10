- **Stale-read detectors for the two kept recycling pools (#1665).** ASan
  builds now poison a NUM parked on the per-thread freelist (all but its link
  word) and a call env parked on its chunk (its slot, name, count and hash
  arrays and the Env struct, all but `parent`), so a read of a recycled
  object reports `use-after-poison` instead of passing silently (#1661 was
  such a read). `make jit-checked` builds a JIT that checks every emitted
  direct env-slot access against the env and aborts with the read site; CI
  runs the JIT-tier sections against it. Release builds are unchanged.
