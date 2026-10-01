- Make the #1144 TSan scope-boundary probe synchronize both workers at a spin barrier and give each an unprotected access to the same shared list element, so the probe's race capture does not
  depend on overlapping scheduling quanta on a loaded or single-core runner.
