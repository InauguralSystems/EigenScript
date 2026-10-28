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

private def decodeString (s : String) : String :=
  let rec decode : List Char → List Char
    | [] => []
    | '\\' :: c :: rest =>
        (match c with | 'n' => '\n' | 't' => '\t' | 'r' => '\r' | other => other) :: decode rest
    | c :: rest => c :: decode rest
  String.ofList (decode s.toList)

private def splitTopLevel (source marker : String) : List String :=
  let needle := marker.toList
  let rec scan : Nat → List Char → List Char → List String → Nat → Nat → Bool → Bool → List String
    | 0, _, current, parts, _, _, _, _ =>
      (String.ofList current.reverse :: parts).reverse
    | _ + 1, [], current, parts, _, _, _, _ =>
      (String.ofList current.reverse :: parts).reverse
    | fuel + 1, remaining@(c :: rest), current, parts, parenDepth, bracketDepth,
        inString, escaped =>
      if !needle.isEmpty && !inString && parenDepth == 0 && bracketDepth == 0 &&
          needle.isPrefixOf remaining then
        scan fuel (remaining.drop needle.length) [] (String.ofList current.reverse :: parts)
          parenDepth bracketDepth inString false
      else
        let nextString := if c == '"' && !escaped then !inString else inString
        let nextEscaped := inString && !escaped && c == '\\'
        let nextParen :=
          if inString then parenDepth
          else if c == '(' then parenDepth + 1
          else if c == ')' then parenDepth - 1
          else parenDepth
        let nextBracket :=
          if inString then bracketDepth
          else if c == '[' then bracketDepth + 1
          else if c == ']' then bracketDepth - 1
          else bracketDepth
        scan fuel rest (c :: current) parts nextParen nextBracket nextString nextEscaped
  scan (source.length + 1) source.toList [] [] 0 0 false false

private def atom (s : String) : Except String Expr :=
  let t := trim s
  if ["break", "continue", "return", "try", "catch", "for", "import"].contains t then
    throw "not yet modeled"
  else if t == "true" then pure (.literal (.bool true))
  else if t == "false" then pure (.literal (.bool false))
  else if t == "null" then pure (.literal .null)
  else if t.startsWith "\"" && t.endsWith "\"" && t.length >= 2 then
    pure (.literal (.string (decodeString ((t.drop 1).dropEnd 1).toString)))
  else
    match t.toInt? with
    | some n => if n.natAbs < 9007199254740992 then pure (.literal (.int n)) else throw "integer literal outside |n| < 2^53"
    | none => if validIdent t then pure (.variable t) else throw "not yet modeled"

private def matchingOuter (opener closer : Char) (source : String) : Bool :=
  let chars := source.toList
  let rec loop : List Char → Nat → Bool → Bool → Bool
    | [], depth, _, _ => depth == 0
    | c :: rest, depth, quoted, escaped =>
      if quoted then loop rest depth (c != '"' || escaped) (c == '\\' && !escaped)
      else if c == '"' then loop rest depth true false
      else if c == opener then loop rest (depth + 1) false false
      else if c == closer then
        if depth == 1 then rest.isEmpty else depth > 1 && loop rest (depth - 1) false false
      else loop rest depth false false
  chars.head? == some opener && loop chars 0 false false

private def expressionFuel : Nat → String → Except String Expr
  | 0, _ => throw "expression nesting limit"
  | fuel + 1, source =>
    let t := trim source
    if t.startsWith "what is " then throw "discarded interrogative"
    else if matchingOuter '(' ')' t then expressionFuel fuel ((t.drop 1).dropEnd 1).toString
    else if matchingOuter '[' ']' t then do
      let inside := trim ((t.drop 1).dropEnd 1).toString
      let values ← if inside.isEmpty then pure [] else (splitTopLevel inside ",").mapM (expressionFuel fuel)
      pure (.array values)
    else
      -- `or`, then `and`, then `not`, then comparisons (#1648).  Looking
      -- for the lower-precedence binary words before the prefix is what makes
      -- `not true and false` split as `(not true) and false`, while delaying
      -- every comparison until after the prefix makes `not 1 < 2` negate it.
      let logic : List (String × BinOp) := [(" or ", .or), (" and ", .and)]
      match logic.find? (fun p => (splitTopLevel t p.1).length > 1) with
      | some (marker, op) =>
        match splitTopLevel t marker with
        | [a, b] => do pure (.binary op (← expressionFuel fuel a) (← expressionFuel fuel b))
        | _ => throw "not yet modeled"
      | none =>
        if t.startsWith "not " then do pure (.not (← expressionFuel fuel (t.drop 4).toString))
        else if t.startsWith "when is " then
          let name := trim (t.drop 8).toString
          if validIdent name then pure (.when name) else throw "not yet modeled"
        else
          -- Everything below `not` is an operand position in which the C
          -- grammar starts at comparison-or-tighter, so an unparenthesized
          -- `not` is a parse error rather than another recursive expression.
          let operand (s : String) : Except String Expr :=
            if (trim s).startsWith "not " then
              throw "unexpected 'not' in expression (not binds below comparisons and of; parenthesize it)"
            else expressionFuel fuel s
          let operations : List (String × BinOp) :=
            [(" == ", .eq), (" != ", .ne), (" <= ", .le), (" >= ", .ge),
             (" < ", .lt), (" > ", .gt), (" + ", .add), (" - ", .sub), (" * ", .mul)]
          match operations.find? (fun p => (splitTopLevel t p.1).length > 1) with
          | some (marker, op) =>
            match splitTopLevel t marker with
            | [a, b] => do pure (.binary op (← operand a) (← operand b))
            | _ => throw "not yet modeled"
          | none =>
            -- `of` is relation precedence in C: its RHS is unary-or-tighter.
            -- Since lower-precedence operators were split above, they apply
            -- to the result of this call rather than being swallowed by it.
            match splitTopLevel t " of " with
            | [fn, arg] =>
              let packed := trim arg
              if matchingOuter '[' ']' packed then do
                let inside := trim ((packed.drop 1).dropEnd 1).toString
                let values ← if inside.isEmpty then pure [] else
                  (splitTopLevel inside ",").mapM (expressionFuel fuel)
                pure (.call (← operand fn) values)
              else do pure (.call (← operand fn) [← operand arg])
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
    else if line.contents.startsWith "print of " then do
      -- Parse the complete expression so a lower-precedence suffix is not
      -- captured as print's argument.  This branch merely prevents `is`
      -- inside that expression from being mistaken for statement assignment.
      let value ← expression line.contents
      match value with
      | .call (.variable "print") [argument] => pure (.print argument)
      | _ => pure (.expression value)
    else if line.contents.startsWith "return " then do pure (.return_ (← expression (line.contents.drop 7).toString))
    else if line.contents.startsWith "local " then
      match splitBinding (line.contents.drop 6).toString with
      | some (name, value) => if validIdent name then do pure (.assign name (← expression value) true) else throw "local declaration"
      | none => throw "local declaration"
    else
      match splitBinding line.contents with
      | some (name, value) => if validIdent name then do pure (.assign name (← expression value) false) else throw "assignment target"
      | none => do
        let value ← expression line.contents
        -- `print of x` is ordinary expression-level `of` syntax.  Only a
        -- whole-line print call is represented by the statement node; a call
        -- nested in `print of x and y` remains an expression and returns null.
        match value with
        | .call (.variable "print") [argument] => pure (.print argument)
        | _ => pure (.expression value)
  parsed.mapError fun why => ⟨why, line.number⟩

private def isLoop : Stmt → Bool
  | .loop _ _ => true
  | _ => false

private def definitionSignature (signature : String) : Except String (String × List String) :=
  match signature.splitOn "(" with
  | [name] =>
    let name := trim name
    if validIdent name then pure (name, ["n"]) else throw "function definition"
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

private def unsupportedExpr (functions : List String) : Nat → Expr → Option String
  | 0, _ => some "support-check nesting limit"
  | _, .literal _ | _, .when _ => none
  | _, .variable name =>
      if name == "converged" || name == "__loop_exit__" || name == "__loop_iterations__" then
        some s!"builtin {name}"
      else none
  | fuel + 1, .binary _ left right => unsupportedExpr functions fuel left |>.orElse (fun _ => unsupportedExpr functions fuel right)
  | fuel + 1, .not value => unsupportedExpr functions fuel value
  | _, .array _ => some "array literal"
  | fuel + 1, .call (.variable "print") [value] => unsupportedExpr functions fuel value
  | fuel + 1, .call (.variable name) arguments =>
      if ["converged", "loop_iterations", "loop_exit"].contains name then
        some s!"builtin {name}"
      else if functions.contains name || name.startsWith "undefined_" then
        arguments.findSome? (unsupportedExpr functions fuel)
      else some s!"call to unmodeled function {name}"
  | fuel + 1, .call function arguments =>
      unsupportedExpr functions fuel function |>.orElse (fun _ => arguments.findSome? (unsupportedExpr functions fuel))
  | _, .prev _ => some "prev"
  | _, .whatWhen _ _ => some "what-when"

private def unsupportedStmts (functions : List String) (insideFunction : Bool) : Nat → List Stmt → Option String
  | 0, _ => some "support-check nesting limit"
  | _, [] => none
  | fuel + 1, statement :: rest =>
      let here := match statement with
        | .assign _ value _ | .print value | .return_ value | .expression value =>
            unsupportedExpr functions fuel value
        | .branch condition yes elifs otherwise =>
            unsupportedExpr functions fuel condition
              |>.orElse (fun _ => unsupportedStmts functions insideFunction fuel yes)
              |>.orElse (fun _ => elifs.findSome? fun (arm : Expr × List Stmt) =>
                unsupportedExpr functions fuel arm.1 |>.orElse (fun _ => unsupportedStmts functions insideFunction fuel arm.2))
              |>.orElse (fun _ => otherwise.bind (unsupportedStmts functions insideFunction fuel))
        | .loop condition body =>
            unsupportedExpr functions fuel condition |>.orElse (fun _ => unsupportedStmts functions insideFunction fuel body)
        | .define _ parameters body =>
            if parameters.length > 16 then some "function exceeds 16 parameters"
            else unsupportedStmts functions true fuel body
      here.orElse (fun _ => unsupportedStmts functions insideFunction fuel rest)

/-- The single support predicate used by both classification and evaluation. -/
def unsupportedConstruct (program : Program) : Option String :=
  let rec callableNames : Nat → List Stmt → List String
    | 0, _ => []
    | _, [] => []
    | fuel + 1, statement :: rest =>
      let here := match statement with
        | .define name _ body => name :: callableNames fuel body
        -- A stored return value is the surface form used for returned closures.
        | .assign name (.call _ _) _ => [name]
        | .branch _ yes elifs otherwise =>
            callableNames fuel yes ++ elifs.flatMap (callableNames fuel ∘ Prod.snd) ++
              otherwise.toList.flatMap (callableNames fuel)
        | .loop _ body => callableNames fuel body
        | _ => []
      here ++ callableNames fuel rest
  let functions := callableNames 100000 program
  unsupportedStmts functions false 100000 program

def classifyModeled (source : String) : Classification :=
  match parse source with
  | .error why =>
      -- This is a modeled parse rejection, not an unsupported source shape:
      -- parity must execute it and compare the C/Lean error exit classes.
      if why.construct.startsWith "unexpected 'not' in expression" then .inSubset else .out why
  | .ok program => match unsupportedConstruct program with
    | some construct => .out ⟨s!"unsupported in EigenCore-0 step 2b-iii: {construct}", 1⟩
    | none => .inSubset

def classify (source : String) : Classification :=
  match parse source with
  | .ok program =>
    -- Array literals are recognized only so nested call argument packs can be
    -- delimited.  They remain outside the step-1 language on their own.
    let rec standaloneArrayExpr : Expr → Bool
      | .array _ => true
      | .binary _ left right => standaloneArrayExpr left || standaloneArrayExpr right
      | .not value => standaloneArrayExpr value
      | .call _ _ => false
      | _ => false
    let rec standaloneArrayStmts : Nat → List Stmt → Bool
      | 0, _ => false
      | _, [] => false
      | fuel + 1, statement :: rest =>
        let here := match statement with
          | .assign _ value _ | .print value | .return_ value | .expression value => standaloneArrayExpr value
          | .branch condition yes elifs otherwise =>
            standaloneArrayExpr condition || standaloneArrayStmts fuel yes ||
              elifs.any (fun arm => standaloneArrayExpr arm.1 || standaloneArrayStmts fuel arm.2) ||
              otherwise.any (standaloneArrayStmts fuel)
          | .loop condition body => standaloneArrayExpr condition || standaloneArrayStmts fuel body
          | .define _ _ body => standaloneArrayStmts fuel body
        here || standaloneArrayStmts fuel rest
    if standaloneArrayStmts 100000 program then .out ⟨"not yet modeled", 1⟩ else .inSubset
  | .error why =>
      if why.construct.startsWith "unexpected 'not' in expression" then .inSubset else .out why

end EigenCore
