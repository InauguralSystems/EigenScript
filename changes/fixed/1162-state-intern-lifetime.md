- Fixed the embedding API so globals, builtins, and dictionary keys remain valid
when a host thread detaches and another attachment continues using the state.
