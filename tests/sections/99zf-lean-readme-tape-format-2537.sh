echo "[99zf] spec/lean README names no tape format but the model's (#2537)"
# The README once said "Tape format `8`" while Tape.lean had moved to 10.
# It now names `tapeFormat` instead of a number; any number it states again
# must equal the model's.
TOTAL=$((TOTAL + 1))
_2537_model=$(sed -n 's/^def tapeFormat : String := "\([0-9]*\)"$/\1/p' ../spec/lean/EigenCore/Tape.lean)
# awk extracts (grep -o is not POSIX); the model's number is passed through the environment.
_2537_bad=$(_2537_model="${_2537_model:-none}" awk '
    { line = tolower($0)
      while (match(line, /tape format `?[0-9]+/)) {
          num = substr(line, RSTART, RLENGTH); sub(/^[^0-9]*/, "", num)
          if (num != ENVIRON["_2537_model"]) printf "%s ", num
          line = substr(line, RSTART + RLENGTH)
      } }' ../spec/lean/README.md)
if [ -n "$_2537_model" ] && [ -z "$_2537_bad" ]; then
    PASS=$((PASS + 1)); echo "  PASS: README tape format agrees with tapeFormat ($_2537_model)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: README tape format '${_2537_bad}' vs Tape.lean '${_2537_model:-unparsed}'"
fi
unset _2537_model _2537_bad
