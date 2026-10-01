- Make `eigen_generate` and `eigen_eval_loss` raise when a prompt exceeds the
  model's `max_seq_len`, matching the training API instead of truncating input.
