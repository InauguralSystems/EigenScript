- Made `tensor_load` accept tensors up to the runtime's 10,000,000-element
  construction limit and raise a descriptive, catchable error above it;
  tensor file writers now enforce the same limit.
