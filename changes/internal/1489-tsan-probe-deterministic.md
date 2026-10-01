Make the #1144 TSan scope-boundary probe synchronize both workers at a spin barrier and keep them in deliberately racing user-slot assignments, so the probe cannot pass or fail
according to scheduler luck on a loaded or single-core runner.
