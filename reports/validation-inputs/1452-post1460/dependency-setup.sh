#!/usr/bin/env bash
# Environment-only setup. Source identity must be verified before invoking.
set -uo pipefail
src=$1
out=$2
mkdir -p "$out/setup"
attempt=0
receipt() {
    attempt=$((attempt + 1))
    local name=$1 rc
    shift
    "$@" > "$out/setup/$attempt-$name.log" 2>&1
    rc=$?
    printf '%s\t%s\t%s\n' "$attempt" "$name" "$rc" >> "$out/setup/exits.tsv"
    return "$rc"
}
pkg=()
if [ "$(id -u)" = 0 ]; then pkg=(apt-get)
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then pkg=(sudo -n apt-get); fi
install_pkgs() {
    [ "${#pkg[@]}" -gt 0 ] || return 1
    receipt apt-install timeout 180 "${pkg[@]}" install -y --no-install-recommends "$@" && return 0
    receipt apt-refresh timeout 120 "${pkg[@]}" update || return 1
    receipt apt-retry timeout 180 "${pkg[@]}" install -y --no-install-recommends "$@"
}
receipt platform uname -a
receipt architecture uname -m
receipt bash bash --version
receipt uid id -u
receipt tool-paths bash -c 'command -v python3 gcc make git objdump timeout valgrind; command -v /usr/bin/time'
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || exit 1
tools_ok=1
for tool in python3 gcc make git objdump timeout valgrind; do command -v "$tool" >/dev/null || tools_ok=0; done
[ -x /usr/bin/time ] || tools_ok=0
receipt initial-python python3 -c 'import sys,yaml; print(sys.executable); print(sys.version); print(yaml.__version__); print(yaml.__file__)' || tools_ok=0
if [ "$tools_ok" != 1 ]; then
    install_pkgs build-essential git ca-certificates python3 python3-yaml valgrind time || true
fi
if ! receipt child-python python3 -c 'import sys,yaml; print(sys.executable); print(yaml.__version__); print(yaml.__file__)'; then
    if ! receipt venv python3 -m venv "$out/dependency-venv"; then
        install_pkgs python3-venv || true
        if ! receipt venv-retry python3 -m venv "$out/dependency-venv"; then
            receipt distro-venv /usr/bin/python3 -m venv "$out/dependency-venv" || exit 1
        fi
    fi
    vpy="$out/dependency-venv/bin/python"
    receipt pip-probe "$vpy" -m pip --version || receipt ensurepip "$vpy" -m ensurepip || exit 1
    receipt hashed-pyyaml timeout 180 "$vpy" -m pip install --require-hashes -r "$src/.github/requirements-release.txt" || exit 1
    export PATH="$out/dependency-venv/bin:$PATH"
fi
receipt final-python python3 -c 'import sys,yaml; print(sys.executable); print(sys.version); print(yaml.__version__); print(yaml.__file__)' || exit 1
for tool in gcc make git objdump; do receipt "$tool-version" "$tool" --version || exit 1; done
receipt timeout timeout --version || exit 1
receipt cachegrind-version valgrind --version || exit 1
receipt cachegrind-help valgrind --tool=cachegrind --help || exit 1
receipt gnu-time-version /usr/bin/time --version || exit 1
receipt gnu-time-run /usr/bin/time -f '%M' true || exit 1
cd "$src"
receipt workflow-yaml bash tools/workflow_yaml_check.sh || exit 1
python3 - "$src" "$out/setup" <<'PY'
import pathlib,re,sys
src,out=map(pathlib.Path,sys.argv[1:])
log=next(out.glob('*-workflow-yaml.log')).read_text()
rows=re.findall(r'^workflow-yaml: OK \(examined=(\d+) file\(s\), loader=pyyaml\)$',log,re.M)
n=len(list((src/'.github/workflows').glob('*.yml')))+len(list((src/'.github/workflows').glob('*.yaml')))
assert len(rows)==1 and int(rows[0])==n and n>0,(rows,n)
print('actual child interpreter and workflow inventory verified:',n)
PY
rc=$?
printf '%s\tworkflow-inventory\t%s\n' "$((attempt + 1))" "$rc" >> "$out/setup/exits.tsv"
[ "$rc" = 0 ] || exit "$rc"
printf '%s\n' "$PATH" > "$out/setup/selected-path.txt"
printf 'SETUP_COMPLETE\n'
