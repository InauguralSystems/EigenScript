#!/bin/bash
# Every .github/workflows file must LOAD as YAML with a top-level jobs:
# mapping, and every present workflow, job, and step name must be a string
# (#1207). No PyYAML, or zero files, is RED — a skip is not a pass.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="${WORKFLOW_CHECK_DIR:-$ROOT/.github/workflows}"
DEV_DOCKERFILE="${WORKFLOW_CHECK_DOCKERFILE:-$ROOT/.devcontainer/Dockerfile}"
if [ "${1:-}" = --selftest ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/workflow_yaml_selftest.XXXXXX") || exit 2
    trap 'rm -rf "$tmp"' EXIT
    python3 - "$0" "$tmp" <<'PY_SELFTEST'
import json, os, pathlib, subprocess, sys
checker, scratch = sys.argv[1], pathlib.Path(sys.argv[2])
base = "FROM debian:stable\nRUN apt-get install -y python3\n"
# These strings are only parsed as workflow data; no planted command executes.
cases = [
    ("bare", "jq .", base, False, "run command 'jq'"),
    ("pipeline", "printf ok | jq .", base, False, "run command 'jq'"),
    ("substitution", 'echo "$(jq .)"', base, False, "run command 'jq'"),
    ("env", "env MODE=test jq .", base, False, "run command 'jq'"),
    ("timeout", "timeout 1 jq .", base, False, "run command 'jq'"),
    ("timeout-options", "timeout -s TERM -k 2 1 jq .", base, False, "run command 'jq'"),
    ("subshell", "(jq)", base, False, "run command 'jq'"),
    ("absolute", "/usr/bin/jq .", base, False, "run command 'jq'"),
    ("case-body", "case x in x) jq . ;; esac", base, False, "run command 'jq'"),
    ("clean", 'echo "$(printf ok)"; timeout 1 true; (true)', base, True, "workflow-container: OK"),
    ("case-pattern", "case x in jq) true ;; x) printf ok ;; esac", base, True, "workflow-container: OK"),
    ("installed-jq", "timeout 1 jq .", base + "RUN apt-get install -y jq\n", True, "workflow-container: OK"),
    ("comment-is-data", "jq .", base + "# apt-get install jq\n", False, "run command 'jq'"),
    ("continued-comment-data", "jq .", "FROM debian:stable\nRUN apt-get install -y python3 \\\n    # jq unavailable\n    && true\n", False, "run command 'jq'"),
    ("continued-after-comment", "jq .", "FROM debian:stable\nRUN apt-get install -y python3 \\\n    # not a package\n    jq\n", True, "workflow-container: OK"),
    ("missing-dockerfile", "true", None, False, "Dockerfile cannot be read"),
    ("no-install", "true", "FROM debian:stable\n", False, "no apt-get install"),
    ("unprovided-sysctl", "sysctl -w x=0", base, False, "run command 'sysctl'"),
    ("installed-procps", "sysctl -w x=0", base + "RUN apt-get install -y procps\n", True, "workflow-container: OK"),
    # Only image-provisioned commands count; script text cannot widen it.
    ("late-install", "jq .; apt-get install -y jq", base, False, "run command 'jq'"),
    ("early-install", "apt-get install -y jq; jq .", base, False, "run command 'jq'"),
    ("commented-install", "true # apt-get install -y jq\njq .", base, False, "run command 'jq'"),
    ("quoted-install", "echo 'apt-get install -y jq'; jq .", base, False, "run command 'jq'"),
    ("command-v", "command -v valgrind; timeout 1 true", base, True, "workflow-container: OK"),
    ("command-V", "command -V jq", base, True, "workflow-container: OK"),
    ("query-then-call", "command -v jq; command jq .", base, False, "run command 'jq'"),
    ("command-call", "command jq .", base, False, "run command 'jq'"),
    ("exec-call", "exec jq .", base, False, "run command 'jq'"),
    ("query-substitution", 'command -v "$(jq .)"', base, False, "run command 'jq'"),
    ("quoted-hash-then-call", "echo '# quoted data'; jq .", base, False, "run command 'jq'"),
    ("comment-apostrophe-query", "# don't require the optional tool\ncommand -v \"$(jq .)\"", base, False, "run command 'jq'"),
    ("comment-apostrophe-echo", "# don't require the optional tool\necho \"$(jq .)\"", base, False, "run command 'jq'"),
    ("comment-doublequote-query", '# "optional tool\ncommand -v "$(jq .)"', base, False, "run command 'jq'"),
    ("comment-doublequote-inert", '# "optional tool\necho \'$(jq .)\'', base, True, "workflow-container: OK"),
    ("doublequoted-comment-substitution", "echo \"# don't require $(jq .)\"", base, False, "run command 'jq'"),
    ("singlequoted-comment-inert", 'echo \'# "$(jq .)\'', base, True, "workflow-container: OK"),
    ("escaped-hash-substitution", 'echo \\# "$(jq .)"', base, False, "run command 'jq'"),
    ("embedded-hash-substitution", 'echo tag#part "$(jq .)"', base, False, "run command 'jq'"),
    ("comment-apostrophe-inert", "# don't require $(jq .)\ntrue", base, True, "workflow-container: OK"),
    ("comment-substitution-inert", "# $(jq .)\ntrue", base, True, "workflow-container: OK"),
]
for name, command, docker, green, marker in cases:
    row = scratch / name; (row / "workflows").mkdir(parents=True)
    (row / "workflows/ci.yml").write_text("name: fixture\njobs:\n  check:\n    container: {image: dev-image}\n    steps:\n      - run: " + json.dumps(command) + "\n")
    if docker is not None: (row / "Dockerfile").write_text(docker)
    env = dict(os.environ, WORKFLOW_CHECK_DIR=str(row / "workflows"), WORKFLOW_CHECK_DOCKERFILE=str(row / "Dockerfile"))
    result = subprocess.run(["bash", checker], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != green or marker not in result.stdout:
        print("FAIL: " + name + " (rc=%d)\n" % result.returncode + result.stdout); sys.exit(1)
print("workflow-yaml selftest: %d/%d passed" % (len(cases), len(cases)))
PY_SELFTEST
    selftest_rc=$?
    [ "$selftest_rc" -eq 0 ] || exit "$selftest_rc"
    exit 0
fi
[ -z "${1:-}" ] || { echo "usage: $0 [--selftest]" >&2; exit 2; }
exec 0</dev/null
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "workflow-yaml: RED: PyYAML is not importable, so nothing in $WF_DIR was loaded. This is not a pass. Install it: apt install python3-yaml, or python3 -m pip install --user pyyaml."
    exit 1
fi
out=$(WF_DIR="$WF_DIR" DEV_DOCKERFILE="$DEV_DOCKERFILE" python3 - 2>&1 <<'PY'
import glob, io, os, re, shlex, sys, yaml
d = os.environ["WF_DIR"]
files = sorted(set(glob.glob(os.path.join(d, "*.yml")) + glob.glob(os.path.join(d, "*.yaml"))))
sys.stdout.write("EXAMINED %d\n" % len(files))
bad = 0
def note(f, path, val):
    global bad
    if isinstance(val, str): return
    sys.stdout.write("RED: %s: %s is %s, not a string\n" % (f, path, type(val).__name__)); bad += 1
def violation(f, path, value):
    global bad
    sys.stdout.write("RED: %s: %s %r is not provided by the dev image\n" % (f, path, value)); bad += 1

# Commands supplied by Debian's base image, POSIX shell builtins, and coreutils
# do not need an explicit dev-image package. Package-specific commands do. Keep
# this table deliberately narrower than a host PATH: the Dockerfile is the
# contract being checked, not whatever happens to be installed on this runner.
BASE = set("apt-get awk bash cmp find grep kill lscpu sed sh xargs [ : .".split())
# GNU coreutils installed in the Debian base image.  Keep the complete command
# set here rather than a sample: workflows are allowed to use coreutils without
# the Dockerfile redundantly installing the package.
BASE.update("""b2sum base32 base64 basenc basename cat chcon chgrp chmod chown
chroot cksum comm cp csplit cut date dd df dir dircolors dirname du echo env
expand expr factor false fmt fold groups head hostid id install join link ln
logname ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od
paste pathchk pinky pr printenv printf ptx pwd readlink realpath rm rmdir runcon
seq sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort split
stat stdbuf stty sum sync tac tail tee test timeout touch tr true truncate tsort
tty uname unexpand uniq unlink users vdir wc who whoami yes""".split())
BUILTINS = set("break cd command continue eval exec exit export getopts hash local popd pushd read readonly return set shift source times trap type ulimit umask unalias unset wait".split())
PACKAGE_COMMANDS = {
    "build-essential": "ar as c++ cc cpp g++ gcc ld make nm objcopy objdump ranlib readelf size strings strip",
    "clang": "clang clang++",
    "git": "git",
    "jq": "jq",
    "procps": "sysctl ps",
    "curl": "curl",
    "gdb": "gdb",
    "postgresql-client": "psql pg_dump pg_restore",
    "python3": "python3",
    "python3-yaml": "python3",
    "valgrind": "valgrind",
    "time": "time",
}
def docker_packages(path):
    global bad
    try: text = open(path, encoding="utf-8").read()
    except OSError as exc:
        sys.stdout.write("RED: dev image Dockerfile cannot be read: %s\n" % exc); bad += 1; return set()
    # The package list is the continuation containing apt-get install. Options
    # are discarded; package names are the remaining words up to &&.
    text = re.sub(r"(?m)^[ \t]*#.*(?:\n|$)", "", text)
    text = re.sub(r"(?m)(^|[ \t]+)#.*$", "", text)
    flat = re.sub(r"\\\n", " ", text)
    installs = re.findall(r"\bapt-get\s+install\b([^;&\n]*)", flat)
    if not installs:
        sys.stdout.write("RED: dev image Dockerfile has no apt-get install package list\n"); bad += 1; return set()
    return {w for w in re.findall(r"[A-Za-z0-9][A-Za-z0-9+.-]*", " ".join(installs)) if not w.startswith("-") and w not in ("y", "no-install-recommends")}
packages = docker_packages(os.environ["DEV_DOCKERFILE"])
available = BASE | BUILTINS
for package in packages:
    available.update(PACKAGE_COMMANDS.get(package, "").split())
CONTAINER_STEPS = 0

class ShellCommentStream(io.StringIO):
    # shlex drops the rest of a comment with readline(), including its newline.
    # Keep that newline pending so it still separates executable positions.
    # Quoted hashes remain data because shlex never calls readline() for them.
    def readline(self, *args):
        line = super().readline(*args)
        if line.endswith("\n"):
            self.seek(self.tell() - 1)
        return line

def commands(script, known_functions=None):
    """Return executable words from shell lists, pipelines, and substitutions."""
    found = []
    # Here-document bodies are data for the command that introduced them, not
    # shell source (they commonly contain Python or generated YAML).
    shell_lines = []
    heredoc_end = None
    for raw in script.splitlines():
        stripped = raw.strip()
        if heredoc_end is not None:
            if stripped == heredoc_end: heredoc_end = None
            continue
        shell_lines.append(raw)
        heredoc = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", raw)
        if heredoc: heredoc_end = heredoc.group(1)
    script = "\n".join(shell_lines)
    functions = set(known_functions or ())
    functions.update(re.findall(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", script))
    # shlex correctly keeps a quoted $(...) inside one argument, so walk the
    # source as well and recursively audit every balanced command substitution.
    # Single quotes suppress substitution; double quotes intentionally do not.
    quote = None
    i = 0
    while i + 1 < len(script):
        char = script[i]
        # Comments cannot change quote state or contain executable substitutions.
        # A quoted, escaped or word-internal hash remains shell data.
        if char == "\\" and quote != "'":
            i += 2; continue
        if char == "#" and quote is None and (i == 0 or script[i - 1] in " \t\r\n;|&()"):
            newline = script.find("\n", i)
            if newline < 0: break
            i = newline + 1; continue
        if char == "'" and quote != '"':
            quote = None if quote == "'" else "'"
        elif char == '"' and quote != "'":
            quote = None if quote == '"' else '"'
        elif char == "$" and script[i + 1] == "(" and quote != "'":
            depth, j = 1, i + 2
            while j < len(script) and depth:
                if script[j] == "(": depth += 1
                elif script[j] == ")": depth -= 1
                j += 1
            if depth == 0:
                found.extend(commands(script[i + 2:j - 1], functions))
                i = j - 1
        i += 1
    try:
        # Treat newlines as shell punctuation instead of whitespace so they
        # start commands, while newlines inside quoted arguments remain data.
        lexer = shlex.shlex(ShellCommentStream(script), posix=True, punctuation_chars="();|&\n")
        lexer.whitespace_split = True
        lexer.whitespace = " \t\r"
        lexer.commenters = "#"
        words = list(lexer)
    except ValueError:
        words = re.sub(r"(&&|\|\||[;|()\n])", r" \1 ", script).split()
    command_position = True
    wrappers = {"command", "exec", "env", "xargs", "timeout", "stdbuf"}
    wrapper = None
    option_value = False
    timeout_duration = False
    cases = []
    controls = {"if", "then", "elif", "else", "while", "until", "do", "!"}
    endings = {"fi", "done", "case", "esac", "for", "select", "function", "{" , "}"}
    for index, word in enumerate(words):
        # Case patterns are data only inside a real case/in ... esac arm.
        # A subshell such as (jq) must still audit jq before its closing ).
        if word == "esac" and cases:
            cases.pop(); command_position = False; continue
        if cases and cases[-1] == "expression":
            if word == "in": cases[-1] = "pattern"
            continue
        if cases and cases[-1] == "pattern":
            if ")" in word: cases[-1] = "body"; command_position = True
            continue
        if cases and word in (";;", ";&", ";;&"):
            cases[-1] = "pattern"; command_position = True; continue
        if re.fullmatch(r"[;|&()\n]+", word):
            command_position = True
            wrapper = None; option_value = False; timeout_duration = False
            continue
        if not command_position:
            continue
        if word == "case":
            cases.append("expression"); continue
        if option_value:
            option_value = False; continue
        # command -v/-V query availability; their operands do not execute.
        # Substitutions were already audited above, and a separator resumes
        # command positions so a later command/exec/env/timeout still counts.
        if wrapper == "command" and word in ("-v", "-V"):
            command_position = False; wrapper = None; continue
        if wrapper and word.startswith("-"):
            option_value = word in {"-u", "--unset", "-s", "--signal", "-k", "--kill-after", "-n", "--max-args", "-P", "--max-procs", "-I", "--replace", "-i", "-o", "-e"}
            continue
        if timeout_duration:
            timeout_duration = False; continue
        if word in controls:
            continue
        if word == "for":
            command_position = False
            continue
        if word in endings or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", word):
            continue
        # Wrapper options precede the executable operand.  Keeping command
        # position true after a wrapper makes both wrapper and target get
        # audited (env assignments are handled by the branch above).
        if word.startswith("-"):
            continue
        if word.startswith(("/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/")):
            word = os.path.basename(word)
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9_+-]*", word) and word not in functions:
            found.append(word)
            command_position = word in wrappers
            wrapper = word if command_position else None
            timeout_duration = word == "timeout"
        else:
            command_position = False
    return found
for f in files:
    try:
        with open(f, encoding="utf-8") as fh: doc = yaml.safe_load(fh)
    except Exception as exc:
        sys.stdout.write("RED: %s: %s\n" % (f, str(exc).replace("\n", " ")[:200])); bad += 1; continue
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        sys.stdout.write("RED: %s: loaded, but no top-level jobs: mapping\n" % f); bad += 1; continue
    if "name" in doc: note(f, "name", doc.get("name"))
    for jid, job in doc["jobs"].items():
        if not isinstance(job, dict): continue
        if "name" in job: note(f, "jobs.%s.name" % jid, job.get("name"))
        steps = job.get("steps") if isinstance(job.get("steps"), list) else []
        for i, st in enumerate(steps):
            if isinstance(st, dict) and "name" in st:
                note(f, "jobs.%s.steps[%d].name" % (jid, i), st.get("name"))
            if not isinstance(st, dict) or "run" not in st or "container" not in job: continue
            CONTAINER_STEPS += 1
            for cmd in commands(str(st["run"])):
                # Repository paths and action-generated tools are not external
                # image commands. Everything else must be furnished above.
                if "/" in cmd or cmd.startswith("$") or cmd in available: continue
                violation(f, "jobs.%s.steps[%d].run command" % (jid, i), cmd)
if CONTAINER_STEPS == 0:
    sys.stdout.write("RED: examined 0 run steps in dev-image container jobs\n"); bad += 1
sys.stdout.write("CONTAINER_STEPS %d\n" % CONTAINER_STEPS)
sys.exit(1 if bad else 0)
PY
)
pyrc=$?
examined=$(printf '%s\n' "$out" | sed -n 's/^EXAMINED //p' | head -1); examined=${examined:-0}
container_steps=$(printf '%s\n' "$out" | sed -n 's/^CONTAINER_STEPS //p' | head -1); container_steps=${container_steps:-0}
printf '%s\n' "$out" | grep '^RED:' || true
if [ "$pyrc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q '^RED:'; then
    printf '%s\n' "$out"
    echo "workflow-yaml: RED: the YAML loader failed on $WF_DIR"; exit 1
fi
if [ "$examined" -eq 0 ]; then
    echo "workflow-yaml: RED: examined 0 workflow files in $WF_DIR — an empty population loaded nothing"; exit 1
fi
if [ "$pyrc" -ne 0 ]; then
    echo "workflow-yaml: FAIL (examined=$examined file(s), loader=pyyaml, problems=$(printf '%s\n' "$out" | grep -c '^RED:'))"
    exit 1
fi
echo "workflow-yaml: OK (examined=$examined file(s), loader=pyyaml)"
echo "workflow-container: OK (run-steps=$container_steps, image=dev-image)"
exit 0
