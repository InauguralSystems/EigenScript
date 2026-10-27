- `loop while` now counts iterations that end in `continue`. `__loop_iterations__`, the iteration cap and
  the observer stall guard see every completed iteration, so a loop that only ever `continue`s can no longer
  run past the cap. Before, such a loop ran until an external timeout (#2003).
