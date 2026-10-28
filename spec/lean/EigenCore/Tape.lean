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


/-- With a limit large enough for one Unicode scalar, `chunks` never emits an
empty physical chunk. -/
theorem chunks_all_nonempty (limit : Nat) (s : String) (limitAtLeastFour : 4 ≤ limit) :
    ∀ chunk ∈ chunks limit s, chunk ≠ "" := by
  have invariant : ∀ (input : List Char) (done : List String) (current : String),
      (∀ chunk ∈ done, chunk ≠ "") →
      let result := input.foldl (chunkStep limit) (done, current)
      ∀ chunk ∈ result.1, chunk ≠ "" := by
    intro input
    induction input with
    | nil => simpa
    | cons c rest ih =>
      intro done current doneNonempty
      simp only [List.foldl_cons]
      by_cases overflow : (current.push c).utf8ByteSize > limit
      · rw [show chunkStep limit (done, current) c = (done ++ [current], c.toString) by
          simp only [chunkStep]
          rw [if_pos (by simpa [String.utf8ByteSize_push] using overflow)]]
        apply ih
        intro chunk member
        simp only [List.mem_append, List.mem_singleton] at member
        rcases member with member | rfl
        · exact doneNonempty chunk member
        · intro currentEmpty
          simp [currentEmpty] at overflow
          have charAtMostFour := Char.utf8Size_le_four c
          omega
      · rw [show chunkStep limit (done, current) c = (done, current.push c) by
          simp only [chunkStep]
          rw [if_neg (by simpa [String.utf8ByteSize_push] using overflow)]]
        exact ih done (current.push c) doneNonempty
  have folded := invariant s.toList [] "" (by simp)
  simp only [chunks]
  generalize hstate : s.toList.foldl (chunkStep limit) ([], "") = state at folded ⊢
  rcases state with ⟨done, current⟩
  simp only at folded
  by_cases empty : current.isEmpty
  · simpa [empty] using folded
  · rw [if_neg empty]
    intro chunk member
    simp only [List.mem_append, List.mem_singleton] at member
    rcases member with member | rfl
    · exact folded chunk member
    · exact fun currentEmpty => empty (String.isEmpty_iff.mpr currentEmpty)

/-- The physical chunks account for exactly all UTF-8 bytes in the input. -/
theorem chunks_utf8ByteSize_sum (limit : Nat) (s : String) :
    ((chunks limit s).map String.utf8ByteSize).sum = s.utf8ByteSize := by
  have foldSize : ∀ (pieces : List String) (acc : String),
      (pieces.foldl (· ++ ·) acc).utf8ByteSize =
        acc.utf8ByteSize + (pieces.map String.utf8ByteSize).sum := by
    intro pieces
    induction pieces with
    | nil => simp
    | cons piece rest ih =>
      intro acc
      simp only [List.foldl_cons]
      rw [ih, String.utf8ByteSize_append]
      simp only [List.map_cons, List.sum_cons]
      omega
  have joinSize (pieces : List String) :
      (String.join pieces).utf8ByteSize = (pieces.map String.utf8ByteSize).sum := by
    simpa [String.join] using foldSize pieces ""
  calc
    ((chunks limit s).map String.utf8ByteSize).sum =
        (String.join (chunks limit s)).utf8ByteSize := (joinSize _).symm
    _ = s.utf8ByteSize := congrArg String.utf8ByteSize (chunks_join limit s)

/-- A value with positive byte size necessarily produces a first chunk. -/
theorem chunks_ne_nil_of_utf8ByteSize_pos (limit : Nat) (s : String)
    (positive : 0 < s.utf8ByteSize) : chunks limit s ≠ [] := by
  intro empty
  have joined := chunks_join limit s
  rw [empty] at joined
  simp only [String.join_nil] at joined
  subst s
  simp at positive

/-- Every character in every physical chunk came from the chunked string. -/
theorem chunks_char_mem (limit : Nat) (s chunk : String) (inChunks : chunk ∈ chunks limit s) :
    ∀ c ∈ chunk.toList, c ∈ s.toList := by
  intro c inChunk
  have joined := congrArg String.toList (chunks_join limit s)
  simp only [String.toList_join] at joined
  rw [← joined]
  exact List.mem_flatMap.mpr ⟨chunk, inChunks, inChunk⟩

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

theorem splitFirst_before_subset (separator : Char) (input : List Char) :
    ∀ c ∈ (splitFirst separator input).1, c ∈ input := by
  intro c member
  have joined := splitFirst_join separator input
  generalize splitFirst separator input = result at joined member
  rcases result with ⟨before, after⟩
  cases after with
  | none => simpa [joined] using member
  | some after =>
    rw [← joined]
    simp [member]

theorem splitFirst_after_subset (separator : Char) (input after : List Char)
    (found : (splitFirst separator input).2 = some after) :
    ∀ c ∈ after, c ∈ input := by
  intro c member
  have joined := splitFirst_join separator input
  generalize splitFirst separator input = result at joined found
  rcases result with ⟨before, tail⟩
  cases tail with
  | none => simp at found
  | some tail =>
    simp only [Prod.snd, Option.some.injEq] at found
    subst tail
    rw [← joined]
    simp [member]

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

theorem newline_not_mem_toString (n : Nat) : '\n' ∉ (toString n).toList := by
  intro newline
  change '\n' ∈ (Nat.repr n).toList at newline
  rw [Nat.toList_repr] at newline
  have digit := Nat.isDigit_of_mem_toDigits (n := n) (b := 10) (by omega) (by omega) newline
  have notDigit : ¬'\n'.isDigit := by decide
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

set_option maxRecDepth 2000 in
/-- A successful continuation gather leaves an actual suffix of the rows it
was given.  In particular, it can never manufacture work for the recursive
record assembler. -/
theorem gatherContinuations_suffix (count bytes : Nat) (accumulated : String)
    (rows : List String) (value : String) (more : List String)
    (result : gatherContinuations count bytes accumulated rows = .ok (value, more)) :
    more <:+ rows := by
  induction rows generalizing bytes accumulated with
  | nil =>
    by_cases done : (bytes == count) = true
    · simp only [gatherContinuations, done, if_true, Except.ok.injEq,
        Prod.mk.injEq] at result
      rcases result with ⟨_, rfl⟩
      exact ⟨[], rfl⟩
    · by_cases over : bytes > count
      · simp [gatherContinuations, done, over] at result
      · simp [gatherContinuations, done, over] at result
  | cons row rows ih =>
    by_cases done : (bytes == count) = true
    · simp only [gatherContinuations, done, if_true, Except.ok.injEq,
        Prod.mk.injEq] at result
      rcases result with ⟨_, rfl⟩
      exact ⟨[], rfl⟩
    · by_cases over : bytes > count
      · simp [gatherContinuations, done, over] at result
      · by_cases badRow : (!row.startsWith "C ") = true
        · simp only [gatherContinuations, done, ite_false, over, badRow,
            ite_true] at result
          change Except.error "malformed N continuation" = .ok (value, more) at result
          contradiction
        · by_cases found : afterSecondSpace row.toList = none
          · simp [gatherContinuations, done, over, badRow, found] at result
          · obtain ⟨chunkChars, chunkFound⟩ := Option.ne_none_iff_exists.mp found
            have result' := result
            simp only [gatherContinuations, done, ite_false, over, badRow] at result'
            rw [chunkFound.symm] at result'
            by_cases wrongStream :
                (splitFirst ' ' row.toList).2.bind
                    (fun rest => some (String.ofList (splitFirst ' ' rest).1)) !=
                  some "0"
            · simp only [wrongStream, ite_true] at result'
              change Except.error "malformed N continuation" = .ok (value, more) at result'
              contradiction
            · by_cases empty : (String.ofList chunkChars).isEmpty
              · simp only [wrongStream, ite_false, empty, ite_true] at result'
                change Except.error "malformed N continuation" = .ok (value, more) at result'
                contradiction
              · have recursiveResult : gatherContinuations count
                    (bytes + (String.ofList chunkChars).utf8ByteSize)
                    (accumulated ++ String.ofList chunkChars) rows =
                    .ok (value, more) := by
                  simpa [wrongStream, empty] using result'
                have suffix := ih (bytes :=
                    bytes + (String.ofList chunkChars).utf8ByteSize)
                  (accumulated := accumulated ++ String.ofList chunkChars)
                  recursiveResult
                exact suffix.trans ⟨[row], rfl⟩


/-- Continuation rows written by the serializer are consumed completely and
reconstruct their chunks in order. -/
theorem gatherContinuations_writer (rest tail : List String) (bytes : Nat)
    (accumulated : String) (restNonempty : ∀ chunk ∈ rest, chunk ≠ "") :
    gatherContinuations
        (bytes + (rest.map String.utf8ByteSize).sum)
        bytes accumulated (rest.map ("C 0 " ++ ·) ++ tail) =
      .ok (accumulated ++ String.join rest, tail) := by
  induction rest generalizing bytes accumulated with
  | nil =>
    unfold gatherContinuations
    simp
    rfl
  | cons chunk rest ih =>
    have chunkNonempty : chunk ≠ "" := restNonempty chunk (by simp)
    have chunkBytesPositive : 0 < chunk.utf8ByteSize := by
      rw [Nat.pos_iff_ne_zero, ne_eq, String.utf8ByteSize_eq_zero_iff]
      exact chunkNonempty
    have laterNonempty : ∀ piece ∈ rest, piece ≠ "" := by
      intro piece member
      exact restNonempty piece (by simp [member])
    have notDone : bytes ≠
        bytes + chunk.utf8ByteSize + (rest.map String.utf8ByteSize).sum := by omega
    have notOver : ¬bytes >
        bytes + chunk.utf8ByteSize + (rest.map String.utf8ByteSize).sum := by omega
    have continuationChars : ("C 0 " ++ chunk).toList =
        ['C', ' ', '0', ' '] ++ chunk.toList := by simp
    simp only [List.map_cons, List.sum_cons, List.cons_append]
    rw [show bytes + (chunk.utf8ByteSize + (rest.map String.utf8ByteSize).sum) =
        bytes + chunk.utf8ByteSize + (rest.map String.utf8ByteSize).sum by omega]
    simp [gatherContinuations, notDone, notOver, continuationChars,
      afterSecondSpace, splitFirst, chunkNonempty]
    simpa [String.join, String.append_assoc] using
      ih (bytes := bytes + chunk.utf8ByteSize)
        (accumulated := accumulated ++ chunk) laterNonempty


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

/-- Once fuel covers every remaining physical row, its exact value is
irrelevant.  The framed branch is safe because continuation gathering only
removes a prefix of the tail. -/
theorem assembleRecordsFuel_eq_length (rows : List String) (fuel : Nat)
    (enough : rows.length ≤ fuel) :
    assembleRecordsFuel fuel rows = assembleRecordsFuel rows.length rows := by
  induction fuel using Nat.strongRecOn generalizing rows with
  | ind fuel ih =>
    cases fuel with
    | zero =>
      have : rows = [] := List.eq_nil_of_length_eq_zero (Nat.eq_zero_of_le_zero enough)
      subst rows
      rfl
    | succ fuel =>
    cases rows with
    | nil => rfl
    | cons line tail =>
      have tailEnough : tail.length ≤ fuel := by simpa using enough
      have tailEq := ih fuel (Nat.lt_succ_self fuel) tail tailEnough
      simp only [List.length_cons, assembleRecordsFuel]
      split
      · rw [tailEq]
      · split
        · rw [tailEq]
        · split <;> try rfl
          split <;> try rfl
          rename_i _ _ count _ _
          generalize gatherResult : gatherContinuations count _ _ tail = result
          cases result with
          | error message =>
            rfl
          | ok pair =>
            rcases pair with ⟨value, more⟩
            have suffix := gatherContinuations_suffix _ _ _ _ _ _ gatherResult
            have moreEnough : more.length ≤ fuel :=
              Nat.le_trans suffix.length_le tailEnough
            change (List.cons _ <$> assembleRecordsFuel fuel more) =
              (List.cons _ <$> assembleRecordsFuel tail.length more)
            rw [ih fuel (Nat.lt_succ_self fuel) more moreEnough,
              ih tail.length (by omega) more suffix.length_le]


/-- The exact writer domain on which textual tape serialization is injective
through the reader's line-oriented representation. -/
def WriterRecords (records : List String) : Prop :=
  ∀ record ∈ records,
    '\n' ∉ record.toList ∧ record ≠ "" ∧
      ¬(record.startsWith "N " ∧
        let encoded := String.ofList ((splitFirst '=' record.toList).2.getD [])
        encoded.utf8ByteSize ≤ 65536 ∧ encoded.startsWith "@")

/-- Every physical row emitted for an admissible logical record is a
nonempty line. -/
theorem serializeRecord_rows_valid (record : String)
    (valid : '\n' ∉ record.toList ∧ record ≠ "" ∧
      ¬(record.startsWith "N " ∧
        let encoded := String.ofList ((splitFirst '=' record.toList).2.getD [])
        encoded.utf8ByteSize ≤ 65536 ∧ encoded.startsWith "@")) :
    ∀ row ∈ serializeRecord record, '\n' ∉ row.toList ∧ row ≠ "" := by
  rcases valid with ⟨recordClean, recordNonempty, validFrame⟩
  intro row member
  simp only [serializeRecord] at member
  by_cases notN : (!record.startsWith "N ") = true
  · simp [notN] at member
    subst row
    exact ⟨recordClean, recordNonempty⟩
  · simp only [notN, ite_false] at member
    generalize splitEq : splitFirst '=' record.toList = split at member
    rcases split with ⟨leaderChars, encodedChars⟩
    let encoded := String.ofList (encodedChars.getD [])
    have leaderClean : '\n' ∉ leaderChars := by
      intro bad
      exact recordClean (splitFirst_before_subset '=' record.toList '\n' (by simpa [splitEq] using bad))
    have encodedClean : '\n' ∉ encoded.toList := by
      cases encodedChars with
      | none => simp [encoded]
      | some chars =>
        intro bad
        apply recordClean
        apply splitFirst_after_subset '=' record.toList chars
          (by simp [splitEq]) '\n'
        simpa [encoded] using bad
    by_cases short : encoded.utf8ByteSize ≤ 65536
    · simp [encoded, short] at member
      subst row
      exact ⟨recordClean, recordNonempty⟩
    · simp only [encoded, short, if_neg] at member
      generalize chunksEq : chunks 65536 encoded = pieces at member
      cases pieces with
      | nil =>
        simp [chunksEq] at member
        subst row
        exact ⟨recordClean, recordNonempty⟩
      | cons first rest =>
        simp only [chunksEq, List.mem_cons] at member
        have pieceClean : ∀ piece ∈ first :: rest, '\n' ∉ piece.toList := by
          intro piece inPieces bad
          exact encodedClean (chunks_char_mem 65536 encoded piece (by simpa [chunksEq] using inPieces) '\n' bad)
        rcases member with firstEq | member
        · constructor
          · have countClean := newline_not_mem_toString encoded.utf8ByteSize
            have firstClean := pieceClean first (by simp)
            intro bad
            simp only [String.toList_append, String.toList_ofList,
              List.mem_append] at bad
            simp [leaderClean, countClean, firstClean] at bad
            have digit := Nat.isDigit_of_mem_toDigits
              (n := encoded.utf8ByteSize) (b := 10) (by omega) (by omega) bad
            have notDigit : ¬'\n'.isDigit := by decide
            exact notDigit digit
          · intro empty
            have equalsMem : '=' ∈
                (String.ofList leaderChars ++ "=" ++ "@" ++
                  toString encoded.utf8ByteSize ++ ":" ++ first).toList := by
              simp
            rw [empty] at equalsMem
            simp at equalsMem
        · rename_i continuationMember
          obtain ⟨piece, inRest, rfl⟩ := List.mem_map.mp continuationMember
          constructor
          · simp [pieceClean piece (by simp [inRest])]
          · simp

/-- Reading the physical rows emitted for one admissible record reproduces
that record, then continues with the supplied tail. -/
theorem assembleRecordsFuel_serializeRecord (record : String) (tail : List String)
    (valid : '\n' ∉ record.toList ∧ record ≠ "" ∧
      ¬(record.startsWith "N " ∧
        let encoded := String.ofList ((splitFirst '=' record.toList).2.getD [])
        encoded.utf8ByteSize ≤ 65536 ∧ encoded.startsWith "@")) :
    assembleRecordsFuel (serializeRecord record ++ tail).length
        (serializeRecord record ++ tail) =
      (List.cons record <$> assembleRecordsFuel tail.length tail) := by
  rcases valid with ⟨_, recordNonempty, validFrame⟩
  simp only [serializeRecord]
  by_cases notN : (!record.startsWith "N ") = true
  · simp [notN, assembleRecordsFuel]
  · have startsN : record.startsWith "N " := by
      simpa [Bool.not_eq_true] using notN
    simp only [notN, ite_false]
    generalize leaderResult : splitFirst '=' record.toList = split
    rcases split with ⟨leaderChars, encodedChars?⟩
    let encoded := String.ofList (encodedChars?.getD [])
    by_cases short : encoded.utf8ByteSize ≤ 65536
    · have notAt : ¬encoded.startsWith "@" := by
        intro beginsAt
        apply validFrame
        simp only [leaderResult, encoded]
        exact ⟨startsN, short, beginsAt⟩
      simp only [short, if_pos]
      simp [serializeRecord, notN, assembleRecordsFuel, startsN, leaderResult, encoded, short, notAt]
    · simp only [short, if_neg]
      have encodedPositive : 0 < encoded.utf8ByteSize := by omega
      generalize chunkResult : chunks 65536 encoded = pieces
      cases pieces with
      | nil =>
        exact False.elim ((chunks_ne_nil_of_utf8ByteSize_pos 65536 encoded encodedPositive) chunkResult)
      | cons first rest =>
        simp only [chunkResult, encoded, short, if_neg]
        have piecesNotNil := chunks_ne_nil_of_utf8ByteSize_pos 65536 encoded encodedPositive
        have restNonempty : ∀ chunk ∈ rest, chunk ≠ "" := by
          intro chunk member
          apply chunks_all_nonempty 65536 encoded (by omega) chunk
          rw [chunkResult]
          simp [member]
        have sizeSum := chunks_utf8ByteSize_sum 65536 encoded
        rw [chunkResult] at sizeSum
        simp only [List.map_cons, List.sum_cons] at sizeSum
        have gather := gatherContinuations_writer rest tail first.utf8ByteSize first restNonempty
        rw [sizeSum] at gather
        have leaderClean := splitFirst_before_not_mem '=' record.toList
        rw [leaderResult] at leaderClean
        have recordJoin := splitFirst_join '=' record.toList
        rw [leaderResult] at recordJoin
        cases encodedChars? with
        | none =>
          simp [encoded] at encodedPositive
        | some encodedChars =>
          have encodedEq : encoded = String.ofList encodedChars := rfl
          have recordEq : record = String.ofList leaderChars ++ "=" ++ encoded := by
            apply String.ext
            simp only [String.toList_append, String.toList_ofList]
            have eqChars : "=".toList = ['='] := by decide
            rw [eqChars, encodedEq]
            simpa using recordJoin.symm
          subst record
          have framedStartsN :
              (String.ofList leaderChars ++ "=" ++ "@" ++
                toString encoded.utf8ByteSize ++ ":" ++ first).startsWith "N " := by
            simp only [String.startsWith, String.toList_append, String.toList_ofList] at startsN ⊢
            cases leaderChars with
            | nil => simp at startsN
            | cons a chars =>
              cases chars with
              | nil => simp at startsN
              | cons b chars => simpa using startsN
          simp only [List.length_append]
          have noEquals : '=' ∉ (String.ofList leaderChars).toList := by simpa using leaderClean
          have framedEq :
              String.ofList leaderChars ++ "=" ++ "@" ++
                  toString (String.ofList encodedChars).utf8ByteSize ++ ":" ++ first =
                String.ofList leaderChars ++ "=" ++
                  ("@" ++ toString (String.ofList encodedChars).utf8ByteSize ++ ":" ++ first) := by
            apply String.ext
            simp
          simp only [Bool.false_eq_true, ↓reduceIte, List.length_cons, List.length_map, List.cons_append]
          rw [show rest.length + 1 + tail.length = Nat.succ (rest.length + tail.length) by omega]
          simp only [assembleRecordsFuel]
          simp only [encoded, Option.getD_some] at framedStartsN ⊢
          rw [show (!(String.ofList leaderChars ++ "=" ++ "@" ++
              toString (String.ofList encodedChars).utf8ByteSize ++ ":" ++ first).startsWith
              "N ") = false by simpa using framedStartsN]
          simp only [Bool.false_eq_true, ↓reduceIte]
          rw [framedEq]
          rw [splitFirst_leader_value (String.ofList leaderChars)
            ("@" ++ toString (String.ofList encodedChars).utf8ByteSize ++ ":" ++ first) noEquals]
          simp only [Option.getD_some, String.ofList_toList]
          simp only [show (!("@" ++ toString (String.ofList encodedChars).utf8ByteSize ++
            ":" ++ first).startsWith "@") = false by
              have startsAt : ("@" ++ toString (String.ofList encodedChars).utf8ByteSize ++
                  ":" ++ first).startsWith "@" := by
                apply String.startsWith_string_iff.mpr
                exact ⟨Nat.toDigits 10 (String.ofList encodedChars).utf8ByteSize ++
                  ':' :: first.toList, by simp⟩
              simpa using startsAt,
            Bool.false_eq_true, ↓reduceIte]
          rw [splitFirst_framed_header (String.ofList encodedChars).utf8ByteSize first]
          simp only [Prod.fst, Prod.snd, String.ofList_toList, Option.getD_some]
          simp
          have long : ¬(String.ofList encodedChars).utf8ByteSize ≤ 65536 := by
            simpa [encoded] using short
          have gather' : gatherContinuations (String.ofList encodedChars).utf8ByteSize
              first.utf8ByteSize first (rest.map ("C 0 " ++ ·) ++ tail) =
                .ok (first ++ String.join rest, tail) := by
            simpa [encoded] using gather
          rw [if_neg long, gather']
          have joined : first ++ String.join rest = String.ofList encodedChars := by
            have lossless := chunks_join 65536 encoded
            rw [chunkResult] at lossless
            calc
              first ++ String.join rest = String.join (first :: rest) := by
                apply String.ext
                simp only [String.toList_append, String.toList_join]
                simp
              _ = encoded := lossless
              _ = String.ofList encodedChars := encodedEq
          rw [joined]
          change (List.cons (String.ofList leaderChars ++ "=" ++ String.ofList encodedChars) <$>
            assembleRecordsFuel (rest.length + tail.length) tail) = _
          rw [assembleRecordsFuel_eq_length tail (rest.length + tail.length) (by omega)]

/-- The one-record result composes over every admissible writer list. -/
theorem assembleRecords_serializeRecords (records : List String)
    (valid : WriterRecords records) :
    assembleRecordsFuel (records.flatMap serializeRecord).length
      (records.flatMap serializeRecord) = .ok records := by
  induction records with
  | nil => rfl
  | cons record records ih =>
    have recordValid := valid record (by simp)
    have recordsValid : WriterRecords records := by
      intro r member
      exact valid r (by simp [member])
    simp only [List.flatMap_cons]
    rw [assembleRecordsFuel_serializeRecord record (records.flatMap serializeRecord)
      recordValid]
    rw [ih recordsValid]
    rfl

private def assembleRecords (rows : List String) : Except String (List String) :=
  assembleRecordsFuel rows.length rows

private def splitLines : List Char → List String
  | [] => [""]
  | c :: rest =>
    if c = '\n' then "" :: splitLines rest
    else match splitLines rest with
      | [] => [c.toString]
      | line :: lines => (c.toString ++ line) :: lines

/-- A newline-free prefix is the first line returned by the structural
splitter. -/
theorem splitLines_prefix (chars rest : List Char) (clean : '\n' ∉ chars) :
    splitLines (chars ++ '\n' :: rest) = String.ofList chars :: splitLines rest := by
  induction chars with
  | nil => simp [splitLines]
  | cons c chars ih =>
    simp only [List.mem_cons, not_or] at clean
    have hc : c ≠ '\n' := Ne.symm clean.1
    rw [show (c :: chars) ++ '\n' :: rest = c :: (chars ++ '\n' :: rest) by rfl]
    simp only [splitLines, hc, ↓reduceIte, ih clean.2]
    congr 1
    apply String.ext
    simp

/-- Intercalating admissible physical lines, adding the writer's final
newline, splitting, and discarding empty rows recovers the lines exactly. -/
theorem splitLines_intercalate_newline_filter (lines : List String)
    (clean : ∀ line ∈ lines, '\n' ∉ line.toList)
    (nonempty : ∀ line ∈ lines, line ≠ "") :
    (splitLines (String.intercalate "\n" lines ++ "\n").toList).filter (· != "") =
      lines := by
  rw [String.toList_append, String.toList_intercalate]
  have newlineChars : "\n".toList = ['\n'] := by decide
  rw [newlineChars]
  induction lines with
  | nil => simp [splitLines]
  | cons line lines ih =>
    have lineClean := clean line (by simp)
    have lineNonempty := nonempty line (by simp)
    have tailClean : ∀ row ∈ lines, '\n' ∉ row.toList := by
      intro row member
      exact clean row (by simp [member])
    have tailNonempty : ∀ row ∈ lines, row ≠ "" := by
      intro row member
      exact nonempty row (by simp [member])
    cases lines with
    | nil =>
      simp only [List.map_cons, List.map_nil, List.intercalate_singleton]
      rw [splitLines_prefix line.toList [] lineClean, String.ofList_toList]
      simp [lineNonempty, splitLines]
    | cons next more =>
      simp only [List.map_cons, List.intercalate_cons_cons]
      rw [show line.toList ++ ['\n'] ++
          List.intercalate ['\n'] (next.toList :: more.map String.toList) ++ ['\n'] =
          line.toList ++ '\n' ::
            (List.intercalate ['\n'] (next.toList :: more.map String.toList) ++ ['\n']) by
        simp]
      rw [splitLines_prefix line.toList
        (List.intercalate ['\n'] (next.toList :: more.map String.toList) ++ ['\n']) lineClean]
      rw [String.ofList_toList]
      simp only [List.filter_cons]
      rw [show (line != "") = true by simp [lineNonempty]]
      simp only [Bool.true_eq, ite_true]
      have tailResult := ih tailClean tailNonempty
      simp only [List.map_cons] at tailResult
      rw [tailResult]

def tapeParse (text : String) : Except String (List String) :=
  match splitLines text.toList with
  | header::rest => if header == "V 8 0.47.0" then
      assembleRecords (rest.filter (· != ""))
    else throw "invalid tape header"
  | _ => throw "empty tape"

/-- Every admissible logical tape survives serialization and parsing.  The
reader also returns the mandatory root record written by `tapeSerialize`. -/
theorem tape_roundtrip (records : List String) (valid : WriterRecords records) :
    tapeParse (tapeSerialize records) =
      .ok ("B 0 1 1 0 root -" :: records) := by
  let physical := records.flatMap serializeRecord
  have physicalValid : ∀ row ∈ physical, '\n' ∉ row.toList ∧ row ≠ "" := by
    intro row member
    obtain ⟨record, inRecords, inRows⟩ := List.mem_flatMap.mp member
    exact serializeRecord_rows_valid record (valid record inRecords) row inRows
  let restLines := "B 0 1 1 0 root -" :: physical
  have linesClean : ∀ line ∈ restLines, '\n' ∉ line.toList := by
    intro line member
    simp only [restLines, List.mem_cons] at member
    rcases member with rfl | member
    · decide
    · exact (physicalValid line member).1
  have linesNonempty : ∀ line ∈ restLines, line ≠ "" := by
    intro line member
    simp only [restLines, List.mem_cons] at member
    rcases member with rfl | member
    · decide
    · exact (physicalValid line member).2
  have serialized : tapeSerialize records =
      "V 8 0.47.0" ++ "\n" ++ String.intercalate "\n" restLines ++ "\n" := by
    apply String.ext
    simp only [tapeSerialize, restLines, physical, String.toList_append,
      String.toList_intercalate]
    have newlineChars : "\n".toList = ['\n'] := by decide
    rw [newlineChars]
    cases empty : records.flatMap serializeRecord with
    | nil => simp [List.intercalate]
    | cons first rest => simp [List.intercalate, List.append_assoc]
  have splitBack := splitLines_intercalate_newline_filter restLines linesClean linesNonempty
  unfold tapeParse
  rw [show (tapeSerialize records).toList =
      "V 8 0.47.0".toList ++ '\n' ::
        (String.intercalate "\n" restLines ++ "\n").toList by
    rw [serialized]
    simp [String.toList_append]]
  rw [splitLines_prefix "V 8 0.47.0".toList
    (String.intercalate "\n" restLines ++ "\n").toList (by decide)]
  simp only [String.ofList_toList, beq_self_eq_true, if_true]
  rw [splitBack]
  simp only [restLines]
  unfold assembleRecords
  simp only [List.length_cons, assembleRecordsFuel]
  have rootNotN : ¬"B 0 1 1 0 root -".startsWith "N " := by
    intro begins
    obtain ⟨suffix, equality⟩ := String.startsWith_string_iff.mp begins
    simp at equality
  rw [show (!"B 0 1 1 0 root -".startsWith "N ") = true by
    simpa using rootNotN]
  simp only [if_true]
  rw [assembleRecords_serializeRecords records valid]
  rfl

end EigenCore
