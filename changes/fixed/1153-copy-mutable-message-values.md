- Copy buffers and text builders, including nested instances, at channel,
  thread-join, and cooperative-task transfer boundaries instead of sharing
  mutable storage across execution contexts.
