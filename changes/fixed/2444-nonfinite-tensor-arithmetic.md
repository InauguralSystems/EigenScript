- Treat non-finite elements as IEEE arithmetic in `softmax`, `log_softmax`,
  `relu`, `leaky_relu`, `matmul`, `matmul_at` and `matmul_bt`, including
  their buffer forms. `EIGS_STRICT=1` raises on non-finite results; unset
  and `0` retain IEEE values and arithmetic flags. Remove the softmax
  uniform fallback and compute log-softmax directly as
  `(x[j] - m) - log(sum(exp(x - m)))`, preserving finite log-probabilities
  such as `-1000.0`. Tensor storage and ordinary buffer-read guards remain
  unchanged (#2444).
