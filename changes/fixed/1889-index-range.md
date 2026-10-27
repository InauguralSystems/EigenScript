- Sparse tensor row/column selectors and model token ids now raise `index_range`
  when outside their documented domains. Sparse SGD validates every selector
  before updating, so an invalid later selector cannot leave a partial update.
  This includes `eigen_eval_loss` targets; its `-1.0` sentinel is now reserved
  for the no-model-loaded case. Recorded `eigen_generate` refusals preserve
  their error kind and replay without consulting a missing or replaced model.
