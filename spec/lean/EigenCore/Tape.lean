import EigenCore.Semantics
namespace EigenCore

def tapeSerialize (records : List String) : String :=
  "V 7 eigs-ref\n" ++ String.intercalate "\n" records ++ (if records.isEmpty then "" else "\n")

def tapeParse (text : String) : Except String (List String) :=
  match text.splitOn "\n" with
  | header::rest => if header.startsWith "V 7 " then pure (rest.filter (· != "")) else throw "invalid tape header"
  | _ => throw "empty tape"

end EigenCore
