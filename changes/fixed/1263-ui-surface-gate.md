- Gate every public `lib/ui*.eigs` export on test and reference-document coverage,
and exercise the hand-declared SDL event fields through SDL's real event queue
in the graphics CI leg. The gate self-test plants both an uncovered export and
the mouse-motion ABI regression from #599.
