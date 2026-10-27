namespace EigenCore

inductive Value where
  | int (value : Int)
  | string (value : String)
  | bool (value : Bool)
  | null
  | array (values : List Value)
  | closure (name : String)
  deriving Repr, BEq, Inhabited

/-- The byte representation used by the C VM's `print of`. -/
def Value.print : Value → String
  | .int n => toString n
  | .string s => s
  | .bool true => "true"
  | .bool false => "false"
  | .null => "null"
  | .array values => "[" ++ String.intercalate ", " (values.map Value.print) ++ "]"
  | .closure name => s!"<fn {name}>"

end EigenCore
