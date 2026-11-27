#!/usr/bin/env python3
"""Refuse undefined uppercase variables in every suite section (#2544).

Order and scope are not modelled: a setter anywhere in the fragment, its source
closure, or the runner's source closure counts as set everywhere in that fragment.
Bare names evaluated as arithmetic outside $(( ))/(( )) (including subscripts, parameter offsets, numeric tests, -v/unset operands, integer attributes and let) are not checked.
Text that a builtin evaluates again when it runs (a quoted subscript given to unset, -v or declare; eval; trap) is not checked.
Reads are $NAME and ${NAME...} where Bash expands the fragment's words (including operator words),
plus bare arithmetic names inside $(( )) and (( )).
Shell syntax belongs to _shell_tokens; this consumer uses token roles and APIs.
The documented environment contract is ONLY tests/README.md's marked table.
"""
from __future__ import annotations

import argparse
import functools
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from _shell_tokens import (TokenizerGap, assignment_split, emptied, simple_commands,
                           tokenize_file, unquote, variable_effects, setter_names, redirection_fd_names,
                           implicit_arithmetic_effects, associative_declarations, array_context, assignment_words, builtin_readings)

UPPER = re.compile(r'(?=[A-Z_0-9]*[A-Z])[A-Z_][A-Z_0-9]*\Z')
IDENT = re.compile(r'[a-zA-Z_][a-zA-Z_0-9]*\Z')
ENV_START = '<!-- suite-environment -->'
ENV_END = '<!-- /suite-environment -->'


@functools.lru_cache(maxsize=1)
def bash_variables():
    result = subprocess.run(['env', '-i', 'bash', '--norc', '--noprofile', '-c', 'compgen -v'],
                            text=True, capture_output=True, timeout=10, check=True)
    # GNU Bash Reference Manual, "Bash Variables": these are created only
    # in the relevant context and so may be absent from a fresh compgen -v.
    # https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
    # BASH_ENV, ENV: "Bash Startup Files"; HISTFILE, HISTTIMEFORMAT,
    # HISTCONTROL, HISTIGNORE: "Bash History Facilities" / "Bash Variables".
    # CDPATH HOME: "Bourne Shell Variables"; BASH_REMATCH: "Conditional Constructs".
    # COMP_* and COMPREPLY: "Bash Variables" (completion context).
    # These are bash's documented special variables, not suite exemptions.
    specials = {
        "CDPATH",  # CDPATH: Bourne Shell Variables (GNU Bash Reference Manual).
        "HOME",  # HOME: Bourne Shell Variables (GNU Bash Reference Manual).
        "LANG",  # LANG: Bash Variables (GNU Bash Reference Manual).
        "LC_ALL",  # LC_ALL: Bash Variables (GNU Bash Reference Manual).
        "LC_COLLATE",  # LC_COLLATE: Bash Variables (GNU Bash Reference Manual).
        "LC_CTYPE",  # LC_CTYPE: Bash Variables (GNU Bash Reference Manual).
        "LC_MESSAGES",  # LC_MESSAGES: Bash Variables (GNU Bash Reference Manual).
        "LC_NUMERIC",  # LC_NUMERIC: Bash Variables (GNU Bash Reference Manual).
        "LC_TIME",  # LC_TIME: Bash Variables (GNU Bash Reference Manual).
        "COLUMNS",  # COLUMNS: Bash Variables (GNU Bash Reference Manual).
        "LINES",  # LINES: Bash Variables (GNU Bash Reference Manual).
        "OLDPWD",  # OLDPWD: Bash Variables (GNU Bash Reference Manual).
        "OPTARG",  # OPTARG: Bourne Shell Variables (GNU Bash Reference Manual).
        "PIPESTATUS",  # PIPESTATUS: Bash Variables (GNU Bash Reference Manual).
        "READLINE_ARGUMENT",  # READLINE_ARGUMENT: Bash Variables (GNU Bash Reference Manual).
        "READLINE_LINE",  # READLINE_LINE: Bash Variables (GNU Bash Reference Manual).
        "READLINE_MARK",  # READLINE_MARK: Bash Variables (GNU Bash Reference Manual).
        "READLINE_POINT",  # READLINE_POINT: Bash Variables (GNU Bash Reference Manual).
        "BASH_ARGV0",  # BASH_ARGV0: Bash Variables (GNU Bash Reference Manual).
        "BASH_COMPAT",  # BASH_COMPAT: Bash Variables (GNU Bash Reference Manual).
        "BASH_ENV",  # BASH_ENV: Bash Startup Files (GNU Bash Reference Manual).
        "BASH_XTRACEFD",  # BASH_XTRACEFD: Bash Variables (GNU Bash Reference Manual).
        "CHILD_MAX",  # CHILD_MAX: Bash Variables (GNU Bash Reference Manual).
        "COMP_CWORD",  # COMP_CWORD: Bash Variables (GNU Bash Reference Manual).
        "COMP_LINE",  # COMP_LINE: Bash Variables (GNU Bash Reference Manual).
        "COMP_POINT",  # COMP_POINT: Bash Variables (GNU Bash Reference Manual).
        "COMP_TYPE",  # COMP_TYPE: Bash Variables (GNU Bash Reference Manual).
        "COMP_KEY",  # COMP_KEY: Bash Variables (GNU Bash Reference Manual).
        "COMP_WORDBREAKS",  # COMP_WORDBREAKS: Bash Variables (GNU Bash Reference Manual).
        "COMP_WORDS",  # COMP_WORDS: Bash Variables (GNU Bash Reference Manual).
        "COMPREPLY",  # COMPREPLY: Bash Variables (GNU Bash Reference Manual).
        "COPROC",  # COPROC: Bash Variables (GNU Bash Reference Manual).
        "DIRSTACK",  # DIRSTACK: Bash Variables (GNU Bash Reference Manual).
        "EMACS",  # EMACS: Bash Variables (GNU Bash Reference Manual).
        "ENV",  # ENV: Bash Startup Files (GNU Bash Reference Manual).
        "EXECIGNORE",  # EXECIGNORE: Bash Variables (GNU Bash Reference Manual).
        "FCEDIT",  # FCEDIT: Bash Variables (GNU Bash Reference Manual).
        "FIGNORE",  # FIGNORE: Bash Variables (GNU Bash Reference Manual).
        "FUNCNAME",  # FUNCNAME: Bash Variables (GNU Bash Reference Manual).
        "FUNCNEST",  # FUNCNEST: Bash Variables (GNU Bash Reference Manual).
        "GLOBIGNORE",  # GLOBIGNORE: Bash Variables (GNU Bash Reference Manual).
        "HISTCONTROL",  # HISTCONTROL: Bash Variables (GNU Bash Reference Manual).
        "HISTFILE",  # HISTFILE: Bash Variables (GNU Bash Reference Manual).
        "HISTFILESIZE",  # HISTFILESIZE: Bash Variables (GNU Bash Reference Manual).
        "HISTIGNORE",  # HISTIGNORE: Bash Variables (GNU Bash Reference Manual).
        "HISTSIZE",  # HISTSIZE: Bash Variables (GNU Bash Reference Manual).
        "HISTTIMEFORMAT",  # HISTTIMEFORMAT: Bash Variables (GNU Bash Reference Manual).
        "HOSTFILE",  # HOSTFILE: Bash Variables (GNU Bash Reference Manual).
        "IGNOREEOF",  # IGNOREEOF: Bash Variables (GNU Bash Reference Manual).
        "INPUTRC",  # INPUTRC: Bash Variables (GNU Bash Reference Manual).
        "MAIL",  # MAIL: Bourne Shell Variables (GNU Bash Reference Manual).
        "MAILCHECK",  # MAILCHECK: Bash Variables (GNU Bash Reference Manual).
        "MAILPATH",  # MAILPATH: Bourne Shell Variables (GNU Bash Reference Manual).
        "MAPFILE",  # MAPFILE: Bash Variables (GNU Bash Reference Manual).
        "POSIXLY_CORRECT",  # POSIXLY_CORRECT: Bash Variables (GNU Bash Reference Manual).
        "PROMPT_COMMAND",  # PROMPT_COMMAND: Bash Variables (GNU Bash Reference Manual).
        "PROMPT_DIRTRIM",  # PROMPT_DIRTRIM: Bash Variables (GNU Bash Reference Manual).
        "PS0",  # PS0: Bash Variables (GNU Bash Reference Manual).
        "PS1",  # PS1: Bourne Shell Variables (GNU Bash Reference Manual).
        "PS2",  # PS2: Bourne Shell Variables (GNU Bash Reference Manual).
        "PS3",  # PS3: Bash Variables (GNU Bash Reference Manual).
        "PS4",  # PS4: Bash Variables (GNU Bash Reference Manual).
        "REPLY",  # REPLY: Bash Variables (GNU Bash Reference Manual).
        "TIMEFORMAT",  # TIMEFORMAT: Bash Variables (GNU Bash Reference Manual).
        "TMOUT",  # TMOUT: Bash Variables (GNU Bash Reference Manual).
        "TMPDIR",  # TMPDIR: Bash Variables (GNU Bash Reference Manual).
        "BASH_COMMAND",  # BASH_COMMAND: Bash Variables (GNU Bash Reference Manual).
        "BASH_REMATCH",  # BASH_REMATCH: Conditional Constructs (GNU Bash Reference Manual).
    }
    return set(result.stdout.splitlines()) | specials


def documented_environment(root):
    doc = root / 'tests/README.md'
    if not doc.exists():
        return set()
    text = doc.read_text()
    if ENV_START not in text or ENV_END not in text:
        return set()
    table = text.split(ENV_START, 1)[1].split(ENV_END, 1)[0]
    return {m.group(1) for m in re.finditer(r'^\| `([A-Z_][A-Z_0-9]*)` \|', table, re.M)}



@functools.lru_cache(maxsize=1)
def bash_associatives():
    script = r'''
while IFS= read -r name; do
    declaration=$(declare -p "$name" 2>/dev/null) || continue
    flags=${declaration#declare -}; flags=${flags%% *}
    case $flags in *A*) printf 'A %s\n' "$name";; esac
done < <(compgen -v)
'''
    result = subprocess.run(['env', '-i', 'bash', '--norc', '--noprofile', '-c', script],
                            text=True, capture_output=True, timeout=10, check=True)
    rows = [line.split() for line in result.stdout.splitlines()]
    return {n for flag, n in rows if flag == 'A'}


class Reader:
    def __init__(self, root):
        self.root = root.resolve()
        self.cache, self.nodes, self.edges = {}, {}, {}
        self.associatives = {}
        self.file_cache, self.data_cache, self.resolved = {}, {}, {}

    def resolve(self, path):
        if path not in self.resolved:
            canonical = path.resolve()
            self.resolved[path] = self.resolved[canonical] = canonical
        return self.resolved[path]

    def source_path(self, word):
        expansions = []
        literal = unquote(word, expansions)
        if not expansions:
            path = pathlib.Path(literal)
            if path.is_absolute():
                return path
            return next((p for p in (self.root / 'src' / path, self.root / path,
                                    self.root / 'tests' / path) if p.is_file()), None)
        if len(expansions) == 1 and str(expansions[0]) in ('$TESTS_DIR', '${TESTS_DIR}'):
            return pathlib.Path(unquote(word).replace(str(expansions[0]), str(self.root / 'tests'), 1))
        return None

    def read(self, path):
        path = self.resolve(path)
        if path in self.cache:
            return
        self.nodes[path], self.edges[path] = [], []
        self.associatives[path] = set()

        def walk(body, base=0, guards=frozenset(), inherited_a=frozenset()):
            tokens = tokenize_file(body, str(path), effects=True)
            associations = inherited_a | associative_declarations(tokens)
            self.nodes[path].append((tokens, body, base, guards, associations))
            if not guards:
                self.associatives[path].update(associations)
            for tok in tokens:
                for sub in tok.subst:
                    start = body.find(sub, tok.start)
                    line = getattr(sub, 'source_line', None)
                    delta = line - 1 if line is not None else body[:start].count('\n') if start >= 0 else tok.line - 1
                    guard = getattr(sub, 'array_guard', None)
                    walk(sub, base + delta, guards | ({guard} if guard else set()), associations)
            for command in simple_commands(tokens):
                raw = [t for t in command if t.role in ('command', 'argument')]
                for words in builtin_readings(command):
                    if words[0] not in ('.', 'source'):
                        continue
                    i = next((i for i, t in enumerate(raw) if words[0] in (unquote(t.text), emptied(t.text))), None)
                    if i is not None:
                        i += 1
                        if i < len(raw) and unquote(raw[i].text) == '--':
                            i += 1
                        source = self.source_path(raw[i].text) if i < len(raw) else None
                        if source is not None and source.is_file():
                            self.edges[path].append((guards, self.resolve(source)))
        walk(path.read_text())
        self.cache[path] = True

    def files(self, path, seen=None, associations=frozenset()):
        path = self.resolve(path)
        key = path, frozenset(associations)
        if seen is None:
            if key not in self.file_cache:
                self.file_cache[key] = frozenset(self.files(path, set(), set(associations)))
            return set(self.file_cache[key])
        if path in seen or not path.is_file():
            return seen
        seen.add(path); self.read(path)
        associations.update(self.associatives[path])
        # Unconditional source helpers supply array types before guarded code.
        for guarded in (False, True):
            sources = {p for guard, p in self.edges[path] if bool(guard) == guarded and guard.isdisjoint(associations)}
            for source in sources:
                self.files(source, seen, associations)
        return seen

    def data(self, path, associations):
        path = self.resolve(path)
        key = path, frozenset(associations)
        if key in self.data_cache:
            return self.data_cache[key]
        definitions, reads = set(), []
        for tokens, body, base, guards, local_a in self.nodes[path]:
            if not guards.isdisjoint(associations):
                continue
            with array_context(associations | local_a):
                assignments = {t.start for t, _ in assignment_words(tokens) if assignment_split(t.text)}
                previous = None
                for tok in tokens:
                    if tok.role == 'name' and previous and previous.role == 'reserved' and previous.text in ('for', 'select'):
                        definitions.add(unquote(tok.text))
                    if previous and previous.role == 'reserved' and previous.text == 'coproc':
                        # bash binds NAME and NAME_PID, or COPROC and COPROC_PID unnamed.
                        name = unquote(tok.text) if tok.role == 'name' else 'COPROC'
                        definitions.update((name, name + '_PID'))
                    if tok.kind == 'word' and tok.role != 'delimiter' or tok.kind in ('pattern', 'arith'):
                        expr = str(tok.text[2:-2]) if tok.kind == 'arith' else tok.text
                        refs, sets = variable_effects(expr, arithmetic=tok.kind == 'arith', assignment=tok.start in assignments)
                        definitions.update(sets)
                        reads.extend((base + tok.line + expr[:pos].count('\n'), name) for name, pos in refs if UPPER.fullmatch(name))
                    if tok.heredoc is not None:
                        target = next((t for t in tokens if t.start == tok.end or t.role == 'delimiter' and t.start > tok.start), None)
                        expanded = target is not None and unquote(target.text) == target.text
                        if expanded:
                            refs, sets = variable_effects(tok.heredoc, expanded=True)
                            definitions.update(sets)
                            line = base + body[:body.find(tok.heredoc, tok.end)].count('\n') + 1
                            reads.extend((line + tok.heredoc[:pos].count('\n'), name) for name, pos in refs if UPPER.fullmatch(name))
                    previous = tok
                definitions.update(redirection_fd_names(body, tokens))
                for command in simple_commands(tokens):
                    if not any(t.role == 'command' for t in command):
                        definitions.update(pair[0] for t in command if t.role == 'assignment' and (pair := assignment_split(t.text)))
                    definitions.update(setter_names(command))
                for token, refs, sets in implicit_arithmetic_effects(tokens):
                    definitions.update(sets)
                    reads.extend((base + token.line + token.text[:pos].count('\n'), name) for name, pos in refs if UPPER.fullmatch(name))
        self.data_cache[key] = definitions, reads
        return definitions, reads


def scan(root: pathlib.Path, fragments: list[pathlib.Path]) -> list[tuple[str, int, str]]:
    reader = Reader(root)
    shared = bash_variables() | documented_environment(root)
    builtin_a = bash_associatives()
    runner = root / 'tests/run_all_tests.sh'
    common = reader.files(runner, associations=builtin_a)
    common_a = builtin_a | set().union(*(reader.associatives[f] for f in common))
    findings = []
    examined = read_count = 0
    for fragment in fragments:
        path = reader.resolve(fragment if fragment.is_absolute() else root / fragment)
        files = common | reader.files(path, associations=common_a)
        associations = builtin_a | set().union(*(reader.associatives[f] for f in files))
        files = reader.files(runner, associations=associations) | reader.files(path, associations=associations)
        defined, reads = set(shared), []
        for file in files:
            extra_sets, extra_reads = reader.data(file, associations)
            defined.update(extra_sets)
            if file == path:
                reads.extend(extra_reads)
        read_count += len(reads)
        findings.extend((str(fragment), line, name) for line, name in reads if name not in defined)
        examined += 1
    if not examined == len(fragments) > 0:
        raise ValueError(f'examined {examined} of {len(fragments)} fragments (empty population)')
    scan.examined, scan.read_count = examined, read_count
    return sorted(set(findings))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selftest', action='store_true')
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    if args.selftest:
        from section_undefined_vars_test import selftest
        return selftest()
    root = args.root.resolve()
    population = sorted((root / 'tests/sections').glob('*.sh'))
    try:
        findings = scan(root, population)
        assert scan.examined == len(population) > 0
    except (TokenizerGap, ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'section-undefined-vars: ERROR: {exc}', file=sys.stderr)
        return 2
    for path, line, name in findings:
        print(f'{path}:{line}: undefined variable {name}')
    print(f'section-undefined-vars: examined {scan.examined} fragments, {scan.read_count} reads, {len(findings)} undefined')
    return int(bool(findings))


if __name__ == '__main__':
    sys.exit(main())
