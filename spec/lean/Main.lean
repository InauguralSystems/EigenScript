import EigenCore

open EigenCore

private def usage : IO UInt32 := do
  IO.eprintln "usage: eigs-ref --classify FILE | [--trace TAPE] [--replay TAPE] [--strict] [--seed N] FILE"
  pure 2

private def mainClassify (path : String) : IO UInt32 := do
  let source ← IO.FS.readFile path
  match classify source with
  | .inSubset => IO.println "in-subset"; pure 0
  | .out why => IO.println s!"out: {why.construct} at line {why.line}"; pure 0

private def mainRuntimeClassify (path : String) : IO UInt32 := do
  let source ← IO.FS.readFile path
  match classifyModeled source with
  | .inSubset => IO.println "in-subset"; pure 0
  | .out why => IO.println s!"out: {why.construct} at line {why.line}"; pure 0

structure Options where
  source : String := ""
  trace : Option String := none
  replay : Option String := none
  strict : Bool := false
  seed : Nat := 2018

private def options : List String → Except String Options
  | [] => throw "missing source"
  | [source] => pure {source:=source}
  | "--trace"::path::rest => do let o ← options rest; pure {o with trace:=some path}
  | "--replay"::path::rest => do let o ← options rest; pure {o with replay:=some path}
  | "--strict"::rest => do let o ← options rest; pure {o with strict:=true}
  | "--seed"::value::rest => do
      let some seed := value.toNat? | throw "invalid seed"
      let o ← options rest
      pure {o with seed:=seed}
  | _ => throw "invalid arguments"

/-- The command-line adapter, not the evaluator, turns its logged seed into a
finite explicit oracle.  The modeled corpus has one taped call per source
line; preserving source order therefore preserves dynamic order for its
straight-line taped fixtures. -/
private def generatedOracle (source : String) (seed : Nat) : List OracleValue :=
  let (_, values) := source.splitOn "\n" |>.foldl (fun (state : Nat × List OracleValue) line =>
    let (cursor, out) := state
    if line.contains "random_int" then
      (cursor + 1, out ++ [.int (Int.ofNat ((seed + cursor * 1103515245 + 12345) % 2147483648))])
    else if line.contains "read_line" then (cursor + 1, out ++ [.null])
    else if line.contains "env_get" then (cursor + 1, out ++ [.string ""])
    else state) (0, [])
  values

private def execute (o : Options) : IO UInt32 := do
  let source ← IO.FS.readFile o.source
  let mode ← match o.replay with
    | none =>
      let oracle := generatedOracle source o.seed
      pure (if o.trace.isSome then .record oracle else .live oracle)
    | some path => match tapeParse (← IO.FS.readFile path) with
      | .ok tape => pure (.replayStrict tape)
      | .error e => IO.eprintln s!"runtime error: {e}"; return 1
  match parse source with
  | .error e =>
      -- Modeled parse errors still participate in record/replay parity.  A
      -- header-only trace is complete for a program rejected before run.
      match o.trace with | some path => IO.FS.writeFile path (tapeSerialize []) | none => pure ()
      IO.eprintln s!"parse error at line {e.line}: {e.construct}"; pure 2
  | .ok program =>
      let result := run 100000 program mode
      IO.print result.stdout
      match o.trace with | some path => IO.FS.writeFile path (tapeSerialize result.tape) | none => pure ()
      match result.error with
      | none => pure 0
      | some .fuel => IO.eprintln "refused at runtime: evaluator fuel exhausted"; pure 1
      | some (.unsupported construct) =>
          IO.eprintln s!"unsupported in EigenCore-0 step 2b-ii: {construct}"; pure 1
      | some (.refusal reason) => IO.eprintln s!"refused at runtime: {reason}"; pure 1
      | some (.replay reason) => IO.eprintln s!"trace: {reason} (strict replay — aborting)"; pure 3
      | some (.runtime e) => IO.eprintln s!"runtime error: {e}"; pure 1

def main (args : List String) : IO UInt32 :=
  match args with
  | ["--classify", path] => mainClassify path
  | ["--classify-runtime", path] => mainRuntimeClassify path
  | _ => match options args with | .ok o => execute o | .error _ => usage
