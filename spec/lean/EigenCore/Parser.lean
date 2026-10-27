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

private def trim (s : String) : String := s.trimAscii.toString

private def validIdent (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: cs => (c.isAlpha || c == '_') && cs.all (fun x => x.isAlphanum || x == '_')

private def atom (s : String) : Except String Expr :=
  let t := trim s
  if ["break", "continue", "return", "try", "catch", "for", "import"].contains t then
    throw "not yet modeled"
  else if t == "true" then pure (.literal (.bool true))
  else if t == "false" then pure (.literal (.bool false))
  else if t == "null" then pure (.literal .null)
  else if t.startsWith "\"" && t.endsWith "\"" && t.length >= 2 then
    pure (.literal (.string ((t.drop 1).dropEnd 1).toString))
  else
    match t.toInt? with
    | some n => if n.natAbs < 9007199254740992 then pure (.literal (.int n)) else throw "integer literal outside |n| < 2^53"
    | none => if validIdent t then pure (.variable t) else throw "not yet modeled"

private def expressionFuel : Nat → String → Except String Expr
  | 0, _ => throw "expression nesting limit"
  | fuel + 1, source =>
    let t := trim source
    if t.startsWith "what is " then throw "discarded interrogative"
    else if t.startsWith "(" && t.endsWith ")" then expressionFuel fuel ((t.drop 1).dropEnd 1).toString
    else if t.startsWith "not " then do pure (.not (← expressionFuel fuel (t.drop 4).toString))
    else if t.startsWith "when is " then
      let name := trim (t.drop 8).toString
      if validIdent name then pure (.when name) else throw "not yet modeled"
    else
      let operations : List (String × BinOp) :=
        [(" and ", .and), (" or ", .or), (" == ", .eq), (" != ", .ne), (" <= ", .le),
         (" >= ", .ge), (" < ", .lt), (" > ", .gt), (" + ", .add), (" - ", .sub), (" * ", .mul)]
      match operations.find? (fun p => t.contains p.1) with
      | some (marker, op) =>
        match t.splitOn marker with
        | [a, b] => do pure (.binary op (← expressionFuel fuel a) (← expressionFuel fuel b))
        | _ => throw "not yet modeled"
      | none =>
        match t.splitOn " of [" with
        | [fn, args] => do
          if !args.endsWith "]" then throw "not yet modeled"
          let inside := trim (args.dropEnd 1).toString
          let values ← if inside.isEmpty then pure [] else (inside.splitOn ",").mapM (expressionFuel fuel)
          pure (.call (← atom fn) values)
        | _ => atom t

private def expression (s : String) : Except String Expr := expressionFuel (s.length + 1) s

private def splitBinding (s : String) : Option (String × String) :=
  match s.splitOn " is " with
  | name :: rhs => if rhs.isEmpty then none else some (trim name, trim (String.intercalate " is " rhs))
  | _ => none

private structure SourceLine where
  number : Nat
  indentation : Nat
  contents : String

private def lineIndent (s : String) : Nat := s.toList.takeWhile (· == ' ') |>.length

private def requireLine (line : Option SourceLine) (error : Outside) : Except Outside SourceLine :=
  match line with
  | some value => pure value
  | none => throw error

private def simple (line : SourceLine) : Except Outside Stmt :=
  let parsed : Except String Stmt :=
    if line.contents.startsWith "what is " then throw "discarded interrogative"
    else if line.contents.startsWith "print of " then do pure (.print (← expression (line.contents.drop 9).toString))
    else if line.contents.startsWith "return " then do pure (.return_ (← expression (line.contents.drop 7).toString))
    else if line.contents.startsWith "local " then
      match splitBinding (line.contents.drop 6).toString with
      | some (name, value) => if validIdent name then do pure (.assign name (← expression value) true) else throw "local declaration"
      | none => throw "local declaration"
    else
      match splitBinding line.contents with
      | some (name, value) => if validIdent name then do pure (.assign name (← expression value) false) else throw "assignment target"
      | none => do pure (.expression (← expression line.contents))
  parsed.mapError fun why => ⟨why, line.number⟩

private def isLoop : Stmt → Bool
  | .loop _ _ => true
  | _ => false

private def definitionSignature (signature : String) : Except String (String × List String) :=
  match signature.splitOn "(" with
  | [name] =>
    let name := trim name
    if validIdent name then pure (name, []) else throw "function definition"
  | [name, parameters] => do
    if !parameters.endsWith ")" then throw "function definition"
    let name := trim name
    let inside := trim (parameters.dropEnd 1).toString
    let parameters := if inside.isEmpty then [] else (inside.splitOn ",").map trim
    if validIdent name && parameters.all validIdent then pure (name, parameters)
    else throw "function definition"
  | _ => throw "function definition"

private def parseBlock (lines : Array SourceLine) (start indentation fuel : Nat) : Except Outside (List Stmt × Nat) :=
  match fuel with
  | 0 => throw ⟨"parser fuel exhausted", 1⟩
  | remaining + 1 =>
    match lines[start]? with
    | none => pure ([], start)
    | some line => do
      if line.indentation < indentation then return ([], start)
      if line.indentation > indentation then throw ⟨"unexpected indent", line.number⟩
      if (line.contents.startsWith "if " || line.contents.startsWith "elif ") && line.contents.endsWith ":" then
        let prefixLength := if line.contents.startsWith "if " then 3 else 5
        let condition ← expression ((line.contents.drop prefixLength).dropEnd 1).toString |>.mapError fun why => ⟨why, line.number⟩
        let child ← requireLine lines[start + 1]? ⟨"empty block", line.number⟩
        if child.indentation <= indentation then throw ⟨"empty block", line.number⟩
        let (yes, afterYes) ← parseBlock lines (start + 1) child.indentation remaining
        match lines[afterYes]? with
        | some next =>
          if next.indentation == indentation && next.contents.startsWith "elif " then
            let (tail, after) ← parseBlock lines afterYes indentation remaining
            match tail with
            | .branch c body elifs otherwise :: rest => pure (.branch condition yes ((c, body) :: elifs) otherwise :: rest, after)
            | _ => throw ⟨"malformed elif", next.number⟩
          else if next.indentation == indentation && next.contents == "else:" then
            let child ← requireLine lines[afterYes + 1]? ⟨"empty block", next.number⟩
            if child.indentation <= indentation then throw ⟨"empty block", next.number⟩
            let (otherwise, afterElse) ← parseBlock lines (afterYes + 1) child.indentation remaining
            let (rest, after) ← parseBlock lines afterElse indentation remaining
            pure (.branch condition yes [] (some otherwise) :: rest, after)
          else
            let (rest, after) ← parseBlock lines afterYes indentation remaining
            pure (.branch condition yes [] none :: rest, after)
        | none => pure ([.branch condition yes [] none], afterYes)
      else if line.contents.startsWith "loop while " && line.contents.endsWith ":" then
        let condition ← expression ((line.contents.drop 11).dropEnd 1).toString |>.mapError fun why => ⟨why, line.number⟩
        let child ← requireLine lines[start + 1]? ⟨"empty block", line.number⟩
        if child.indentation <= indentation then throw ⟨"empty block", line.number⟩
        let (body, afterBody) ← parseBlock lines (start + 1) child.indentation remaining
        if body.any isLoop then throw ⟨"nested loop", line.number⟩
        let (rest, after) ← parseBlock lines afterBody indentation remaining
        pure (.loop condition body :: rest, after)
      else if line.contents == "else:" || line.contents.startsWith "elif " then
        pure ([], start)
      else if line.contents.startsWith "define " && line.contents.endsWith " as:" then
        let signature := trim ((line.contents.drop 7).dropEnd 4).toString
        let (name, parameters) ← definitionSignature signature |>.mapError fun why => ⟨why, line.number⟩
        let child ← requireLine lines[start + 1]? ⟨"empty block", line.number⟩
        if child.indentation <= indentation then throw ⟨"empty block", line.number⟩
        let (body, afterBody) ← parseBlock lines (start + 1) child.indentation remaining
        let (rest, after) ← parseBlock lines afterBody indentation remaining
        pure (.define name parameters body :: rest, after)
      else
        let statement ← simple line
        let (rest, after) ← parseBlock lines (start + 1) indentation remaining
        pure (statement :: rest, after)

/-- The classifier and evaluator share this single AST-producing parser. -/
def parse (source : String) : Except Outside Program := do
  let lines := ((source.splitOn "\n").zipIdx.filterMap fun (raw, index) =>
    let contents := trim ((raw.splitOn "#").head!)
    if contents.isEmpty then none
    else some { number := index + 1, indentation := lineIndent raw, contents }).toArray
  let (program, after) ← parseBlock lines 0 0 (lines.size + 1)
  if after == lines.size then pure program
  else
    match lines[after]? with
    | some line => throw ⟨"unparsed input", line.number⟩
    | none => throw ⟨"unparsed input", 1⟩

private def unsupportedExpr : Expr → Option String
  | .literal _ | .when _ => none
  | .variable name =>
      if name == "converged" || name == "__loop_exit__" || name == "__loop_iterations__" then
        some s!"builtin {name}"
      else none
  | .binary _ left right => unsupportedExpr left |>.orElse (fun _ => unsupportedExpr right)
  | .not value => unsupportedExpr value
  | .call (.variable name) _ =>
      if ["converged", "loop_iterations", "loop_exit"].contains name then
        some s!"builtin {name}"
      else
        some "function call"
  | .call _ _ => some "function call"
  | .prev _ => some "prev"
  | .whatWhen _ _ => some "what-when"

private def unsupportedStmts : Nat → List Stmt → Option String
  | 0, _ => some "support-check nesting limit"
  | _, [] => none
  | fuel + 1, statement :: rest =>
      let here := match statement with
        | .assign _ value _ | .print value | .return_ value | .expression value =>
            unsupportedExpr value
        | .branch condition yes elifs otherwise =>
            unsupportedExpr condition
              |>.orElse (fun _ => unsupportedStmts fuel yes)
              |>.orElse (fun _ => elifs.findSome? fun (arm : Expr × List Stmt) =>
                unsupportedExpr arm.1 |>.orElse (fun _ => unsupportedStmts fuel arm.2))
              |>.orElse (fun _ => otherwise.bind (unsupportedStmts fuel))
        | .loop condition body =>
            unsupportedExpr condition |>.orElse (fun _ => unsupportedStmts fuel body)
        | .define _ _ _ => some "function definition"
      here.orElse (fun _ => unsupportedStmts fuel rest)

/-- The single support predicate used by both classification and evaluation. -/
def unsupportedConstruct (program : Program) : Option String := unsupportedStmts 100000 program

def classifyModeled (source : String) : Classification :=
  match parse source with
  | .error why => .out why
  | .ok program => match unsupportedConstruct program with
    | some construct => .out ⟨s!"unsupported in EigenCore-0 step 2a: {construct}", 1⟩
    | none => .inSubset

def classify (source : String) : Classification :=
  match parse source with
  | .ok _ => .inSubset
  | .error why => .out why

end EigenCore
