- Align binary tensor loading and writing with the 10,000,000-element cap;
  report over-cap files with catchable limit errors, and document the shared
  stream count constraints.
- Record the tensor loader's cap decision so the same limit diagnostic and
  catch branch replay after the file changes, without taping tensor payloads.
