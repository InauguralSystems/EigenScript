import EigenCore.Tape

namespace EigenCore

private def counterexample : Program :=
  match parse "local x is random_int of [1, 2]\nprint of x\n" with
  | .ok program => program
  | .error _ => []

private def recordOne : RunResult := run 100 counterexample (.record [.int 1])
private def recordTwo : RunResult := run 100 counterexample (.record [.int 2])
private def replayOne : RunResult := run 100 counterexample (.replayStrict
  ["B 0 1 1 0 root -", "N 0 random_int=1"])

example : recordOne.stdout == "1\n" &&
    recordOne.tape.contains "N 0 random_int=1" := by native_decide
example : recordTwo.stdout == "2\n" := by native_decide
example : replayOne == recordOne := by native_decide

end EigenCore
