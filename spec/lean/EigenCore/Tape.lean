import EigenCore.Semantics
namespace EigenCore

private def chunkStep (limit : Nat) (state : List String × String) (c : Char) :
    List String × String :=
  let (done, current) := state
  let next := current.push c
  if next.utf8ByteSize > limit then (done ++ [current], c.toString)
  else (done, next)

private def chunks (limit : Nat) (s : String) : List String :=
  let (done, current) := s.toList.foldl (chunkStep limit) ([], "")
  if current.isEmpty then done else done ++ [current]

/-- Splitting an encoded value into physical continuation chunks loses no
characters.  This is deliberately independent of the byte limit: the limit
chooses boundaries, while this lemma establishes that every boundary choice
made by `chunks` is lossless. -/
theorem chunks_join (limit : Nat) (s : String) :
    String.join (chunks limit s) = s := by
  have invariant : ∀ (input : List Char) (done : List String) (current : String),
      let result := input.foldl (chunkStep limit) (done, current)
      String.join result.1 ++ result.2 =
        String.join done ++ current ++ String.ofList input := by
    intro input
    induction input with
    | nil => simp
    | cons c rest ih =>
      intro done current
      simp only [List.foldl_cons]
      rw [ih]
      simp only [chunkStep]
      split
      · apply String.ext
        simp only [String.toList_append, String.toList_join,
          String.toList_ofList]
        simp [List.flatMap_append, String.toList_singleton]
      · apply String.ext
        simp only [String.toList_append, String.toList_join,
          String.toList_singleton, String.toList_ofList]
        rw [String.toList_push]
        simp
  have folded := invariant s.toList [] ""
  simp only [String.join_nil, String.empty_append, String.ofList_toList] at folded
  simp only [chunks]
  generalize hstate : s.toList.foldl (chunkStep limit) ([], "") = state at folded ⊢
  rcases state with ⟨done, current⟩
  simp only at folded
  by_cases empty : current.isEmpty
  · have currentEmpty : current = "" := String.isEmpty_iff.mp empty
    simpa [currentEmpty] using folded
  · rw [if_neg empty]
    simp [String.join_append, folded]

private def splitFirst (separator : Char) : List Char → List Char × Option (List Char)
  | [] => ([], none)
  | c :: rest =>
    if c == separator then ([], some rest)
    else
      let (before, after) := splitFirst separator rest
      (c :: before, after)

/-- The pieces returned by `splitFirst` reconstruct its input (putting the
separator back when it was found). -/
theorem splitFirst_join (separator : Char) (input : List Char) :
    match splitFirst separator input with
    | (before, none) => before = input
    | (before, some after) => before ++ separator :: after = input := by
  induction input with
  | nil => rfl
  | cons c rest ih =>
    by_cases h : c = separator
    · simp [splitFirst, h]
    · simp only [splitFirst, h, Char.toString, beq_iff_eq, ↓reduceIte]
      generalize splitFirst separator rest = result at ih ⊢
      rcases result with ⟨before, after⟩
      cases after <;> simp_all

/-- `splitFirst` never leaves the searched-for separator in its prefix. -/
theorem splitFirst_before_not_mem (separator : Char) (input : List Char) :
    separator ∉ (splitFirst separator input).1 := by
  induction input with
  | nil => simp [splitFirst]
  | cons c rest ih =>
    by_cases h : c = separator
    · simp [splitFirst, h]
    · simp [splitFirst, h, Ne.symm h, ih]

/-- A separator-free leader is recovered exactly when an encoded value is
split at the first equals sign. -/
theorem splitFirst_leader_value (leader v : String) (noEquals : '=' ∉ leader.toList) :
    splitFirst '=' (leader ++ "=" ++ v).toList =
      (leader.toList, some v.toList) := by
  rw [String.toList_append, String.toList_append]
  have equalsChars : "=".toList = ['='] := by decide
  rw [equalsChars]
  have listLemma : ∀ (xs : List Char), '=' ∉ xs →
      splitFirst '=' (xs ++ '=' :: v.toList) = (xs, some v.toList) := by
    intro xs clean
    induction xs with
    | nil => simp [splitFirst]
    | cons c rest ih =>
      simp only [List.mem_cons, not_or] at clean
      have hc : c ≠ '=' := Ne.symm clean.1
      simp [splitFirst, hc, ih clean.2]
  simpa [List.append_assoc] using listLemma leader.toList noEquals

/-- Decimal rendering is accepted by the standard-library natural parser. -/
theorem toString_toNat_some (n : Nat) : (toString n).toNat? = some n := by
  exact Nat.toNat?_repr n

/-- A decimal rendering cannot contain the framing separator. -/
theorem colon_not_mem_toString (n : Nat) : ':' ∉ (toString n).toList := by
  intro colon
  change ':' ∈ (Nat.repr n).toList at colon
  rw [Nat.toList_repr] at colon
  have digit := Nat.isDigit_of_mem_toDigits (n := n) (b := 10) (by omega) (by omega) colon
  have notDigit : ¬ ':'.isDigit := by decide
  exact notDigit digit

/-- Dropping the framing marker and splitting the header recovers both the
decimal byte count and the first physical chunk. -/
theorem splitFirst_framed_header (n : Nat) (first : String) :
    splitFirst ':' (("@" ++ toString n ++ ":" ++ first).drop 1).toString.toList =
      ((toString n).toList, some first.toList) := by
  have listLemma : ∀ (xs : List Char), ':' ∉ xs →
      splitFirst ':' (xs ++ ':' :: first.toList) = (xs, some first.toList) := by
    intro xs clean
    induction xs with
    | nil => simp [splitFirst]
    | cons c rest ih =>
      simp only [List.mem_cons, not_or] at clean
      have hc : c ≠ ':' := Ne.symm clean.1
      simp [splitFirst, hc, ih clean.2]
  change splitFirst ':' (("@" ++ toString n ++ ":" ++ first).drop 1).copy.toList = _
  have headerChars : ("@" ++ toString n ++ ":" ++ first).toList =
      '@' :: (toString n).toList ++ ':' :: first.toList := by
    simp only [String.toList_append]
    have atChars : "@".toList = ['@'] := by decide
    have colonChars : ":".toList = [':'] := by decide
    rw [atChars, colonChars]
    simp [List.append_assoc]
  rw [String.toList_copy_drop, headerChars]
  simpa [List.append_assoc] using listLemma (toString n).toList (colon_not_mem_toString n)

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
