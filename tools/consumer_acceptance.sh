#!/usr/bin/env bash
# Run the acceptance command each pinned consumer uses in its own CI.
# A complete wave needs every recorded consumer, a command for each one,
# and at least one counted candidate call in every passing row.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED=(DeslanStudio DMG dynamics eddy eigen-edit EigenGauntlet EigenMiniSat EigenRegex eigen-sheet iLambdaAi liferaft ouroboros phugoid polymethod tidelog Tidepool)
# These repositories pin EigenScript but have no release acceptance command.
EXCLUDED=(EigenAttention EigenAttic tmp legibility-experiment awesome-eigenscript eigs-package-template homebrew-eigenscript EigenOS)
# These four CI jobs have no devcontainer runCmd; their own test scripts are explicit.
declared_cmd() {
  case "$1" in
    eigen-edit|eigen-sheet) printf '%s' 'bash tests/test_smoke.sh' ;;
    EigenGauntlet) printf '%s' 'bash tests/run_smoke.sh' ;;
    EigenMiniSat) printf '%s' "python3 -m unittest discover -s benchmarks -p 'test_*.py' && bash tests/run_smoke.sh && bash tests/run_proof_check.sh && eigenscript minisat.eigs --proof-bench --size 1" ;;
    *) return 1 ;;
  esac
}
contains() { local wanted="$1" item; shift; for item in "$@"; do [ "$item" = "$wanted" ] && return 0; done; return 1; }
resolve_eco() {
  ECO="$(cd "${CA_ECO:-$HERE/..}" 2>/dev/null && pwd)" || { echo "CA_ECO is not a directory: ${CA_ECO:-$HERE/..}"; exit 2; }
}
pin_of() {
  local p="" f
  f="$ECO/$1/.devcontainer/Dockerfile"
  [ ! -f "$f" ] || p="$(sed -n 's/^ARG EIGS_REF=\([^ ]*\).*/\1/p' "$f" | head -1)"
  if [ -z "$p" ] && [ -d "$ECO/$1/.github/workflows" ]; then
    p="$(grep -rho -- '--branch v[0-9][0-9.]*' "$ECO/$1/.github/workflows" 2>/dev/null | head -1 | awk '{print $2}')"
  fi
  printf '%s' "$p"
}
ACCEPT_CMD=""; ACCEPT_WF=""; ACCEPT_WHY=""
accept_cmd_of() {
  local r="$1" wfdir="$ECO/$1/.github/workflows" f b cmd
  local -a others=()
  ACCEPT_CMD=""; ACCEPT_WF=""; ACCEPT_WHY=""
  for b in ci.yml tests.yml test.yml; do
    f="$wfdir/$b"
    [ -f "$f" ] || continue
    if cmd="$(python3 "$HERE/tools/_extract_runcmd.py" "$f")"; then
      ACCEPT_CMD="$cmd"; ACCEPT_WF="$b"; return 0
    fi
  done
  for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    case "$b" in ci.yml|tests.yml|test.yml) continue ;; esac
    if python3 "$HERE/tools/_extract_runcmd.py" "$f" >/dev/null 2>&1; then others+=("$f"); fi
  done
  if [ "${#others[@]}" -eq 1 ]; then
    ACCEPT_WF="${others[0]##*/}"
    ACCEPT_CMD="$(python3 "$HERE/tools/_extract_runcmd.py" "${others[0]}")" || return 1
    return 0
  fi
  if [ "${#others[@]}" -gt 1 ]; then ACCEPT_WHY=ambiguous-workflow; fi
  return 1
}
# Declared external tools and candidate capabilities required by real rows.
prereqs_of() {
  case "$1" in
    eddy) printf '%s' 'go java' ;;
    EigenMiniSat) printf '%s' 'drat-trim' ;;
    dynamics) printf '%s' gfx ;;
  esac
  if [ -f "$ECO/.ca_fixture" ] && [ -f "$ECO/$1/.ca_prereqs" ]; then
    printf ' '; tr '\n' ' ' < "$ECO/$1/.ca_prereqs"
  fi
}
probe_prereq() {
  local name="$1" cmd="$2" binary="$3" tools t part first api src output rc
  tools="$(prereqs_of "$name")"
  # Only top-level command positions can declare these tool dependencies.
  while IFS= read -r part; do
    part="${part#"${part%%[![:space:]]*}"}"
    first="${part%%[[:space:]]*}"
    case "$first" in go|java|python3|python|make) tools="$tools $first" ;; esac
  done <<< "${cmd//&&/$'\n'}"
  for t in $tools; do
    if [ "$t" = gfx ]; then
      [ -n "${GFX:-}" ] && continue
      api="$(timeout 5 "$binary" --api --json 2>/dev/null)" || api=""
      case "$api" in *gfx_open*) ;; *) printf 'gfx-build'; return 0 ;; esac
      src="${WORK:-${TMPDIR:-/tmp}}/ca-gfx-probe-$$.eigs"
      printf 'print of gfx_open\n' > "$src" || { printf 'gfx-build'; return 0; }
      output="$(timeout 5 "$binary" "$src" 2>&1)" && rc=0 || rc=$?
      rm -f "$src"
      case "$output" in *'<fn gfx_open>'*|*'<builtin>'*) [ "$rc" -eq 0 ] && continue ;; esac
      printf 'gfx-build (probe rc %s)' "$rc"; return 0
    fi
    if ! command -v "$t" >/dev/null 2>&1; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

NAMES=(); PINS=(); CMDS=(); KINDS=(); WFS=(); GAPS=0; SCANNED=0; FLOOR=0
record_floor() {
  local f n
  FLOOR=0
  if [ ! -f "$ECO/.ca_fixture" ]; then
    for f in "$HERE"/reports/consumer_acceptance/*.record; do
      [ -f "$f" ] || continue
      grep -q '^status=COMPLETE$' "$f" || continue
      n="$(sed -n 's/^inventory=\([0-9][0-9]*\).*$/\1/p' "$f" | tail -1)"
      [ -n "$n" ] && [ "$n" -gt "$FLOOR" ] && FLOOR="$n"
    done
  fi
  # CA_RECORD can live outside the standard reports directory.
  if [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] && grep -q '^status=COMPLETE$' "$RECORD"; then
    n="$(sed -n 's/^inventory=\([0-9][0-9]*\).*$/\1/p' "$RECORD" | tail -1)"
    [ -n "$n" ] && [ "$n" -gt "$FLOOR" ] && FLOOR="$n"
  fi
}
load_expected() {
  WANT=()
  if [ -f "$ECO/.ca_expected" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do [ -z "$line" ] || WANT+=("$line"); done < "$ECO/.ca_expected"
  elif [ ! -f "$ECO/.ca_fixture" ]; then WANT=("${EXPECTED[@]}"); fi
}
scan_inventory() {
  local d r pin cmd kind wf why e
  NAMES=(); PINS=(); CMDS=(); KINDS=(); WFS=(); GAPS=0; SCANNED=0
  load_expected
  for d in "$ECO"/*/; do
    [ -d "$d" ] || continue
    r="${d%/}"; r="${r##*/}"
    [ "$r" != EigenScript ] || continue
    pin="$(pin_of "$r")"
    [ -n "$pin" ] || continue
    if contains "$r" "${EXCLUDED[@]}"; then continue; fi
    kind=derived; wf=""; cmd=""; why=""
    if accept_cmd_of "$r"; then cmd="$ACCEPT_CMD"; wf="$ACCEPT_WF"
    elif [ -n "$ACCEPT_WHY" ]; then kind=UNRUNNABLE; why="$ACCEPT_WHY"
    elif cmd="$(declared_cmd "$r")"; then kind=declared
    elif [ -f "$ECO/.ca_fixture" ] && [ -f "$d/.ca_declared" ]; then
      cmd="$(cat "$d/.ca_declared")"; kind=declared
    else kind=UNRUNNABLE; why=no-acceptance-command
    fi
    if [ "$kind" = UNRUNNABLE ]; then GAPS=$((GAPS+1)); fi
    NAMES+=("$r"); PINS+=("$pin"); CMDS+=("$cmd"); KINDS+=("$kind${why:+:$why}"); WFS+=("$wf")
    SCANNED=$((SCANNED+1))
  done
  for e in "${WANT[@]}"; do
    if ! contains "$e" "${NAMES[@]}"; then
      NAMES+=("$e"); PINS+=(absent); CMDS+=(""); KINDS+=(missing-inventory); WFS+=("")
      GAPS=$((GAPS+1)); echo "inventory floor: declared consumer absent: $e"
    fi
  done
  for e in "${NAMES[@]}"; do
    if [ "${#WANT[@]}" -gt 0 ] && ! contains "$e" "${WANT[@]}"; then
      GAPS=$((GAPS+1)); echo "inventory floor: undeclared consumer present: $e"
    fi
  done
  if [ "$SCANNED" -lt "$FLOOR" ]; then GAPS=$((GAPS+1)); echo "inventory floor: scanned=$SCANNED below record_floor=$FLOOR"; fi
  echo "inventory_floor expected=${#WANT[@]} scanned=$SCANNED record_floor=$FLOOR"
}
plan() {
  local name="${1:-}" i seen=0
  resolve_eco
  if [ "$#" -gt 2 ]; then echo 'usage: plan [--cmd consumer]' >&2; return 2; fi
  if [ -n "$name" ] && [ "$name" != --cmd ]; then echo 'usage: plan [--cmd consumer]' >&2; return 2; fi
  if [ "$name" = --cmd ]; then
    name="${2:-}"
    [ -n "$name" ] || { echo 'plan --cmd needs a consumer' >&2; return 2; }
    # Do not mix the inventory diagnostics with byte-exact command output.
    if [ -d "$ECO/$name" ] && { accept_cmd_of "$name" || [ -z "$ACCEPT_WHY" ]; }; then
      if [ -n "$ACCEPT_CMD" ]; then printf '%s\n' "$ACCEPT_CMD"; return 0; fi
      if ACCEPT_CMD="$(declared_cmd "$name")"; then printf '%s\n' "$ACCEPT_CMD"; return 0; fi
      if [ -f "$ECO/.ca_fixture" ] && [ -f "$ECO/$name/.ca_declared" ]; then cat "$ECO/$name/.ca_declared"; return 0; fi
    fi
    echo "UNRUNNABLE: $name" >&2; return 1
  fi
  echo 'consumer acceptance -- plan'; echo
  record_floor
  scan_inventory
  for ((i=0; i<${#NAMES[@]}; i++)); do
    if [ -z "${CMDS[i]}" ]; then echo "  UNRUNNABLE ${NAMES[i]} -- ${KINDS[i]}"
    else
      echo "  gate   ${NAMES[i]}  (${PINS[i]})"
      [ -z "${WFS[i]}" ] || echo "  workflow|${NAMES[i]}|${WFS[i]}"
    fi
    local p=""
    p="$(probe_prereq "${NAMES[i]}" "${CMDS[i]}" "$HERE/src/eigenscript")" || p=none
    echo "  prereq|${NAMES[i]}|${p:-none}"
    seen=$((seen+1))
  done
  echo "inventory=$SCANNED examined=$seen"
  if [ "$seen" -eq 0 ] || [ "$seen" -ne "${#NAMES[@]}" ] || [ "$GAPS" -ne 0 ]; then echo 'VERDICT: FAIL -- inventory or command gap'; return 1; fi
  echo "VERDICT: PASS -- $seen consumers, every one with a derived acceptance command"
}

WORK=""; RECORD=""; ACTIVE=""; SHIM=""; CALL_LOG=""; OVERLAY=""
stop_row_group() {
  local pid="${ACTIVE:-}"
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  ACTIVE=""
}
cleanup() { stop_row_group; [ -z "$WORK" ] || rm -rf "$WORK"; }
interrupted() {
  stop_row_group
  if [ -n "$RECORD" ]; then
    # The initial record already ends this way. Re-arm it if a write was
    # interrupted before the marker reached disk.
    if [ "$(tail -n 1 "$RECORD" 2>/dev/null)" != 'VERDICT: INCOMPLETE' ]; then
      { echo 'status=INCOMPLETE'; echo 'VERDICT: INCOMPLETE'; } >> "$RECORD" 2>/dev/null || true
    fi
  fi
  echo 'VERDICT: INCOMPLETE'
  exit 130
}
# The shim uses an absolute candidate and log path, so the consumer can change cwd.
make_shim() {
  local name="$1" target="$2" path="$SHIM/$1" qtarget qlog qname
  printf -v qtarget '%q' "$target"
  printf -v qlog '%q' "$CALL_LOG"
  printf -v qname '%q' "$name"
  cat > "$path" <<SHIM
#!/usr/bin/env bash
target=$qtarget
log=$qlog
name=$qname
kind=probe
for arg in "\$@"; do case "\$arg" in -*) ;; *) kind=call ;; esac; done
if [ "\$target" = missing ]; then printf '%s|127|%s\n' "\$name" "\$kind" >> "\$log"; exit 127; fi
"\$target" "\$@"
rc=\$?
printf '%s|%s|%s\n' "\$name" "\$rc" "\$kind" >> "\$log"
exit "\$rc"
SHIM
  chmod 755 "$path"
}
tree_of_candidate() {
  local d="$(dirname "$1")" parent fallback=""
  while :; do
    if [ -d "$d/src" ] && [ -z "$fallback" ]; then fallback="$d"; fi
    if [ -d "$d/src" ] && [ -d "$d/lib" ]; then TREE="$d"; return 0; fi
    [ "$d" != / ] || break
    parent="$(dirname "$d")"; [ "$parent" != "$d" ] || break; d="$parent"
  done
  # Minimal fixture trees can omit lib/, but the binary must still match.
  TREE="${fallback:-$(dirname "$1")}"; return 0
}
same_candidate_tree() {
  local f
  for f in "$TREE/src/eigenscript" "$TREE/build/release/eigenscript"; do
    [ -f "$f" ] || continue
    [ "$f" -ef "$candidate" ] && return 0
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$CAND_SHA" ] && return 0
  done
  return 1
}
# A private, dereferenced copy lets consumer builds and writes stay in WORK.
# The runtime executable slots alone route to the counting shims.
overlay_runtime_slots() {
  local dir="$1" item base
  [ -d "$dir" ] || return 0
  for item in "$dir"/eigenscript*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    base="${item##*/}"
    case "$base" in
      *.*) continue ;;
      eigenscript|eigenscript-full|eigenscript-gfx) ;;
      eigenscript-*) [ -x "$item" ] || continue ;;
      *) continue ;;
    esac
    [ -e "$SHIM/$base" ] || make_shim "$base" missing || return 1
    rm -f "$item" || return 1
    cp "$SHIM/$base" "$item" || return 1
  done
}
build_overlay() {
  local item base name
  OVERLAY="$WORK/tree"
  mkdir -p "$OVERLAY" || return 1
  if [ -d "$TREE/src" ]; then cp -rL "$TREE/src" "$OVERLAY/src" || return 1
  else mkdir -p "$OVERLAY/src" || return 1; fi
  if [ -d "$TREE/lib" ]; then cp -rL "$TREE/lib" "$OVERLAY/lib" || return 1
  else mkdir -p "$OVERLAY/lib" || return 1; fi
  for item in "$TREE"/* "$TREE"/.[!.]* "$TREE"/..?*; do
    [ -f "$item" ] || continue
    base="${item##*/}"
    cp -L "$item" "$OVERLAY/$base" || return 1
  done
  overlay_runtime_slots "$OVERLAY/src" || return 1
  overlay_runtime_slots "$OVERLAY" || return 1
  overlay_runtime_slots "$OVERLAY/lib" || return 1
  for name in eigenscript eigenscript-full eigenscript-gfx; do
    [ -e "$OVERLAY/src/$name" ] || cp "$SHIM/$name" "$OVERLAY/src/$name" || return 1
  done
}
# The source scanner considers invocation sites, not prose or Dockerfile PATH lines.
unsupported_variant() {
  local repo="$1" cmd="$2" raw n f
  raw="$(python3 "$HERE/tools/_derive_variants.py" "$repo" 2>/dev/null)" || { echo variant-derivation; return; }
  f="$WORK/command.sh"; printf '%s\n' "$cmd" > "$f"
  raw="$raw"$'\n'"$(python3 "$HERE/tools/_derive_variants.py" --shell "$f" 2>/dev/null)" || { echo variant-derivation; return; }
  while IFS= read -r n; do
    case "$n" in variant\|*) n="${n#variant|}"; n="${n%%|*}" ;; *) continue ;; esac
    case "$n" in
      eigenscript) ;;
      eigenscript-full) [ -n "$FULL" ] || { echo "$n"; return; } ;;
      eigenscript-gfx) [ -n "$GFX" ] || { echo "$n"; return; } ;;
      eigenscript*) echo "$n"; return ;;
    esac
  done <<< "$raw"
}
row() {
  local i="$1" name="${NAMES[i]}" pin="${PINS[i]}" cmd="${CMDS[i]}" kind="${KINDS[i]}"
  local verdict=PASS rc=- dur=0 calls=0 ok=0 fail=0 skips=0 prereq="" v log start end missing_variant="" actual mutated=""
  local -a session=(setsid)
  if ! command -v setsid >/dev/null 2>&1; then
    session=(python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1],sys.argv[1:])')
  fi
  log="$WORK/$name.log"
  : > "$CALL_LOG"
  if [ "$kind" = missing-inventory ] || [ -z "$cmd" ]; then verdict=UNRUNNABLE; prereq="$kind"
  elif v="$(unsupported_variant "$ECO/$name" "$cmd")" && [ -n "$v" ]; then verdict=UNRUNNABLE; prereq="variant:$v"
  elif v="$(probe_prereq "$name" "$cmd" "$candidate")" && [ -n "$v" ]; then verdict=UNRUNNABLE; prereq="$v"
  else
    start="$(date +%s)"
    ( cd "$ECO/$name" && exec "${session[@]}" env PATH="$SHIM:$PATH" EIGS=eigenscript EIGENSCRIPT=eigenscript \
        EIGENSCRIPT_BIN="$SHIM/eigenscript" EIGS_DIR="$OVERLAY" EIGENSCRIPT_DIR="$OVERLAY" \
        "${GFX_ENV[@]}" timeout --kill-after=2s "$BUDGET" bash -e -o pipefail -c "$cmd" ) < /dev/null > "$log" 2>&1 &
    ACTIVE=$!
    wait "$ACTIVE" && rc=0 || rc=$?
    stop_row_group
    end="$(date +%s)"; dur=$((end-start))
    while IFS='|' read -r v _rc _kind; do
      if [ "$_rc" -eq 127 ]; then
        case "$v" in
          eigenscript-full) [ -n "$FULL" ] || missing_variant="$v" ;;
          eigenscript-gfx) [ -n "$GFX" ] || missing_variant="$v" ;;
          eigenscript*) missing_variant="$v" ;;
        esac
      fi
      [ "$_kind" = call ] || continue
      calls=$((calls+1))
      if [ "$_rc" -eq 0 ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done < "$CALL_LOG"
    skips="$(grep -c '^SKIP' "$log" || true)"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then verdict=HANG
    elif [ -n "$missing_variant" ]; then verdict=UNRUNNABLE; prereq="variant:$missing_variant"
    elif [ "$rc" -ne 0 ]; then verdict=FAIL
    elif [ "$calls" -eq 0 ]; then verdict=FAIL; prereq=UNEXERCISED
    elif [ "$ok" -eq 0 ]; then verdict=FAIL; prereq=SWALLOWED
    elif [ "$skips" -gt 0 ]; then verdict=FAIL; prereq="skips:$skips"
    fi
    if [ -n "${CA_LOGS:-}" ]; then mkdir -p "$CA_LOGS" && cp "$log" "$CA_LOGS/$name.log"; fi
  fi
  # A consumer may write the original binary. Account for that row as a
  # failure even when its command and every counted call returned zero.
  actual="$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}')" || actual=missing
  [ "$actual" = "$CAND_SHA" ] || mutated=eigenscript
  if [ -n "$FULL" ]; then
    actual="$(sha256sum "$FULL" 2>/dev/null | awk '{print $1}')" || actual=missing
    [ "$actual" = "$FULL_SHA" ] || mutated="${mutated:+$mutated,}eigenscript-full"
  fi
  if [ -n "$GFX" ]; then
    actual="$(sha256sum "$GFX" 2>/dev/null | awk '{print $1}')" || actual=missing
    [ "$actual" = "$GFX_SHA" ] || mutated="${mutated:+$mutated,}eigenscript-gfx"
  fi
  if [ -n "$mutated" ]; then verdict=FAIL; prereq="candidate-mutated:$mutated"; fi
  local line="row|$name|$pin|$verdict|$rc|$dur|cand_calls=$calls|cand_ok=$ok|cand_fail=$fail|consumer_skips=$skips"
  [ -z "$prereq" ] || line="$line|prereq=$prereq"
  echo "$line" | tee -a "$BODY"
  if [ "$verdict" != PASS ] && [ -s "$log" ]; then
    tail -n 20 "$log" | while IFS= read -r v; do printf 'log|%s|%s\n' "$name" "$v"; done >> "$BODY"
  fi
  [ "$verdict" = PASS ]
}
run() {
  local candidate="${1:-}" arg i examined=0 bad=0 rc version final_tmp
  FULL=""; GFX=""; GFX_ENV=()
  [ -n "$candidate" ] || { echo 'usage: run <tree-or-binary> [--full binary] [--gfx binary]'; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --full) [ "$#" -ge 2 ] || return 2; FULL="$2"; shift 2 ;;
      --gfx) [ "$#" -ge 2 ] || return 2; GFX="$2"; shift 2 ;;
      *) echo "unknown argument: $1"; return 2 ;;
    esac
  done
  resolve_eco
  if [ -d "$candidate" ]; then candidate="$candidate/src/eigenscript"; fi
  [ -f "$candidate" ] && [ -x "$candidate" ] || { echo "candidate not executable: $candidate"; return 2; }
  candidate="$(readlink -f "$candidate")" || { echo 'candidate resolution failed'; return 2; }
  for arg in "$FULL" "$GFX"; do [ -z "$arg" ] || { [ -f "$arg" ] && [ -x "$arg" ]; } || { echo "variant not executable: $arg"; return 2; }; done
  [ -z "$FULL" ] || FULL="$(readlink -f "$FULL")"
  [ -z "$GFX" ] || GFX="$(readlink -f "$GFX")"
  BUDGET="${CA_TIMEOUT:-1800}"
  case "$BUDGET" in ''|*[!0-9]*|0) echo 'CA_TIMEOUT must be positive'; return 2 ;; esac
  command -v timeout >/dev/null || { echo 'timeout missing'; return 2; }
  # Output-path selection completes argument validation. Read the old floor,
  # invalidate that exact path, and install traps before any candidate hash.
  RECORD="${CA_RECORD:-$HERE/reports/consumer_acceptance/$(date -u +%F)-candidate.record}"
  record_floor
  {
    echo '# consumer_acceptance record'
    echo "run_id=$$"
    echo "eco_root=$ECO"
    echo "candidate_path=$candidate"
    echo 'candidate_tree=PENDING'
    echo 'candidate_tree_override=PENDING'
    echo 'candidate_version=PENDING'
    echo "candidate_full=${FULL:-none}"
    echo "candidate_gfx=${GFX:-none}"
    echo 'candidate_sha256=PENDING'
    echo 'full_sha256=PENDING'
    echo 'gfx_sha256=PENDING'
    echo "record_floor=$FLOOR"
    echo 'inventory=PENDING'
    echo 'examined=0'
    echo 'status=INCOMPLETE'
    echo 'VERDICT: INCOMPLETE'
  } > "$RECORD" || { echo "cannot initialise record: $RECORD"; return 2; }
  trap 'interrupted' INT TERM HUP
  trap 'cleanup' EXIT
  CAND_SHA="$(sha256sum "$candidate" | awk '{print $1}')" || { echo 'cannot hash candidate'; return 2; }
  [ "${#CAND_SHA}" -eq 64 ] || { echo 'invalid candidate SHA256'; return 2; }
  if [ -n "${CA_TREE:-}" ]; then
    TREE="$(cd "$CA_TREE" && pwd)" || { echo "CA_TREE invalid: $CA_TREE"; return 2; }
    TREE_OVERRIDE=explicit
  else
    tree_of_candidate "$candidate" || { echo "candidate tree not found: $candidate"; return 2; }
    if [ -d "$TREE/src" ]; then
      same_candidate_tree || { echo "candidate tree mismatch: $TREE does not contain $candidate"; return 2; }
      TREE_OVERRIDE=none
    else TREE_OVERRIDE=standalone; fi
  fi
  FULL_SHA=none; GFX_SHA=none
  if [ -n "$FULL" ]; then FULL_SHA="$(sha256sum "$FULL" | awk '{print $1}')" || { echo 'cannot hash full variant'; return 2; }; [ "${#FULL_SHA}" -eq 64 ] || { echo 'invalid full SHA256'; return 2; }; fi
  if [ -n "$GFX" ]; then GFX_SHA="$(sha256sum "$GFX" | awk '{print $1}')" || { echo 'cannot hash gfx variant'; return 2; }; [ "${#GFX_SHA}" -eq 64 ] || { echo 'invalid gfx SHA256'; return 2; }; fi
  CAND_GIT_SHA="$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null)" || CAND_GIT_SHA=none
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ca-run.XXXXXX")" || { echo 'cannot create scratch'; return 2; }
  version="$(timeout "$BUDGET" "$candidate" --version 2>/dev/null)" || version=unknown
  version="${version%%$'\n'*}"
  [ -n "$version" ] || version=unknown
  SHIM="$WORK/bin"; mkdir -p "$SHIM"
  CALL_LOG="$WORK/calls"; : > "$CALL_LOG"
  make_shim eigenscript "$candidate"
  make_shim eigenscript-full "${FULL:-missing}"
  make_shim eigenscript-gfx "${GFX:-missing}"
  build_overlay || { echo "cannot build candidate overlay: $TREE"; return 2; }
  [ -z "$GFX" ] || GFX_ENV=("EIGENSCRIPT_GFX=$SHIM/eigenscript-gfx")
  BODY="$WORK/record-body"; : > "$BODY"
  scan_inventory > "$WORK/inventory"
  cat "$WORK/inventory" | tee -a "$BODY"
  if [ "$SCANNED" -eq 0 ]; then
    echo 'consumer_acceptance: inventory examined ZERO consumers'
    return 2
  fi
  local inventory="${#NAMES[@]}"
  echo "inventory=$inventory" >> "$BODY"
  if [ "$SCANNED" -eq 0 ] || [ "$GAPS" -ne 0 ]; then bad=1; fi
  for ((i=0; i<${#NAMES[@]}; i++)); do
    row "$i" || bad=1
    examined=$((examined+1))
  done
  [ "$examined" -gt 0 ] && [ "$examined" -eq "$inventory" ] || bad=1
  echo "inventory=$inventory examined=$examined" | tee -a "$BODY"
  final_tmp="$(mktemp "$RECORD.tmp.XXXXXX")" || { echo 'cannot create final record'; return 2; }
  {
    echo '# consumer_acceptance record'
    echo "run_id=$(date +%s).$$"
    echo "eco_root=$ECO"
    echo "candidate_path=$candidate"
    echo "candidate_tree=$TREE"
    echo "candidate_tree_override=$TREE_OVERRIDE"
    echo "candidate_git_sha=$CAND_GIT_SHA"
    echo "candidate_version=$version"
    echo "candidate_full=${FULL:-none}"
    echo "candidate_gfx=${GFX:-none}"
    echo "candidate_sha256=$CAND_SHA"
    echo "full_sha256=$FULL_SHA"
    echo "gfx_sha256=$GFX_SHA"
    echo "record_floor=$FLOOR"
    echo "inventory=$inventory"
    echo "examined=$examined"
    echo 'status=COMPLETE'
    cat "$BODY"
    if [ "$bad" -eq 0 ]; then echo 'VERDICT: PASS'; else echo 'VERDICT: FAIL'; fi
  } > "$final_tmp" || { rm -f "$final_tmp"; echo 'cannot write final record'; return 2; }
  mv "$final_tmp" "$RECORD" || { rm -f "$final_tmp"; echo 'cannot publish final record'; return 2; }
  if [ "$bad" -eq 0 ]; then echo 'VERDICT: PASS'; rc=0
  else echo 'VERDICT: FAIL'; rc=1; fi
  return "$rc"
}

# One-time calibration against the public run mode. Every fixture is a pinned
# checkout under a private temp root; no real consumer checkout is touched.
selftest() {
  local st_root st_eco st_record st_out st_candidate st_rc=0 st_bad=0 p tries
  st_root="$(mktemp -d "${TMPDIR:-/tmp}/ca-selftest.XXXXXX")" || return 2
  st_eco="$st_root/eco"; mkdir -p "$st_eco"
  st_candidate="$st_root/eigenscript"
  printf '#!/bin/sh\nexit 0\n' > "$st_candidate"; chmod +x "$st_candidate"
  st_record="$st_root/record"; st_out="$st_root/output"
  st_reset() {
    rm -rf "$st_eco"; mkdir -p "$st_eco"; : > "$st_eco/.ca_fixture"
  }
  st_consumer() {
    local n="$1" cmd="${2:-}"
    mkdir -p "$st_eco/$n/.devcontainer"
    printf 'ARG EIGS_REF=v0.43.0\n' > "$st_eco/$n/.devcontainer/Dockerfile"
    [ -z "$cmd" ] || printf '%s\n' "$cmd" > "$st_eco/$n/.ca_declared"
  }
  st_run() {
    : > "$st_out"; rm -f "$st_record"
    CA_ECO="$st_eco" CA_RECORD="$st_record" CA_TREE="$st_root" CA_TIMEOUT=1 \
      timeout 12 bash "$HERE/tools/consumer_acceptance.sh" run "$st_candidate" > "$st_out" 2>&1
  }
  st_check() {
    local label="$1" guard="$2" pattern="$3" file="$4" line
    if [ "$st_rc" -ne 0 ] && grep -Fq "$pattern" "$file" && ! grep -Fqx 'VERDICT: PASS' "$st_record" 2>/dev/null; then
      line="$(grep -F "$pattern" "$file" | head -1)"
      printf 'plant %s check=%s RED %s\n' "$label" "$guard" "$line"
    else
      printf 'plant %s check=%s SILENT expected=%s\n' "$label" "$guard" "$pattern"
      st_bad=1
    fi
  }
  # (a) The recorded inventory names a checkout absent from disk.
  st_reset; st_consumer one 'eigenscript work.eigs'
  printf 'one\ntwo\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  st_check a inventory-floor 'declared consumer absent: two' "$st_record"
  # (b) A pinned checkout with no runCmd or declaration is UNRUNNABLE.
  st_reset; st_consumer no_command
  printf 'no_command\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  st_check b missing-command 'row|no_command|v0.43.0|UNRUNNABLE' "$st_record"
  # (c) Exiting zero without calling the candidate is UNEXERCISED.
  st_reset; st_consumer no_call true
  printf 'no_call\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  st_check c candidate-call-count 'row|no_call|v0.43.0|FAIL|0|0|cand_calls=0' "$st_record"
  # (d) timeout(1) terminates a hanging command and names HANG.
  st_reset; st_consumer hanging 'sleep 8'
  printf 'hanging\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  st_check d timeout-hang 'row|hanging|v0.43.0|HANG|124|' "$st_record"
  # (e) A signal must stop the timeout and the consumer's own child.
  st_reset; st_consumer interrupted 'printf "%s\n" "$PPID" > "$CA_TIMEOUT_PID_FILE"; sleep 31 & child=$!; printf "%s\n" "$child" > "$CA_SLEEP_PID_FILE"; wait "$child"'
  printf 'interrupted\n' > "$st_eco/.ca_expected"
  local timeout_pid="" sleep_pid="" timeout_file="$st_root/timeout.pid" sleep_file="$st_root/sleep.pid" alive_timeout=0 alive_sleep=0
  st_alive() {
    local state
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
    case "$state" in Z*|'') return 1 ;; *) return 0 ;; esac
  }
  rm -f "$st_record" "$timeout_file" "$sleep_file"; : > "$st_out"
  CA_TIMEOUT_PID_FILE="$timeout_file" CA_SLEEP_PID_FILE="$sleep_file" \
    CA_ECO="$st_eco" CA_RECORD="$st_record" CA_TREE="$st_root" CA_TIMEOUT=30 \
    bash "$HERE/tools/consumer_acceptance.sh" run "$st_candidate" > "$st_out" 2>&1 &
  p=$!
  tries=0
  while { [ ! -s "$timeout_file" ] || [ ! -s "$sleep_file" ]; } && [ "$tries" -lt 200 ]; do sleep 0.02; tries=$((tries+1)); done
  [ ! -s "$timeout_file" ] || timeout_pid="$(cat "$timeout_file")"
  [ ! -s "$sleep_file" ] || sleep_pid="$(cat "$sleep_file")"
  kill -TERM "$p" 2>/dev/null || true
  tries=0
  while { st_alive "$p" || st_alive "$timeout_pid" || st_alive "$sleep_pid"; } && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries+1)); done
  st_alive "$timeout_pid" && alive_timeout=1
  st_alive "$sleep_pid" && alive_sleep=1
  if [ -n "$timeout_pid" ] && [ -n "$sleep_pid" ] && [ "$(tail -n 1 "$st_record" 2>/dev/null)" = 'VERDICT: INCOMPLETE' ] && [ "$alive_timeout" -eq 0 ] && [ "$alive_sleep" -eq 0 ]; then
    echo 'plant e check=interrupt-process-group RED record=INCOMPLETE timeout=dead sleep=dead'
  else echo "plant e check=interrupt-process-group SILENT timeout_alive=$alive_timeout sleep_alive=$alive_sleep"; st_bad=1; fi
  if st_alive "$p"; then kill -KILL "$p" 2>/dev/null || true; fi
  if [ "$alive_timeout" -eq 1 ] || [ "$alive_sleep" -eq 1 ]; then
    kill -TERM -- "-$timeout_pid" 2>/dev/null || true; kill -KILL -- "-$timeout_pid" 2>/dev/null || true
  fi
  wait "$p" 2>/dev/null || true
  # (f) An uncovered eigenscript* invocation is a named refusal.
  st_reset; st_consumer variant 'eigenscript-gfx work.eigs'
  printf 'variant\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  st_check f variant-set 'row|variant|v0.43.0|UNRUNNABLE|-|0|cand_calls=0|cand_ok=0|cand_fail=0|consumer_skips=0|prereq=variant:eigenscript-gfx' "$st_record"
  # (g) Two honest candidate calls across two pinned consumers pass.
  st_reset; st_consumer first 'eigenscript first.eigs'; st_consumer second 'eigenscript second.eigs'
  printf 'first\nsecond\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  if [ "$st_rc" -eq 0 ] && grep -Fqx 'inventory=2 examined=2' "$st_record" && grep -Fqx 'VERDICT: PASS' "$st_record" && [ "$(grep -c '^row|.*|PASS|' "$st_record")" -eq 2 ]; then
    echo 'plant g check=honest-control GREEN inventory=2 examined=2 VERDICT: PASS'
  else echo 'plant g check=honest-control SILENT'; st_bad=1; fi
  # (h) A tree-path launch is counted, and a stale tree variant is masked.
  local h_base=0 h_variant=0
  mkdir -p "$st_root/src" "$st_root/lib"
  printf '/* source */\n' > "$st_root/src/stub.c"
  printf '# library\n' > "$st_root/lib/stub.eigs"
  st_reset; st_consumer tree_base 'test -r "$EIGS_DIR/src/stub.c" && test -r "$EIGS_DIR/lib/stub.eigs" && "$EIGS_DIR/src/eigenscript" work.eigs'
  printf 'tree_base\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  if [ "$st_rc" -eq 0 ] && grep -Fq 'row|tree_base|v0.43.0|PASS|0|' "$st_record" && grep -Fq 'cand_calls=1' "$st_record"; then h_base=1; fi
  printf '#!/bin/sh\necho stale > %q\nexit 0\n' "$st_root/stale-ran" > "$st_root/src/eigenscript-gfx"
  chmod +x "$st_root/src/eigenscript-gfx"
  st_reset; st_consumer tree_variant '"$EIGS_DIR/src/eigenscript-gfx" work.eigs'
  printf 'tree_variant\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  if [ "$st_rc" -ne 0 ] && grep -Fq 'prereq=variant:eigenscript-gfx' "$st_record" && [ ! -e "$st_root/stale-ran" ]; then h_variant=1; fi
  if [ "$h_base" -eq 1 ] && [ "$h_variant" -eq 1 ]; then
    echo 'plant h check=tree-path-routing GREEN counted=1 missing-gfx=UNRUNNABLE stale=not-run'
  else echo "plant h check=tree-path-routing SILENT counted=$h_base missing-gfx=$h_variant"; st_bad=1; fi
  # (A) C source names beginning eigenscript stay source, in a private copy.
  printf 'int runtime_value(void);\n' > "$st_root/src/eigenscript.h"
  printf '#include "eigenscript.h"\nint runtime_value(void) { return 7; }\n' > "$st_root/src/eigenscript.c"
  st_reset; st_consumer sources 'cc -c "$EIGS_DIR/src/eigenscript.c" -o runtime.o && printf changed > "$EIGS_DIR/src/eigenscript.h" && eigenscript smoke.eigs'
  printf 'sources\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  if [ "$st_rc" -eq 0 ] && grep -Fq 'row|sources|v0.43.0|PASS|0|' "$st_record" && grep -Fqx 'int runtime_value(void);' "$st_root/src/eigenscript.h"; then
    echo 'plant A check=private-source-copy GREEN cc=PASS source-unchanged=yes'
  else echo 'plant A check=private-source-copy SILENT'; st_bad=1; fi
  # (B) A consumer rebuild of its overlay cannot replace the original binary.
  printf '#!/bin/sh\ncase "$1" in regression.eigs) exit 42;; esac\nexit 0\n' > "$st_candidate"; chmod +x "$st_candidate"
  printf '#!/bin/sh\nexit 0\n' > "$st_root/rebuilt-runtime"; chmod +x "$st_root/rebuilt-runtime"
  printf 'build:\n\tcp rebuilt-runtime src/eigenscript\n' > "$st_root/Makefile"
  local before_sha after_sha
  before_sha="$(sha256sum "$st_candidate" | awk '{print $1}')"
  st_reset; st_consumer rebuild 'cc -c "$EIGS_DIR/src/eigenscript.c" -o runtime.o && eigenscript smoke.eigs && make -C "$EIGS_DIR" build && eigenscript regression.eigs'
  printf 'rebuild\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  after_sha="$(sha256sum "$st_candidate" | awk '{print $1}')"
  if [ "$st_rc" -ne 0 ] && grep -Fq 'row|rebuild|v0.43.0|FAIL|42|' "$st_record" && [ "$before_sha" = "$after_sha" ]; then
    echo 'plant B check=private-overlay GREEN rebuild-rc=42 candidate-sha256=unchanged'
  else echo 'plant B check=private-overlay SILENT'; st_bad=1; fi
  # (C) A candidate adjacent to unrelated source cannot claim that tree.
  mkdir -p "$st_root/mismatch/src" "$st_root/mismatch/lib" "$st_root/mismatch/bin"
  cp "$st_candidate" "$st_root/mismatch/bin/candidate"
  printf '#!/bin/sh\nexit 0\n' > "$st_root/mismatch/src/eigenscript"; chmod +x "$st_root/mismatch/src/eigenscript"
  st_reset; st_consumer mismatch 'eigenscript smoke.eigs'
  st_rc=0
  CA_ECO="$st_eco" CA_RECORD="$st_record" timeout 8 bash "$HERE/tools/consumer_acceptance.sh" run "$st_root/mismatch/bin/candidate" > "$st_out" 2>&1 || st_rc=$?
  if [ "$st_rc" -eq 2 ] && grep -Fq 'candidate tree mismatch:' "$st_out"; then
    echo 'plant C check=tree-correspondence RED candidate tree mismatch: unrelated src/eigenscript'
  else echo 'plant C check=tree-correspondence SILENT'; st_bad=1; fi
  # (D) A completed target record is a floor witness before replacement.
  st_reset; rm -f "$st_eco/.ca_fixture"
  st_consumer first 'eigenscript smoke.eigs'; st_consumer second 'eigenscript smoke.eigs'
  printf 'first\nsecond\n' > "$st_eco/.ca_expected"
  mkdir -p "$st_root/runner/tools" "$st_root/runner/reports/consumer_acceptance"
  cp "$HERE/tools/consumer_acceptance.sh" "$HERE/tools/_derive_variants.py" "$HERE/tools/_extract_runcmd.py" "$st_root/runner/tools/"
  printf 'status=COMPLETE\ninventory=3\nexamined=3\nVERDICT: PASS\n' > "$st_record"
  st_rc=0
  CA_ECO="$st_eco" CA_TREE="$st_root" CA_RECORD="$st_record" CA_TIMEOUT=2 timeout 12 bash "$st_root/runner/tools/consumer_acceptance.sh" run "$st_candidate" > "$st_out" 2>&1 || st_rc=$?
  if [ "$st_rc" -ne 0 ] && grep -Fqx 'record_floor=3' "$st_record" && grep -Fqx 'VERDICT: FAIL' "$st_record"; then
    echo 'plant D check=record-floor-before-replacement RED record_floor=3 VERDICT: FAIL'
  else echo 'plant D check=record-floor-before-replacement SILENT'; st_bad=1; fi
  # (E) A named missing capability is UNRUNNABLE before the command runs.
  st_reset; st_consumer dynamics 'eigenscript smoke.eigs'
  printf 'dynamics\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  if [ "$st_rc" -ne 0 ] && grep -Fq 'row|dynamics|v0.43.0|UNRUNNABLE' "$st_record" && grep -Fq 'prereq=gfx-build' "$st_record"; then
    echo 'plant E check=named-prerequisite RED dynamics prereq=gfx-build'
  else echo 'plant E check=named-prerequisite SILENT'; st_bad=1; fi
  # (F) The executable location, not EIGS_DIR, resolves this candidate lib.
  printf 'CANDIDATE_MARKER\n' > "$st_root/lib/marker"
  printf '#!/bin/sh\ncase "$1" in --version) echo 0.43.0; exit 0;; esac\nbase=$(dirname "$(readlink -f "$0")")\ncat "$base/lib/marker"\n' > "$st_candidate"
  chmod +x "$st_candidate"
  st_reset; st_consumer original_path 'eigenscript smoke.eigs > actual.marker && grep -Fqx CANDIDATE_MARKER actual.marker'
  printf 'original_path\n' > "$st_eco/.ca_expected"
  st_rc=0; st_run || st_rc=$?
  if [ "$st_rc" -eq 0 ] && grep -Fq 'row|original_path|v0.43.0|PASS|0|' "$st_record"; then
    echo 'plant F check=original-executable-path GREEN candidate-lib=CANDIDATE_MARKER'
  else echo 'plant F check=original-executable-path SILENT'; st_bad=1; fi
  # (G) A consumer overwrite of the supplied binary must fail that row.
  printf '#!/bin/sh\nexit 0\n' > "$st_candidate"; chmod +x "$st_candidate"
  st_reset; st_consumer mutated 'eigenscript smoke.eigs && printf "#!/bin/sh\nexit 7\n" > "$CA_MUTATE_TARGET" && chmod +x "$CA_MUTATE_TARGET"'
  printf 'mutated\n' > "$st_eco/.ca_expected"
  export CA_MUTATE_TARGET="$st_candidate"
  st_rc=0; st_run || st_rc=$?
  unset CA_MUTATE_TARGET
  if [ "$st_rc" -ne 0 ] && grep -Fq 'row|mutated|v0.43.0|FAIL|0|' "$st_record" && grep -Fq 'prereq=candidate-mutated:eigenscript' "$st_record"; then
    echo "plant G check=candidate-mutation RED $(grep '^row|mutated|' "$st_record" | head -1)"
  else echo 'plant G check=candidate-mutation SILENT'; st_bad=1; fi
  rm -rf "$st_root"
  if [ "$st_bad" -eq 0 ]; then echo 'SELF-TEST: PASS -- 15/15 plants'; return 0; fi
  echo 'SELF-TEST: FAIL'; return 1
}

case "${1:-plan}" in
  plan) shift 2>/dev/null || true; plan "$@" ;;
  run) shift; run "$@" ;;
  --self-test) selftest ;;
  *) echo 'usage: consumer_acceptance.sh [plan [--cmd consumer]|run candidate [--full binary] [--gfx binary]|--self-test]'; exit 2 ;;
esac
