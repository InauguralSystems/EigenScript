import EigenCore.Semantics
namespace EigenCore

private def chunks (limit : Nat) (s : String) : List String :=
  let (done, current) := s.toList.foldl (fun (state : List String × String) c =>
    let (done, current) := state
    let next := current.push c
    if next.utf8ByteSize > limit then (done ++ [current], c.toString)
    else (done, next)) ([], "")
  if current.isEmpty then done else done ++ [current]

private def serializeRecord (record : String) : List String :=
  if !record.startsWith "N " then [record] else
    let fields := record.splitOn "="
    let encoded := String.intercalate "=" (fields.drop 1)
    if encoded.utf8ByteSize ≤ 65536 then [record] else
      let leader := String.intercalate "=" fields.dropLast ++ "="
      match chunks 65536 encoded with
      | [] => [record]
      | first :: rest =>
        (leader ++ "@" ++ toString encoded.utf8ByteSize ++ ":" ++ first) ::
          rest.map ("C 0 " ++ ·)

def tapeSerialize (records : List String) : String :=
  let physical := records.flatMap serializeRecord
  "V 9 0.47.0\nB 0 1 1 0 root -\n" ++ String.intercalate "\n" physical ++
    (if physical.isEmpty then "" else "\n")

private def gatherContinuations (count : Nat) : Nat → String → List String →
    Except String (String × List String)
  | bytes, accumulated, rows => do
    if bytes == count then pure (accumulated, rows)
    else if bytes > count then throw "malformed N continuation"
    else match rows with
      | continuation :: more =>
        if !continuation.startsWith "C " then throw "malformed N continuation"
        let parts := continuation.splitOn " "
        if parts[1]? != some "0" then throw "malformed N continuation"
        let chunk := String.intercalate " " (parts.drop 2)
        if chunk.isEmpty then throw "malformed N continuation"
        gatherContinuations count (bytes + chunk.utf8ByteSize) (accumulated ++ chunk) more
      | [] => throw "malformed N continuation"

private partial def assembleRecords : List String → Except String (List String)
  | [] => pure []
  | line :: tail => do
    if !line.startsWith "N " then
      return line :: (← assembleRecords tail)
    let fields := line.splitOn "="
    let raw := String.intercalate "=" (fields.drop 1)
    if !raw.startsWith "@" then
      return line :: (← assembleRecords tail)
    let framing := (raw.drop 1).toString.splitOn ":"
    let some count := framing.head?.bind String.toNat?
      | throw "malformed length-framed N record"
    if count ≤ 65536 then throw "malformed length-framed N record"
    let first := String.intercalate ":" (framing.drop 1)
    let (value, more) ← gatherContinuations count first.utf8ByteSize first tail
    let leader := String.intercalate "=" (fields.dropLast) ++ "="
    return (leader ++ value) :: (← assembleRecords more)

def tapeParse (text : String) : Except String (List String) :=
  match text.splitOn "\n" with
  | header::rest => if header == "V 9 0.47.0" then
      assembleRecords (rest.filter (· != ""))
    else throw "invalid tape header"
  | _ => throw "empty tape"

end EigenCore
