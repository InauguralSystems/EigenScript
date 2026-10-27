import EigenCore.Syntax

namespace EigenCore

structure Outside where
  construct : String
  line : Nat
  deriving Repr, BEq

inductive Classification where
  | inSubset
  | out (why : Outside)
  deriving Repr, BEq


private def trim (s : String) : String :=
  String.ofList (s.toList.dropWhile Char.isWhitespace |>.reverse.dropWhile Char.isWhitespace |>.reverse)

private def identStart (c : Char) := c.isAlpha || c == '_'
private def identRest (c : Char) := c.isAlphanum || c == '_'
private def validIdent (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: cs => identStart c && cs.all identRest

private def indentation (s : String) : Nat × String :=
  let rec go (cs : List Char) (width : Nat) : Nat × List Char :=
    match cs with
    | ' ' :: rest => go rest (width + 1)
    | '\t' :: rest => go rest (((width / 4) + 1) * 4)
    | rest => (width, rest)
  let (n, rest) := go s.toList 0
  (n, String.ofList rest)

/-- Removes a comment, respecting the C lexer's double-quoted string rule. -/
private def withoutComment (s : String) : String :=
  let rec go (cs : List Char) (quoted escaped : Bool) (acc : List Char) :=
    match cs with
    | [] => String.ofList acc.reverse
    | c :: rest =>
      if escaped then go rest quoted false (c :: acc)
      else if quoted && c == '\\' then go rest quoted true (c :: acc)
      else if c == '"' then go rest (!quoted) false (c :: acc)
      else if c == '#' && !quoted then String.ofList acc.reverse
      else go rest quoted false (c :: acc)
  go s.toList false false []

private def words (s : String) : List String :=
  let flush (cur : List Char) (out : List String) :=
    if cur.isEmpty then out else String.ofList cur.reverse :: out
  let rec scan (cs : List Char) (quoted escaped : Bool) (cur : List Char) (out : List String) :=
    match cs with
    | [] => (flush cur out).reverse
    | c :: rest =>
      if escaped then scan rest quoted false (c :: cur) out
      else if quoted && c == '\\' then scan rest quoted true (c :: cur) out
      else if c == '"' then scan rest (!quoted) false (c :: cur) out
      else if !quoted && (c.isWhitespace || "()[],:".contains c) then
        let out := flush cur out
        scan rest quoted false [] (if c.isWhitespace then out else c.toString :: out)
      else if !quoted && "=<>!+-*/%".contains c then
        scan rest false false [] (c.toString :: flush cur out)
      else scan rest quoted false (c :: cur) out
  let rec merge : List String → List String
    | a :: "=" :: rest => if ["=", "!", "<", ">"].contains a then (a ++ "=") :: merge rest else a :: "=" :: merge rest
    | a :: rest => a :: merge rest
    | [] => []
  merge (scan s.toList false false [] [])

private def intMagnitudeOK (t : String) : Bool :=
  let raw := if t.startsWith "-" then (t.drop 1).toString else t
  if raw.isEmpty || !raw.toList.all Char.isDigit then false
  else match raw.toNat? with
    | some n => n < 9007199254740992
    | none => false

private def firstBadToken (ts : List String) : Option String :=
  let excluded := ["for", "in", "try", "catch", "break", "continue", "import", "match", "case",
    "report", "unobserved", "=>", "at", "who", "where", "why", "how"]
  let allowed := ["(", ")", "[", "]", ",", "+", "-", "*", "==", "!=",
    "<", "<=", ">", ">=", "and", "or", "not", "of", "is", "what", "when",
    "prev", "true", "false", "null"]
  let rec loop : List String → Option String
    | [] => none
    | t :: rest =>
      if excluded.contains t then some s!"{t} construct"
      else if t.startsWith "\"" then
        if t.length >= 2 && t.endsWith "\"" then loop rest else some "unterminated string literal"
      else if t.any (fun c => c == '.') || t.contains 'e' && t.toList.any Char.isDigit then
        some "float literal"
      else if t == "/" then some "division"
      else if t == "%" then some "modulo"
      else if t.toList.all Char.isDigit then
        if intMagnitudeOK t then loop rest else some "integer literal outside |n| < 2^53"
      else if allowed.contains t || validIdent t then loop rest
      else some s!"token '{t}'"
  loop ts

private def statementExpression (line : String) : Except String String :=
  let t := line |> trim
  if t.startsWith "local " then
    let r := (t.drop 6).toString |> trim
    match r.splitOn " is " with
    | [_name, expr] => pure expr
    | _ => throw "local declaration"
  else if t.startsWith "return " then pure (t.drop 7).toString
  else if t.startsWith "print of " then pure (t.drop 9).toString
  else if t.startsWith "loop while " && t.endsWith ":" then pure ((t.drop 11).dropEnd 1).toString
  else if (t.startsWith "if " || t.startsWith "elif ") && t.endsWith ":" then
    pure ((t.drop (if t.startsWith "if " then 3 else 5)).dropEnd 1).toString
  else if t == "else:" then pure "true"
  else if t.startsWith "define " && t.endsWith ":" then
    let head := ((t.drop 7).dropEnd 1).toString |> trim
    let name := (head.splitOn "(").head!
    if validIdent name && (head.splitOn " as").length > 1 then pure "true" else throw "function definition"
  else
    match t.splitOn " is " with
    | [name, expr] => if validIdent (trim name) then pure expr else throw "assignment target"
    | _ => pure t

private def classifyLine (line : String) (lineNo : Nat) : Option Outside :=
  let (_, body) := indentation line
  let clean := trim (withoutComment body)
  if clean.isEmpty then none
  else
    match statementExpression clean with
    | .error why => some ⟨why, lineNo⟩
    | .ok expr =>
      match firstBadToken (words expr) with
      | some why => some ⟨why, lineNo⟩
      | none =>
        let ts := words clean
        if ts.contains "[" && !ts.contains "of" then some ⟨"list literal", lineNo⟩ else none

private def indentationError (source : String) : Option Outside :=
  let rec loop (lines : List String) (lineNo current : Nat) (levels : List Nat)
      (previousOpened : Bool) : Option Outside :=
    match lines with
    | [] => none
    | line :: rest =>
      let (width, body) := indentation line
      let clean := trim (withoutComment body)
      if clean.isEmpty then loop rest (lineNo + 1) current levels previousOpened
      else if width > current then
        if previousOpened then loop rest (lineNo + 1) width (width :: levels) (clean.endsWith ":")
        else some ⟨"unexpected indent", lineNo⟩
      else if width < current then
        if levels.contains width then loop rest (lineNo + 1) width (levels.dropWhile (· > width)) (clean.endsWith ":")
        else some ⟨"inconsistent dedent", lineNo⟩
      else loop rest (lineNo + 1) current levels (clean.endsWith ":")
  loop (source.splitOn "\n") 1 0 [0] false

/-- Classify source without accepting an unsupported construct by recovery. -/
def classify (source : String) : Classification :=
  let rec loop (lines : List String) (n : Nat) : Classification :=
    match lines with
    | [] => .inSubset
    | line :: rest => match classifyLine line n with
      | some why => .out why
      | none => loop rest (n + 1)
  match indentationError source, loop (source.splitOn "\n") 1 with
  | some indentWhy, .out syntaxWhy => if indentWhy.line <= syntaxWhy.line then .out indentWhy else .out syntaxWhy
  | some why, _ => .out why
  | none, result => result

/-- Step 1 validates and classifies syntax; construction is completed with semantics in step 2. -/
def parse (source : String) : Except Outside Program :=
  match classify source with
  | .inSubset => pure []
  | .out why => throw why

end EigenCore
