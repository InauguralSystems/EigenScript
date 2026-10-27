import EigenCore.Parser
namespace EigenCore
private def trim (s : String) := s.trimAscii.toString
private def validIdent (s : String) : Bool := match s.toList with | [] => false | c::cs => (c.isAlpha || c == '_') && cs.all (fun x => x.isAlphanum || x == '_')
private def atom (s : String) : Except String Expr :=
  let t := trim s
  if ["break", "continue", "return", "try", "catch", "for", "import"].contains t then throw "not yet modeled"
  else if t == "true" then pure (.literal (.bool true)) else if t == "false" then pure (.literal (.bool false)) else if t == "null" then pure (.literal .null)
  else if t.startsWith "\"" && t.endsWith "\"" && t.length >= 2 then pure (.literal (.string ((t.drop 1).dropEnd 1).toString))
  else match t.toInt? with | some n => if n.natAbs < 9007199254740992 then pure (.literal (.int n)) else throw "integer literal outside |n| < 2^53" | none => if validIdent t then pure (.variable t) else throw "not yet modeled"
private def expression (s : String) : Except String Expr := do
  let t := trim s
  if t.startsWith "not " then return .not (← atom (t.drop 4).toString)
  else if t.startsWith "when is " then let n := trim (t.drop 8).toString; if validIdent n then return .when n else throw "not yet modeled"
  let operations : List (String × BinOp) := [(" and ",.and),(" or ",.or),(" == ",.eq),(" != ",.ne),(" <= ",.le),(" >= ",.ge),(" < ",.lt),(" > ",.gt),(" + ",.add),(" - ",.sub),(" * ",.mul)]
  match operations.find? (fun p => t.contains p.1) with
  | some (marker, op) =>
    match t.splitOn marker with
    | [a,b] => pure (.binary op (← atom a) (← atom b))
    | _ => throw "not yet modeled"
  | none => atom t
private def splitBinding (s : String) : Option (String × String) := match s.splitOn " is " with | n::rhs => if rhs.isEmpty then none else some (trim n, trim (String.intercalate " is " rhs)) | _ => none
/-- Executable step-2 part: flat expressions/statements. Blocks, functions, calls,
closures, most history readers, and taped builtins are explicitly not yet modeled. -/
def parseRuntime (source : String) : Except Outside Program :=
  let rec go (lines : List String) (number : Nat) (acc : List Stmt) := match lines with
    | [] => pure acc.reverse
    | raw::rest =>
      let clean := trim (raw.splitOn "#").head!
      if clean.isEmpty then go rest (number+1) acc
      else if raw.startsWith " " || raw.startsWith "\t" || clean.endsWith ":" || clean.startsWith "define " then throw ⟨"not yet modeled",number⟩
      else
        let parsed : Except String Stmt :=
          if clean.startsWith "print of " then do pure (.print (← expression (clean.drop 9).toString))
          else if clean.startsWith "local " then match splitBinding (clean.drop 6).toString with | some (n,e) => if validIdent n then do pure (.assign n (← expression e) true) else throw "local declaration" | none => throw "local declaration"
          else match splitBinding clean with | some (n,e) => if validIdent n then do pure (.assign n (← expression e) false) else throw "assignment target" | none => do pure (.expression (← expression clean))
        match parsed with | .ok stmt => go rest (number+1) (stmt::acc) | .error why => throw ⟨why,number⟩
  go (source.splitOn "\n") 1 []
end EigenCore
