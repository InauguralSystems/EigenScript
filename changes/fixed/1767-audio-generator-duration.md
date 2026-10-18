- Audio generators now raise a `value` error naming the builtin when their
  duration exceeds the documented 30-second allocation limit, rather than
  silently returning an empty list. Sample counts are range-checked before
  conversion to C `int`.
