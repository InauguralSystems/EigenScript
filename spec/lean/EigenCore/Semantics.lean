import EigenCore.Parser
import EigenCore.Value
import Std.Data.String.ToInt
namespace EigenCore

inductive Err where | runtime (message : String) | replay (message : String) | unsupported (construct : String) | refusal (reason : String) | fuel deriving Repr, BEq, DecidableEq
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
inductive OracleValue where | int (v : Int) | string (v : String) | null deriving Repr, BEq, DecidableEq
inductive Mode where | live (oracle : List OracleValue) | record (oracle : List OracleValue) | replayStrict (tape : List String) deriving Repr, BEq

/-- The answer kinds which a successful writer can record. -/
inductive WriterAnswer where
  | randomInt (value : Int)
  | envGet (value : String)
  | readLine (value : String)
  | readLineNull
  deriving Repr, BEq

def StructuralRecord (line : String) : Prop :=
  ¬ line.startsWith "N " ∧ ¬ line.startsWith "V " ∧
    '\n' ∉ line.toList ∧ line ≠ ""

/-- A structural tape row whose validity is carried as data. -/
abbrev StructuralRow := {line : String // StructuralRecord line}

/-- Structural records emitted since the preceding answer, paired with the
next answer record. -/
structure WriterChunk where
  structural : List StructuralRow
  answer : WriterAnswer
  deriving Repr, BEq
/-- One answer actually consumed by the evaluator.  Positions are positions in
the single supplied answer sequence, not byte offsets in a tape. -/
inductive TapedAnswer where
  | value (position : Nat) (name : String) (value : OracleValue)
  | replayError (position : Nat) (error : Err)
  | replayExhausted (position : Nat)
  | oracleExhausted (position : Nat)
  deriving Repr, BEq, DecidableEq

/-- The model position carried by every kind of supplied answer. -/
def positionOf : TapedAnswer → Nat
  | .value position _ _ | .replayError position _
  | .replayExhausted position | .oracleExhausted position => position

/-- Every answer is numbered consecutively from `start`. -/
def WellPositioned : Nat → List TapedAnswer → Prop
  | _, [] => True
  | start, answer :: rest =>
      positionOf answer = start ∧ WellPositioned (start + 1) rest

@[simp] theorem wellPositioned_nil (start : Nat) : WellPositioned start [] := trivial

@[simp] theorem wellPositioned_cons (start : Nat) (answer : TapedAnswer)
    (rest : List TapedAnswer) :
    WellPositioned start (answer :: rest) ↔
      positionOf answer = start ∧ WellPositioned (start + 1) rest := Iff.rfl

/-- Dropping `count` entries advances the required starting position. -/
theorem WellPositioned.drop {start : Nat} {answers : List TapedAnswer}
    (positioned : WellPositioned start answers) (count : Nat) :
    WellPositioned (start + count) (answers.drop count) := by
  induction count generalizing start answers with
  | zero => simpa using positioned
  | succ count ih =>
      cases answers with
      | nil => simp
      | cons answer rest =>
          have tail := ih positioned.2
          simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using tail

/-- Consecutively positioned lists compose exactly when the second list starts
after the first list. -/
theorem wellPositioned_append (start : Nat) (first second : List TapedAnswer) :
    WellPositioned start (first ++ second) ↔
      WellPositioned start first ∧ WellPositioned (start + first.length) second := by
  induction first generalizing start with
  | nil => simp
  | cons answer rest ih =>
      simp only [List.cons_append, wellPositioned_cons, List.length_cons]
      rw [ih (start + 1)]
      constructor
      · rintro ⟨head, tail, secondPositioned⟩
        exact ⟨⟨head, tail⟩, by simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using secondPositioned⟩
      · rintro ⟨⟨head, tail⟩, secondPositioned⟩
        exact ⟨head, tail, by simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using secondPositioned⟩

/-- A taped operation is an explicit interaction, rather than an implicit read
from evaluator state. -/
structure TapedQuery where
  name : String
  deriving Repr, BEq

/-- Record oracles do not carry call names. Complete that wildcard at the
effect boundary, so continuations receive the same answer as strict replay. -/
private def deliveredAnswer (query : TapedQuery) : TapedAnswer → TapedAnswer
  | .value position name value =>
      .value position (if name.isEmpty then query.name else name) value
  | answer => answer

/-- A record-mode answer carries an empty name; delivery fills it with the
query name. -/
theorem deliveredAnswer_wildcard (query : TapedQuery) (position : Nat)
    (value : OracleValue) :
    deliveredAnswer query (.value position "" value) =
      .value position query.name value := by
  simp [deliveredAnswer]

/-- Completing the wildcard name at the effect boundary is idempotent. -/
theorem deliveredAnswer_idem (query : TapedQuery) (answer : TapedAnswer) :
    deliveredAnswer query (deliveredAnswer query answer) = deliveredAnswer query answer := by
  cases answer with
  | value position name value =>
      by_cases empty : name.isEmpty <;> simp [deliveredAnswer, empty]
  | replayError | replayExhausted | oracleExhausted => rfl

/-- The finite interaction tree produced by evaluation.  Its continuation is
positive: an interpreter, and only an interpreter, supplies taped answers. -/
inductive Interaction (α : Type) where
  | done : α → Interaction α
  | ask : TapedQuery → (TapedAnswer → Interaction α) → Interaction α

namespace Interaction
def bind : Interaction α → (α → Interaction β) → Interaction β
  | .done value, next => next value
  | .ask query continuation, next => .ask query fun answer => bind (continuation answer) next

instance : Monad Interaction where
  pure := .done
  bind := bind
end Interaction

structure World where
  environments : Array Environment := #[{id := 0, parent := none}]
  frames : Array Frame := #[{serial := 0, environment := 0}]
  nextFrameSerial : Nat := 1
  functions : Array FunctionDef := #[]
  stdout : String := ""
  /-- Completed answer chunks and the structural tail form the canonical writer
  state. Keeping this shape makes record/replay invariants structural. -/
  writerChunks : List WriterChunk := []
  writerTrailing : List StructuralRow := []
abbrev EvalM := ExceptT Err (StateT World Interaction)

/-- Expose the concrete evaluator stack at its `Interaction` boundary. -/
private def evalRun (m : EvalM α) (world : World) : Interaction (Except Err α × World) :=
  (m.run).run world

/-- `evalRun` is the single proof-level spelling of the concrete evaluator stack. -/
theorem evalRun_eq (m : EvalM α) (w : World) :
    evalRun m w = (m.run).run w := rfl

/-- Running `pure` immediately returns its value and preserves the world. -/
theorem evalRun_pure (value : α) (world : World) :
    evalRun (pure value) world = .done (.ok value, world) := by
  rfl

/-- Running `throw` immediately returns its error and preserves the world. -/
theorem evalRun_throw (error : Err) (world : World) :
    evalRun (throw error : EvalM α) world = .done (.error error, world) := by
  rfl

/-- Running `get` returns the current world without changing it. -/
theorem evalRun_get (world : World) :
    evalRun (get : EvalM World) world = .done (.ok world, world) := by
  rfl

/-- Running `set` replaces the world and returns unit. -/
theorem evalRun_set (replacement world : World) :
    evalRun (set replacement : EvalM Unit) world = .done (.ok (), replacement) := by
  rfl

/-- Running `modify` applies its update once and returns unit. -/
theorem evalRun_modify (f : World → World) (world : World) :
    evalRun (modify f : EvalM Unit) world = .done (.ok (), f world) := by
  rfl

/-- Lifting an interaction preserves the evaluator world at every leaf. -/
theorem evalRun_liftM (tree : Interaction α) (world : World) :
    evalRun (liftM tree : EvalM α) world =
      Interaction.bind tree (fun value => .done (.ok value, world)) := by
  change ((ExceptT.lift (StateT.lift tree)).run).run world = _
  change (StateT.map Except.ok (StateT.lift tree)).run world = _
  unfold StateT.map StateT.lift
  change Interaction.bind
      (Interaction.bind tree (fun value => Interaction.done (value, world)))
      (fun pair => Interaction.done (Except.ok pair.1, pair.2)) = _
  induction tree with
  | done value => rfl
  | ask query continuation ih =>
      simp only [Interaction.bind]
      congr 1
      funext answer
      exact ih answer

/-- Concrete run equation for evaluator bind. -/
theorem evalRun_bind (m : EvalM α) (k : α → EvalM β) (world : World) :
    evalRun (m >>= k) world = Interaction.bind (evalRun m world) (fun (result, nextWorld) =>
      match result with
      | .ok value => evalRun (k value) nextWorld
      | .error error => .done (.error error, nextWorld)) := by
  change ((ExceptT.bind m k).run).run world = _
  change Interaction.bind (evalRun m world) _ = Interaction.bind (evalRun m world) _
  congr 1
  funext pair
  cases pair with
  | mk result nextWorld => cases result <;> rfl

/-- Concrete run equation for evaluator exception handling. -/
theorem evalRun_tryCatch (m : EvalM α) (handler : Err → EvalM α) (world : World) :
    evalRun (tryCatch m handler) world =
      Interaction.bind (evalRun m world) (fun (result, nextWorld) =>
        match result with
        | .ok value => .done (.ok value, nextWorld)
        | .error error => evalRun (handler error) nextWorld) := by
  change ((ExceptT.tryCatch m handler).run).run world = _
  change Interaction.bind (evalRun m world) _ = Interaction.bind (evalRun m world) _
  congr 1
  funext pair
  cases pair with
  | mk result nextWorld => cases result <;> rfl

/-- Catching an evaluator error into an `Except` value maps every leaf of the
inner computation, including its error leaves, into an outer success. -/
theorem evalRun_catchToExcept (m : EvalM α) (g : α → β) (world : World) :
    evalRun (tryCatch (m >>= fun value => pure (.ok (g value)))
        (fun error => pure (.error error))) world =
      (evalRun m world).bind (fun (result, nextWorld) =>
        .done (.ok (result.map g), nextWorld)) := by
  rw [evalRun_tryCatch, evalRun_bind]
  generalize evalRun m world = tree
  induction tree with
  | done pair =>
      cases pair with
      | mk result nextWorld => cases result <;> rfl
  | ask query continuation ih =>
      simp only [Interaction.bind]
      congr 1
      funext answer
      exact ih answer

/-- The catch/pop/rethrow shell around a computation maps its successful
values, preserves its error status, and pops one frame at every leaf. -/
theorem evalRun_catchPopRethrow (m : EvalM α) (g : α → β) (world : World) :
    evalRun (do
      let outcome : Except Err β ← try
        let returned ← m
        pure (Except.ok (g returned))
      catch error => pure (Except.error error)
      modify fun w => {w with frames := w.frames.pop}
      match outcome with
      | .ok value => pure value
      | .error error => throw error) world =
    (evalRun m world).bind (fun (result, nextWorld) =>
      .done (result.map g, {nextWorld with frames := nextWorld.frames.pop})) := by
  rw [evalRun_bind, evalRun_catchToExcept]
  generalize evalRun m world = tree
  induction tree with
  | done pair =>
      cases pair with
      | mk result nextWorld => cases result <;> rfl
  | ask query continuation ih =>
      simp only [Interaction.bind]
      congr 1
      funext answer
      exact ih answer

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

/-- Make a writer structural row line-safe without changing ordinary rows. -/
private def structuralChars : List Char → List Char
  | [] => []
  | c :: rest =>
      (if c == '\n' then ['\\', 'n'] else if c == '\r' then ['\\', 'r'] else [c]) ++
        structuralChars rest

private def structuralRecord (line : String) : String :=
  String.ofList (structuralChars line.toList)

theorem structuralChars_no_newline (chars : List Char) :
    '\n' ∉ structuralChars chars := by
  induction chars with
  | nil => simp [structuralChars]
  | cons c rest ih =>
      simp only [structuralChars]
      by_cases newline : c == '\n'
      · simp [newline, ih]
      · by_cases carriage : c == '\r'
        · simp [newline, carriage, ih]
        · simp only [newline, carriage, Bool.false_eq_true, if_false, List.singleton_append,
            List.mem_cons, ih, or_false, not_false_eq_true]
          intro same
          subst c
          simp at newline

private def nondetChar (c : Char) : List Char :=
  if c == '"' then ['\\', '"'] else if c == '\\' then ['\\', '\\']
  else if c == '\n' then ['\\', 'n'] else if c == '\r' then ['\\', 'r']
  else if c.toNat < 0x20 then
    ['\\', 'x', lowerHexDigit (c.toNat / 16), lowerHexDigit (c.toNat % 16)]
  else [c]

private def nondetChars : List Char → List Char
  | [] => []
  | c :: rest => nondetChar c ++ nondetChars rest

private def nondetString (s : String) : String :=
  String.ofList ('"' :: nondetChars s.toList ++ ['"'])

private def nondetValue : Value → String
  | .int n => toString n | .string s => nondetString s | .null => "null"
  | .bool true => "true" | .bool false => "false"
  | .array values => s!"<list:{values.length}>" | .closure _ _ => "<fn>"

/-- The C VM's return-kind table, restricted to EigenCore-0's taped calls. -/
def k_tape_kinds : List (String × List String) :=
  [("env_get", ["string"]), ("random_int", ["number"]),
   ("read_line", ["string", "null"])]

private def hexNibble (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

private def parseQuotedGo : Nat → List Char → String → Option String
  | 0, _, _ => none
  | _, [], out => some out
  | fuel + 1, '\\' :: 'x' :: hi :: lo :: rest, out =>
      match hexNibble hi, hexNibble lo with
      | some h, some l => parseQuotedGo fuel rest (out.push (Char.ofNat (h * 16 + l)))
      | _, _ => none
  | fuel + 1, '\\' :: c :: rest, out =>
      if c == '"' then parseQuotedGo fuel rest (out.push '"')
      else if c == '\\' then parseQuotedGo fuel rest (out.push '\\')
      else if c == 'n' then parseQuotedGo fuel rest (out.push '\n')
      else if c == 'r' then parseQuotedGo fuel rest (out.push '\r')
      else none
  | fuel + 1, c :: rest, out => parseQuotedGo fuel rest (out.push c)

private def parseQuoted (s : String) : Option String :=
  -- C's line buffer retains a raw NUL, but its value parser is deliberately
  -- NUL-terminated.  It therefore sees the quoted token as truncated and
  -- reports a malformed taped value.  Only the encoder spelling (`\\x00`)
  -- may carry NUL in a replayable string.
  if s.toList.contains (Char.ofNat 0) then none else match s.toList with
  | '"' :: rest =>
      match rest.reverse with
      | '"' :: bodyReverse =>
          let body := bodyReverse.reverse
          parseQuotedGo (body.length + 1) body ""
      | _ => none
  | _ => none

private def parseNValue (fn raw : String) : Except Err OracleValue :=
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

theorem hexNibble_lowerHexDigit (n : Nat) (h : n < 16) :
    hexNibble (lowerHexDigit n) = some n := by
  have cases : n = 0 ∨ n = 1 ∨ n = 2 ∨ n = 3 ∨ n = 4 ∨ n = 5 ∨
      n = 6 ∨ n = 7 ∨ n = 8 ∨ n = 9 ∨ n = 10 ∨ n = 11 ∨ n = 12 ∨
      n = 13 ∨ n = 14 ∨ n = 15 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> rfl

theorem parseQuotedGo_quote (fuel : Nat) (rest : List Char) (out : String) :
    parseQuotedGo (fuel + 1) (nondetChar '"' ++ rest) out =
      parseQuotedGo fuel rest (out.push '"') := by
  rfl

theorem parseQuotedGo_backslash (fuel : Nat) (rest : List Char) (out : String) :
    parseQuotedGo (fuel + 1) (nondetChar '\\' ++ rest) out =
      parseQuotedGo fuel rest (out.push '\\') := by
  rfl

theorem parseQuotedGo_newline (fuel : Nat) (rest : List Char) (out : String) :
    parseQuotedGo (fuel + 1) (nondetChar '\n' ++ rest) out =
      parseQuotedGo fuel rest (out.push '\n') := by
  rfl

theorem parseQuotedGo_return (fuel : Nat) (rest : List Char) (out : String) :
    parseQuotedGo (fuel + 1) (nondetChar '\r' ++ rest) out =
      parseQuotedGo fuel rest (out.push '\r') := by
  rfl

theorem parseQuotedGo_control (c : Char) (fuel : Nat) (rest : List Char) (out : String)
    (hq : c ≠ '"') (hb : c ≠ '\\') (hn : c ≠ '\n') (hr : c ≠ '\r')
    (hc : c.toNat < 0x20) :
    parseQuotedGo (fuel + 1) (nondetChar c ++ rest) out =
      parseQuotedGo fuel rest (out.push c) := by
  have hhi : c.toNat / 16 < 16 := by omega
  have hlo : c.toNat % 16 < 16 := Nat.mod_lt _ (by omega)
  have rebuilt : Char.ofNat ((c.toNat / 16) * 16 + c.toNat % 16) = c := by
    rw [Nat.mul_comm (c.toNat / 16) 16]
    rw [Nat.div_add_mod]
    exact Char.ofNat_toNat c
  simp [nondetChar, hq, hb, hn, hr, hc, parseQuotedGo,
    hexNibble_lowerHexDigit _ hhi, hexNibble_lowerHexDigit _ hlo, rebuilt]

theorem parseQuotedGo_printable (c : Char) (fuel : Nat) (rest : List Char) (out : String)
    (hq : c ≠ '"') (hb : c ≠ '\\') (hn : c ≠ '\n') (hr : c ≠ '\r')
    (hc : ¬ c.toNat < 0x20) :
    parseQuotedGo (fuel + 1) (nondetChar c ++ rest) out =
      parseQuotedGo fuel rest (out.push c) := by
  simp [nondetChar, hq, hb, hn, hr, hc, parseQuotedGo]

theorem push_append_ofList (out : String) (c : Char) (rest : List Char) :
    (out.push c) ++ String.ofList rest = out ++ String.ofList (c :: rest) := by
  rw [show out.push c = out ++ String.singleton c by apply String.ext; simp]
  rw [String.ofList_cons, String.append_assoc]

theorem parseQuotedGo_nondetChars (chars : List Char) (fuel : Nat) (out : String)
    (enough : chars.length < fuel) :
    parseQuotedGo fuel (nondetChars chars) out = some (out ++ String.ofList chars) := by
  induction chars generalizing fuel out with
  | nil =>
      cases fuel with
      | zero => simp at enough
      | succ fuel => simp [nondetChars, parseQuotedGo]
  | cons c rest ih =>
      cases fuel with
      | zero => simp at enough
      | succ fuel =>
          have enough' : rest.length < fuel := by simp at enough; omega
          simp only [nondetChars]
          by_cases hq : c = '"'
          · subst c
            rw [parseQuotedGo_quote, ih fuel (out.push '"') enough']
            exact congrArg some (push_append_ofList out '"' rest)
          · by_cases hb : c = '\\'
            · subst c
              rw [parseQuotedGo_backslash, ih fuel (out.push '\\') enough']
              exact congrArg some (push_append_ofList out '\\' rest)
            · by_cases hn : c = '\n'
              · subst c
                rw [parseQuotedGo_newline, ih fuel (out.push '\n') enough']
                exact congrArg some (push_append_ofList out '\n' rest)
              · by_cases hr : c = '\r'
                · subst c
                  rw [parseQuotedGo_return, ih fuel (out.push '\r') enough']
                  exact congrArg some (push_append_ofList out '\r' rest)
                · by_cases hc : c.toNat < 0x20
                  · rw [parseQuotedGo_control c fuel (nondetChars rest) out hq hb hn hr hc,
                      ih fuel (out.push c) enough']
                    exact congrArg some (push_append_ofList out c rest)
                  · rw [parseQuotedGo_printable c fuel (nondetChars rest) out hq hb hn hr hc,
                      ih fuel (out.push c) enough']
                    exact congrArg some (push_append_ofList out c rest)

theorem nondetChars_length (chars : List Char) :
    chars.length ≤ (nondetChars chars).length := by
  induction chars with
  | nil => simp [nondetChars]
  | cons c rest ih =>
      simp only [nondetChars, List.length_cons, List.length_append]
      have one : 1 ≤ (nondetChar c).length := by
        by_cases hq : c = '"' <;> by_cases hb : c = '\\' <;>
          by_cases hn : c = '\n' <;> by_cases hr : c = '\r' <;>
          by_cases hc : c.toNat < 0x20 <;> simp [nondetChar, hq, hb, hn, hr, hc]
      omega

theorem lowerHexDigit_ne_nul (n : Nat) (h : n < 16) :
    lowerHexDigit n ≠ Char.ofNat 0 := by
  have cases : n = 0 ∨ n = 1 ∨ n = 2 ∨ n = 3 ∨ n = 4 ∨ n = 5 ∨
      n = 6 ∨ n = 7 ∨ n = 8 ∨ n = 9 ∨ n = 10 ∨ n = 11 ∨ n = 12 ∨
      n = 13 ∨ n = 14 ∨ n = 15 := by omega
  rcases cases with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl |
    rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide

theorem nondetChars_no_raw_nul (chars : List Char) :
    (nondetChars chars).contains (Char.ofNat 0) = false := by
  induction chars with
  | nil => rfl
  | cons c rest ih =>
      simp only [nondetChars, List.contains_append, Bool.or_eq_false_iff, ih,
        and_true]
      by_cases hc : c.toNat < 0x20
      · have hi := lowerHexDigit_ne_nul (c.toNat / 16) (by omega)
        have lo := lowerHexDigit_ne_nul (c.toNat % 16) (Nat.mod_lt _ (by omega))
        by_cases hq : c = '"' <;> by_cases hb : c = '\\' <;>
          by_cases hn : c = '\n' <;> by_cases hr : c = '\r' <;>
          simp [nondetChar, hq, hb, hn, hr, hc, hi.symm, lo.symm]
      · have cnul : Char.ofNat 0 ≠ c := by
          intro equal
          have same := congrArg Char.toNat equal
          simp at same
          omega
        by_cases hq : c = '"' <;> by_cases hb : c = '\\' <;>
          by_cases hn : c = '\n' <;> by_cases hr : c = '\r' <;>
          simp [nondetChar, hq, hb, hn, hr, hc, cnul]

/-- The VM-compatible quoted-string decoder is a left inverse of its encoder. -/
theorem parseQuoted_nondetString (s : String) :
    parseQuoted (nondetString s) = some s := by
  have noNul : Char.ofNat 0 ∉ nondetChars s.toList := by
    intro member
    have : (nondetChars s.toList).contains (Char.ofNat 0) = true :=
      List.contains_iff_mem.mpr member
    rw [nondetChars_no_raw_nul] at this
    contradiction
  simp [parseQuoted, nondetString, noNul]
  rw [parseQuotedGo_nondetChars]
  · simp
  · have := nondetChars_length s.toList
    omega

/-- The numeric `N` encoder and decoder are a left inverse.  This is the
first per-answer round-trip needed by replay fidelity; unlike strings it has
neither escaping nor continuation framing to account for. -/
theorem parseNValue_random_int_encode (n : Int) :
    parseNValue "random_int" (nondetValue (.int n)) = .ok (.int n) := by
  simp [parseNValue, nondetValue, Int.toInt?_repr]
  change Except.ok (OracleValue.int n) = Except.ok (OracleValue.int n)
  rfl

/-- The null spelling used by `read_line` is decoded without ambiguity. -/
theorem parseNValue_read_line_null_encode :
    parseNValue "read_line" (nondetValue .null) = .ok .null := by
  rfl

/-- A quoted string round-trips through either string-valued taped builtin. -/
theorem parseNValue_string_encode (s : String) :
    parseNValue "env_get" (nondetValue (.string s)) = .ok (.string s) ∧
    parseNValue "read_line" (nondetValue (.string s)) = .ok (.string s) := by
  have quoted := parseQuoted_nondetString s
  have notNull : nondetString s ≠ "null" := by
    intro equal
    rw [equal] at quoted
    simp [parseQuoted] at quoted
  constructor
  · simp only [parseNValue, nondetValue, quoted]
    rfl
  · simp [parseNValue, nondetValue, quoted, notNull]
    rfl

private def WriterAnswer.name : WriterAnswer → String
  | .randomInt _ => "random_int"
  | .envGet _ => "env_get"
  | .readLine _ | .readLineNull => "read_line"

private def WriterAnswer.value : WriterAnswer → OracleValue
  | .randomInt value => .int value
  | .envGet value | .readLine value => .string value
  | .readLineNull => .null

private def WriterAnswer.runtimeValue : WriterAnswer → Value
  | .randomInt value => .int value
  | .envGet value | .readLine value => .string value
  | .readLineNull => .null

/-- The exact physical N record appended by `consumeAnswer`: stream number
zero, one space after the header, the called builtin name, and its encoded
runtime value separated by the first equals sign. -/
private def writerNRecordValue (name : String) (value : Value) : String :=
  "N 0 " ++ name ++ "=" ++ nondetValue value

private def writerNRecord (answer : WriterAnswer) : String :=
  writerNRecordValue answer.name answer.runtimeValue

/-- The actual record-mode N-record encoder is decoded by `parseNValue`. -/
theorem parseNValue_writerNRecord_payload (answer : WriterAnswer) :
    parseNValue answer.name (nondetValue answer.runtimeValue) = .ok answer.value := by
  cases answer with
  | randomInt value => exact parseNValue_random_int_encode value
  | envGet value => exact (parseNValue_string_encode value).1
  | readLine value => exact (parseNValue_string_encode value).2
  | readLineNull => exact parseNValue_read_line_null_encode

/-- Normalize replay input once into the evaluator's answer type.  Non-answer
records are skipped, and a later `V` header ends the current session.  Parsing
errors are deliberately stored rather than raised, so evaluation observes one
at precisely the corresponding answer position. -/
private def afterSecondSpace : List Char → List Char
  | [] => []
  | ' ' :: rest =>
    match rest.dropWhile (· != ' ') with
    | [] => []
    | _ :: payload => payload
  | _ :: rest => afterSecondSpace rest

private def splitFirstEquals : List Char → List Char × List Char
  | [] => ([], [])
  | '=' :: rest => ([], rest)
  | c :: rest =>
    let (name, value) := splitFirstEquals rest
    (c :: name, value)

theorem afterSecondSpace_writerRecord (name recorded : String) :
    afterSecondSpace ("N 0 " ++ name ++ "=" ++ recorded).toList =
      (name ++ "=" ++ recorded).toList := by
  simp [String.toList_append, afterSecondSpace, String.append_assoc]

theorem writerNRecord_parts (answer : WriterAnswer) :
    splitFirstEquals (afterSecondSpace (writerNRecord answer).toList) =
      (answer.name.toList, (nondetValue answer.runtimeValue).toList) := by
  cases answer with
  | randomInt value =>
      simp only [writerNRecord, writerNRecordValue, WriterAnswer.name, WriterAnswer.runtimeValue]
      rw [afterSecondSpace_writerRecord]
      simp [String.toList_append, splitFirstEquals]
  | envGet value =>
      simp only [writerNRecord, writerNRecordValue, WriterAnswer.name, WriterAnswer.runtimeValue]
      rw [afterSecondSpace_writerRecord]
      simp [String.toList_append, splitFirstEquals]
  | readLine value =>
      simp only [writerNRecord, writerNRecordValue, WriterAnswer.name, WriterAnswer.runtimeValue]
      rw [afterSecondSpace_writerRecord]
      simp [String.toList_append, splitFirstEquals]
  | readLineNull =>
      simp only [writerNRecord, writerNRecordValue, WriterAnswer.name, WriterAnswer.runtimeValue]
      rw [afterSecondSpace_writerRecord]
      simp [String.toList_append, splitFirstEquals]

private def normalizeTapeFrom (position : Nat) : List String → List TapedAnswer
  | [] => []
  | line :: rest =>
    if line.startsWith "V " then []
    else if line.startsWith "N " then
      let payload := afterSecondSpace line.toList
      match splitFirstEquals payload with
      | (nameChars, recordedChars) =>
        let name := String.ofList nameChars
        let recorded := String.ofList recordedChars
        -- Unknown recorded names stay as values until the call supplies its
        -- expected name.  This preserves the C/previous-model rule that a
        -- wrong-name error takes precedence over parsing that record's value.
        let parsed := if k_tape_kinds.any (fun entry => entry.1 == name) then
            parseNValue name recorded else pure .null
        let answer := match parsed with
          | .ok value => TapedAnswer.value position name value
          | .error error => TapedAnswer.replayError position error
        answer :: normalizeTapeFrom (position + 1) rest
    else normalizeTapeFrom position rest

/-- Tape normalization numbers each emitted N record consecutively from its
requested starting position. -/
theorem wellPositioned_normalizeTapeFrom (start : Nat) (tape : List String) :
    WellPositioned start (normalizeTapeFrom start tape) := by
  induction tape generalizing start with
  | nil => trivial
  | cons line rest ih =>
      simp only [normalizeTapeFrom]
      split
      · trivial
      · split
        · split
          · simp [WellPositioned, positionOf, ih]
          · simp [WellPositioned, positionOf, ih]
        · exact ih start

def normalizeTape (tape : List String) : List TapedAnswer :=
  normalizeTapeFrom 0 tape

/-- A strict-replay tape is kind-valid when every answer record recognized by
its reader names one of the taped builtins and parses as a value of that
builtin's declared return kind.  Structural rows are ignored exactly as they
are by `normalizeTape`, and a `V` row ends the replay session. -/
def TapeKindValid (tape : List String) : Prop :=
  ∀ answer ∈ normalizeTape tape,
    ∃ position name value,
      answer = .value position name value ∧
      ∃ kinds, (name, kinds) ∈ k_tape_kinds

/-- Kind validity rules out every delayed parse error and unknown-name
placeholder in the normalized replay stream. -/
theorem TapeKindValid.onlyValues {tape : List String} (valid : TapeKindValid tape)
    {answer : TapedAnswer} (member : answer ∈ normalizeTape tape) :
    ∃ position name value, answer = .value position name value := by
  obtain ⟨position, name, value, answerEq, _⟩ := valid answer member
  exact ⟨position, name, value, answerEq⟩

/-- Names admitted by the taped-builtin table are nonempty. -/
theorem k_tape_kinds_name_nonempty {name : String} {kinds : List String}
    (member : (name, kinds) ∈ k_tape_kinds) : name.isEmpty = false := by
  simp [k_tape_kinds] at member
  rcases member with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> decide

theorem structuralRecord_A_valid (rest : String) :
    StructuralRecord (structuralRecord ("A " ++ rest)) := by
  constructor
  · simp [structuralRecord, structuralChars]

  constructor
  · simp [structuralRecord, structuralChars]
  constructor
  · simpa [structuralRecord] using structuralChars_no_newline ("A " ++ rest).toList
  · simp [structuralRecord, structuralChars]

private def structuralA (rest : String) : StructuralRow :=
  ⟨structuralRecord ("A " ++ rest), structuralRecord_A_valid rest⟩

/-- Within a session, every non-N structural record (including the writer's
`A` and `B` records) is skipped without advancing the answer position. -/
theorem normalizeTapeFrom_skips_structural (position : Nat) (records rest : List String)
    (structural : ∀ line ∈ records, StructuralRecord line) :
    normalizeTapeFrom position (records ++ rest) = normalizeTapeFrom position rest := by
  induction records with
  | nil => rfl
  | cons line records ih =>
      have lineStructural := structural line (by simp)
      have restStructural : ∀ item ∈ records, StructuralRecord item := by
        intro item member
        exact structural item (by simp [member])
      simp only [List.cons_append, normalizeTapeFrom]
      rw [if_neg lineStructural.2.1, if_neg lineStructural.1]
      exact ih restStructural

/-- A V header ends the current replay session: its payload and every record
after it are ignored.  Structural records before it are skipped normally. -/
theorem normalizeTapeFrom_stops_at_session (position : Nat) (before rest : List String)
    (header : String) (structural : ∀ line ∈ before, StructuralRecord line) :
    normalizeTapeFrom position (before ++ ("V " ++ header) :: rest) = [] := by
  rw [normalizeTapeFrom_skips_structural position before _ structural]
  simp [normalizeTapeFrom]

/-- One N record in precisely the form appended by `consumeAnswer` emits the
corresponding answer and advances the answer-sequence position once. -/
theorem normalizeTapeFrom_writerNRecord (position : Nat) (answer : WriterAnswer)
    (rest : List String) :
    normalizeTapeFrom position (writerNRecord answer :: rest) =
      .value position answer.name answer.value :: normalizeTapeFrom (position + 1) rest := by
  simp only [normalizeTapeFrom]
  have notV : ¬ (writerNRecord answer).startsWith "V " := by
    cases answer <;> simp [writerNRecord, writerNRecordValue]
  have startsN : (writerNRecord answer).startsWith "N " := by
    cases answer <;> simp [writerNRecord, writerNRecordValue]
  rw [if_neg notV, if_pos startsN]
  rw [writerNRecord_parts]
  simp only [String.ofList_toList]
  rw [parseNValue_writerNRecord_payload]
  cases answer <;> simp [WriterAnswer.name, WriterAnswer.value, k_tape_kinds]

/-- The evaluator writer's record layout: each structural prefix is followed
by the exact N record appended by `consumeAnswer`, then a structural tail. -/
def writerProducedRecords : List WriterChunk → List StructuralRow → List String
  | [], trailing => trailing.map fun row => row.val
  | chunk :: chunks, trailing =>
      chunk.structural.map (fun row => row.val) ++ writerNRecord chunk.answer ::
        writerProducedRecords chunks trailing

def writerAnswersFrom : Nat → List WriterChunk → List TapedAnswer
  | _, [] => []
  | position, chunk :: chunks =>
      .value position chunk.answer.name chunk.answer.value ::
        writerAnswersFrom (position + 1) chunks

/-- Whole-tape ANSWER lemma: normalization of the records produced by the
record-mode writer is exactly its answer sequence, in order, numbered from
the supplied starting position.  Interleaved structural records and the
structural tail contribute no answers. -/
theorem normalizeTapeFrom_writerProducedRecords (position : Nat)
    (chunks : List WriterChunk) (trailing : List StructuralRow) :
    normalizeTapeFrom position (writerProducedRecords chunks trailing) =
      writerAnswersFrom position chunks := by
  induction chunks generalizing position with
  | nil =>
      simp only [writerProducedRecords, writerAnswersFrom]
      have skipped := normalizeTapeFrom_skips_structural position
        (trailing.map fun row => row.val) [] (by
          intro line member
          simp only [List.mem_map] at member
          obtain ⟨row, _, rfl⟩ := member
          exact row.property)
      simpa [normalizeTapeFrom] using skipped
  | cons chunk chunks ih =>
      simp only [writerProducedRecords, writerAnswersFrom]
      rw [normalizeTapeFrom_skips_structural position (chunk.structural.map fun row => row.val) _ (by
        intro line member
        simp only [List.mem_map] at member
        obtain ⟨row, _, rfl⟩ := member
        exact row.property)]
      rw [normalizeTapeFrom_writerNRecord]
      rw [ih (position := position + 1)]

/-- At position zero, the whole writer tape normalizes to positions 0, 1, 2,
and so on. -/
theorem normalizeTape_writerProducedRecords (chunks : List WriterChunk)
    (trailing : List StructuralRow) :
    normalizeTape (writerProducedRecords chunks trailing) = writerAnswersFrom 0 chunks := by
  exact normalizeTapeFrom_writerProducedRecords 0 chunks trailing

/-- Any delayed normalization error retains the exact answer-sequence position
at which it will be raised.  In particular, skipped A/B records cannot move an
error earlier or later among the N answers. -/
theorem normalizeTape_error_position {tape : List String} {i p : Nat} {e : Err}
    (h : (normalizeTape tape)[i]? = some (.replayError p e)) : p = i := by
  -- `normalizeTapeFrom` increments its position exactly when it emits an
  -- element; this stronger accumulator invariant avoids reasoning about the
  -- irrelevant records which normalization skips.
  have invariant : ∀ (xs : List String) (start j q : Nat) (error : Err),
      (normalizeTapeFrom start xs)[j]? = some (.replayError q error) →
      q = start + j := by
    intro xs
    induction xs with
    | nil => simp [normalizeTapeFrom]
    | cons line rest ih =>
      intro start j q error found
      simp only [normalizeTapeFrom] at found
      split at found
      · simp at found
      · split at found
        · split at found
          · cases j with
            | zero => simp at found
            | succ j =>
              simp only [List.getElem?_cons_succ] at found
              have := ih (start + 1) j q error found
              omega
          · cases j with
            | zero => simp at found; omega
            | succ j =>
              simp only [List.getElem?_cons_succ] at found
              have := ih (start + 1) j q error found
              omega
        · exact ih start j q error found
  simpa [normalizeTape] using invariant tape 0 i p e h

private def oracleAnswers (oracle : List OracleValue) : List TapedAnswer :=
  oracle.zipIdx.map fun (value, position) => .value position "" value

theorem wellPositioned_oracleZipIdx (start : Nat) (oracle : List OracleValue) :
    WellPositioned start
      (oracle.zipIdx start |>.map fun (value, position) => .value position "" value) := by
  induction oracle generalizing start with
  | nil => trivial
  | cons value rest ih =>
      simp [List.zipIdx, WellPositioned, positionOf, ih]

/-- Oracle producers number their answers consecutively from zero. -/
theorem wellPositioned_oracleAnswers (oracle : List OracleValue) :
    WellPositioned 0 (oracleAnswers oracle) :=
  wellPositioned_oracleZipIdx 0 oracle

/-- Convert the value actually delivered to an `ask` continuation into the
single writer-answer representation used both by execution and the N encoder. -/
private def writerAnswerFor (fn : String) (raw : OracleValue) : Except Err WriterAnswer :=
  match fn, raw with
  | "random_int", .int n => pure (.randomInt n)
  | "env_get", .string s => pure (.envGet s)
  | "read_line", .string s => pure (.readLine s)
  | "read_line", .null => pure .readLineNull
  | _, _ => throw (.runtime s!"{fn}: oracle value has the wrong kind")

/-- Per-`ask` record invariant. Whenever a delivered value is accepted, the
writer chunk's N answer has exactly that call name and value; no independent
"value to record" exists which could diverge from the continuation's value. -/
theorem writerAnswerFor_roundtrip (fn : String) (raw : OracleValue)
    (answer : WriterAnswer) (accepted : writerAnswerFor fn raw = .ok answer) :
    answer.name = fn ∧ answer.value = raw := by
  unfold writerAnswerFor at accepted
  split at accepted <;> try contradiction
  all_goals
    change Except.ok _ = Except.ok answer at accepted
    injection accepted with same
    subst answer
    simp [WriterAnswer.name, WriterAnswer.value]

private def decodeSupplied (fn : String) (position : Nat) (supplied : TapedAnswer) : EvalM OracleValue :=
  match supplied with
  | TapedAnswer.oracleExhausted _ => throw (.runtime s!"{fn}: oracle exhausted at value {position}")
  | .replayError _ error => throw error
  | .replayExhausted _ => throw (.runtime s!"{fn}: replay stream 0 has no matching recorded N value")
  | .value _ recordedName value =>
    if !recordedName.isEmpty && recordedName != fn then
      throw (.replay s!"replay name mismatch: tape has '{recordedName}', program called '{fn}'")
    else pure value

private def liftAnswer (fn : String) (raw : OracleValue) : EvalM WriterAnswer :=
  writerAnswerFor fn raw

private def appendChunk (w : World) (answer : WriterAnswer) : EvalM Value := do
  let chunk : WriterChunk := {structural := w.writerTrailing, answer := answer}
  set {w with writerChunks := w.writerChunks ++ [chunk], writerTrailing := []}
  pure answer.runtimeValue

private def consumeRest (fn : String) (w : World) (supplied : TapedAnswer) : EvalM Value := do
  let position := w.writerChunks.length
  let raw ← decodeSupplied fn position supplied
  let answer ← liftAnswer fn raw
  appendChunk w answer

theorem decodeSupplied_oracleExhausted_run (fn : String) (position suppliedPosition : Nat) (w : World) :
    ((decodeSupplied fn position (.oracleExhausted suppliedPosition)).run).run w =
      .done (.error (.runtime s!"{fn}: oracle exhausted at value {position}"), w) := by rfl

theorem decodeSupplied_replayError_run (fn : String) (position suppliedPosition : Nat)
    (error : Err) (w : World) :
    ((decodeSupplied fn position (.replayError suppliedPosition error)).run).run w =
      .done (.error error, w) := by rfl

theorem decodeSupplied_replayExhausted_run (fn : String) (position suppliedPosition : Nat) (w : World) :
    ((decodeSupplied fn position (.replayExhausted suppliedPosition)).run).run w =
      .done (.error (.runtime s!"{fn}: replay stream 0 has no matching recorded N value"), w) := by rfl

theorem decodeSupplied_value_run (fn recordedName : String) (position suppliedPosition : Nat)
    (value : OracleValue) (w : World) :
    ((decodeSupplied fn position (.value suppliedPosition recordedName value)).run).run w =
      if !recordedName.isEmpty && recordedName != fn then
        .done (.error (.replay s!"replay name mismatch: tape has '{recordedName}', program called '{fn}'"), w)
      else .done (.ok value, w) := by
  change ((if !recordedName.isEmpty && recordedName != fn then
    throw (.replay s!"replay name mismatch: tape has '{recordedName}', program called '{fn}'")
    else pure value : EvalM OracleValue).run).run w = _
  split <;> rfl

theorem liftAnswer_run (fn : String) (raw : OracleValue) (w : World) :
    ((liftAnswer fn raw).run).run w =
      .done (writerAnswerFor fn raw, w) := by rfl

theorem appendChunk_run (w : World) (answer : WriterAnswer) (state : World) :
    ((appendChunk w answer).run).run state = .done (.ok answer.runtimeValue,
      {w with writerChunks := w.writerChunks ++
        [{structural := w.writerTrailing, answer := answer}], writerTrailing := []}) := by rfl

/-- The extracted post-ask tail is exactly the bind composition of its named stages. -/
theorem consumeRest_extraction (fn : String) (w : World) (supplied : TapedAnswer) :
    consumeRest fn w supplied = (do
      let raw ← decodeSupplied fn w.writerChunks.length supplied
      let answer ← liftAnswer fn raw
      appendChunk w answer) := by rfl

private def consumeAnswer (fn : String) : EvalM Value := do
  let w ← get
  let supplied : TapedAnswer ← liftM
    (Interaction.ask {name := fn} (fun answer => Interaction.done answer))
  consumeRest fn w supplied

/-- The complete operation asks once and delegates its continuation to the extracted tail. -/
theorem consumeAnswer_run (fn : String) (w : World) :
    ((consumeAnswer fn).run).run w =
      .ask {name := fn} (fun supplied => ((consumeRest fn w supplied).run).run w) := by
  rfl

/-- Oracle exhaustion is an error leaf and leaves the world unchanged. -/
theorem consumeRest_oracleExhausted_run (fn : String) (w : World) (position : Nat) :
    ((consumeRest fn w (.oracleExhausted position)).run).run w =
      .done (.error (.runtime s!"{fn}: oracle exhausted at value {w.writerChunks.length}"), w) := by rfl

/-- A stored replay parse error is propagated unchanged. -/
theorem consumeRest_replayError_run (fn : String) (w : World) (position : Nat) (error : Err) :
    ((consumeRest fn w (.replayError position error)).run).run w = .done (.error error, w) := by rfl

/-- Replay-stream exhaustion is an error leaf and leaves the world unchanged. -/
theorem consumeRest_replayExhausted_run (fn : String) (w : World) (position : Nat) :
    ((consumeRest fn w (.replayExhausted position)).run).run w =
      .done (.error (.runtime s!"{fn}: replay stream 0 has no matching recorded N value"), w) := by rfl

/-- A nonempty recorded name different from the call is rejected. -/
theorem consumeRest_nameMismatch_run (fn recordedName : String) (w : World)
    (position : Nat) (raw : OracleValue) (nonempty : recordedName.isEmpty = false)
    (different : recordedName ≠ fn) :
    ((consumeRest fn w (.value position recordedName raw)).run).run w =
      .done (.error (.replay s!"replay name mismatch: tape has '{recordedName}', program called '{fn}'"), w) := by
  unfold consumeRest
  simp only [decodeSupplied, nonempty, Bool.not_false, Bool.true_and, bne_iff_ne]
  rw [if_pos different]
  rfl

/-- An empty record name is the live/record wildcard; accepted values append exactly one chunk. -/
theorem consumeRest_emptyName_run (fn : String) (w : World) (position : Nat)
    (raw : OracleValue) (answer : WriterAnswer) (accepted : writerAnswerFor fn raw = .ok answer) :
    ((consumeRest fn w (.value position "" raw)).run).run w =
      .done (.ok answer.runtimeValue, {w with writerChunks := w.writerChunks ++
        [{structural := w.writerTrailing, answer := answer}], writerTrailing := []}) := by
  unfold consumeRest
  unfold writerAnswerFor at accepted
  split at accepted <;> try contradiction
  all_goals
    injection accepted with same
    subst answer
    rfl

/-- A matching record name is accepted and appends exactly one chunk. -/
theorem consumeRest_matchingName_run (fn : String) (w : World) (position : Nat)
    (raw : OracleValue) (answer : WriterAnswer) (accepted : writerAnswerFor fn raw = .ok answer) :
    ((consumeRest fn w (.value position fn raw)).run).run w =
      .done (.ok answer.runtimeValue, {w with writerChunks := w.writerChunks ++
        [{structural := w.writerTrailing, answer := answer}], writerTrailing := []}) := by
  unfold consumeRest
  unfold writerAnswerFor at accepted
  split at accepted <;> try contradiction
  all_goals
    injection accepted with same
    subst answer
    rfl

/-- A value whose kind is rejected by the named taped builtin propagates that
error without changing the world.  The calculation deliberately exposes both
evaluator binds rather than simplifying the raw `do` block. -/
theorem consumeRest_rejected_run (fn name : String) (w : World) (position : Nat)
    (raw : OracleValue) (error : Err)
    (nameOk : ¬ ((!name.isEmpty && name != fn) = true))
    (rejected : writerAnswerFor fn raw = .error error) :
    evalRun (consumeRest fn w (.value position name raw)) w =
      .done (.error error, w) := by
  have hdec : evalRun
      (decodeSupplied fn w.writerChunks.length (.value position name raw)) w =
      .done (.ok raw, w) := by
    rw [evalRun_eq, decodeSupplied_value_run, if_neg nameOk]
  calc
    evalRun (consumeRest fn w (.value position name raw)) w =
        evalRun (decodeSupplied fn w.writerChunks.length (.value position name raw) >>= fun r =>
          (liftAnswer fn r >>= fun a => appendChunk w a)) w := by
            exact congrArg (evalRun · w) (consumeRest_extraction _ _ _)
    _ = Interaction.bind
          (evalRun (decodeSupplied fn w.writerChunks.length (.value position name raw)) w) _ :=
            evalRun_bind _ _ _
    _ = evalRun (liftAnswer fn raw >>= fun a => appendChunk w a) w := by
          rw [hdec]
          rfl
    _ = Interaction.bind (evalRun (liftAnswer fn raw) w) _ := evalRun_bind _ _ _
    _ = .done (.error error, w) := by
          rw [evalRun_eq, liftAnswer_run, rejected]
          rfl

/-- Live and record modes consume the supplied oracle exactly once per taped
call.  Exhaustion is a runtime error, rather than a fabricated default: this
keeps completed record runs honest and lets the N values of any successful
strict replay serve directly as the witness oracle for replay fidelity. -/
private def tapedCall (fn : String) : EvalM Value := do
  consumeAnswer fn
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
  set {w with environments:=environments, writerTrailing:=w.writerTrailing ++
    [structuralA s!"0 {name}={tapeValue v}"]}

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

/-- Restore the caller frame after a function body, preserving either its
return value or its error.  Naming this non-recursive suffix keeps its
structure available to proofs about the well-founded evaluator. -/
def callSuffix (m : EvalM (Option Value)) : EvalM Value := do
  let outcome : Except Err Value ← try
    let returned ← m
    pure (Except.ok (returned.getD .null))
  catch error => pure (Except.error error)
  modify fun w => {w with frames := w.frames.pop}
  match outcome with
  | .ok value => pure value
  | .error error => throw error

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
    callSuffix (exec f definition.body)
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
  answersConsumed : List TapedAnswer := []
  error : Option Err := none
  deriving Repr, BEq

inductive CoreModeTag where | live | record | replayStrict deriving Repr, BEq
structure CorePolicy where
  modeTag : CoreModeTag
  emitAnswers : Bool

structure CoreResult where
  stdout : String
  assignments : List String
  answersConsumed : List TapedAnswer
  error : Option Err
  deriving Repr, BEq

private def isAnswerRecord (line : String) : Bool := line.startsWith "N "
private def isAssignmentRecord (line : String) : Bool := line.startsWith "A "

/-- Result of interpreting a finite interaction tree.  `consumed` counts the
supplied entries selected by `ask` nodes, including an explicitly supplied
error entry when that is what stops evaluation. -/
structure Interpretation (α : Type) where
  value : α
  consumed : Nat
  /-- The answers actually passed to `ask` continuations.  In particular,
  record-oracle wildcards are completed with the query name here. -/
  answers : List TapedAnswer
  deriving Repr, BEq

/-- Interpret explicit taped interactions against a supplied answer list. -/
def interpret : Interaction α → List TapedAnswer → Interpretation α
  | .done value, _ => {value := value, consumed := 0, answers := []}
  | .ask query continuation, [] =>
      let answer := deliveredAnswer query (.oracleExhausted 0)
      let result := interpret (continuation answer) []
      {result with consumed := 0}
  | .ask query continuation, answer :: rest =>
      let answer := deliveredAnswer query answer
      let result := interpret (continuation answer) rest
      {value := result.value, consumed := result.consumed + 1,
        answers := answer :: result.answers}

/-- With no supplied entries, the outermost exhausted interaction keeps the
consumption count at zero. -/
theorem interpret_nil_consumed (tree : Interaction α) :
    (interpret tree []).consumed = 0 := by
  cases tree <;> rfl

/-- Interpretation records exactly one delivered answer per consumed entry; an
exhausted ask records and consumes nothing. -/
theorem interpret_answers_length (tree : Interaction α) (supplied : List TapedAnswer) :
    (interpret tree supplied).answers.length = (interpret tree supplied).consumed := by
  induction tree generalizing supplied with
  | done value => rfl
  | ask query continuation ih =>
      cases supplied with
      | nil =>
          simp only [interpret]
          rw [ih (deliveredAnswer query (.oracleExhausted 0)) []]
          exact interpret_nil_consumed _
      | cons answer rest =>
          simp only [interpret, List.length_cons]
          rw [ih (deliveredAnswer query answer) rest]

/-- An interpretation cannot consume more entries than it was supplied. -/
theorem interpret_consumed_le (tree : Interaction α) (supplied : List TapedAnswer) :
    (interpret tree supplied).consumed ≤ supplied.length := by
  induction tree generalizing supplied with
  | done value => simp [interpret]
  | ask query continuation ih =>
      cases supplied with
      | nil => simp [interpret]
      | cons answer rest =>
          simp only [interpret, List.length_cons]
          have bounded := ih (deliveredAnswer query answer) rest
          omega

/-- If every delivered answer is a value, interpretation stopped before the
first explicit oracle-exhaustion guard. -/
theorem interpret_consumed_before_oracleExhausted (tree : Interaction α)
    (entries : List TapedAnswer) (first second : Nat)
    (onlyValues : ∀ answer ∈
      (interpret tree (entries ++ [.oracleExhausted first,
        .oracleExhausted second])).answers,
      ∃ p name value, answer = .value p name value) :
    (interpret tree (entries ++ [.oracleExhausted first,
      .oracleExhausted second])).consumed ≤ entries.length := by
  induction tree generalizing entries with
  | done value => simp [interpret]
  | ask query continuation ih =>
      cases entries with
      | nil =>
          have impossible := onlyValues (.oracleExhausted first) (by simp [interpret, deliveredAnswer])
          rcases impossible with ⟨p, name, value, contradiction⟩
          cases contradiction
      | cons answer rest =>
          simp only [List.cons_append, interpret, List.length_cons]
          have childValues : ∀ child ∈
              (interpret (continuation (deliveredAnswer query answer))
                (rest ++ [.oracleExhausted first, .oracleExhausted second])).answers,
              ∃ p name value, child = .value p name value := by
            intro child member
            apply onlyValues child
            simp [interpret, member]
          have bounded := ih (deliveredAnswer query answer) rest childValues
          omega

/-- Interpreting a bound interaction concatenates the answers observed by
its two phases.  The second phase receives precisely the supplied suffix not
consumed by the first. -/
theorem interpret_bind (tree : Interaction α) (next : α → Interaction β)
    (supplied : List TapedAnswer) :
    let first := interpret tree supplied
    let second := interpret (next first.value) (supplied.drop first.consumed)
    interpret (Interaction.bind tree next) supplied =
      { value := second.value
        consumed := first.consumed + second.consumed
        answers := first.answers ++ second.answers } := by
  induction tree generalizing supplied with
  | done value => simp [Interaction.bind, interpret]
  | ask query continuation ih =>
      cases supplied with
      | nil =>
          simp only [Interaction.bind, interpret]
          rw [ih (deliveredAnswer query (.oracleExhausted 0)) []]
          simp [interpret_nil_consumed]
      | cons answer rest =>
          simp only [Interaction.bind, interpret]
          rw [ih (deliveredAnswer query answer) rest]
          simp [List.drop_succ_cons, Nat.add_assoc, List.cons_append]
          omega

/-- Mapping the successful leaf of an interaction changes only its value;
consumption and the delivered-answer trace are preserved. -/
theorem interpret_map (tree : Interaction α) (f : α → β)
    (supplied : List TapedAnswer) :
    interpret (tree.bind (fun value => .done (f value))) supplied =
      { value := f (interpret tree supplied).value
        consumed := (interpret tree supplied).consumed
        answers := (interpret tree supplied).answers } := by
  induction tree generalizing supplied with
  | done value => rfl
  | ask query continuation ih =>
      cases supplied with
      | nil =>
          simp only [Interaction.bind, interpret]
          rw [ih (deliveredAnswer query (.oracleExhausted 0)) []]
      | cons answer rest =>
          simp only [Interaction.bind, interpret]
          rw [ih (deliveredAnswer query answer) rest]

/-- Every value answer on the path actually traversed by `interpret` carries
the name of the query to which it was delivered.  Exhaustion and stored-error
answers have no name to compare, but their continuation path is still
checked. -/
def NamesAligned : Interaction α → List TapedAnswer → Prop
  | .done _, _ => True
  | .ask query continuation, [] =>
      let delivered := deliveredAnswer query (.oracleExhausted 0)
      NamesAligned (continuation delivered) []
  | .ask query continuation, answer :: rest =>
      let delivered := deliveredAnswer query answer
      (match delivered with
        | .value _ name _ => name = query.name
        | _ => True) ∧
      NamesAligned (continuation delivered) rest

/-- A computation is aligned when every successful interpretation follows a
name-aligned interaction path. -/
def Aligned (m : EvalM α) : Prop :=
  ∀ (world : World) (supplied : List TapedAnswer) (value : α),
    (interpret (evalRun m world) supplied).value.1 = .ok value →
    NamesAligned (evalRun m world) supplied

/-- A silent computation has no asks, hence is name-aligned. -/
theorem NamesAligned_of_silent (m : EvalM α) (r : World → Except Err α)
    (f : World → World)
    (runs : ∀ world, evalRun m world = .done (r world, f world)) : Aligned m := by
  intro world supplied value successful
  rw [runs]
  trivial

/-- A computation is paired when every successful interpretation preserves
the starting writer chunks as a prefix and its appended chunks encode exactly
the interaction answers, numbered from that prefix length.

EigenCore-0 has no user-level catch.  Its only catch is `callFunction`'s frame
pop, which re-throws the captured error; thus successful runs cannot discard an
error path that consumed an answer. -/
def Paired (m : EvalM α) : Prop :=
  ∀ (w0 : World) (supplied : List TapedAnswer),
    WellPositioned w0.writerChunks.length supplied →
    let interpreted := interpret ((m.run).run w0) supplied
    ∀ value, interpreted.value.1 = .ok value →
      ∃ appended,
        interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
        interpreted.answers = writerAnswersFrom w0.writerChunks.length appended

/-- Pairing specialized to one fixed starting world.  This is the useful
granularity for computations which save that world and later restore a record
update based on precisely the saved value. -/
def PairedAt (w0 : World) (m : EvalM α) : Prop :=
  ∀ (supplied : List TapedAnswer),
    WellPositioned w0.writerChunks.length supplied →
    let interpreted := interpret ((m.run).run w0) supplied
    ∀ value, interpreted.value.1 = .ok value →
      ∃ appended,
        interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
        interpreted.answers = writerAnswersFrom w0.writerChunks.length appended

theorem Paired_iff_PairedAt (m : EvalM α) :
    Paired m ↔ ∀ w0, PairedAt w0 m := Iff.rfl

theorem PairedAt_of_Paired (paired : Paired m) (w0 : World) : PairedAt w0 m :=
  paired w0

/-- Reading the fixed initial world before continuing is definitionally the
same run as starting that continuation at the fixed world. -/
theorem PairedAt_get_bind (w0 : World) (k : World → EvalM α)
    (paired : PairedAt w0 (k w0)) : PairedAt w0 (get >>= k) := by
  intro supplied positioned
  change let interpreted := interpret (evalRun (get >>= k) w0) supplied
    ∀ value, interpreted.value.1 = .ok value → ∃ appended,
      interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
      interpreted.answers = writerAnswersFrom w0.writerChunks.length appended
  rw [evalRun_bind, evalRun_get]
  exact paired supplied positioned

/-- A successful, interaction-free prefix can be composed at a fixed world
when it preserves completed writer chunks. -/
theorem PairedAt_silent_bind (w0 w1 : World) (s : EvalM α) (x : α)
    (k : α → EvalM β) (runs : evalRun s w0 = .done (.ok x, w1))
    (preserves : w1.writerChunks = w0.writerChunks)
    (paired : PairedAt w1 (k x)) : PairedAt w0 (s >>= k) := by
  intro supplied positioned
  change let interpreted := interpret (evalRun (s >>= k) w0) supplied
    ∀ value, interpreted.value.1 = .ok value → ∃ appended,
      interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
      interpreted.answers = writerAnswersFrom w0.writerChunks.length appended
  rw [evalRun_bind, runs]
  simp only [Interaction.bind]
  have positioned' : WellPositioned w1.writerChunks.length supplied := by
    simpa [preserves] using positioned
  intro value successful
  obtain ⟨appended, world, answers⟩ := paired supplied positioned' value successful
  refine ⟨appended, ?_, ?_⟩
  · change (interpret (((k x).run).run w1) supplied).value.2.writerChunks =
      w0.writerChunks ++ appended
    simpa [preserves] using world
  · change (interpret (((k x).run).run w1) supplied).answers =
      writerAnswersFrom w0.writerChunks.length appended
    simpa [preserves] using answers

/-- An interaction-free prefix which throws makes fixed-world pairing
vacuous, because bind cannot turn that error into success. -/
theorem PairedAt_silent_bind_error (w0 w1 : World) (s : EvalM α) (error : Err)
    (k : α → EvalM β) (runs : evalRun s w0 = .done (.error error, w1)) :
    PairedAt w0 (s >>= k) := by
  intro supplied positioned
  change let interpreted := interpret (evalRun (s >>= k) w0) supplied
    ∀ value, interpreted.value.1 = .ok value → ∃ appended,
      interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
      interpreted.answers = writerAnswersFrom w0.writerChunks.length appended
  rw [evalRun_bind, runs]
  simp only [Interaction.bind, interpret]
  intro value successful
  contradiction

/-- Any computation which is silent for every initial world and preserves
writer chunks is paired.  In particular, interpreting its completed tree
consumes no supplied answers, so the appended chunk witness is empty. -/
theorem Paired_of_silent (m : EvalM α) (r : World → Except Err α) (f : World → World)
    (runs : ∀ world, evalRun m world = .done (r world, f world))
    (preserves : ∀ world, (f world).writerChunks = world.writerChunks) : Paired m := by
  intro w0 supplied positioned
  change let interpreted := interpret (evalRun m w0) supplied
    ∀ value, interpreted.value.1 = .ok value → ∃ appended,
      interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
      interpreted.answers = writerAnswersFrom w0.writerChunks.length appended
  rw [runs]
  dsimp only [interpret]
  intro value successful
  refine ⟨[], ?_, ?_⟩
  · simpa using preserves w0
  · rfl

/-- Variable lookup is silent: resolution either returns a value or throws,
and both leaves leave the world unchanged. -/
theorem Paired_valueAt (name : String) : Paired (valueAt name) := by
  apply Paired_of_silent (valueAt name)
    (fun world => match resolve name world with
      | some binding => .ok world.environments[binding.envId]!.slots[binding.slot]!.value
      | none => .error (Err.runtime s!"undefined variable: {name}"))
    id
  · intro world
    unfold valueAt
    rw [evalRun_bind, evalRun_get]
    simp only [Interaction.bind]
    split <;> rfl
  · intro world
    rfl

/-- Variable lookup performs no taped interaction. -/
theorem NamesAligned_valueAt (name : String) : Aligned (valueAt name) := by
  apply NamesAligned_of_silent (valueAt name)
    (fun world => match resolve name world with
      | some binding => .ok world.environments[binding.envId]!.slots[binding.slot]!.value
      | none => .error (Err.runtime s!"undefined variable: {name}")) id
  intro world
  unfold valueAt
  rw [evalRun_bind, evalRun_get]
  simp only [Interaction.bind]
  split <;> rfl

/-- Creating a parameter is silent and changes only its environment slots. -/
theorem Paired_bindParameter (environment : Nat) (name : String) (value : Value) :
    Paired (bindParameter environment name value) := by
  apply Paired_of_silent (bindParameter environment name value) (fun _ => .ok ())
    (fun world => {world with environments := world.environments.modify environment fun env =>
      {env with slots := env.slots.push {name:=name, value:=value, history:=#[value], assignments:=1}}})
  · intro world
    unfold bindParameter
    rw [evalRun_modify]
  · intro world
    rfl

/-- Parameter binding performs no taped interaction. -/
theorem NamesAligned_bindParameter (environment : Nat) (name : String) (value : Value) :
    Aligned (bindParameter environment name value) := by
  apply NamesAligned_of_silent (bindParameter environment name value) (fun _ => .ok ())
    (fun world => {world with environments := world.environments.modify environment fun env =>
      {env with slots := env.slots.push {name:=name, value:=value, history:=#[value], assignments:=1}}})
  intro world
  unfold bindParameter
  rw [evalRun_modify]

/-- Storing a variable appends a structural `A` row to `writerTrailing`, but
never appends a completed `writerChunks` entry, so it is silent for pairing. -/
theorem Paired_store (name : String) (value : Value) (isLocal : Bool) :
    Paired (store name value isLocal) := by
  apply Paired_of_silent (store name value isLocal) (fun _ => .ok ())
    (fun world =>
      let current := currentEnvironment world
      let found := if isLocal then
          findCell name world.environments[current]!.slots |>.map
            ({envId := current, slot := ·})
        else resolve name world
      let environments := (match found with
        | some binding => world.environments.modify binding.envId fun environment =>
            {environment with slots := environment.slots.modify binding.slot fun c =>
              {c with value:=value, history:=(c.history.push value).extract ((c.history.size+1).sub 256) (c.history.size+1), assignments:=c.assignments+1}}
        | none => world.environments.modify current fun environment =>
            {environment with slots := environment.slots.push {name:=name,value:=value,history:=#[value],assignments:=1}})
      {world with environments:=environments, writerTrailing:=world.writerTrailing ++
          [structuralA s!"0 {name}={tapeValue value}"]})
  · intro world
    unfold store
    rw [evalRun_bind, evalRun_get]
    rfl
  · intro world
    rfl

/-- Variable storage is silent with respect to taped interactions. -/
theorem NamesAligned_store (name : String) (value : Value) (isLocal : Bool) :
    Aligned (store name value isLocal) := by
  intro world supplied result successful
  unfold store
  rw [evalRun_bind, evalRun_get]
  trivial

/-- The anonymous stdout write used by both print forms is silent for tape
pairing: it changes `stdout`, not completed writer chunks. -/
theorem Paired_printModify (value : Value) :
    Paired (modify fun world => {world with stdout := world.stdout ++ value.print ++ "\n"}) := by
  apply Paired_of_silent _ (fun _ => .ok ())
    (fun world => {world with stdout := world.stdout ++ value.print ++ "\n"})
  · intro world
    rw [evalRun_modify]
  · intro world
    rfl

/-- Printing performs no taped interaction. -/
theorem NamesAligned_printModify (value : Value) :
    Aligned (modify fun world => {world with stdout := world.stdout ++ value.print ++ "\n"}) := by
  intro world supplied result successful
  rw [evalRun_modify]
  trivial

/-- The anonymous function-table write used by `define` is silent. -/
theorem Paired_defineModify (definition : FunctionDef) :
    Paired (modify fun world => {world with functions := world.functions.push definition}) := by
  apply Paired_of_silent _ (fun _ => .ok ())
    (fun world => {world with functions := world.functions.push definition})
  · intro world
    rw [evalRun_modify]
  · intro world
    rfl

/-- Installing a function definition performs no taped interaction. -/
theorem NamesAligned_defineModify (definition : FunctionDef) :
    Aligned (modify fun world => {world with functions := world.functions.push definition}) := by
  intro world supplied result successful
  rw [evalRun_modify]
  trivial

/-- Reading the pre-call world and installing its new environment and frame is
one silent computation.  The update also advances `nextFrameSerial`, but does
not touch completed writer chunks. -/
theorem Paired_callFrameSetup (parent : Option Nat) : Paired (do
    let before ← get
    let environment := before.environments.size
    let frame : Frame := {serial := before.nextFrameSerial, environment := environment}
    set {before with
      environments := before.environments.push
        {id := environment, parent := parent}
      frames := before.frames.push frame
      nextFrameSerial := before.nextFrameSerial + 1}) := by
  apply Paired_of_silent _ (fun _ => .ok ())
    (fun before =>
      let environment := before.environments.size
      let frame : Frame := {serial := before.nextFrameSerial, environment := environment}
      {before with
        environments := before.environments.push {id := environment, parent := parent}
        frames := before.frames.push frame
        nextFrameSerial := before.nextFrameSerial + 1})
  · intro world
    rw [evalRun_bind, evalRun_get]
    rfl
  · intro world
    rfl

/-- Entering a call frame performs no taped interaction. -/
theorem NamesAligned_callFrameSetup (parent : Option Nat) : Aligned (do
    let before ← get
    let environment := before.environments.size
    let frame : Frame := {serial := before.nextFrameSerial, environment := environment}
    set {before with
      environments := before.environments.push {id := environment, parent := parent}
      frames := before.frames.push frame
      nextFrameSerial := before.nextFrameSerial + 1}) := by
  intro world supplied result successful
  rw [evalRun_bind, evalRun_get]
  trivial

/-- One successful taped builtin call consumes one positioned answer and
appends the one corresponding writer chunk.  All other leaves are errors and
therefore cannot satisfy `Paired`'s successful-result premise. -/
theorem Paired_consumeAnswer (fn : String) : Paired (consumeAnswer fn) := by
  intro w0 supplied hwp
  rw [consumeAnswer_run]
  cases supplied with
  | nil =>
      dsimp only [interpret, deliveredAnswer]
      intro value successful
      rw [consumeRest_oracleExhausted_run] at successful
      contradiction
  | cons supplied rest =>
      cases supplied with
      | oracleExhausted position =>
          dsimp only [interpret, deliveredAnswer]
          intro value successful
          rw [consumeRest_oracleExhausted_run] at successful
          contradiction
      | replayError position error =>
          dsimp only [interpret, deliveredAnswer]
          intro value successful
          rw [consumeRest_replayError_run] at successful
          contradiction
      | replayExhausted position =>
          dsimp only [interpret, deliveredAnswer]
          intro value successful
          rw [consumeRest_replayExhausted_run] at successful
          contradiction
      | value position name raw =>
          dsimp only [interpret, deliveredAnswer]
          intro value successful
          let deliveredName := if name.isEmpty then fn else name
          change (interpret
            (evalRun (consumeRest fn w0 (.value position deliveredName raw)) w0) rest).value.1 =
              .ok value at successful
          change ∃ appended,
            (interpret (evalRun (consumeRest fn w0 (.value position deliveredName raw)) w0)
              rest).value.2.writerChunks = w0.writerChunks ++ appended ∧
            .value position deliveredName raw ::
              (interpret (evalRun (consumeRest fn w0 (.value position deliveredName raw)) w0)
                rest).answers = writerAnswersFrom w0.writerChunks.length appended
          by_cases mismatch : ((!deliveredName.isEmpty && deliveredName != fn) = true)
          · have parts : deliveredName.isEmpty = false ∧ deliveredName ≠ fn := by
              simpa using mismatch
            rw [evalRun_eq, consumeRest_nameMismatch_run fn deliveredName w0 position raw
              parts.1 parts.2] at successful
            contradiction
          · cases accepted : writerAnswerFor fn raw with
            | error error =>
                rw [consumeRest_rejected_run fn deliveredName w0 position raw error mismatch accepted]
                  at successful
                contradiction
            | ok answer =>
                have deliveredMatches : deliveredName = fn := by
                  by_cases nameEmpty : name.isEmpty = true
                  · simp [deliveredName, nameEmpty]
                  · have deliveredDef : deliveredName = name := by
                      simp [deliveredName, nameEmpty]
                    rw [deliveredDef] at mismatch ⊢
                    apply Classical.byContradiction
                    intro different
                    apply mismatch
                    simp [nameEmpty, different]
                rw [deliveredMatches] at successful ⊢
                rw [evalRun_eq, consumeRest_matchingName_run fn w0 position raw answer accepted]
                  at successful ⊢
                change Except.ok answer.runtimeValue = Except.ok value at successful
                injection successful with same
                subst value
                let chunk : WriterChunk :=
                  {structural := w0.writerTrailing, answer := answer}
                refine ⟨[chunk], ?_, ?_⟩
                · rfl
                · have positionEq : position = w0.writerChunks.length := hwp.1
                  have roundtrip := writerAnswerFor_roundtrip fn raw answer accepted
                  rw [positionEq, writerAnswersFrom]
                  rw [roundtrip.1, roundtrip.2]
                  rfl

/-- `consumeAnswer` is the semantic source of name alignment: wildcard names
are filled by delivery, while a nonempty different name is an error leaf. -/
theorem NamesAligned_consumeAnswer (fn : String) : Aligned (consumeAnswer fn) := by
  intro world supplied value successful
  rw [evalRun_eq, consumeAnswer_run]
  cases supplied with
  | nil =>
      simp [NamesAligned, deliveredAnswer, evalRun_eq, consumeRest_oracleExhausted_run]
  | cons answer rest =>
      cases answer with
      | oracleExhausted position =>
          simp [NamesAligned, deliveredAnswer, consumeRest_oracleExhausted_run]
      | replayError position error =>
          simp [NamesAligned, deliveredAnswer, consumeRest_replayError_run]
      | replayExhausted position =>
          simp [NamesAligned, deliveredAnswer, consumeRest_replayExhausted_run]
      | value position name raw =>
          by_cases empty : name.isEmpty
          · simp only [NamesAligned, deliveredAnswer, empty, if_true, true_and]
            cases accepted : writerAnswerFor fn raw with
            | error error =>
                change NamesAligned (evalRun (consumeRest fn world (.value position fn raw)) world) rest
                rw [consumeRest_rejected_run fn fn world position raw error
                  (by simp) accepted]
                trivial
            | ok answer =>
                change NamesAligned (evalRun (consumeRest fn world (.value position fn raw)) world) rest
                rw [evalRun_eq, consumeRest_matchingName_run fn world position raw answer accepted]
                trivial
          · by_cases same : name = fn
            · subst name
              simp only [NamesAligned, deliveredAnswer, ite_self, true_and]
              cases accepted : writerAnswerFor fn raw with
              | error error =>
                  change NamesAligned (evalRun (consumeRest fn world (.value position fn raw)) world) rest
                  rw [consumeRest_rejected_run fn fn world position raw error
                    (by simp) accepted]
                  trivial
              | ok answer =>
                  change NamesAligned (evalRun (consumeRest fn world (.value position fn raw)) world) rest
                  rw [evalRun_eq, consumeRest_matchingName_run fn world position raw answer accepted]
                  trivial
            · have nonempty : name.isEmpty = false := by
                cases found : name.isEmpty with
                | false => rfl
                | true => exact False.elim (empty found)
              have impossible :
                Except.error (Err.replay s!"replay name mismatch: tape has '{name}', program called '{fn}'") =
                    Except.ok value := calc
                  Except.error (Err.replay s!"replay name mismatch: tape has '{name}', program called '{fn}'") =
                    (interpret (evalRun (consumeAnswer fn) world)
                      (.value position name raw :: rest)).value.1 := by
                      rw [evalRun_eq, consumeAnswer_run]
                      simp only [interpret, deliveredAnswer, empty, if_false]
                      simp only [Bool.false_eq_true, if_false]
                      rw [consumeRest_nameMismatch_run fn name world position raw nonempty same]
                      rfl
                  _ = .ok value := successful
              contradiction

/-- `tapedCall` is exactly the single-answer interaction boundary. -/
theorem Paired_tapedCall (fn : String) : Paired (tapedCall fn) := by
  unfold tapedCall
  exact Paired_consumeAnswer fn

/-- A pure computation neither changes writer chunks nor observes answers. -/
theorem Paired_pure (value : α) : Paired (pure value : EvalM α) := by
  intro w0 supplied
  intro positioned
  dsimp
  intro result successful
  change Except.ok value = Except.ok result at successful
  injection successful with same
  subst result
  refine ⟨[], ?_, ?_⟩
  · change w0.writerChunks = w0.writerChunks ++ []
    simp
  · change [] = writerAnswersFrom w0.writerChunks.length []
    rfl

/-- A thrown error cannot have a successful interpretation. -/
theorem Paired_throw (error : Err) : Paired (throw error : EvalM α) := by
  intro w0 supplied
  intro positioned
  dsimp
  intro value successful
  change Except.error error = Except.ok value at successful
  contradiction

/-- Reading the world preserves chunks and performs no interaction. -/
theorem Paired_get : Paired (get : EvalM World) := by
  intro w0 supplied
  intro positioned
  dsimp
  intro value successful
  change Except.ok w0 = Except.ok value at successful
  injection successful with same
  subst value
  refine ⟨[], ?_, ?_⟩
  · change w0.writerChunks = w0.writerChunks ++ []
    simp
  · change [] = writerAnswersFrom w0.writerChunks.length []
    rfl

/-- `writerAnswersFrom` emits one model answer for each writer chunk. -/
theorem writerAnswersFrom_length (position : Nat) (chunks : List WriterChunk) :
    (writerAnswersFrom position chunks).length = chunks.length := by
  induction chunks generalizing position with
  | nil => rfl
  | cons chunk chunks ih =>
      simp [writerAnswersFrom, ih]

/-- Writer answer projections contain only ordinary value answers. -/
theorem writerAnswersFrom_isValue (position : Nat) (chunks : List WriterChunk) :
    ∀ answer ∈ writerAnswersFrom position chunks,
      ∃ p name value, answer = .value p name value := by
  induction chunks generalizing position with
  | nil => simp [writerAnswersFrom]
  | cons chunk chunks ih =>
      intro answer member
      simp only [writerAnswersFrom, List.mem_cons] at member
      rcases member with rfl | member
      · cases chunk.answer <;> simp
      · exact ih (position + 1) answer member

/-- Numbering writer answers across appended chunk lists advances by the
length of the first list. -/
theorem writerAnswersFrom_append (position : Nat) (first second : List WriterChunk) :
    writerAnswersFrom position (first ++ second) =
      writerAnswersFrom position first ++ writerAnswersFrom (position + first.length) second := by
  induction first generalizing position with
  | nil => simp [writerAnswersFrom]
  | cons chunk chunks ih =>
      simp only [List.cons_append, writerAnswersFrom, List.length_cons, List.append_assoc,
        List.cons_append]
      rw [ih]
      congr 1
      simp [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm]

/-- Pairing is compositional for the concrete `ExceptT`/`StateT` evaluator
bind. -/
theorem Paired_bind (m : EvalM α) (k : α → EvalM β) (pairedM : Paired m)
    (pairedK : ∀ value, Paired (k value)) : Paired (m >>= k) := by
  intro w0 supplied
  intro positioned
  dsimp
  intro result successful
  let first := interpret ((m.run).run w0) supplied
  let secondTree := fun pair : Except Err α × World =>
    (ExceptT.bindCont k pair.1).run pair.2
  have composed := interpret_bind (((m.run).run w0)) secondTree supplied
  change (interpret (Interaction.bind ((m.run).run w0) secondTree) supplied).value.1 =
    .ok result at successful
  change ∃ appended,
    (interpret (Interaction.bind ((m.run).run w0) secondTree) supplied).value.2.writerChunks =
      w0.writerChunks ++ appended ∧
    (interpret (Interaction.bind ((m.run).run w0) secondTree) supplied).answers =
      writerAnswersFrom w0.writerChunks.length appended
  rw [composed] at successful ⊢
  dsimp only [secondTree] at successful ⊢
  cases firstValue : first.value.1 with
  | error error =>
      rw [firstValue] at successful
      change Except.error error = Except.ok result at successful
      contradiction
  | ok value =>
      rw [firstValue] at successful
      have bindContOk : ExceptT.bindCont k (Except.ok value) = k value := rfl
      rw [bindContOk] at successful ⊢
      change (interpret (((k value).run).run first.value.2)
        (supplied.drop first.consumed)).value.1 = .ok result at successful
      change ∃ appended,
        (interpret (((k value).run).run first.value.2)
          (supplied.drop first.consumed)).value.2.writerChunks = w0.writerChunks ++ appended ∧
        first.answers ++ (interpret (((k value).run).run first.value.2)
          (supplied.drop first.consumed)).answers =
            writerAnswersFrom w0.writerChunks.length appended
      have firstPaired := pairedM w0 supplied positioned value firstValue
      obtain ⟨firstChunks, firstWorld, firstAnswers⟩ := firstPaired
      let remaining := supplied.drop first.consumed
      have remainingPositioned : WellPositioned first.value.2.writerChunks.length remaining := by
        have dropped := positioned.drop first.consumed
        have lengths := congrArg List.length firstWorld
        have answerCount := interpret_answers_length ((m.run).run w0) supplied
        change first.answers.length = first.consumed at answerCount
        simp at lengths
        have chunkCount : firstChunks.length = first.consumed := by
          rw [firstAnswers, writerAnswersFrom_length] at answerCount
          exact answerCount
        have indexEqual : first.value.2.writerChunks.length =
            w0.writerChunks.length + first.consumed := by
          calc
            _ = (w0.writerChunks ++ firstChunks).length := congrArg List.length firstWorld
            _ = w0.writerChunks.length + firstChunks.length := by simp
            _ = w0.writerChunks.length + first.consumed := by rw [chunkCount]
        rw [indexEqual]
        simpa [remaining] using dropped
      have secondPaired := pairedK value first.value.2 remaining remainingPositioned result successful
      obtain ⟨secondChunks, secondWorld, secondAnswers⟩ := secondPaired
      refine ⟨firstChunks ++ secondChunks, ?_, ?_⟩
      · rw [secondWorld, firstWorld, List.append_assoc]
      · rw [firstAnswers, secondAnswers, writerAnswersFrom_append]
        congr 2
        have lengths := congrArg List.length firstWorld
        simp at lengths
        omega

/-- Pairing follows either branch of a pure conditional. -/
theorem Paired_ite (condition : Bool) (yes no : EvalM α)
    (pairedYes : Paired yes) (pairedNo : Paired no) :
    Paired (if condition then yes else no) := by
  cases condition <;> assumption

/-- `List.mapM` preserves pairing without requiring a `LawfulMonad` instance.
The worker lemma follows the core accumulator implementation and is therefore
generalised over that accumulator. -/
theorem Paired_mapM (f : α → EvalM β) (items : List α)
    (paired : ∀ item ∈ items, Paired (f item)) : Paired (items.mapM f) := by
  have loop : ∀ remaining : List α,
      (∀ item ∈ remaining, Paired (f item)) →
      ∀ accumulator : List β, Paired (List.mapM.loop f remaining accumulator) := by
    intro remaining
    induction remaining with
    | nil =>
        intro paired accumulator
        change Paired (pure accumulator.reverse : EvalM (List β))
        exact Paired_pure accumulator.reverse
    | cons item rest ih =>
        intro paired accumulator
        change Paired (f item >>= fun value => List.mapM.loop f rest (value :: accumulator))
        apply Paired_bind
        · exact paired item (by simp)
        · intro value
          apply ih
          intro tail member
          exact paired tail (by simp [member])
  change Paired (List.mapM.loop f items [])
  exact loop items paired []

/-- A unit-state `for` loop over a list preserves pairing when every body
step does.  This is the elaborated shape used for parameter binding in
`callFunction`; the proof follows `List.forIn'` directly and needs no monad
law assumptions. -/
theorem Paired_forIn_unit (items : List α) (body : α → EvalM Unit)
    (paired : ∀ item ∈ items, Paired (body item)) :
    Paired (for item in items do body item) := by
  have loop : ∀ remaining : List α,
      (∀ item ∈ remaining, Paired (body item)) →
      Paired (forIn' remaining PUnit.unit fun item _ _ => do
        body item
        pure (ForInStep.yield PUnit.unit)) := by
    intro remaining
    induction remaining with
    | nil =>
        intro paired
        rw [List.forIn'_nil]
        exact Paired_pure PUnit.unit
    | cons item rest ih =>
        intro paired
        rw [List.forIn'_cons]
        apply Paired_bind
        · apply Paired_bind (body item) (fun _ => pure (ForInStep.yield PUnit.unit))
          · exact paired item (by simp)
          · intro
            exact Paired_pure (ForInStep.yield PUnit.unit)
        · intro step
          cases step with
          | done state => exact Paired_pure state
          | yield state =>
              apply ih
              intro tail member
              exact paired tail (by simp [member])
  change Paired (forIn' items PUnit.unit (fun item _ _ => do
    body item
    pure (ForInStep.yield PUnit.unit)) >>= fun _ => pure ())
  apply Paired_bind
  · exact loop items paired
  · intro
    exact Paired_pure ()

/-- The raw `forIn` worker before the elaborator's final `pure ()`.  This is
the exact form retained inside the larger `callFunction` do-block. -/
theorem Paired_forIn_unit_raw (items : List α) (body : α → EvalM Unit)
    (paired : ∀ item ∈ items, Paired (body item)) :
    Paired (forIn items PUnit.unit fun item _ => do
      body item
      pure (ForInStep.yield PUnit.unit)) := by
  induction items with
  | nil =>
      change Paired (forIn' [] PUnit.unit fun item _ _ => do
        body item
        pure (ForInStep.yield PUnit.unit))
      rw [List.forIn'_nil]
      exact Paired_pure PUnit.unit
  | cons item rest ih =>
      change Paired (forIn' (item :: rest) PUnit.unit fun item _ _ => do
        body item
        pure (ForInStep.yield PUnit.unit))
      rw [List.forIn'_cons]
      apply Paired_bind
      · apply Paired_bind (body item) (fun _ => pure (ForInStep.yield PUnit.unit))
        · exact paired item (by simp)
        · intro
          exact Paired_pure (ForInStep.yield PUnit.unit)
      · intro step
        cases step with
        | done state => exact Paired_pure state
        | yield state =>
            apply ih
            intro tail member
            exact paired tail (by simp [member])

/-- Popping the active call frame does not alter completed writer chunks. -/
theorem popFrame_writerChunks (world : World) :
    ({world with frames := world.frames.pop} : World).writerChunks = world.writerChunks := rfl

/-- Catching a computation into an intermediate `Except`, popping its frame,
and rethrowing the captured error preserves pairing.  The proof keeps the
intermediate error leaf until overall success rules it out. -/
theorem Paired_catchPopRethrow (m : EvalM α) (g : α → β) (paired : Paired m) :
    Paired (do
      let outcome : Except Err β ← try
        let returned ← m
        pure (Except.ok (g returned))
      catch error => pure (Except.error error)
      modify fun w => {w with frames := w.frames.pop}
      match outcome with
      | .ok value => pure value
      | .error error => throw error) := by
  intro w0 supplied positioned
  change let interpreted := interpret (evalRun (do
      let outcome : Except Err β ← tryCatch
        (m >>= fun value => pure (Except.ok (g value)))
        (fun error => pure (Except.error error))
      modify fun w => {w with frames := w.frames.pop}
      match outcome with
      | .ok value => pure value
      | .error error => throw error) w0) supplied
    ∀ value, interpreted.value.1 = .ok value → ∃ appended,
      interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
      interpreted.answers = writerAnswersFrom w0.writerChunks.length appended
  rw [evalRun_catchPopRethrow, interpret_map]
  dsimp only
  intro value successful
  cases original : (interpret (evalRun m w0) supplied).value.1 with
  | error error =>
      rw [original] at successful
      contradiction
  | ok innerValue =>
      rw [original] at successful
      have innerSuccessful :
          (interpret (evalRun m w0) supplied).value.1 = .ok innerValue := original
      obtain ⟨appended, chunks, answers⟩ :=
        paired w0 supplied positioned innerValue innerSuccessful
      refine ⟨appended, ?_, answers⟩
      exact chunks

/-- The named suffix is definitionally the ordinary catch/pop/rethrow form. -/
theorem callSuffix_eq (m : EvalM (Option Value)) : callSuffix m = (do
      let outcome : Except Err Value ← tryCatch
        (m >>= fun returned => pure (Except.ok (returned.getD .null)))
        (fun error => pure (Except.error error))
      modify fun w => {w with frames := w.frames.pop}
      match outcome with
      | .ok value => pure value
      | .error error => throw error) := rfl

/-- Running the named suffix maps every body leaf while popping its frame. -/
theorem evalRun_callSuffix (m : EvalM (Option Value)) (world : World) :
    evalRun (callSuffix m) world =
      (evalRun m world).bind (fun (result, nextWorld) =>
        .done (result.map (fun returned => returned.getD .null),
          {nextWorld with frames := nextWorld.frames.pop})) := by
  unfold callSuffix
  rw [evalRun_bind, evalRun_catchToExcept]
  generalize evalRun m world = tree
  induction tree with
  | done pair =>
      cases pair with
      | mk result nextWorld => cases result <;> rfl
  | ask query continuation ih =>
      simp only [Interaction.bind]
      congr 1
      funext answer
      exact ih answer

/-- The named function-call suffix preserves pairing structurally. -/
theorem Paired_callSuffix (m : EvalM (Option Value)) (paired : Paired m) :
    Paired (callSuffix m) := by
  intro w0 supplied positioned
  change let interpreted := interpret (evalRun (callSuffix m) w0) supplied
    ∀ value, interpreted.value.1 = .ok value → ∃ appended,
      interpreted.value.2.writerChunks = w0.writerChunks ++ appended ∧
      interpreted.answers = writerAnswersFrom w0.writerChunks.length appended
  rw [evalRun_callSuffix, interpret_map]
  dsimp only
  intro value successful
  cases original : (interpret (evalRun m w0) supplied).value.1 with
  | error error =>
      rw [original] at successful
      contradiction
  | ok returned =>
      rw [original] at successful
      obtain ⟨appended, chunks, answers⟩ :=
        paired w0 supplied positioned returned original
      exact ⟨appended, chunks, answers⟩

/-- The catch suffix written by `callFunction` is the generic
catch/pop/rethrow combinator, up to the local binder name. -/
theorem callFunction_catchPopRethrow_eq (m : EvalM (Option Value)) :
    (do
      let outcome : Except Err Value ← try
        let returned ← m
        pure (Except.ok (returned.getD .null))
      catch error => pure (Except.error error)
      modify fun (w : World) => {w with frames := w.frames.pop}
      match outcome with
      | .ok value => pure value
      | .error error => throw error) =
    (do
      let outcome : Except Err Value ← tryCatch
        (m >>= fun value => pure (Except.ok (value.getD .null)))
        (fun error => pure (Except.error error))
      modify fun (w : World) => {w with frames := w.frames.pop}
      match outcome with
      | .ok value => pure value
      | .error error => throw error) := rfl

/-- A world update which preserves writer chunks is paired. -/
theorem Paired_modify (f : World → World)
    (preserves : ∀ world, (f world).writerChunks = world.writerChunks) :
    Paired (modify f : EvalM Unit) := by
  intro w0 supplied
  intro positioned
  dsimp
  intro value successful
  change Except.ok () = Except.ok value at successful
  injection successful with same
  subst value
  refine ⟨[], ?_, ?_⟩
  · change (f w0).writerChunks = w0.writerChunks ++ []
    simpa using preserves w0
  · change [] = writerAnswersFrom w0.writerChunks.length []
    rfl

/-- The simultaneous fuel-induction assertion for the five evaluator entry
points.  Keeping this as one proposition makes every recursive call at the
previous fuel available to each named successor lemma. -/
def PairedAll (fuel : Nat) : Prop :=
  (∀ e, Paired (evalExpr fuel e)) ∧
  (∀ id args, Paired (callFunction fuel id args)) ∧
  (∀ arms otherwise, Paired (chooseBranch fuel arms otherwise)) ∧
  (∀ condition body rest, Paired (execLoop fuel condition body rest)) ∧
  (∀ statements, Paired (exec fuel statements))

/-- At zero fuel all five evaluator functions immediately raise `fuel`. -/
theorem PairedAll_zero : PairedAll 0 := by
  constructor
  · intro expression
    rw [evalExpr]
    exact Paired_throw .fuel
  constructor
  · intro functionId arguments
    rw [callFunction]
    exact Paired_throw .fuel
  constructor
  · intro arms otherwise
    rw [chooseBranch]
    exact Paired_throw .fuel
  constructor
  · intro condition body rest
    rw [execLoop]
    exact Paired_throw .fuel
  · intro statements
    rw [exec]
    exact Paired_throw .fuel

set_option maxHeartbeats 1000000 in
/-- Function calls preserve pairing at successor fuel.  The named suffix
keeps the recursive body call visible as a structural subcomputation. -/
theorem Paired_callFunction_succ (f : Nat) (ih : PairedAll f)
    (functionId : Nat) (arguments : List Value) :
    Paired (callFunction (f + 1) functionId arguments) := by
  obtain ⟨exprIH, callIH, branchIH, loopIH, execIH⟩ := ih
  rw [callFunction.eq_def]
  intro before
  apply PairedAt_get_bind
  cases found : before.functions[functionId]? with
  | none =>
      simp only [found]
      exact PairedAt_of_Paired
        (Paired_throw (.runtime s!"undefined function id: {functionId}")) before
  | some definition =>
      simp only [found]
      split
      · exact PairedAt_of_Paired (Paired_throw (.runtime
          s!"call passes {arguments.length} arguments but the callee takes {definition.parameters.length}")) before
      · let environment := before.environments.size
        let frame : Frame := {serial := before.nextFrameSerial, environment := environment}
        let entered : World := {before with
          environments := before.environments.push
            {id := environment, parent := some definition.definingEnvironment}
          frames := before.frames.push frame
          nextFrameSerial := before.nextFrameSerial + 1}
        let supplied := if definition.parameters.length == 0 then []
          else if definition.parameters.length == 1 && arguments.length != 1 then
            [.array arguments] else arguments
        apply PairedAt_silent_bind before entered (set entered) () _ rfl rfl
        apply PairedAt_of_Paired
        apply Paired_bind
        · apply Paired_forIn_unit_raw
            (items := definition.parameters.zipIdx)
            (body := fun parameter => bindParameter environment parameter.1
              (supplied[parameter.2]?.getD .null))
          intro parameter member
          exact Paired_bindParameter environment parameter.1
            (supplied[parameter.2]?.getD .null)
        · intro _
          exact Paired_callSuffix _ (execIH definition.body)

/-- Literal and variable expressions preserve pairing at successor fuel. -/
theorem Paired_evalExpr_succ_literal (f : Nat) (literal : Literal) :
    Paired (evalExpr (f + 1) (.literal literal)) := by
  rw [evalExpr.eq_def]
  cases literal <;> exact Paired_pure _

theorem Paired_evalExpr_succ_variable (f : Nat) (name : String) :
    Paired (evalExpr (f + 1) (.variable name)) := by
  rw [evalExpr.eq_def]
  exact Paired_valueAt name

/-- Boolean and binary expressions preserve pairing when recursive expressions do. -/
theorem Paired_evalExpr_succ_not (f : Nat) (ih : PairedAll f) (x : Expr) :
    Paired (evalExpr (f + 1) (.not x)) := by
  rw [evalExpr.eq_def]
  exact Paired_bind _ _ (ih.1 x) (fun value => Paired_pure (Value.bool (!truthy value)))

theorem Paired_evalExpr_succ_binary (f : Nat) (ih : PairedAll f)
    (op : BinOp) (a b : Expr) : Paired (evalExpr (f + 1) (.binary op a b)) := by
  rw [evalExpr.eq_def]
  cases op with
  | and =>
      apply Paired_bind _ _ (ih.1 a)
      intro value
      exact Paired_ite (truthy value) _ _ (ih.1 b) (Paired_pure value)
  | or =>
      apply Paired_bind _ _ (ih.1 a)
      intro value
      exact Paired_ite (truthy value) _ _ (Paired_pure value) (ih.1 b)
  | add | sub | mul | eq | ne | lt | le | gt | ge =>
      apply Paired_bind _ _ (ih.1 a)
      intro left
      apply Paired_bind _ _ (ih.1 b)
      intro right
      cases evalBin _ left right with
      | ok value => exact Paired_pure value
      | error error => exact Paired_throw error

/-- Assignment-count observation and printing preserve pairing. -/
theorem Paired_evalExpr_succ_when (f : Nat) (name : String) :
    Paired (evalExpr (f + 1) (.when name)) := by
  rw [evalExpr.eq_def]
  apply Paired_bind _ _ Paired_get
  intro world
  cases resolve name world with
  | none => exact Paired_throw (.runtime s!"undefined variable: {name}")
  | some binding => exact Paired_pure (Value.int
      world.environments[binding.envId]!.slots[binding.slot]!.assignments)

theorem Paired_evalExpr_succ_print (f : Nat) (ih : PairedAll f) (argument : Expr) :
    Paired (evalExpr (f + 1) (.call (.variable "print") [argument])) := by
  rw [evalExpr.eq_def]
  apply Paired_bind _ _ (ih.1 argument)
  intro value
  exact Paired_bind _ _ (Paired_printModify value) (fun _ => Paired_pure Value.null)

/-- The zero-argument taped builtin preserves pairing, including shadowing. -/
theorem Paired_evalExpr_succ_readLine (f : Nat) (ih : PairedAll f) :
    Paired (evalExpr (f + 1) (.call (.variable "read_line") [])) := by
  rw [evalExpr.eq_def]
  intro world
  apply PairedAt_get_bind
  split
  · apply PairedAt_of_Paired
    apply Paired_bind _ _ (ih.1 (.variable "read_line"))
    intro callable
    cases callable with
    | closure functionId name => exact ih.2.1 functionId []
    | _ => exact Paired_throw (.runtime "value is not callable")
  · exact PairedAt_of_Paired (Paired_tapedCall "read_line") world

theorem Paired_evalExpr_succ_randomInt (f : Nat) (ih : PairedAll f)
    (loExpr hiExpr : Expr) :
    Paired (evalExpr (f + 1) (.call (.variable "random_int") [loExpr, hiExpr])) := by
  rw [evalExpr.eq_def]
  intro world
  apply PairedAt_get_bind
  split
  · apply PairedAt_of_Paired
    apply Paired_bind _ _ (ih.1 (.variable "random_int"))
    intro callable
    apply Paired_bind _ _ (Paired_mapM (evalExpr f) [loExpr, hiExpr] (fun item _ => ih.1 item))
    intro values
    cases callable with
    | closure functionId name => exact ih.2.1 functionId values
    | _ => exact Paired_throw (.runtime "value is not callable")
  · apply PairedAt_of_Paired
    apply Paired_bind _ _ (ih.1 loExpr)
    intro lo
    apply Paired_bind _ _ (ih.1 hiExpr)
    intro hi
    cases lo with
    | int low =>
        cases hi with
        | int high =>
            simp only
            split
            · exact Paired_bind _ _ (Paired_throw (.runtime
                s!"random_int: range span {high - low + 1} exceeds 2^31 (lrand48 supplies 31 bits)"))
                (fun _ => Paired_tapedCall "random_int")
            · exact Paired_tapedCall "random_int"
        | _ => exact Paired_throw (.runtime "random_int expects numeric bounds")
    | _ => exact Paired_throw (.runtime "random_int expects numeric bounds")

theorem Paired_evalExpr_succ_envGet (f : Nat) (ih : PairedAll f) (nameExpr : Expr) :
    Paired (evalExpr (f + 1) (.call (.variable "env_get") [nameExpr])) := by
  rw [evalExpr.eq_def]
  intro world
  apply PairedAt_get_bind
  split
  · apply PairedAt_of_Paired
    apply Paired_bind _ _ (ih.1 (.variable "env_get"))
    intro callable
    apply Paired_bind _ _ (ih.1 nameExpr)
    intro value
    cases callable with
    | closure functionId name => exact ih.2.1 functionId [value]
    | _ => exact Paired_throw (.runtime "value is not callable")
  · apply PairedAt_of_Paired
    apply Paired_bind _ _ (ih.1 nameExpr)
    intro name
    cases name with
    | string value => exact Paired_tapedCall "env_get"
    | _ => exact Paired_throw (.runtime "env_get expects a string name")

/-- A general function-call body preserves pairing. -/
theorem Paired_evalExpr_generalCall (f : Nat) (ih : PairedAll f)
    (function : Expr) (arguments : List Expr) : Paired (do
      let callable ← evalExpr f function
      let values ← arguments.mapM (evalExpr f)
      match callable with
      | .closure functionId _ => callFunction f functionId values
      | _ => throw (.runtime "value is not callable")) := by
  apply Paired_bind _ _ (ih.1 function)
  intro callable
  apply Paired_bind _ _ (Paired_mapM (evalExpr f) arguments (fun item _ => ih.1 item))
  intro values
  cases callable with
  | closure functionId name => exact ih.2.1 functionId values
  | _ => exact Paired_throw (.runtime "value is not callable")

set_option maxHeartbeats 1000000 in
/-- Every expression preserves pairing at successor fuel. -/
theorem Paired_evalExpr_succ (f : Nat) (ih : PairedAll f) :
    ∀ e, Paired (evalExpr (f + 1) e) := by
  intro e
  cases e with
  | literal literal => exact Paired_evalExpr_succ_literal f literal
  | «variable» name => exact Paired_evalExpr_succ_variable f name
  | not x => exact Paired_evalExpr_succ_not f ih x
  | array items => rw [evalExpr.eq_def]; exact Paired_throw (.unsupported "array literal")
  | binary op a b => exact Paired_evalExpr_succ_binary f ih op a b
  | when name => exact Paired_evalExpr_succ_when f name
  | prev x => rw [evalExpr.eq_def]; exact Paired_throw (.unsupported "prev")
  | whatWhen a b => rw [evalExpr.eq_def]; exact Paired_throw (.unsupported "what-when")
  | call function arguments =>
      rw (occs := .pos [1]) [evalExpr.eq_def]
      simp only
      split <;> rename_i h <;> cases h
      · apply Paired_bind _ _ (ih.1 _)
        intro value
        exact Paired_bind _ _ (Paired_printModify value) (fun _ => Paired_pure Value.null)
      · intro world
        apply PairedAt_get_bind
        split
        · apply PairedAt_of_Paired
          apply Paired_bind _ _ (ih.1 _)
          intro callable
          apply Paired_bind _ _ (Paired_mapM _ _ (fun item _ => ih.1 item))
          intro values
          cases callable with
          | closure functionId name => exact ih.2.1 functionId values
          | _ => exact Paired_throw (.runtime "value is not callable")
        · apply PairedAt_of_Paired
          apply Paired_bind _ _ (ih.1 _)
          intro lo
          apply Paired_bind _ _ (ih.1 _)
          intro hi
          cases lo with
          | int low =>
              cases hi with
              | int high =>
                  simp only
                  split
                  · exact Paired_bind _ _ (Paired_throw _) (fun _ => Paired_tapedCall "random_int")
                  · exact Paired_tapedCall "random_int"
              | _ => exact Paired_throw _
          | _ => exact Paired_throw _
      · intro world
        apply PairedAt_get_bind
        split
        · apply PairedAt_of_Paired
          apply Paired_bind _ _ (ih.1 _)
          intro callable
          cases callable with
          | closure functionId name => exact ih.2.1 functionId []
          | _ => exact Paired_throw _
        · exact PairedAt_of_Paired (Paired_tapedCall "read_line") world
      · intro world
        apply PairedAt_get_bind
        split
        · apply PairedAt_of_Paired
          apply Paired_bind _ _ (ih.1 _)
          intro callable
          apply Paired_bind _ _ (ih.1 _)
          intro value
          cases callable with
          | closure functionId name => exact ih.2.1 functionId [value]
          | _ => exact Paired_throw _
        · apply PairedAt_of_Paired
          apply Paired_bind _ _ (ih.1 _)
          intro name
          cases name with
          | string value => exact Paired_tapedCall "env_get"
          | _ => exact Paired_throw _
      · exact Paired_evalExpr_generalCall f ih _ _

/-- The statement-list evaluator preserves pairing at successor fuel. -/
theorem Paired_exec_succ (f : Nat) (ih : PairedAll f) (statements : List Stmt) :
    Paired (exec (f + 1) statements) := by
  obtain ⟨exprIH, callIH, branchIH, loopIH, execIH⟩ := ih
  rw [exec.eq_def]
  cases statements with
  | nil => exact Paired_pure none
  | cons statement rest =>
    cases statement with
    | assign name expression isLocal =>
        apply Paired_bind (evalExpr f expression)
          (fun value => store name value isLocal >>= fun _ => exec f rest) (exprIH expression)
        intro value
        exact Paired_bind _ _ (Paired_store name value isLocal) (fun _ => execIH rest)
    | print expression =>
        apply Paired_bind (evalExpr f expression) _ (exprIH expression)
        intro value
        exact Paired_bind _ _ (Paired_printModify value) (fun _ => execIH rest)
    | expression expression =>
        exact Paired_bind _ _ (exprIH expression) (fun _ => execIH rest)
    | return_ expression =>
        exact Paired_bind _ _ (exprIH expression) (fun value => Paired_pure (some value))
    | branch condition yes elifs no =>
        apply Paired_bind (evalExpr f condition) _ (exprIH condition)
        intro value
        apply Paired_ite (truthy value)
        · apply Paired_bind _ _ (execIH yes)
          intro result
          cases result with
          | none => exact execIH rest
          | some returned => exact Paired_pure (some returned)
        · apply Paired_bind _ _ (branchIH elifs no)
          intro result
          cases result with
          | none => exact execIH rest
          | some returned => exact Paired_pure (some returned)
    | loop condition body => exact loopIH condition body rest
    | define name parameters body =>
        apply Paired_bind (get : EvalM World) _ Paired_get
        intro world
        let definition : FunctionDef := {
          name := name
          parameters := if parameters.isEmpty then ["n"] else parameters
          body := body
          definingEnvironment := currentEnvironment world }
        apply Paired_bind
        · exact Paired_defineModify definition
        · intro _
          apply Paired_bind
          · exact Paired_store name (.closure world.functions.size name) true
          · intro _
            exact execIH rest

/-- Branch selection preserves pairing at successor fuel. -/
theorem Paired_chooseBranch_succ (f : Nat) (ih : PairedAll f)
    (arms : List (Expr × List Stmt)) (otherwise : Option (List Stmt)) :
    Paired (chooseBranch (f + 1) arms otherwise) := by
  obtain ⟨exprIH, callIH, branchIH, loopIH, execIH⟩ := ih
  rw [chooseBranch.eq_def]
  cases arms with
  | nil =>
      cases otherwise with
      | none => exact Paired_pure none
      | some body => exact execIH body
  | cons arm rest =>
      rcases arm with ⟨condition, body⟩
      apply Paired_bind (evalExpr f condition) _ (exprIH condition)
      intro value
      exact Paired_ite (truthy value) _ _ (execIH body) (branchIH rest otherwise)

/-- Loop execution preserves pairing at successor fuel. -/
theorem Paired_execLoop_succ (f : Nat) (ih : PairedAll f)
    (condition : Expr) (body rest : List Stmt) :
    Paired (execLoop (f + 1) condition body rest) := by
  obtain ⟨exprIH, callIH, branchIH, loopIH, execIH⟩ := ih
  rw [execLoop]
  apply Paired_bind (evalExpr f condition) _ (exprIH condition)
  intro value
  apply Paired_ite (truthy value)
  · apply Paired_bind (exec f body) _ (execIH body)
    intro result
    cases result with
    | none => exact loopIH condition body rest
    | some returned => exact Paired_pure (some returned)
  · exact Paired_bind _ _ (Paired_store "__loop_exit__" (.string "normal") false)
      (fun _ => execIH rest)

/-- Pairing is preserved when evaluator fuel is increased. -/
theorem PairedAll_succ (f : Nat) (ih : PairedAll f) : PairedAll (f + 1) := by
  exact ⟨Paired_evalExpr_succ f ih, Paired_callFunction_succ f ih,
    Paired_chooseBranch_succ f ih, Paired_execLoop_succ f ih,
    Paired_exec_succ f ih⟩

/-- All five evaluator entry points preserve the writer/tape pairing invariant. -/
theorem Paired_evaluator : ∀ fuel, PairedAll fuel := by
  intro fuel
  induction fuel with
  | zero => exact PairedAll_zero
  | succ f ih => exact PairedAll_succ f ih

/-- Prefix sufficiency for the interaction interpreter.  The strict bound says
the run stopped before exhausting its supplied stream (callers include an
explicit error answer).  Thus answers after the exactly-consumed prefix cannot
be observed. -/
theorem interpret_prefix_sufficient (tree : Interaction α) :
    ∀ (supplied alternative : List TapedAnswer),
      (interpret tree supplied).consumed < supplied.length →
      supplied.take (interpret tree supplied).consumed =
        alternative.take (interpret tree supplied).consumed →
      interpret tree supplied = interpret tree alternative := by
  induction tree with
  | done value =>
      intro supplied alternative within agree
      simp [interpret]
  | ask query continuation ih =>
      intro supplied alternative within agree
      cases supplied with
      | nil => simp [interpret] at within
      | cons answer rest =>
        cases alternative with
        | nil =>
          simp [interpret] at agree within
        | cons other others =>
          simp only [interpret] at within agree ⊢
          have positive : 0 <
              (interpret (continuation (deliveredAnswer query answer)) rest).consumed + 1 := by omega
          have heads : answer = other := by
            simpa [List.take_succ_cons, positive] using congrArg List.head? agree
          subst other
          have tails : rest.take
                (interpret (continuation (deliveredAnswer query answer)) rest).consumed =
              others.take
                (interpret (continuation (deliveredAnswer query answer)) rest).consumed := by
            simpa [List.take_succ_cons] using congrArg List.tail agree
          have childWithin :
              (interpret (continuation (deliveredAnswer query answer)) rest).consumed < rest.length := by
            simpa using within
          rw [ih (deliveredAnswer query answer) rest others childWithin tails]

/-- A stream containing the answers already delivered by another interpretation
replays that interpretation.  This differs from raw prefix sufficiency because
record-mode values acquire their query names at the effect boundary. -/
theorem interpret_delivered_congruence (tree : Interaction α) :
    ∀ (supplied replay : List TapedAnswer),
      (interpret tree supplied).consumed < supplied.length →
      replay.take (interpret tree supplied).consumed =
        (interpret tree supplied).answers →
      interpret tree replay = interpret tree supplied := by
  induction tree with
  | done value =>
      intro supplied replay within agree
      simp [interpret]
  | ask query continuation ih =>
      intro supplied replay within agree
      cases supplied with
      | nil => simp [interpret] at within
      | cons answer rest =>
        cases replay with
        | nil =>
          simp only [interpret, List.take_nil] at agree
          simp at agree
        | cons other others =>
          simp only [interpret] at within agree ⊢
          have positive : 0 <
              (interpret (continuation (deliveredAnswer query answer)) rest).consumed + 1 := by omega
          have heads : other = deliveredAnswer query answer := by
            simpa [List.take_succ_cons, positive] using congrArg List.head? agree
          subst other
          rw [deliveredAnswer_idem]
          have tails : others.take
                (interpret (continuation (deliveredAnswer query answer)) rest).consumed =
              (interpret (continuation (deliveredAnswer query answer)) rest).answers := by
            simpa [List.take_succ_cons] using congrArg List.tail agree
          have childWithin :
              (interpret (continuation (deliveredAnswer query answer)) rest).consumed < rest.length := by
            simpa using within
          rw [ih (deliveredAnswer query answer) rest others childWithin tails]

/-- A replacement stream whose delivered answers agree with an interpretation's
consumed answers produces the same interpretation.  Unlike
`interpret_delivered_congruence`, the replacement entries need not literally
contain the delivered query names (record-mode entries use empty wildcards). -/
theorem interpret_delivered_congruence' (tree : Interaction α) :
    ∀ (supplied replacement : List TapedAnswer),
      (interpret tree supplied).consumed < supplied.length →
      (interpret tree supplied).consumed < replacement.length →
      (interpret tree replacement).answers.take
          (interpret tree supplied).consumed =
        (interpret tree supplied).answers →
      interpret tree replacement = interpret tree supplied := by
  induction tree with
  | done value =>
      intro supplied replacement within replacementWithin agree
      simp [interpret]
  | ask query continuation ih =>
      intro supplied replacement within replacementWithin agree
      cases supplied with
      | nil => simp [interpret] at within
      | cons answer rest =>
        cases replacement with
        | nil => simp at replacementWithin
        | cons other others =>
          simp only [interpret] at within replacementWithin agree ⊢
          let child := interpret (continuation (deliveredAnswer query answer)) rest
          let otherChild := interpret (continuation (deliveredAnswer query other)) others
          have positive : 0 < child.consumed + 1 := by omega
          have heads : deliveredAnswer query other = deliveredAnswer query answer := by
            simpa [List.take_succ_cons, positive, child, otherChild] using
              congrArg List.head? agree
          have childWithin : child.consumed < rest.length := by
            simpa [child] using within
          have otherChildEq :
              interpret (continuation (deliveredAnswer query other)) others = child := by
            rw [heads]
            apply ih (deliveredAnswer query answer) rest others childWithin
            · simpa [child, otherChild, heads] using replacementWithin
            · simpa [List.take_succ_cons, child, otherChild, heads] using
                congrArg List.tail agree
          simpa [child, otherChild, otherChildEq]

/-- The two explicit exhaustion guards appended by `evaluateCore` continue the
numbering of any already well-positioned supplied stream. -/
theorem wellPositioned_withOracleExhaustion (answers : List TapedAnswer)
    (positioned : WellPositioned 0 answers) :
    WellPositioned 0 (answers ++
      [.oracleExhausted answers.length, .oracleExhausted (answers.length + 1)]) := by
  rw [wellPositioned_append]
  exact ⟨positioned, by simp [WellPositioned, positionOf]
    ⟩

/-- The complete stream supplied by live and record modes, including core
exhaustion guards, is positioned from zero. -/
theorem wellPositioned_liveRecordSupplied (oracle : List OracleValue) :
    WellPositioned 0 (oracleAnswers oracle ++
      [.oracleExhausted (oracleAnswers oracle).length,
       .oracleExhausted ((oracleAnswers oracle).length + 1)]) :=
  wellPositioned_withOracleExhaustion _ (wellPositioned_oracleAnswers oracle)

/-- Strict replay's replay-exhaustion entry and the two core guards all
continue normalization's numbering. -/
theorem wellPositioned_replaySupplied (tape : List String) :
    let normalized := normalizeTape tape
    WellPositioned 0
      (normalized ++ [.replayExhausted normalized.length] ++
        [.oracleExhausted (normalized.length + 1),
         .oracleExhausted (normalized.length + 2)]) := by
  dsimp
  have normalized : WellPositioned 0 (normalizeTape tape) :=
    wellPositioned_normalizeTapeFrom 0 tape
  have replay : WellPositioned 0
      (normalizeTape tape ++ [.replayExhausted (normalizeTape tape).length]) := by
    rw [wellPositioned_append]
    exact ⟨normalized, by simp [WellPositioned, positionOf]⟩
  rw [wellPositioned_append]
  exact ⟨replay, by simp [WellPositioned, positionOf]⟩

/-- Evaluate with the canonical event stream.  No mode metadata enters the
mutually recursive evaluator. -/
private def evaluateCore (fuel : Nat) (p : Program)
    (supplied : List TapedAnswer) : RunResult :=
  if let some construct := unsupportedConstruct p then
    {stdout := "", tape := [], error := some (.unsupported construct)}
  else
    let root : Environment := {id := 0, parent := none}
    let initial : World := {environments := #[root]}
    -- Keep exhaustion explicit too.  The second marker is an unobservable
    -- guard entry, ensuring every completed interpretation has a proper
    -- suffix beyond the consumed prefix.
    let suppliedWithError := supplied ++
      [.oracleExhausted supplied.length, .oracleExhausted (supplied.length + 1)]
    let interpreted := interpret (((exec fuel p).run).run initial) suppliedWithError
    let (result, w) := interpreted.value
    let error := match result with | .ok _ => none | .error e => some e
    {stdout := w.stdout, tape := writerProducedRecords w.writerChunks w.writerTrailing,
      answersConsumed := writerAnswersFrom 0 w.writerChunks, error := error}

/-- A completed evaluator result exposes precisely the canonical writer layout:
each consumed answer has its structural prefix and exact encoded N record, in
order, followed by the remaining structural records. -/
def WriterProjectionInvariant (result : RunResult) : Prop :=
  ∃ chunks trailing,
    result.tape = writerProducedRecords chunks trailing ∧
    result.answersConsumed = writerAnswersFrom 0 chunks

/-- Writer projection invariant. Evaluation exposes its tape and public
consumed-answer projection from the same canonical chunks. This is the
structural precursor to the stronger record-run invariant. -/
theorem writer_projection_invariant (fuel : Nat) (p : Program)
    (supplied : List TapedAnswer) :
    WriterProjectionInvariant (evaluateCore fuel p supplied) := by
  simp only [evaluateCore]
  split
  · exact ⟨[], [], rfl, rfl⟩
  · exact ⟨_, _, rfl, rfl⟩

/-- The public answer projection of an evaluation is exactly the normalization
of its writer-produced tape.  This lemma deliberately needs neither
`WriterRecords` nor `tape_roundtrip`: `run` replays the record list itself, and
writer row validity is carried by `StructuralRow` construction. -/
theorem normalizeTape_evaluateCore (fuel : Nat) (p : Program)
    (supplied : List TapedAnswer) :
    normalizeTape (evaluateCore fuel p supplied).tape =
      (evaluateCore fuel p supplied).answersConsumed := by
  simp only [evaluateCore]
  split
  · rfl
  · exact normalizeTape_writerProducedRecords _ _

/-- Entry point of the evaluator core.  The tag is carried so callers from
different modes can be compared, but cannot affect evaluation. -/
def runCore (fuel : Nat) (p : Program) (supplied : List TapedAnswer)
    (policy : CorePolicy) : CoreResult :=
  let result := evaluateCore fuel p supplied
  match policy.modeTag with
  | .live | .record | .replayStrict =>
    { stdout := result.stdout
      assignments := result.tape.filter isAssignmentRecord
      answersConsumed := result.answersConsumed
      error := result.error }

/-- The core result is a function of program, fuel, and supplied answers only,
even when its callers carry different mode tags. -/
theorem runCore_deterministic (fuel : Nat) (p : Program)
    (supplied : List TapedAnswer) (left right : CorePolicy) :
    runCore fuel p supplied left = runCore fuel p supplied right := by
  induction fuel with
  | zero => cases left with | mk leftTag leftEmit => cases right with | mk rightTag rightEmit => cases leftTag <;> cases rightTag <;> rfl
  | succ _ _ => cases left with | mk leftTag leftEmit => cases right with | mk rightTag rightEmit => cases leftTag <;> cases rightTag <;> rfl

private def presentCore (fuel : Nat) (p : Program) (supplied : List TapedAnswer)
    (policy : CorePolicy) : RunResult :=
  let result := evaluateCore fuel p supplied
  if policy.emitAnswers then result
  else {result with tape := result.tape.filter (!isAnswerRecord ·)}

def run (fuel : Nat) (p : Program) (mode : Mode) : RunResult :=
  match mode with
  | .live oracle => presentCore fuel p (oracleAnswers oracle) {modeTag := .live, emitAnswers := false}
  | .record oracle => presentCore fuel p (oracleAnswers oracle) {modeTag := .record, emitAnswers := true}
  | .replayStrict tape => let supplied := normalizeTape tape
    presentCore fuel p (supplied ++ [.replayExhausted supplied.length]) {modeTag := .replayStrict, emitAnswers := true}

/-- Recording and live execution consume exactly the same supplied oracle
answers.  Recording changes only whether answer rows are retained in the
presented tape. -/
theorem record_transparent_answersConsumed (fuel : Nat) (p : Program)
    (o : List OracleValue) :
    (run fuel p (.record o)).answersConsumed =
      (run fuel p (.live o)).answersConsumed := by
  rfl

/-- Recording has no effect on the program's stdout or exit error relative to
live execution with the same oracle. -/
theorem record_transparent (fuel : Nat) (p : Program) (o : List OracleValue) :
    (run fuel p (.record o)).stdout = (run fuel p (.live o)).stdout ∧
    (run fuel p (.record o)).error = (run fuel p (.live o)).error := by
  exact ⟨rfl, rfl⟩

/-- A completed recording is a self-contained strict-replay certificate. -/
theorem record_replay (fuel : Nat) (p : Program) (o : List OracleValue)
    (r : RunResult) (recorded : run fuel p (.record o) = r)
    (completed : r.error = none) :
    run fuel p (.replayStrict r.tape) = r := by
  subst r
  simp only [run, presentCore, if_true] at completed ⊢
  rw [normalizeTape_evaluateCore]
  let root : Environment := {id := 0, parent := none}
  let initial : World := {environments := #[root]}
  let tree := (((exec fuel p).run).run initial)
  let recordSupplied := oracleAnswers o ++
    [.oracleExhausted (oracleAnswers o).length,
     .oracleExhausted ((oracleAnswers o).length + 1)]
  let recordedInterpretation := interpret tree recordSupplied
  by_cases supported : unsupportedConstruct p = none
  · have completedMatch :
        (match recordedInterpretation.value.1 with
          | .ok _ => none | .error e => some e) = none := by
      simpa [evaluateCore, supported, recordedInterpretation, tree, recordSupplied,
        initial, root] using completed
    obtain ⟨value, successful⟩ : ∃ value, recordedInterpretation.value.1 = .ok value := by
      cases outcome : recordedInterpretation.value.1 with
      | ok value => exact ⟨value, rfl⟩
      | error error => simp [outcome] at completedMatch
    have positioned : WellPositioned 0 recordSupplied := by
      simpa [recordSupplied] using wellPositioned_liveRecordSupplied o
    have paired : Paired (exec fuel p) := (Paired_evaluator fuel).2.2.2.2 p
    obtain ⟨chunks, chunksEq, answersEq⟩ :=
      paired initial recordSupplied (by simpa [initial] using positioned) value successful
    have resultChunks : recordedInterpretation.value.2.writerChunks = chunks := by
      simpa [initial] using chunksEq
    have answersZero : recordedInterpretation.answers = writerAnswersFrom 0 chunks := by
      simpa [initial] using answersEq
    have answerCount : recordedInterpretation.consumed = chunks.length := by
      rw [← interpret_answers_length tree recordSupplied, answersEq,
        writerAnswersFrom_length]
    let replayCoreSupplied := writerAnswersFrom 0 chunks ++
      [.replayExhausted (writerAnswersFrom 0 chunks).length]
    let replaySupplied := replayCoreSupplied ++
      [.oracleExhausted replayCoreSupplied.length,
       .oracleExhausted (replayCoreSupplied.length + 1)]
    have within : recordedInterpretation.consumed < recordSupplied.length := by
      have valueAnswers := writerAnswersFrom_isValue 0 chunks
      have beforeGuard : recordedInterpretation.consumed ≤ (oracleAnswers o).length := by
        apply interpret_consumed_before_oracleExhausted tree (oracleAnswers o)
          (oracleAnswers o).length ((oracleAnswers o).length + 1)
        simpa [recordedInterpretation, recordSupplied, answersZero] using valueAnswers
      rw [answerCount] at beforeGuard
      calc
        recordedInterpretation.consumed = chunks.length := answerCount
        _ ≤ (oracleAnswers o).length := beforeGuard
        _ < recordSupplied.length := by simp [recordSupplied]
    have replayPrefix : replaySupplied.take recordedInterpretation.consumed =
        recordedInterpretation.answers := by
      rw [answerCount, answersZero]
      simp [replaySupplied, replayCoreSupplied, writerAnswersFrom_length]
    have interpretationsEqual : interpret tree replaySupplied = recordedInterpretation :=
      interpret_delivered_congruence tree recordSupplied replaySupplied within replayPrefix
    change evaluateCore fuel p
        ((evaluateCore fuel p (oracleAnswers o)).answersConsumed ++
          [.replayExhausted (evaluateCore fuel p (oracleAnswers o)).answersConsumed.length]) =
      evaluateCore fuel p (oracleAnswers o)
    have recordAnswers : (evaluateCore fuel p (oracleAnswers o)).answersConsumed =
        writerAnswersFrom 0 chunks := by
      simp [evaluateCore, supported, recordedInterpretation, tree, recordSupplied,
        initial, root, resultChunks]
    rw [recordAnswers]
    rw [evaluateCore, evaluateCore, supported]
    change (let interpreted := interpret tree replaySupplied
      let (result, w) := interpreted.value
      ({ stdout := w.stdout
         tape := writerProducedRecords w.writerChunks w.writerTrailing
         answersConsumed := writerAnswersFrom 0 w.writerChunks
         error := match result with | .ok _ => none | .error e => some e } : RunResult)) =
      (let interpreted := recordedInterpretation
      let (result, w) := interpreted.value
      { stdout := w.stdout
        tape := writerProducedRecords w.writerChunks w.writerTrailing
        answersConsumed := writerAnswersFrom 0 w.writerChunks
        error := match result with | .ok _ => none | .error e => some e })
    rw [interpretationsEqual]
  · obtain ⟨construct, unsupported⟩ := Option.ne_none_iff_exists'.mp supported
    change evaluateCore fuel p
        ((evaluateCore fuel p (oracleAnswers o)).answersConsumed ++
          [.replayExhausted (evaluateCore fuel p (oracleAnswers o)).answersConsumed.length]) =
      evaluateCore fuel p (oracleAnswers o)
    simp [evaluateCore, unsupported]

end EigenCore
