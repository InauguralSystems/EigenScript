- Replay is side-effect-free, as in rr (#1885). Under `EIGS_REPLAY`, module source
  for `import` and `load_file` comes from the tape, and filesystem mutations
  (`mkdir`, `write_text`, `write_bytes`, `remove_file`, `rename`) perform nothing
  and return their recorded results. A replay no longer depends on what the
  record run left on disk. The tape format is now v7. Over-cap `read_text` and
  `read_bytes` tapes replay their recorded `io` error and cap message instead of
  failing return-kind validation (#1890).
