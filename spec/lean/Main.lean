import EigenCore

open EigenCore

private def usage : IO UInt32 := do
  IO.eprintln "usage: eigs-ref --classify FILE | --print-value KIND VALUE"
  pure 2

private def mainClassify (path : String) : IO UInt32 := do
  let source ← IO.FS.readFile path
  match classify source with
  | .inSubset => IO.println "in-subset"; pure 0
  | .out why => IO.println s!"out: {why.construct} at line {why.line}"; pure 0

private def mainPrint (kind text : String) : IO UInt32 := do
  let value? : Option Value := match kind with
    | "int" => text.toInt?.map Value.int
    | "string" => some (.string text)
    | "true" => some (.bool true)
    | "false" => some (.bool false)
    | "null" => some .null
    | "closure" => some (.closure text)
    | _ => none
  match value? with
  | some value => IO.println value.print; pure 0
  | none => usage

def main (args : List String) : IO UInt32 :=
  match args with
  | ["--classify", path] => mainClassify path
  | ["--print-value", kind, value] => mainPrint kind value
  | _ => usage
