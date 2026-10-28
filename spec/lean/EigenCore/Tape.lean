import EigenCore.Semantics
namespace EigenCore

def tapeSerialize (records : List String) : String :=
  "V 8 0.47.0\nB 0 1 1 0 root -\n" ++ String.intercalate "\n" records ++ (if records.isEmpty then "" else "\n")

def tapeParse (text : String) : Except String (List String) :=
  match text.splitOn "\n" with
  | header::rest => if header == "V 8 0.47.0" then pure (rest.filter (· != "")) else throw "invalid tape header"
  | _ => throw "empty tape"

end EigenCore
