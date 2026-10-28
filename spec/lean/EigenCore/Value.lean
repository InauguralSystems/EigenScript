namespace EigenCore

/-- A lower-case hexadecimal digit, shared by the VM-compatible encoders. -/
def lowerHexDigit (n : Nat) : Char :=
  ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'].getD n '0'

inductive Value where
  | int (value : Int)
  | string (value : String)
  | bool (value : Bool)
  | null
  | array (values : List Value)
  | closure (functionId : Nat) (name : String)
  deriving Repr, BEq, Inhabited

/-- Quote a string the same way C's `eigs_json_escape_string` does when a
string is an element of a printed list. -/
private def jsonString (s : String) : String :=
  "\"" ++ s.toList.foldl (fun out c =>
    if c == '"' then out ++ "\\\""
    else if c == '\\' then out ++ "\\\\"
    else if c == '\n' then out ++ "\\n"
    else if c == '\r' then out ++ "\\r"
    else if c == '\t' then out ++ "\\t"
    else if c.toNat < 0x20 then
      out ++ "\\u00" ++ String.ofList [lowerHexDigit (c.toNat / 16), lowerHexDigit (c.toNat % 16)]
    else out ++ c.toString) "" ++ "\""

mutual
/-- The byte representation used by the C VM's `print of`. -/
def Value.print : Value → String
  | .int n => toString n
  | .string s => s
  | .bool true => "true"
  | .bool false => "false"
  | .null => "null"
  | .array values => "[" ++ printList values ++ "]"
  | .closure _ name => s!"<fn {name}>"

def printList : List Value → String
  | [] => ""
  | .string s :: rest => jsonString s ++ (if rest.isEmpty then "" else ", " ++ printList rest)
  | value :: rest => value.print ++ (if rest.isEmpty then "" else ", " ++ printList rest)
end

end EigenCore
