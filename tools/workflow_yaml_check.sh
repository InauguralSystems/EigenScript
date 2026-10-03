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
    ("word-hash-then-command", "echo tag#part; jq .", base, False, "run command 'jq'"),
    ("word-hash-then-exec", "echo tag#part; exec jq .", base, False, "run command 'jq'"),
    ("doublequoted-hash-then-exec", 'echo "# quoted"; exec jq .', base, False, "run command 'jq'"),
    ("escaped-hash-then-exec", 'echo \\#; exec jq .', base, False, "run command 'jq'"),
    ("word-hash-real-comment", "echo tag#part # jq .\ntrue", base, True, "workflow-container: OK"),
    ("escaped-space-word-hash", 'echo tag\\ #part; jq .', base, False, "run command 'jq'"),
]
for name, command, docker, green, marker in cases:
    row = scratch / name; (row / "workflows").mkdir(parents=True)
    (row / "workflows/ci.yml").write_text("name: fixture\njobs:\n  check:\n    container:\n      image: ${{ needs.dev-image.outputs.image }}\n    steps:\n      - run: " + json.dumps(command) + "\n")
    if docker is not None: (row / "Dockerfile").write_text(docker)
    env = dict(os.environ, WORKFLOW_CHECK_DIR=str(row / "workflows"), WORKFLOW_CHECK_DOCKERFILE=str(row / "Dockerfile"))
    result = subprocess.run(["bash", checker], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if (result.returncode == 0) != green or marker not in result.stdout:
        print("FAIL: " + name + " (rc=%d)\n" % result.returncode + result.stdout); sys.exit(1)
print("workflow-yaml selftest: %d/%d passed" % (len(cases), len(cases)))

# Scope contracts are tested separately so each declared population is
# nonempty and its classification is visible through the public entrypoint.
scope_cases = [
    ("compact-image-expression", """jobs:
  control:
    container: {image: '${{ needs.dev-image.outputs.image }}'}
    steps: [{run: 'python3 --version'}]
  compact:
    container: {image: '${{needs.dev-image.outputs.image}}'}
    steps: [{run: 'not_in_the_dev_image'}]
""", 1, ["jobs.compact image=dev-image", "not_in_the_dev_image", "jobs-examined=2, jobs-skipped=0, jobs-unsupported=0"]),
    ("image-scope", """jobs:
  supported:
    container: {image: '${{ needs.dev-image.outputs.image }}'}
    steps: [{shell: bash, run: 'python3 --version'}]
  other:
    container: {image: 'alpine:3.20'}
    steps: [{run: 'not_in_the_dev_image'}]
""", 0, ["jobs.supported image=dev-image", "jobs.other reason=image 'alpine:3.20' is not the dev-image expression", "jobs-examined=1, jobs-skipped=1, jobs-unsupported=0"]),
    ("non-posix-shell", """jobs:
  supported:
    container: {image: '${{ needs.dev-image.outputs.image }}'}
    steps:
      - shell: pwsh
        run: Get-ChildItem
""", 1, ["JOB REJECTED ", "jobs.supported reason=unsupported shell grammar", "unsupported shell 'pwsh'", "jobs-examined=0, jobs-skipped=0, jobs-unsupported=1"]),
    ("empty-shell", """jobs:
  supported:
    container: {image: '${{ needs.dev-image.outputs.image }}'}
    steps: [{shell: '', run: 'python3 --version'}]
""", 1, ["JOB REJECTED ", "unsupported shell ''", "jobs-examined=0, jobs-skipped=0, jobs-unsupported=1"]),
]
for name, workflow, expected_rc, markers in scope_cases:
    row = scratch / name; (row / "workflows").mkdir(parents=True)
    (row / "workflows/ci.yml").write_text("name: fixture\n" + workflow)
    (row / "Dockerfile").write_text(base)
    env = dict(os.environ, WORKFLOW_CHECK_DIR=str(row / "workflows"), WORKFLOW_CHECK_DOCKERFILE=str(row / "Dockerfile"))
    result = subprocess.run(["bash", checker], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != expected_rc or any(marker not in result.stdout for marker in markers):
        print("FAIL: " + name + " (expected rc=%d, observed rc=%d)\n" % (expected_rc, result.returncode) + result.stdout); sys.exit(1)
print("workflow-yaml scope selftest: %d/%d passed" % (len(scope_cases), len(scope_cases)))
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
import glob, os, re, shlex, sys, yaml
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
JOBS_EXAMINED = 0
JOBS_SKIPPED = 0
JOBS_UNSUPPORTED = 0
DEV_IMAGE = re.compile(r"\s*\$\{\{\s*needs\.dev-image\.outputs\.image\s*\}\}\s*")

def strip_shell_comments(script):
    """One comment interpretation for substitutions and command tokenization."""
    kept, quote, i, word_start = [], None, 0, True
    while i < len(script):
        char = script[i]
        if char == "\\" and quote != "'":
            kept.append(script[i:i + 2])
            if script[i + 1:i + 2] != "\n": word_start = False
            i += 2; continue
        if char == "#" and quote is None and word_start:
            newline = script.find("\n", i)
            if newline < 0: break
            i = newline; continue
        kept.append(char)
        if char == "'" and quote != '"':
            quote = None if quote == "'" else "'"
        elif char == '"' and quote != "'":
            quote = None if quote == '"' else '"'
        word_start = quote is None and char in " \t\r\n;|&()"
        i += 1
    return "".join(kept)

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
    script = strip_shell_comments("\n".join(shell_lines))
    functions = set(known_functions or ())
    functions.update(re.findall(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", script))
    # shlex correctly keeps a quoted $(...) inside one argument, so walk the
    # source as well and recursively audit every balanced command substitution.
    # Single quotes suppress substitution; double quotes intentionally do not.
    quote = None
    i = 0
    while i + 1 < len(script):
        char = script[i]
        # Comments were removed once above; preserve escaped quote/dollar data.
        if char == "\\" and quote != "'":
            i += 2; continue
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
        lexer = shlex.shlex(script, posix=True, punctuation_chars="();|&\n")
        lexer.whitespace_split = True
        lexer.whitespace = " \t\r"
        lexer.commenters = ""  # Shared stripping above owns comment semantics.
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
        container = job.get("container")
        image = container.get("image") if isinstance(container, dict) else container
        dev_image = isinstance(image, str) and DEV_IMAGE.fullmatch(image) is not None
        run_steps = [st for st in steps if isinstance(st, dict) and "run" in st]
        if container is None:
            JOBS_SKIPPED += 1
            sys.stdout.write("JOB SKIPPED %s:jobs.%s reason=no container\n" % (f, jid))
        elif not dev_image:
            JOBS_SKIPPED += 1
            sys.stdout.write("JOB SKIPPED %s:jobs.%s reason=image %r is not the dev-image expression\n" % (f, jid, image))
        else:
            workflow_defaults = doc.get("defaults") if isinstance(doc.get("defaults"), dict) else {}
            job_defaults = job.get("defaults") if isinstance(job.get("defaults"), dict) else {}
            workflow_run = workflow_defaults.get("run") if isinstance(workflow_defaults.get("run"), dict) else {}
            job_run = job_defaults.get("run") if isinstance(job_defaults.get("run"), dict) else {}
            unsupported = []
            for i, st in enumerate(steps):
                if not isinstance(st, dict) or "run" not in st: continue
                shell = st.get("shell", job_run.get("shell", workflow_run.get("shell")))
                shell_words = str(shell).strip().split(None, 1) if shell is not None else []
                shell_word = shell_words[0] if shell_words else ""
                if shell is not None and os.path.basename(shell_word) not in ("bash", "sh"):
                    unsupported.append((i, shell))
            if unsupported:
                JOBS_UNSUPPORTED += 1
                sys.stdout.write("JOB REJECTED %s:jobs.%s reason=unsupported shell grammar\n" % (f, jid))
                for i, shell in unsupported:
                    sys.stdout.write("RED: %s: jobs.%s.steps[%d].shell unsupported shell %r; POSIX command availability was not evaluated\n" % (f, jid, i, shell)); bad += 1
            else:
                JOBS_EXAMINED += 1
                sys.stdout.write("JOB EXAMINED %s:jobs.%s image=dev-image run-steps=%d\n" % (f, jid, len(run_steps)))
        for i, st in enumerate(steps):
            if isinstance(st, dict) and "name" in st:
                note(f, "jobs.%s.steps[%d].name" % (jid, i), st.get("name"))
            if not isinstance(st, dict) or "run" not in st or not dev_image or unsupported: continue
            CONTAINER_STEPS += 1
            for cmd in commands(str(st["run"])):
                # Repository paths and action-generated tools are not external
                # image commands. Everything else must be furnished above.
                if "/" in cmd or cmd.startswith("$") or cmd in available: continue
                violation(f, "jobs.%s.steps[%d].run command" % (jid, i), cmd)
if CONTAINER_STEPS == 0:
    sys.stdout.write("RED: examined 0 run steps in dev-image container jobs\n"); bad += 1
sys.stdout.write("CONTAINER_STEPS %d\n" % CONTAINER_STEPS)
sys.stdout.write("JOB_COUNTS %d %d %d\n" % (JOBS_EXAMINED, JOBS_SKIPPED, JOBS_UNSUPPORTED))
sys.exit(1 if bad else 0)
PY
)
pyrc=$?
examined=$(printf '%s\n' "$out" | sed -n 's/^EXAMINED //p' | head -1); examined=${examined:-0}
container_steps=$(printf '%s\n' "$out" | sed -n 's/^CONTAINER_STEPS //p' | head -1); container_steps=${container_steps:-0}
job_counts=$(printf '%s\n' "$out" | sed -n 's/^JOB_COUNTS //p' | head -1); job_counts=${job_counts:-"0 0 0"}
printf '%s\n' "$out" | grep '^RED:' || true
printf '%s\n' "$out" | grep '^JOB \(EXAMINED\|SKIPPED\|REJECTED\) ' || true
if [ "$pyrc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q '^RED:'; then
    printf '%s\n' "$out"
    echo "workflow-yaml: RED: the YAML loader failed on $WF_DIR"; exit 1
fi
if [ "$examined" -eq 0 ]; then
    echo "workflow-yaml: RED: examined 0 workflow files in $WF_DIR — an empty population loaded nothing"; exit 1
fi
if [ "$pyrc" -ne 0 ]; then
    set -- $job_counts
    echo "workflow-yaml: FAIL (examined=$examined file(s), loader=pyyaml, problems=$(printf '%s\n' "$out" | grep -c '^RED:'), jobs-examined=$1, jobs-skipped=$2, jobs-unsupported=$3)"
    exit 1
fi
echo "workflow-yaml: OK (examined=$examined file(s), loader=pyyaml)"
echo "workflow-container: OK (run-steps=$container_steps, image=dev-image)"
set -- $job_counts
echo "workflow-container-scope: OK (jobs-examined=$1, jobs-skipped=$2, jobs-unsupported=$3)"
exit 0
