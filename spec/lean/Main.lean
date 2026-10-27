import EigenCore

open EigenCore

private def usage : IO UInt32 := do
  IO.eprintln "usage: eigs-ref --classify FILE | [--trace TAPE] [--replay TAPE] [--strict] FILE"
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

private def options : List String → Except String Options
  | [] => throw "missing source"
  | [source] => pure {source:=source}
  | "--trace"::path::rest => do let o ← options rest; pure {o with trace:=some path}
  | "--replay"::path::rest => do let o ← options rest; pure {o with replay:=some path}
  | "--strict"::rest => do let o ← options rest; pure {o with strict:=true}
  | _ => throw "invalid arguments"

private def execute (o : Options) : IO UInt32 := do
  let source ← IO.FS.readFile o.source
  let mode ← match o.replay with
    | none => pure (if o.trace.isSome then .record [] else .live [])
    | some path => match tapeParse (← IO.FS.readFile path) with
      | .ok tape => pure (.replayStrict tape)
      | .error e => IO.eprintln s!"runtime error: {e}"; return 1
  match parse source with
  | .error e => IO.eprintln s!"parse error at line {e.line}: {e.construct}"; pure 2
  | .ok program => match run 100000 program mode with
    | .error .fuel => IO.eprintln "runtime error: fuel exhausted"; pure 1
    | .error (.unsupported construct) =>
        IO.eprintln s!"unsupported in EigenCore-0 step 2a: {construct}"; pure 1
    | .error (.runtime e) => IO.eprintln s!"runtime error: {e}"; pure 1
    | .ok result =>
      IO.print result.stdout
      match o.trace with | some path => IO.FS.writeFile path (tapeSerialize result.tape) | none => pure ()
      pure 0

def main (args : List String) : IO UInt32 :=
  match args with
  | ["--classify", path] => mainClassify path
  | ["--classify-runtime", path] => mainRuntimeClassify path
  | _ => match options args with | .ok o => execute o | .error _ => usage
