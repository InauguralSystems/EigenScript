- Route runtime loop-count publication into shared environments through the
  existing locked setter, preserving the slot update and assignment count
  together. This does not change the shared user-binding contract (#1171).
