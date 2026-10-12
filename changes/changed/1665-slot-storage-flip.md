- List items and dict values are now stored as NaN-boxed slots (#1665 arm D B10): a number in a
  list or dict is an 8-byte immediate instead of a pointer to a heap-allocated boxed Value. Peak RSS
  (release build, `/usr/bin/time -v`, minus an empty program): a 1M-element numeric list went from
  103.9 to 8.0 bytes per element (104576 kB to 11008 kB); 100k four-key numeric dicts went from 1095 to
  713 bytes per dict (110028 kB to 72808 kB); 1M empty dicts are unchanged at 144 bytes per dict.
  Program-visible behaviour, trace tapes and the embedding ABI are unchanged. The `slot-rehearsal`
  make target is removed (its semantics are now the only semantics).
