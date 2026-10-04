- Retire possible-root containers held only by their buffer pin during later
  single-threaded admissions, separately from full cycle collection. Preserve
  child-cycle registration and the survivor-work scan budget with an admission
  counter that pin retirement cannot erase (#1623).
