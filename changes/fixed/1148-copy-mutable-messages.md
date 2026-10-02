- Add regression coverage for direct buffer and text-builder `thread_join`
  results, plus a TSan buffer-transfer fixture that sends while its reader
  worker is already live.
