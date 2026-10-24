- Integer literals now retain exact int64 values, with exact int/float
  comparisons and checked `+`, `-`, `*`, negation and `abs` that raise `value`
  on int64 overflow. `num_type` reports `"int"`, `"float"` or `null`; `type`
  continues to report `"num"` for either numeric kind. Trace tape format v7
  preserves numeric kinds and refuses older tapes (#1758).
