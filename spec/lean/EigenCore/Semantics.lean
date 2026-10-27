import EigenCore.Parser
import EigenCore.Value
namespace EigenCore

inductive Err where | runtime (message : String) | unsupported (construct : String) | refusal (reason : String) | fuel deriving Repr, BEq
structure Binding where
  envId : Nat
  slot : Nat
  deriving Repr, BEq
structure Cell where
  name : String
  value : Value
  history : Array Value
  assignments : Nat
  deriving Inhabited
inductive OracleValue where | int (v : Int) | string (v : String) | null deriving Repr, BEq
inductive Mode where | live (oracle : List OracleValue) | record (oracle : List OracleValue) | replayStrict (tape : List String) deriving Repr, BEq
structure World where
  cells : Array Cell := #[]
  stdout : String := ""
  tape : List String := []
  mode : Mode := .live []
abbrev EvalM := ExceptT Err (StateM World)

private def findCell (name : String) (cells : Array Cell) : Option Nat := cells.findIdx? (fun c => c.name == name)
private def valueAt (name : String) : EvalM Value := do
  let w ← get
  match findCell name w.cells with
  | some i => pure w.cells[i]!.value
  | none => throw (Err.runtime s!"undefined variable: {name}")
private def tapeString (s : String) : String :=
  let (_, body) := s.toList.foldl (fun (state : Nat × String) c =>
    let (written, out) := state
    if written >= 60 then state else
      let encoded := if c == '"' then "\\\"" else if c == '\\' then "\\\\"
        else if c == '\n' then "\\n" else if c == '\r' then "\\r" else c.toString
      (written + encoded.utf8ByteSize, out ++ encoded)) (0, "")
  "\"" ++ body ++ (if s.utf8ByteSize > 60 then "…" else "") ++ "\""
private def tapeValue : Value → String
  | .int n => toString n | .string s => tapeString s
  | .bool true => "true" | .bool false => "false" | .null => "null" | .closure n => s!"<fn {n}>"
private def store (name : String) (v : Value) (_isLocal : Bool) : EvalM Unit := do
  let w ← get
  let found := findCell name w.cells
  let cells := match found with
    | some i => w.cells.modify i fun c => {c with value:=v, history:=(c.history.push v).extract ((c.history.size+1).sub 256) (c.history.size+1), assignments:=c.assignments+1}
    | none => w.cells.push {name:=name,value:=v,history:=#[v],assignments:=1}
  set {w with cells:=cells,tape:=w.tape ++ [s!"A 0 {name}={tapeValue v}"]}
private def truthy : Value → Bool | .bool false | .null | .int 0 | .string "" => false | _ => true
private def asInt : Value → Except Err Int | .int n => pure n | _ => throw (Err.runtime "expected integer")
private def safeInt (n : Int) : Except Err Value :=
  if n.natAbs < 9007199254740992 then pure (.int n)
  else throw (.refusal "arithmetic result outside the exact-integer range")
private def evalBin (op : BinOp) (a b : Value) : Except Err Value := match op with
  | .add => match a,b with | .int x,.int y => safeInt (x+y) | .string x,.string y => pure (.string (x++y)) | _,_ => throw (Err.runtime "invalid +")
  | .sub => do safeInt ((← asInt a) - (← asInt b))
  | .mul => do safeInt ((← asInt a) * (← asInt b))
  | .eq | .ne => match a, b with
      | .bool _, .int _ | .int _, .bool _ => throw (Err.runtime "cannot compare boolean and number")
      | _, _ => pure (.bool (if op == .eq then a == b else a != b))
  | .lt | .le | .gt | .ge =>
      match a, b with
      | .int x, .int y => pure (.bool (match op with | .lt => x<y | .le => x<=y | .gt => x>y | _ => x>=y))
      | .string x, .string y => pure (.bool (match op with | .lt => x<y | .le => x<=y | .gt => x>y | _ => x>=y))
      | _, _ => throw (Err.runtime "cannot order operands of different types")
  | .and => pure (if truthy a then b else a) | .or => pure (if truthy a then a else b)

def evalExpr (fuel : Nat) (e : Expr) : EvalM Value := match fuel with
  | 0 => throw .fuel
  | f+1 => match e with
    | .literal (.int n) => pure (.int n) | .literal (.string s) => pure (.string s) | .literal (.bool b) => pure (.bool b) | .literal .null => pure .null
    | .variable n => valueAt n | .not x => do pure (.bool (!truthy (← evalExpr f x)))
    | .binary .and a b => do let x ← evalExpr f a; if truthy x then evalExpr f b else pure x
    | .binary .or a b => do let x ← evalExpr f a; if truthy x then pure x else evalExpr f b
    | .binary op a b => do match evalBin op (← evalExpr f a) (← evalExpr f b) with | .ok v => pure v | .error x => throw x
    | .when n => do let w ← get; match findCell n w.cells with | some i => pure (.int w.cells[i]!.assignments) | none => throw (Err.runtime s!"undefined variable: {n}")
    | .prev _ => throw (.unsupported "prev")
    | .whatWhen _ _ => throw (.unsupported "what-when")
    | .call (.variable "print") [argument] => do
        let value ← evalExpr f argument
        modify fun w => {w with stdout:=w.stdout ++ value.print ++ "\n"}
        -- C's builtin_print returns null (src/builtins.c), not its argument.
        pure .null
    | .call _ _ => throw (.unsupported "function call")

def exec (fuel : Nat) (ss : List Stmt) : EvalM (Option Value) := match fuel with
  | 0 => throw .fuel
  | f+1 => match ss with
    | [] => pure none
    | s::rest => match s with
      | .assign n e isLocal => do store n (← evalExpr f e) isLocal; exec f rest
      | .print e => do let v ← evalExpr f e; modify fun w => {w with stdout:=w.stdout ++ v.print ++ "\n"}; exec f rest
      | .expression e => do let _ ← evalExpr f e; exec f rest
      | .return_ e => do pure (some (← evalExpr f e))
      | .branch condition yes elifs no => do
        let rec choose : List (Expr × List Stmt) → EvalM (Option Value)
          | [] => match no with | some body => exec f body | none => pure none
          | (c, body) :: arms => do if truthy (← evalExpr f c) then exec f body else choose arms
        let result ← if truthy (← evalExpr f condition) then exec f yes else choose elifs
        match result with | some v => pure (some v) | none => exec f rest
      | .loop condition body =>
        let rec again (remaining : Nat) : EvalM (Option Value) := match remaining with
          | 0 => throw .fuel
          | n+1 => do
            if truthy (← evalExpr n condition) then
              match ← exec n body with | some v => pure (some v) | none => again n
            else do
              -- `__loop_exit__` is a language-visible loop binding, and hence
              -- an assignment event under SPEC/TRACE just like source stores.
              store "__loop_exit__" (.string "normal") false
              exec n rest
        again f
      | .define _ _ _ => throw (.unsupported "function definition")

structure RunResult where
  stdout : String
  tape : List String
  error : Option Err := none

def run (fuel : Nat) (p : Program) (mode : Mode) : RunResult :=
  if let some construct := unsupportedConstruct p then
    {stdout:="", tape:=[], error:=some (.unsupported construct)}
  else
    let (result, w) := ((exec fuel p).run).run {mode:=mode}
    let error := match result with | .ok _ => none | .error e => some e
    {stdout:=w.stdout, tape:=w.tape, error:=error}
end EigenCore
