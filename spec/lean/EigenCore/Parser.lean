import EigenCore.Syntax
namespace EigenCore
structure Outside where construct : String; line : Nat deriving Repr, BEq
inductive Classification where | inSubset | out (why : Outside) deriving Repr, BEq
private def trim (s : String) := s.trimAscii.toString
private def validIdent (s : String) : Bool := match s.toList with | [] => false | c::cs => (c.isAlpha || c == '_') && cs.all (fun x => x.isAlphanum || x == '_')
private def atom (s : String) : Except String Expr :=
  let t := trim s
  if ["break", "continue", "return", "try", "catch", "for", "import"].contains t then throw "not yet modeled"
  else if t == "true" then pure (.literal (.bool true)) else if t == "false" then pure (.literal (.bool false)) else if t == "null" then pure (.literal .null)
  else if t.startsWith "\"" && t.endsWith "\"" && t.length >= 2 then pure (.literal (.string ((t.drop 1).dropEnd 1).toString))
  else match t.toInt? with | some n => if n.natAbs < 9007199254740992 then pure (.literal (.int n)) else throw "integer literal outside |n| < 2^53" | none => if validIdent t then pure (.variable t) else throw "not yet modeled"
private def expressionFuel : Nat → String → Except String Expr
| 0, _ => throw "expression nesting limit"
| fuel+1, s => do
  let t := trim s
  if t.startsWith "what is " then throw "discarded interrogative"
  else if t.startsWith "(" && t.endsWith ")" then expressionFuel fuel ((t.drop 1).dropEnd 1).toString
  else if t.startsWith "not " then return .not (← expressionFuel fuel (t.drop 4).toString)
  else if t.startsWith "when is " then let n := trim (t.drop 8).toString; if validIdent n then return .when n else throw "not yet modeled"
  let operations : List (String × BinOp) := [(" and ",.and),(" or ",.or),(" == ",.eq),(" != ",.ne),(" <= ",.le),(" >= ",.ge),(" < ",.lt),(" > ",.gt),(" + ",.add),(" - ",.sub),(" * ",.mul)]
  match operations.find? (fun p => t.contains p.1) with
  | some (marker, op) =>
    match t.splitOn marker with
    | [a,b] => pure (.binary op (← expressionFuel fuel a) (← expressionFuel fuel b))
    | _ => throw "not yet modeled"
  | none =>
    match t.splitOn " of [" with
    | [fn, args] =>
      if !args.endsWith "]" then throw "not yet modeled"
      let inside := trim (args.dropEnd 1).toString
      let values ← if inside.isEmpty then pure [] else (inside.splitOn ",").mapM (expressionFuel fuel)
      pure (.call (← atom fn) values)
    | _ => atom t
private def expression (s : String) := expressionFuel (s.length + 1) s
private def splitBinding (s : String) : Option (String × String) := match s.splitOn " is " with | n::rhs => if rhs.isEmpty then none else some (trim n, trim (String.intercalate " is " rhs)) | _ => none
private structure SourceLine where number : Nat; indent : Nat; text : String
private def lineIndent (s : String) : Nat := s.toList.takeWhile (· == ' ') |>.length
private def simple (l : SourceLine) : Except Outside Stmt :=
  let parsed : Except String Stmt :=
    if l.text.startsWith "print of " then do pure (.print (← expression (l.text.drop 9).toString))
    else if l.text.startsWith "return " then do pure (.return_ (← expression (l.text.drop 7).toString))
    else if l.text.startsWith "local " then match splitBinding (l.text.drop 6).toString with | some (n,e) => if validIdent n then do pure (.assign n (← expression e) true) else throw "local declaration" | none => throw "local declaration"
    else match splitBinding l.text with | some (n,e) => if validIdent n then do pure (.assign n (← expression e) false) else throw "assignment target" | none => do pure (.expression (← expression l.text))
  parsed.mapError fun why => ⟨why, l.number⟩

private def parseBlock (lines : Array SourceLine) (start indent fuel : Nat) : Except Outside (List Stmt × Nat) :=
  match fuel with
  | 0 => throw ⟨"parser fuel exhausted", 1⟩
  | f+1 => match lines[start]? with
    | none => pure ([], start)
    | some l =>
      if l.indent < indent then pure ([], start)
      else if l.indent > indent then throw ⟨"unexpected indent", l.number⟩
      else if (l.text.startsWith "if " || l.text.startsWith "elif ") && l.text.endsWith ":" then
        let drop := if l.text.startsWith "if " then 3 else 5
        let condition ← expression ((l.text.drop drop).dropEnd 1).toString |>.mapError fun e => ⟨e,l.number⟩
        let child ← lines[start+1]?.okOr ⟨"empty block",l.number⟩
        if child.indent <= indent then throw ⟨"empty block",l.number⟩
        let (yes, afterYes) ← parseBlock lines (start+1) child.indent f
        let (elifs, otherwise, after) ← match lines[afterYes]? with
          | some e => if e.indent == indent && e.text.startsWith "elif " then do
              let (tail, k) ← parseBlock lines afterYes indent f
              match tail with | .branch c b es no :: more => pure ((c,b)::es, no, k) | _ => throw ⟨"elif",e.number⟩
            else if e.indent == indent && e.text == "else:" then do
              let ec ← lines[afterYes+1]?.okOr ⟨"empty block",e.number⟩
              let (body,k) ← parseBlock lines (afterYes+1) ec.indent f
              pure ([], some body, k)
            else pure ([], none, afterYes)
          | none => pure ([],none,afterYes)
        let (rest,k) ← parseBlock lines after indent f
        pure (.branch condition yes elifs otherwise :: rest, k)
      else if l.text.startsWith "loop while " && l.text.endsWith ":" then
        let condition ← expression ((l.text.drop 11).dropEnd 1).toString |>.mapError fun e => ⟨e,l.number⟩
        let child ← lines[start+1]?.okOr ⟨"empty block",l.number⟩
        if child.indent <= indent then throw ⟨"empty block",l.number⟩
        let (body, after) ← parseBlock lines (start+1) child.indent f
        let (rest,k) ← parseBlock lines after indent f
        pure (.loop condition body :: rest,k)
      else if l.text == "else:" then pure ([],start)
      else if l.text.startsWith "define " && l.text.endsWith " as:" then
        let sig := trim ((l.text.drop 7).dropEnd 4).toString
        let name := (sig.splitOn "(").head!
        if !validIdent name then throw ⟨"function definition",l.number⟩
        let child ← lines[start+1]?.okOr ⟨"empty block",l.number⟩
        let (body,after) ← parseBlock lines (start+1) child.indent f
        let (rest,k) ← parseBlock lines after indent f
        pure (.define name [] body :: rest,k)
      else
        let stmt ← simple l
        let (rest,k) ← parseBlock lines (start+1) indent f
        pure (stmt::rest,k)

/-- The classifier and evaluator share this single AST-producing parser. -/
def parse (source : String) : Except Outside Program := do
  let lines := ((source.splitOn "\n").zipIdx.filterMap fun (raw,n) =>
    let text := trim ((raw.splitOn "#").head!)
    if text.isEmpty then none else some {number:=n+1, indent:=lineIndent raw, text:=text}).toArray
  let (p,after) ← parseBlock lines 0 0 (lines.size+1)
  if after == lines.size then pure p else throw ⟨"unparsed input",lines[after]!.number⟩

def classify (source : String) : Classification := match parse source with
  | .ok _ => .inSubset | .error why => .out why
end EigenCore
