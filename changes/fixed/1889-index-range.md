- Sparse tensor row/column selectors and model token ids now raise `index_range`
  when outside their documented domains. Sparse SGD validates every selector
  before updating, so an invalid later selector cannot leave a partial update.
