import EigenCore.Parser
import EigenCore.Value
import Std.Data.String.ToInt
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
  deriving Repr, BEq

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

def normalizeTape (tape : List String) : List TapedAnswer :=
  normalizeTapeFrom 0 tape

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
theorem record_run_invariant (fn : String) (raw : OracleValue)
    (answer : WriterAnswer) (accepted : writerAnswerFor fn raw = .ok answer) :
    answer.name = fn ∧ answer.value = raw := by
  unfold writerAnswerFor at accepted
  split at accepted <;> try contradiction
  all_goals
    change Except.ok _ = Except.ok answer at accepted
    injection accepted with same
    subst answer
    simp [WriterAnswer.name, WriterAnswer.value]

private def consumeAnswer (fn : String) : EvalM Value := do
  let w ← get
  let position := w.writerChunks.length
  let supplied : TapedAnswer ← liftM
    (Interaction.ask {name := fn} (fun answer => Interaction.done answer))
  let raw ← match supplied with
    | TapedAnswer.oracleExhausted _ => throw (.runtime s!"{fn}: oracle exhausted at value {position}")
    | .replayError _ error => throw error
    | .replayExhausted _ => throw (.runtime s!"{fn}: replay stream 0 has no matching recorded N value")
    | .value _ recordedName value =>
      if !recordedName.isEmpty && recordedName != fn then
        throw (.replay s!"replay name mismatch: tape has '{recordedName}', program called '{fn}'")
      else pure value
  let answer ← writerAnswerFor fn raw
  let value := answer.runtimeValue
  let chunk : WriterChunk := {structural := w.writerTrailing, answer := answer}
  set {w with writerChunks := w.writerChunks ++ [chunk], writerTrailing := []}
  pure value

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

end EigenCore
