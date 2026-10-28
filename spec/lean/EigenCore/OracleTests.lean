import EigenCore.Tape

namespace EigenCore

private def counterexample : Program :=
  match parse "local x is random_int of [1, 2]\nprint of x\n" with
  | .ok program => program
  | .error _ => []

private def recordOne : RunResult := run 100 counterexample (.record [.int 1])
private def recordTwo : RunResult := run 100 counterexample (.record [.int 2])
private def replayOneTape : List String :=
  ["B 0 1 1 0 root -", "N 0 random_int=1"]

private def replayOne : RunResult :=
  run 100 counterexample (.replayStrict replayOneTape)

example : recordOne.stdout == "1\n" &&
    recordOne.tape.contains "N 0 random_int=1" := by native_decide
example : recordTwo.stdout == "2\n" := by native_decide
example : replayOne == recordOne := by native_decide

example : replayOne.error = none := by
  native_decide

/-- The strict-replay premise used by `replay_sound` is inhabited by a
concrete kind-valid tape whose execution completes successfully. -/
example : TapeKindValid replayOneTape ∧
    (run 100 counterexample (.replayStrict replayOneTape)).error = none := by
  constructor
  · unfold TapeKindValid
    have normalized : normalizeTape replayOneTape =
        [TapedAnswer.value 0 "random_int" (.int 1)] := by native_decide
    rw [normalized]
    intro answer member
    simp only [List.mem_singleton] at member
    subst answer
    exact ⟨0, "random_int", .int 1, rfl, ["number"], by
      simp [k_tape_kinds]⟩
  · native_decide

private def replayAcrossSession : RunResult := run 100 counterexample (.replayStrict
  ["B 0 1 1 0 root -", "V 8 0.0.0-model", "B 0 1 1 0 root -", "N 0 random_int=1"])

example : replayAcrossSession.error == some (.runtime
    "random_int: replay stream 0 has no matching recorded N value") &&
    !replayAcrossSession.tape.any (·.startsWith "N ") := by native_decide

private def escapedProgram : Program :=
  match parse "local x is env_get of \"KEY\"\nprint of x\n" with
  | .ok program => program
  | .error _ => []

private def escapedRecord : RunResult := run 100 escapedProgram (.record [.string "\t"])
private def escapedReplay : RunResult := run 100 escapedProgram (.replayStrict
  ["B 0 1 1 0 root -", "N 0 env_get=\"\\x09\""])

example : escapedRecord.tape.contains "N 0 env_get=\"\\x09\"" &&
    escapedReplay == escapedRecord := by native_decide

-- Normalization skips structural records without shifting answer positions,
-- and delays a malformed value until the evaluator reaches that answer.
example : normalizeTape ["B 0 1 1 0 root -", "N 0 random_int=1",
    "A 0 x=1", "N 0 random_int=not-a-number"] ==
    [.value 0 "random_int" (.int 1),
     .replayError 1 (.replay "tape kind mismatch for random_int: expected number")] := by
  native_decide

private def runSource (source : String) (oracle : List OracleValue) : RunResult :=
  match parse source with
  | .ok program => run 100 program (.record oracle)
  | .error _ => {stdout := "", tape := []}

example : let result := runSource "define env_get(key) as:\n  return \"mock\"\nprint of (env_get of \"KEY\")\n" []
  result.stdout == "mock\n" && !result.tape.any (·.startsWith "N ") := by native_decide

example : let result := runSource "define read_line() as:\n  return \"mock\"\nprint of (read_line of [])\n" []
  result.stdout == "mock\n" && !result.tape.any (·.startsWith "N ") := by native_decide

example : let result := runSource "define random_int(bounds) as:\n  return 7\nprint of (random_int of [0, 10])\n" []
  result.stdout == "7\n" && !result.tape.any (·.startsWith "N ") := by native_decide

example : let result := runSource "print of (random_int of [0, 2147483648])\n" [.int 0]
  result.error == some (.runtime
    "random_int: range span 2147483649 exceeds 2^31 (lrand48 supplies 31 bits)") &&
    !result.tape.any (·.startsWith "N ") := by native_decide

end EigenCore
