import EigenCore.Semantics
namespace EigenCore

private def chunks (limit : Nat) (s : String) : List String :=
  let (done, current) := s.toList.foldl (fun (state : List String × String) c =>
    let (done, current) := state
    let next := current.push c
    if next.utf8ByteSize > limit then (done ++ [current], c.toString)
    else (done, next)) ([], "")
  if current.isEmpty then done else done ++ [current]

private def splitFirst (separator : Char) : List Char → List Char × Option (List Char)
  | [] => ([], none)
  | c :: rest =>
    if c == separator then ([], some rest)
    else
      let (before, after) := splitFirst separator rest
      (c :: before, after)

private def afterSecondSpace : List Char → Option (List Char)
  | [] => none
  | ' ' :: rest =>
    match splitFirst ' ' rest with
    | (_, some payload) => some payload
    | _ => none
  | _ :: rest => afterSecondSpace rest

private def serializeRecord (record : String) : List String :=
  if !record.startsWith "N " then [record] else
    let (leaderChars, encodedChars?) := splitFirst '=' record.toList
    let encoded := String.ofList (encodedChars?.getD [])
    if encoded.utf8ByteSize ≤ 65536 then [record] else
      let leader := String.ofList leaderChars ++ "="
      match chunks 65536 encoded with
      | [] => [record]
      | first :: rest =>
        (leader ++ "@" ++ toString encoded.utf8ByteSize ++ ":" ++ first) ::
          rest.map ("C 0 " ++ ·)

def tapeSerialize (records : List String) : String :=
  let physical := records.flatMap serializeRecord
  "V 8 0.47.0\nB 0 1 1 0 root -\n" ++ String.intercalate "\n" physical ++
    (if physical.isEmpty then "" else "\n")

private def gatherContinuations (count : Nat) : Nat → String → List String →
    Except String (String × List String)
  | bytes, accumulated, rows => do
    if bytes == count then pure (accumulated, rows)
    else if bytes > count then throw "malformed N continuation"
    else match rows with
      | continuation :: more =>
        if !continuation.startsWith "C " then throw "malformed N continuation"
        let some chunkChars := afterSecondSpace continuation.toList
          | throw "malformed N continuation"
        let streamField := (splitFirst ' ' continuation.toList).2.bind
          (fun rest => some (String.ofList (splitFirst ' ' rest).1))
        if streamField != some "0" then throw "malformed N continuation"
        let chunk := String.ofList chunkChars
        if chunk.isEmpty then throw "malformed N continuation"
        gatherContinuations count (bytes + chunk.utf8ByteSize) (accumulated ++ chunk) more
      | [] => throw "malformed N continuation"

private def assembleRecordsFuel : Nat → List String → Except String (List String)
  | _, [] => pure []
  | 0, _ => throw "malformed N continuation"
  | fuel + 1, line :: tail => do
    if !line.startsWith "N " then
      return line :: (← assembleRecordsFuel fuel tail)
    let (leaderChars, rawChars?) := splitFirst '=' line.toList
    let raw := String.ofList (rawChars?.getD [])
    if !raw.startsWith "@" then
      return line :: (← assembleRecordsFuel fuel tail)
    let (countChars, firstChars?) := splitFirst ':' (raw.drop 1).toString.toList
    let some count := (String.ofList countChars).toNat?
      | throw "malformed length-framed N record"
    if count ≤ 65536 then throw "malformed length-framed N record"
    let first := String.ofList (firstChars?.getD [])
    let (value, more) ← gatherContinuations count first.utf8ByteSize first tail
    let leader := String.ofList leaderChars ++ "="
    return (leader ++ value) :: (← assembleRecordsFuel fuel more)

private def assembleRecords (rows : List String) : Except String (List String) :=
  assembleRecordsFuel rows.length rows

def tapeParse (text : String) : Except String (List String) :=
  match text.splitOn "\n" with
  | header::rest => if header == "V 8 0.47.0" then
      assembleRecords (rest.filter (· != ""))
    else throw "invalid tape header"
  | _ => throw "empty tape"

end EigenCore
