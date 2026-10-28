import EigenCore.Parser
import EigenCore.Value
namespace EigenCore

inductive Err where | runtime (message : String) | replay (message : String) | unsupported (construct : String) | refusal (reason : String) | fuel deriving Repr, BEq
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
structure Environment where
  id : Nat
  parent : Option Nat
  slots : Array Cell := #[]
  deriving Inhabited
structure Frame where
  serial : Nat
  environment : Nat
  deriving Inhabited
structure FunctionDef where
  name : String
  parameters : List String
  body : List Stmt
  definingEnvironment : Nat
  deriving Inhabited
inductive OracleValue where | int (v : Int) | string (v : String) | null deriving Repr, BEq
inductive Mode where | live (oracle : List OracleValue) | record (oracle : List OracleValue) | replayStrict (tape : List String) deriving Repr, BEq
/-- The evaluator-facing effect interface.  `Mode` is a public request; this is
the private, stateful handler selected once, before evaluation starts. -/
private inductive TapedHandler where
  | live (oracle : List OracleValue)
  | record (oracle : List OracleValue)
  | replayStrict (remaining : List String)
structure World where
  environments : Array Environment := #[{id := 0, parent := none}]
  frames : Array Frame := #[{serial := 0, environment := 0}]
  nextFrameSerial : Nat := 1
  functions : Array FunctionDef := #[]
  stdout : String := ""
  tape : List String := []
  private mode : TapedHandler := .live []
  oracleCursor : Nat := 0
abbrev EvalM := ExceptT Err (StateM World)

private def findCell (name : String) (cells : Array Cell) : Option Nat := cells.findIdx? (fun c => c.name == name)
private def currentEnvironment (w : World) : Nat :=
  w.frames.back?.map (·.environment) |>.getD 0
private def resolveFrom (name : String) (start : Nat) (environments : Array Environment) : Option Binding :=
  let rec walk : Nat → Nat → Option Binding
    | 0, _ => none
    | fuel + 1, environmentId =>
      match environments[environmentId]? with
      | none => none
      | some environment =>
        match findCell name environment.slots with
        | some slot => some {envId := environmentId, slot := slot}
        | none => environment.parent.bind (walk fuel)
  walk (environments.size + 1) start
private def resolve (name : String) (w : World) : Option Binding :=
  resolveFrom name (currentEnvironment w) w.environments
private def valueAt (name : String) : EvalM Value := do
  let w ← get
  match resolve name w with
  | some binding => pure w.environments[binding.envId]!.slots[binding.slot]!.value
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
  | .bool true => "true" | .bool false => "false" | .null => "null"
  | .array values => s!"<list:{values.length}>"
  | .closure _ _ => "<fn>"

private def nondetString (s : String) : String :=
  "\"" ++ s.toList.foldl (fun out c => out ++
    if c == '"' then "\\\"" else if c == '\\' then "\\\\"
    else if c == '\n' then "\\n" else if c == '\r' then "\\r"
    else if c.toNat < 0x20 then
      "\\x" ++ String.ofList [lowerHexDigit (c.toNat / 16), lowerHexDigit (c.toNat % 16)]
    else c.toString) "" ++ "\""

private def nondetValue : Value → String
  | .int n => toString n | .string s => nondetString s | .null => "null"
  | .bool true => "true" | .bool false => "false"
  | .array values => s!"<list:{values.length}>" | .closure _ _ => "<fn>"

/-- The C VM's return-kind table, restricted to EigenCore-0's taped calls. -/
def k_tape_kinds : List (String × List String) :=
  [("env_get", ["string"]), ("random_int", ["number"]),
   ("read_line", ["string", "null"])]

private def parseQuoted (s : String) : Option String :=
  if !(s.startsWith "\"") || !(s.endsWith "\"") then none else
    let body := ((s.drop 1).dropEnd 1).toString
    let rec go : Nat → List Char → String → Option String
      | 0, _, _ => none
      | _, [], out => some out
      | fuel + 1, '\\' :: 'x' :: hi :: lo :: rest, out =>
          let nibble (c : Char) : Option Nat :=
            if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
            else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
            else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
            else none
          match nibble hi, nibble lo with
          | some h, some l => go fuel rest (out.push (Char.ofNat (h * 16 + l)))
          | _, _ => none
      | fuel + 1, '\\' :: c :: rest, out =>
          if c == '"' then go fuel rest (out.push '"')
          else if c == '\\' then go fuel rest (out.push '\\')
          else if c == 'n' then go fuel rest (out.push '\n')
          else if c == 'r' then go fuel rest (out.push '\r')
          else none
      | fuel + 1, c :: rest, out => go fuel rest (out.push c)
    go (body.length + 1) body.toList ""

private def parseNValue (fn raw : String) : Except Err Value :=
  if fn == "random_int" then
    match raw.toInt? with
    | some n => pure (.int n)
    | none => throw (.replay s!"tape kind mismatch for {fn}: expected number")
  else if fn == "env_get" then
    match parseQuoted raw with
    | some s => pure (.string s)
    | none => throw (.replay s!"tape kind mismatch for {fn}: expected string")
  else if fn == "read_line" then
    if raw == "null" then pure .null else
      match parseQuoted raw with
      | some s => pure (.string s)
      | none => throw (.replay s!"tape kind mismatch for {fn}: expected string or null")
  else throw (.replay s!"tape name mismatch: program called {fn}")

private def takeN (fn : String) : EvalM Value := do
  let w ← get
  let rec scan : List String → Except Err (Value × List String)
    | [] => throw (.runtime s!"{fn}: replay stream 0 has no matching recorded N value")
    | line :: rest =>
      if line.startsWith "V " then
        -- replay_scan_locked retains a subsequent version header as a session
        -- boundary.  A TAKE may not borrow nondeterminism from that session.
        throw (.runtime s!"{fn}: replay stream 0 has no matching recorded N value")
      else if line.startsWith "N " then
        match (line.splitOn " ").drop 2 with
        | payloadParts =>
          let payload := String.intercalate " " payloadParts
          match payload.splitOn "=" with
          | name :: valueParts =>
            let recorded := String.intercalate "=" valueParts
            if name != fn then throw (.replay s!"replay name mismatch: tape has '{name}', program called '{fn}'")
            else do pure (← parseNValue fn recorded, rest)
          | _ => throw (.replay "malformed N record")
      else scan rest
  match scan (match w.mode with | .replayStrict tape => tape | _ => []) with
  | .error e => throw e
  | .ok (value, rest) =>
      let record := "N 0 " ++ fn ++ "=" ++ nondetValue value
      set {w with mode := .replayStrict rest, tape := w.tape ++ [record]}
      pure value

private def oracleValue (fn : String) (oracle : List OracleValue) : EvalM Value := do
  let w ← get
  let some raw := oracle[w.oracleCursor]?
    | throw (.runtime s!"{fn}: oracle exhausted at value {w.oracleCursor}")
  let value ← match fn, raw with
    | "random_int", .int n => pure (.int n)
    | "env_get", .string s => pure (.string s)
    | "read_line", .string s => pure (.string s)
    | "read_line", .null => pure .null
    | _, _ => throw (.runtime s!"{fn}: oracle value has the wrong kind")
  set {w with oracleCursor := w.oracleCursor + 1}
  pure value

private def liveHandler (fn : String) (oracle : List OracleValue) : EvalM Value :=
  oracleValue fn oracle

private def recordHandler (fn : String) (oracle : List OracleValue) : EvalM Value := do
  let value ← oracleValue fn oracle
  modify fun w => {w with tape := w.tape ++ ["N 0 " ++ fn ++ "=" ++ nondetValue value]}
  pure value

private def replayStrictHandler (fn : String) : EvalM Value :=
  takeN fn

/-- Live and record modes consume the supplied oracle exactly once per taped
call.  Exhaustion is a runtime error, rather than a fabricated default: this
keeps completed record runs honest and lets the N values of any successful
strict replay serve directly as the witness oracle for replay fidelity. -/
private def tapedCall (fn : String) : EvalM Value := do
  let w ← get
  match w.mode with
  | .replayStrict _ => replayStrictHandler fn
  | .live oracle => liveHandler fn oracle
  | .record oracle => recordHandler fn oracle
private def store (name : String) (v : Value) (isLocal : Bool) : EvalM Unit := do
  let w ← get
  let current := currentEnvironment w
  let found := if isLocal then
      findCell name w.environments[current]!.slots |>.map ({envId := current, slot := ·})
    else resolve name w
  let environments := match found with
    | some binding => w.environments.modify binding.envId fun environment =>
        {environment with slots := environment.slots.modify binding.slot fun c =>
          {c with value:=v, history:=(c.history.push v).extract ((c.history.size+1).sub 256) (c.history.size+1), assignments:=c.assignments+1}}
    | none => w.environments.modify current fun environment =>
        {environment with slots := environment.slots.push {name:=name,value:=v,history:=#[v],assignments:=1}}
  set {w with environments:=environments,tape:=w.tape ++ [s!"A 0 {name}={tapeValue v}"]}

/-- Parameter creation is its first observation, but is not an assignment tape event. -/
private def bindParameter (environment : Nat) (name : String) (value : Value) : EvalM Unit := do
  modify fun w => {w with environments := w.environments.modify environment fun e =>
    {e with slots := e.slots.push {name:=name, value:=value, history:=#[value], assignments:=1}}}
private def truthy : Value → Bool
  | .bool false | .null | .int 0 | .string "" | .array [] => false
  | _ => true
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

mutual
 def evalExpr (fuel : Nat) (e : Expr) : EvalM Value := match fuel with
  | 0 => throw .fuel
  | f+1 => match e with
    | .literal (.int n) => pure (.int n) | .literal (.string s) => pure (.string s) | .literal (.bool b) => pure (.bool b) | .literal .null => pure .null
    | .variable n => valueAt n | .not x => do pure (.bool (!truthy (← evalExpr f x)))
    | .array _ => throw (.unsupported "array literal")
    | .binary .and a b => do let x ← evalExpr f a; if truthy x then evalExpr f b else pure x
    | .binary .or a b => do let x ← evalExpr f a; if truthy x then pure x else evalExpr f b
    | .binary op a b => do match evalBin op (← evalExpr f a) (← evalExpr f b) with | .ok v => pure v | .error x => throw x
    | .when n => do
      let w ← get
      match resolve n w with
      | some binding => pure (.int w.environments[binding.envId]!.slots[binding.slot]!.assignments)
      | none => throw (Err.runtime s!"undefined variable: {n}")
    | .prev _ => throw (.unsupported "prev")
    | .whatWhen _ _ => throw (.unsupported "what-when")
    | .call (.variable "print") [argument] => do
        let value ← evalExpr f argument
        modify fun w => {w with stdout:=w.stdout ++ value.print ++ "\n"}
        -- C's builtin_print returns null (src/builtins.c), not its argument.
        pure .null
    | .call (.variable "random_int") [loExpr, hiExpr] => do
        let w ← get
        if (resolve "random_int" w).isSome then
          let callable ← evalExpr f (.variable "random_int")
          let values ← [loExpr, hiExpr].mapM (evalExpr f)
          match callable with
          | .closure functionId _ => callFunction f functionId values
          | _ => throw (.runtime "value is not callable")
        else
        let lo ← evalExpr f loExpr; let hi ← evalExpr f hiExpr
        let (.int low) := lo | throw (.runtime "random_int expects numeric bounds")
        let (.int high) := hi | throw (.runtime "random_int expects numeric bounds")
        if high >= low && (high - low + 1) > 2147483648 then
          throw (.runtime s!"random_int: range span {high - low + 1} exceeds 2^31 (lrand48 supplies 31 bits)")
        tapedCall "random_int"
    | .call (.variable "read_line") [] => do
        let w ← get
        if (resolve "read_line" w).isSome then
          let callable ← evalExpr f (.variable "read_line")
          match callable with
          | .closure functionId _ => callFunction f functionId []
          | _ => throw (.runtime "value is not callable")
        else tapedCall "read_line"
    | .call (.variable "env_get") [nameExpr] => do
        let w ← get
        if (resolve "env_get" w).isSome then
          let callable ← evalExpr f (.variable "env_get")
          let value ← evalExpr f nameExpr
          match callable with
          | .closure functionId _ => callFunction f functionId [value]
          | _ => throw (.runtime "value is not callable")
        else
        let name ← evalExpr f nameExpr
        let (.string _) := name | throw (.runtime "env_get expects a string name")
        tapedCall "env_get"
    | .call function arguments => do
      let callable ← evalExpr f function
      let values ← arguments.mapM (evalExpr f)
      match callable with
      | .closure functionId _ => callFunction f functionId values
      | _ => throw (.runtime "value is not callable")
 termination_by fuel

 def callFunction (fuel : Nat) (functionId : Nat) (arguments : List Value) : EvalM Value := match fuel with
  | 0 => throw .fuel
  | f + 1 => do
    let before ← get
    let some definition := before.functions[functionId]?
      | throw (.runtime s!"undefined function id: {functionId}")
    let count := definition.parameters.length
    if count > 1 && arguments.length > count then
      throw (.runtime s!"call passes {arguments.length} arguments but the callee takes {count}")
    let environment := before.environments.size
    let frame : Frame := {serial:=before.nextFrameSerial, environment:=environment}
    set {before with
      environments:=before.environments.push {id:=environment, parent:=some definition.definingEnvironment}
      frames:=before.frames.push frame, nextFrameSerial:=before.nextFrameSerial + 1}
    let supplied := if count == 0 then [] else if count == 1 && arguments.length != 1 then
      [.array arguments] else arguments
    for (parameter, index) in definition.parameters.zipIdx do
      bindParameter environment parameter (supplied[index]?.getD .null)
    let outcome : Except Err Value ← try
      let returned ← exec f definition.body
      pure (Except.ok (returned.getD .null))
    catch error => pure (Except.error error)
    modify fun w => {w with frames:=w.frames.pop}
    match outcome with | .ok value => pure value | .error error => throw error
 termination_by fuel

 def chooseBranch (fuel : Nat) (arms : List (Expr × List Stmt))
     (otherwise : Option (List Stmt)) : EvalM (Option Value) := match fuel with
  | 0 => throw .fuel
  | f + 1 => match arms with
    | [] => match otherwise with | some body => exec f body | none => pure none
    | (condition, body) :: rest => do
      if truthy (← evalExpr f condition) then exec f body else chooseBranch f rest otherwise
 termination_by fuel

 def execLoop (fuel : Nat) (condition : Expr) (body rest : List Stmt) : EvalM (Option Value) :=
  match fuel with
  | 0 => throw .fuel
  | f + 1 => do
    if truthy (← evalExpr f condition) then
      match ← exec f body with | some value => pure (some value) | none => execLoop f condition body rest
    else do
      store "__loop_exit__" (.string "normal") false
      exec f rest
 termination_by fuel

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
        let result ← if truthy (← evalExpr f condition) then exec f yes else chooseBranch f elifs no
        match result with | some v => pure (some v) | none => exec f rest
      | .loop condition body => execLoop f condition body rest
      | .define name parameters body => do
        let w ← get
        let functionId := w.functions.size
        let definition : FunctionDef := {
          name:=name, parameters:=(if parameters.isEmpty then ["n"] else parameters), body:=body,
          definingEnvironment:=currentEnvironment w}
        modify fun state => {state with functions:=state.functions.push definition}
        store name (.closure functionId name) true
        exec f rest
 termination_by fuel
end

structure RunResult where
  stdout : String
  tape : List String
  error : Option Err := none
  deriving Repr, BEq

def run (fuel : Nat) (p : Program) (mode : Mode) : RunResult :=
  if let some construct := unsupportedConstruct p then
    {stdout:="", tape:=[], error:=some (.unsupported construct)}
  else
    let root : Environment := {id:=0, parent:=none}
    let handler := match mode with
      | .live oracle => TapedHandler.live oracle
      | .record oracle => TapedHandler.record oracle
      | .replayStrict tape => TapedHandler.replayStrict tape
    let initial : World := {mode:=handler, environments:=#[root]}
    let action : EvalM (Option Value) := exec fuel p
    let (result, w) := (action.run).run initial
    let error := match result with | .ok _ => none | .error e => some e
    {stdout:=w.stdout, tape:=w.tape, error:=error}
end EigenCore
