#!/usr/bin/env python3
"""O7, the execution oracle of tools/shell_oracle.py: bash RUNS a generated
program, and the commands it ran are the expected answer.

    python3 tools/_shell_exec.py [--seeds 1,2,3] [--n 400] [--show SEED:INDEX]
    python3 tools/_shell_exec.py --mutants SEEDS BASE PER      (see below)

A seeded generator writes shell programs over a closed vocabulary.  Every
command a program runs is a name no machine has (`eigenscript-ok12`), so bash
calls `command_not_found_handle`, and the handler writes the name down.  That
log -- not the generator's intent, and not the tokenizer -- says what ran.

  role     the words the tokenizer gives role 'command' (substitution bodies
           included) must be EXACTLY the names bash ran: a name bash ran and
           we do not have is a command a gate would never see; a name we have
           and bash never ran is data read as a command.  A command word is
           read two ways: after quote removal, and with its expansions taken
           as empty (`${wrap}cmd`, `cmd$(maybe)`: bash runs `cmd` then).
  deriver  tools/_derive_variants.py must report every name bash ran.
  edges    tools/enrolment_edges.py must return a command for every name
           bash ran.
  flags    the GNU-flag scanner in tools/portability_parse_check.sh must read
           a command for every name bash ran.

The generator keeps every command live so that "ran" and "is a command" are
the same set: a condition is a leaf whose status is in its name (`...-okN`
returns 0, `...-noN` returns 1), every `case` arm is selected, every loop body
runs.  Two kinds of name must NOT run and are there to be mistaken for
commands: `...-datN` (data: quoted text, comments, here-document bodies,
arguments, case patterns, the word after a command word that cannot vanish)
and `...-parN` (text the tokenizer may report and this program never runs:
inside `NAME[i]=...` before a command, which bash rejects as "not a valid
identifier" before expanding anything; the unused side of `${set:-...}`; the
word after an expansion that has a value here, `$set cmd`).  `...-wrpN` is run
through a wrapper: the readers must report it, the tokenizer's role -- which
names the wrapper -- need not.  `...-ambN` carries no claim at all -- is
`$((a); b)` arithmetic? does `"${x:-'$(a)'}"` run a? -- bash's log decides
and the tokenizer must agree.

Wrappers.  `command` is the builtin.  `env`, `sudo`, `nohup` and `exec` are
shell FUNCTIONS the harness defines, which skip their options the way the
readers assume and run their operand: a model of the readers' contract, not
the real programs.  Wrappers one reader knows and another does not
(`timeout`, `xvfb-run`, `nice`) are not generated.

INSTRUMENT findings are about the generator, not the tokenizer: a program
`bash -n` rejects, a name the generator meant to run that did not, a `dat`/
`par` name that ran, a program that did not finish.  With any of those the
run proves nothing and says so.

--mutants is exploration, not a gate: each generated program is edited
mechanically (a character or a token inserted, deleted, replaced; lines
dropped, repeated, swapped, joined) and the edits bash still accepts are
run.  Nothing is known about a mutant beforehand, so only what needs no
label is judged: a name bash RAN must be a command word, and every reader
must report it; the tokenizer must not stop on a program bash accepts.

What is executed: only programs this file generates or edits -- builtins,
reserved words and names that do not exist -- in an empty temporary
directory, with PATH pointing at an empty directory, no environment, stdin
/dev/null, and a time limit.  Nothing read from a file or the network is
ever run.

BLIND SPOTS: what the vocabulary does not hold (aliases, `eval`, traps,
`select`, extglob, a command named by an expansion's VALUE -- `$cmd x` with
cmd set, `${x:-cmd} y` -- and builtins that evaluate their arguments:
`unset 'a[$(c)]'`, `let`, `printf -v`); bash's dialect only, and only the
bash on this machine; a command bash parses and the program never reaches is
kept out by construction, so dead code (`else` arms not taken, code after
`exit`) is covered by the parse oracles O1-O6, not here.  Known, measured on
bash 5.2 and NOT modelled:
  - bash 5.2 runs a `$( )` body from its own reprint of the parsed command,
    which moves a leading redirection behind the words: `$(> f else x)` runs
    `else x > f`, where `else` is the reserved word again.  The tokenizer
    reads the text as written (a command named `else`).
  - arithmetic is expanded as if in double quotes, so `$(( '$(c)' ))`,
    `a['$(c)']=1` (indexed) and `${v:'$(c)'}` run c; the tokenizer takes the
    single quotes for quotes.
  - text `bash -n` accepts and bash cannot run (`$((a) # x)`: bad
    substitution; a broken substitution in a here-document body or between
    backquotes): the tokenizer may stop on it, loudly.
The generator's shapes are the ones its author thought of: --mutants and a
second generator by someone else are worth more than more seeds of this one.
"""
from __future__ import annotations

import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import _shell_tokens as ST  # noqa: E402

BASH = shutil.which("bash")
ENV = shutil.which("env")
PREFIX = "eigenscript-"
LEAF_RE = re.compile(r"^eigenscript-(ok|no|wrp|amb|dat|par)[0-9]+$")

# bash reads this file (BASH_ENV) before it runs the program as a script.  The
# program is not `source`d: bash 5.2 rejects a multi-line `((cmd)<newline>cmd)`
# in a sourced file that it runs as a script and that `bash -n` accepts.
_HARNESS = r"""
exec 9>&%d %d>&-
command_not_found_handle() {
  printf '%%s\0' "$1" >&9
  case $1 in *-no[0-9]*) return 1 ;; esac
  return 0
}
declare -A map
arr=(0 1)
empty=()
set1=1
env() { while [[ ${1-} == -* || ${1-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done; "$@"; }
sudo() { while [[ ${1-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done; "$@"; }
nohup() { "$@"; }
exec() { "$@"; }
"""


class Program:
    """One generated program: its text and what the generator meant."""

    def __init__(self, seed, index):
        self.label = f"exec#{seed}.{index}"
        self.rng = random.Random(f"{seed}/{index}")
        self.k = 0
        self.live: set[str] = set()     # the generator means bash to run these
        self.dead: set[str] = set()     # ... and never these
        self.par: set[str] = set()
        self.fn = 0
        self.tag = 0
        self.coproc = False
        lines: list[str] = []
        for _ in range(self.rng.randint(2, 6)):
            lines.extend(self.statement(2))
        self.text = "\n".join(lines) + "\n"
        # A production builds every alternative and keeps one, so names were
        # counted that never reached the text: keep the ones that did (a
        # name may be spelled with quotes, backslashes, a continuation or one
        # of spell()'s two ANSI-C escapes).
        plain = self.text.replace("\\x73", "s").replace("\\145", "e")
        plain = re.sub(r"""\\\n|[\\"']""", "", plain)
        placed = set(re.findall(r"eigenscript-[a-z]+[0-9]+", plain))
        self.live &= placed
        self.dead &= placed
        self.par &= placed

    # ------------------------------------------------------------- vocabulary
    def pick(self, *options):
        return self.rng.choice(options)

    def chance(self, p):
        return self.rng.random() < p

    def name(self, kind):
        self.k += 1
        name = f"{PREFIX}{kind}{self.k}"
        if kind in ("ok", "no", "wrp"):
            self.live.add(name)
        elif kind in ("dat", "par"):
            self.dead.add(name)
            if kind == "par":
                self.par.add(name)
        return name

    def spell(self, name):
        """A command word that is NAME after quote removal."""
        r = self.rng.random()
        if r < 0.80:
            return name
        cut = self.rng.randint(1, len(name) - 1)
        a, b = name[:cut], name[cut:]
        return self.pick(f'"{name}"', f"'{name}'", f"{a}\\{b}", f'{a}""{b}', f"{a}''{b}",
                         f"$'{name}'", f'{a}"{b}"', f"{a}\\\n{b}",
                         "$'" + name.replace("s", "\\x73", 1) + "'",
                         "$'" + name.replace("e", "\\145", 1) + "'")

    def bare(self, kind="ok"):
        """A leaf and nothing else: for backquotes, whose own backslash rules
        would change what a quoted data word means."""
        return self.name(kind) + self.pick("", " a")

    def tagname(self):
        self.tag += 1
        return self.pick("E", "EOF", "END_%d" % self.tag, "_X%d" % self.tag)

    # ------------------------------------------------------------------ words
    def data_word(self):
        d = self.name("dat")
        return self.pick(
            "a", "-x", '"b c"', d, f"'$({d}) x'", f'"\\$({d})"', f"$'e\\'$({d})'", "\\;",
            f"\\$\\({d}\\)", "if", "then", "do", "done", "fi", "esac", "in", "{", "}", "!",
            f"x#{d}", f"v={d}", f"'{d}'", f'"`echo` \\`{d}\\`"', f"a\\ {d}", "time", "[[",
            f"x[1", "]", f"--opt={d}", f'"# {d}"', "'<<E'", f"${{set1:-$({self.name('par')})}}",
            f"${{unset1:+$({self.name('par')})}}", f"$'\\x41{d}'", "function", "case", f"{d}\\)")

    def live_word(self, depth):
        if depth <= 0:
            return f"$({self.leaf_cmd()})"
        sub = self.inline(depth - 1)
        r = self.rng.randrange(16)
        if r == 0:
            return f"$({sub})"
        if r == 1:
            return f'"x $({sub}) y"'
        if r == 2:
            return f"<({sub})"
        if r == 3:
            return f">({sub})"
        if r == 4:
            return f"${{unset1:-$({sub})}}"
        if r == 5:
            return f'"${{unset1:-$({sub})}}"'
        if r == 6:
            return f"$(( $({sub}) + 1 ))"
        if r == 7:
            return f"x$({sub})y"
        if r == 8:
            return f"`{self.bare()}`"
        if r == 9:
            return f'"`{self.bare()}`"'
        if r == 10:
            return f"${{set1:+$({sub})}}"
        if r == 11:
            return f"$({self.leaf_cmd()} # {self.name('dat')}\n {self.leaf_cmd()})"
        if r == 12:
            return f"$(case p in p) {sub};; esac)"
        if r == 13:
            return f"${{arr[$({sub}; echo 0)]}}"
        if r == 14:
            return f"$( ( {sub} ) )"
        return f'"${{set1//$({sub})/x}}"'

    def args(self, depth):
        out = []
        for _ in range(self.rng.randint(0, 2)):
            out.append(self.live_word(depth) if self.chance(0.3) else self.data_word())
        return out

    def redir(self, depth):
        r = self.rng.randrange(12)
        if r == 0:
            return "> o1"
        if r == 1:
            return "2> o2"
        if r == 2:
            return ">> o1"
        if r == 3:
            return "< /dev/null"
        if r == 4:
            return '<<< "x"'
        if r == 5:
            return f"<<< $({self.inline(depth - 1)})"
        if r == 6:
            return f"> o$({self.inline(depth - 1)})"
        if r == 7:
            return "2>&1"
        if r == 8:
            return "&> o1"
        if r == 9:
            return f"< <({self.inline(depth - 1)})"
        if r == 10:
            return "3< /dev/null"
        return f"> {self.name('dat')}"

    def prefix(self, depth):
        r = self.rng.randrange(11)
        if r == 0:
            return "v=1"
        if r == 1:
            return f"v=$({self.inline(depth - 1)})"
        if r == 2:
            return "v+=x"
        if r == 3:
            return "< /dev/null"
        if r == 4:
            return "2>&1"
        if r == 5:
            return f"v={self.name('dat')}"
        if r == 6:
            return "{fd}< /dev/null"
        if r == 7:
            return f"v=<({self.inline(depth - 1)})"
        if r == 8:
            return "> o1"
        if r == 9:
            return f'v="{self.name("dat")} $({self.inline(depth - 1)})"'
        return "w=2 v=1"

    def leaf_cmd(self, kind="ok"):
        """The plainest simple command: a leaf and perhaps one data word."""
        cmd = self.spell(self.name(kind)) if kind == "ok" else self.name(kind)
        return cmd + (" " + self.data_word() if self.chance(0.3) else "")

    def simple(self, depth, kind="ok"):
        parts = []
        if depth > 0 and self.chance(0.3):
            parts.append(self.prefix(depth))
        parts.append(self.spell(self.name(kind)))
        if depth > 0:
            parts.extend(self.args(depth))
            if self.chance(0.25):
                parts.insert(self.rng.randint(0, len(parts)), self.redir(depth))
        return " ".join(parts)

    # ------------------------------------------- one-line command lists (status 0)
    def inline(self, depth):
        """A command list on one line in which every leaf runs."""
        if depth <= 0:
            return self.leaf_cmd()
        r = self.rng.randrange(20)
        a = self.simple(depth - 1)
        if r < 5:
            return a
        if r == 5:
            return f"{a}; {self.simple(depth - 1)}"
        if r == 6:
            return f"{a} && {self.simple(depth - 1)}"
        if r == 7:
            return f"{self.simple(depth - 1, 'no')} || {a}"
        if r == 8:
            return f"{a} | {self.simple(depth - 1)}"
        if r == 9:
            return f"{a} |& {self.simple(depth - 1)}"
        if r == 10:
            return f"if {a}; then {self.inline(depth - 1)}; fi"
        if r == 11:
            return f"if {self.simple(depth - 1, 'no')}; then :; else {self.inline(depth - 1)}; fi"
        if r == 12:
            return f"for v in a b; do {self.inline(depth - 1)}; done"
        if r == 13:
            return f"{{ {self.inline(depth - 1)}; }}"
        if r == 14:
            # the leading blank keeps `$(` + this from reading `$((`: that
            # question is asked on purpose, by s_ambiguous
            return f" ( {self.inline(depth - 1)} )"
        if r == 15:
            return f"while {a}; do {self.inline(depth - 1)}; break; done"
        if r == 16:
            return f"case p in p) {self.inline(depth - 1)};; esac"
        if r == 17:
            return f"! {self.simple(depth - 1, 'no')}"
        if r == 18:
            return f"[[ -n x ]] && {a}"
        return f"until {self.simple(depth - 1, 'no')}; do {self.inline(depth - 1)}; break; done"

    # ------------------------------------------------------------- statements
    def body(self, depth):
        """Lines of a compound command's body."""
        lines = []
        for _ in range(self.rng.randint(1, 2)):
            lines.extend(self.statement(depth - 1))
        return lines

    def statement(self, depth):
        if depth <= 0:
            return [self.simple(1)]
        makers = [
            self.s_simple, self.s_simple, self.s_inline, self.s_inline, self.s_if,
            self.s_loop, self.s_case, self.s_group, self.s_function, self.s_assign,
            self.s_prefix_array, self.s_heredoc, self.s_heredoc, self.s_comment,
            self.s_test, self.s_special, self.s_subscript, self.s_continued,
            self.s_deferred_heredoc, self.s_background, self.s_ambiguous,
            self.s_no_separator, self.s_quoting, self.s_heredoc_edges,
            self.s_after_closer, self.s_more_words, self.s_conditions,
            self.s_expansion_led, self.s_expansion_led, self.s_glued, self.s_wrapped,
            self.s_heredoc_closer,
        ]
        return self.rng.choice(makers)(depth)

    def s_simple(self, depth):
        return [self.simple(depth)]

    def s_inline(self, depth):
        return [self.inline(depth)]

    def s_if(self, depth):
        ok, no = self.simple(depth - 1), self.simple(depth - 1, "no")
        body = self.body(depth)
        r = self.rng.randrange(6)
        if r == 0:
            return [f"if {ok}; then"] + body + ["fi"]
        if r == 1:
            return [f"if {ok}", "then"] + body + ["fi"]
        if r == 2:
            return [f"if {no}; then", "  :", "else"] + body + ["fi"]
        if r == 3:
            return [f"if {no}; then :", f"elif {ok}; then"] + body + ["else :", "fi"]
        if r == 4:
            return [f"if {no}; then :; elif {self.simple(depth - 1, 'no')}", "then :", "else"] + body + ["fi"]
        return [f"if {ok}; then {self.inline(depth - 1)}; fi"]

    def s_loop(self, depth):
        ok, no = self.simple(depth - 1), self.simple(depth - 1, "no")
        body = self.body(depth)
        r = self.rng.randrange(7)
        if r == 0:
            return [f"while {ok}; do"] + body + ["break", "done"]
        if r == 1:
            return [f"until {no}", "do"] + body + ["break; done"]
        if r == 2:
            return [f"for v in a {self.name('dat')} \"b c\"; do"] + body + ["done"]
        if r == 3:
            return ["for ((i=0; i<1; i++)); do"] + body + ["done"]
        if r == 4:
            return ["for ((i=0; i<1; i++))", "do", self.pick("arr[1<<2]=x", "arr[ 1 ]=x", ":")] \
                + body + ["done"]
        if r == 5:
            return ["set -- a", "for v do"] + body + ["done"]
        return [f"for v in $({self.inline(depth - 1)}; echo a); do"] + body + ["done"]

    def s_case(self, depth):
        d = self.name("dat")
        r = self.rng.randrange(7)
        if r == 0:
            return ["for w in p q; do", "case $w in",
                    f"  p) {self.inline(depth - 1)} ;;",
                    f"  q|{d}) {self.inline(depth - 1)}", "     ;;",
                    f"  {d}) : ;;", "esac", "done"]
        if r == 1:
            return [f"case p in p) {self.inline(depth - 1)};& zz) {self.inline(depth - 1)};; esac"]
        if r == 2:
            return [f"case p in p) {self.inline(depth - 1)};;& p*) {self.inline(depth - 1)};; esac"]
        if r == 3:
            return ["case p in", f"  (x[*|{d}) : ;;", "  (p)"] + self.body(depth) + ["  ;;", "esac"]
        if r == 4:
            return [f"case $({self.inline(depth - 1)}) in",
                    f"  $({self.inline(depth - 1)})) {self.inline(depth - 1)} ;;", "esac"]
        if r == 5:
            return ["case p in", f"  \"{d})\"|'q)') : ;;", f"  p) {self.inline(depth - 1)}", "esac"]
        return ["case p in", "  p)"] + self.body(depth) + ["esac"]

    def s_group(self, depth):
        body = self.body(depth)
        r = self.rng.randrange(5)
        if r == 0:
            return ["{"] + body + ["}"]
        if r == 1:
            return ["("] + body + [")"]
        if r == 2:
            return ["{"] + body + [f"}} {self.redir(1)}"]
        if r == 3:
            return [f"( {self.inline(depth - 1)} ) {self.redir(1)}"]
        return [f"{{ {self.inline(depth - 1)}; }} 2>&1 | {self.simple(depth - 1)}"]

    def s_function(self, depth):
        self.fn += 1
        fn = f"fn{self.fn}"
        body = self.body(depth)
        r = self.rng.randrange(7)
        if r == 0:
            return [f"{fn}() {{"] + body + ["}", fn]
        if r == 1:
            return [f"function {fn} {{"] + body + ["}", f"{fn} a"]
        if r == 2:
            return [f"{fn} () ("] + body + [")", fn]
        if r == 3:
            return [f"function {fn}() {{ {self.inline(depth - 1)}; }}", fn]
        if r == 4:
            return [f"{fn}()", "{"] + body + [f"}} {self.redir(1)}", fn]
        if r == 5:
            return [f"{fn}() {{ {self.inline(depth - 1)}; }}; {fn}"]
        if self.chance(0.3):
            # a NAME being defined is not run: one that looks like a runtime
            d = self.name("dat")
            return self.pick([f"{d}() {{ :; }}", self.simple(depth - 1)],
                             [f"function {d} {{ :; }}; {self.simple(depth - 1)}"],
                             [f"{d} ( ) {{ :; }}"])
        return [f"function {fn}", "{"] + body + ["}", f"{fn} {self.live_word(depth - 1)}"]

    def s_assign(self, depth):
        sub = self.inline(depth - 1)
        d = self.name("dat")
        r = self.rng.randrange(12)
        if r == 0:
            return [f"v=$({sub})"]
        if r == 1:
            return [f"arr=( $({sub}) {d} [1]=$({self.inline(depth - 1)}) x<({self.inline(depth - 1)}) )"]
        if r == 2:
            return [f"arr[1]=$({sub})"]
        if r == 3:
            return [f"map[k$({sub})]=v"]
        if r == 4:
            return [f"arr[$({sub}; echo 1)]=x"]
        if r == 5:
            return [f"v={d} w=\"$({sub})\""]
        if r == 6:
            return ["arr=(", f"  a # {d}", f"  $({sub})", f"  '{d}'", ")"]
        if r == 7:
            return [f"v+=$({sub})", f"export v={d}"]
        if r == 8:
            return [f"local_v=`{self.bare()}`"]
        if r == 9:
            return [f"map[${{arr[0]}}]=$({sub})"]
        if r == 10:
            return [f"arr[1<<2]=x; arr[ 1 ]={d}; {self.simple(depth - 1)}"]
        return [f"declare v=$({sub}) w={d}"]

    def s_prefix_array(self, depth):
        """NAME[i]=... before a command: bash rejects the assignment (not a
        valid identifier) before expanding it, and runs the command."""
        p = self.name("par")
        cmd = self.simple(depth - 1)
        return [self.pick(
            f"arr[1]=$({p}) {cmd}", f"arr[1]=<({p}) {cmd}", f"map[$({p})]=v {cmd}",
            f"arr[${{arr[0]}}]=<({p}) {cmd}", f"arr[$[ 1 ]]=<({p}) {cmd}",
            f"map[$(: ${{arr[1]}}; {p})]=<(:) {cmd}", f"arr[1]+=`{p}` {cmd}",
            f"v=1 arr[1]=$({p}) {cmd}", f"< /dev/null arr[1]=$({p}) {cmd}",
            f'map["]"]=$({p}) {cmd}', f"arr[1]=x 2> o2 {cmd}",
            f"arr[<({p})]=1 {cmd}")]

    def s_heredoc(self, depth):
        tag = self.tagname()
        d1, d2 = self.name("dat"), self.name("dat")
        quoted_body = [f"$({d1}) `{d2}` it's \"", f"{tag} x", f" {tag}", f"{d1} <<X", "#!/bin/sh"]
        live_body = [f"a $({self.inline(depth - 1)}) b \\$({d1}) it's",
                     f"`{self.bare()}` \\`{d2}\\` \"", f"{tag}x"]
        cmd = self.simple(depth - 1)
        r = self.rng.randrange(14)
        if r == 0:
            return [f"{cmd} <<'{tag}'"] + quoted_body + [tag]
        if r == 1:
            return [f"{cmd} <<\\{tag}"] + quoted_body + [tag]
        if r == 2:
            return [f'{cmd} <<"{tag}"'] + quoted_body + [tag]
        if r == 3:
            return [f"{cmd} <<{tag}"] + live_body + [tag]
        if r == 4:
            return [f"{cmd} <<-{tag}"] + ["\t" + x for x in live_body] + ["\t" + tag]
        if r == 5:
            return [f"{cmd} <<-'{tag}'"] + ["\t" + x for x in quoted_body] + ["\t\t" + tag]
        if r == 6:
            return [f"{cmd} <<{tag} <<'{tag}2'"] + live_body + [tag] + quoted_body + [tag + "2"]
        if r == 7:
            return [f"{cmd} <<'{tag}' | {self.simple(depth - 1)}"] + quoted_body + [tag]
        if r == 8:
            return [f"{cmd} <<{tag} && {self.simple(depth - 1)}"] + live_body + [tag]
        if r == 9:
            return [f"{cmd} <<'{tag}'; {self.simple(depth - 1)}"] + quoted_body + [tag]
        if r == 10:
            return [f"v=$({cmd} <<'{tag}'"] + quoted_body + [tag, ")"]
        if r == 11:
            return [f"<<'{tag}' {cmd}"] + quoted_body + [tag]
        if r == 12:
            return [f"{cmd} <<{tag}\"q\""] + quoted_body + [tag + "q"]
        return [f"if {cmd} <<'{tag}'"] + quoted_body + [tag, "then"] + self.body(depth) + ["fi"]

    def s_deferred_heredoc(self, depth):
        """A here-document still pending when its substitution closes: bash
        5.2 warns and reads the body from the lines below."""
        tag = self.tagname()
        d = self.name("dat")
        quoted_body = [f"$({d}) `{d}` it's", f"{d} x"]
        cmd = self.bare()          # one line: the body is read after the line the `)` is on
        r = self.rng.randrange(6)
        if r == 0:
            return [f"v=$({cmd} <<'{tag}')"] + quoted_body + [tag]
        if r == 1:
            return [f": $({cmd} <<'{tag}') $({self.bare()})"] + quoted_body + [tag]
        if r == 2:
            return [f": <({cmd} <<'{tag}')"] + quoted_body + [tag]
        if r == 3:
            return [f": \"$({cmd} <<{tag})\"", f"x $({self.bare()}) \\$({d})", tag]
        if r == 4:
            return [f": $({cmd} <<'{tag}') <<'{tag}2'"] + quoted_body + [tag] + quoted_body + [tag + "2"]
        return [f": $(: $({cmd} <<'{tag}')); {self.bare()}"] + quoted_body + [tag]

    def s_comment(self, depth):
        d = self.name("dat")
        return self.pick(
            [f"# {d} $({d}) 'it", self.simple(depth)],
            [f"{self.simple(depth - 1)} # {d}; {d} \"", ""],
            [f"{self.simple(0)} a#{d}"],
            ["", f"   # `{d}`", f"{self.simple(depth - 1)} ; # {d}"],
            [f": '#' {d} ; {self.simple(depth - 1)}"])

    def s_test(self, depth):
        sub = self.inline(depth - 1)
        cmd = self.simple(depth - 1)
        d = self.name("dat")
        return self.pick(
            [f'[[ $({sub}) == "" ]] && {cmd}'],
            [f"[[ a < b ]] && {cmd}"],
            [f"(( 1 << 2 )) && {cmd}"],
            [f"(( $({sub}; echo 1) )) && {cmd}"],
            [f"[[ -n x &&", f"   -z $({sub}) ]] && {cmd}"],
            [f"[[ x =~ ^(x|{d})$ ]] && {cmd}"],
            [f"[[ {d} == x || -z $({sub}) ]] && {cmd}"],
            [f"if [[ -n x ]]; then {cmd}; fi"],
            [f"if (( 1 )); then {cmd}; fi"],
            [f"[[ ! -e {d} && ( -n x ) ]] && {cmd}"],
            [f"(( i = 1 << 3, i > 2 )) && {cmd}"],
            [f"[[ x == x ]] then_{d}; {cmd}".replace(f"then_{d}", f"&& : {d}")])

    def s_special(self, depth):
        cmd = self.simple(depth - 1)
        if not self.coproc and self.chance(0.3):
            self.coproc = True
            return self.pick([f"coproc {self.bare()}"], [f"coproc CP {{ {self.inline(depth - 1)}; }}"],
                             [f"coproc CP ( {self.inline(depth - 1)} )"])
        if self.chance(0.1):
            # a coproc NAME that is not an identifier: bash refuses to run it
            return [f"coproc {self.name('dat')} {{ :; }}", cmd]
        return self.pick(
            [f"time {cmd}"], [f"time -p {cmd}"], [f"! {self.simple(depth - 1, 'no')}"],
            [f"time -p -- {cmd}"], [f"! {{ {self.simple(depth - 1, 'no')}; }}"],
            [f"command {self.name('wrp')} a"], [f"{cmd} | {self.simple(depth - 1)} |& {self.simple(depth - 1)}"])

    def s_subscript(self, depth):
        d = self.name("dat")
        return self.pick(
            [f"x[1 {d} ]", self.simple(depth - 1)],
            [f"x[<({self.inline(depth - 1)})]"],
            [f"x[$({self.inline(depth - 1)})] {d}"],
            [f"echo x[1 ] {d} > /dev/null; {self.simple(depth - 1)}"],
            [f"x[<({self.simple(0)} ])]=1 {d}"],
            [f"x[<(case p in p) {self.simple(depth - 1)};; esac)]"],
            [f"x[1 ; {d} ]", self.simple(depth - 1)],
            [f"< /dev/null then {d}", self.simple(depth - 1)],
            [f"> o1 do {d}; {self.simple(depth - 1)}"],
            [f"v=1 < /dev/null w=2 {self.simple(depth - 1)}"],
            [f'"A={d}" a; {self.simple(depth - 1)}'])

    def s_continued(self, depth):
        d = self.name("dat")
        return self.pick(
            [f"{self.simple(0)} a \\", f"  {d}"],
            [f"{self.simple(depth - 1)} &&", f"  {self.simple(depth - 1)}"],
            [f"{self.simple(depth - 1)} |", "", f"  {self.simple(depth - 1)}"],
            [f"{self.simple(0)} \"a", f"{d}", f"b\" '", f"$({d})", "'"],
            [f": $(", f"  {self.simple(depth - 1)}", f"  # {d})", f"  {self.simple(depth - 1)}", ")"])

    def s_ambiguous(self, depth):
        """`$((` and `((`: arithmetic, or a substitution / subshell holding a
        subshell?  bash decides by whether the parentheses close as `))`; the
        names here are `amb` -- no claim by the generator, bash's log rules."""
        a, b = self.name("amb"), self.name("amb")
        return self.pick(
            [f": $(({a}))"], [f": $(({a}); {b})"], [f": $(( ({a}) ))"],
            [f": $(({a}) | ({b}))"], [f": $(( {a} ) )"], [f"(({a}))"], [f"(({a}); {b})"],
            [f"( ({a}) )"], [f"(( {a} )) ; {b}"], [f"(({a}) && {b})"],
            [f': "$(({a}); {b})"'], [f"v=$(( {a} + 0$({b}) ))"], [f": $(( $({a}) ))"],
            [f"(({a})", f" {b})"], [f": $((", f" {a} ))"],
            # not arithmetic: closed by counting parentheses, quotes respected
            [f": $(({a}) ; : \\) ; {b} )"], [f": $(({a}) ; : ')' ; {b} )"],
            [f': $(({a}) ; : "$({b})" )'], [f": $(({a}) ; case x in (x) {b} ;; esac )"],
            [f": $(({a}) | {{ {b}; }} )"], [f": $(({a}) ; {b} ; ) {self.name('dat')}"],
            # ... and bash -n never parses what is inside: this one cannot run
            [f": $(({self.name('par')}); if) ; {self.simple(0)}"])

    def s_no_separator(self, depth):
        """A reserved word right after a compound command, a `!(`, old `$[ ]`
        arithmetic, pattern operators that look like comments."""
        cmd = self.simple(depth - 1)
        sub = self.inline(depth - 1)
        d = self.name("dat")
        return self.pick(
            [f"if [[ -n x ]] then {cmd}; fi"],
            [f"for ((i=0; i<1; i++)) do {cmd}; done"],
            [f"if (v=1) then {cmd}; fi"],
            [f"if (( 1 )) then {cmd}; fi"],
            [f"while [[ -n x ]] do {cmd}; break; done"],
            [f"!({self.simple(depth - 1, 'no')})"],
            [f"! ( {self.simple(depth - 1, 'no')} ) && {cmd}"],
            [f": $[ 1 + $({self.bare()}; echo 1) ] $[ 2 << 1 ]; {cmd}"],
            [f"[[ x =~ (#{d})|x ]] && {cmd}"],
            [f"[[ x == @(#{d}|x) ]] && {cmd}"],
            [f"for (( i=$({self.bare()}; echo 0); i<1; i++ )); do {cmd}; done"],
            [f"(( i = $({sub}; echo 1) << 1 )) && {cmd}"],
            [f"( fn_sub() {{ {sub}; }}; fn_sub ) ; {cmd}"],
            [f"case p in p) {cmd} ;; esac; {self.simple(depth - 1)}"],
            [f"{{ {cmd}; }}; {self.simple(depth - 1)}"],
            [f"if {cmd}; then {self.simple(depth - 1)}; fi; {self.simple(depth - 1)}"],
            [f"# {d} \\", cmd],
            [f"[[ $({sub}) ]] || {cmd}"],
            [f"fn_if() if {cmd}; then {self.simple(depth - 1)}; fi", "fn_if"],
            [f"a<({sub})b 2> /dev/null; {cmd}"])

    def s_quoting(self, depth):
        """Quoting whose meaning turns on where it stands; `amb` names carry no
        claim from the generator -- bash's log decides whether they ran."""
        cmd = self.simple(depth - 1)
        sub = self.inline(depth - 1)
        a, d = self.name("amb"), self.name("dat")
        return self.pick(
            [f": \"${{unset1:-'$({a})'}}\"; {cmd}"],
            [f": ${{unset1:-'$({a})'}}; {cmd}"],
            [f": \"${{unset1:-\\$({a})}}\"; {cmd}"],
            [f': $"x $({sub}) y"; {cmd}'],
            [f': "`{self.bare()} \\"{d} x\\"`"; {cmd}'],
            [f": `{self.bare()} \\`{self.bare()}\\``; {cmd}"],
            [f": '{d}'\\''$({d})'; {cmd}"],
            [f": \"a\\\"$({sub})\\\"b\"; {cmd}"],
            [f": $'\\'' $({sub}) $'\\''; {cmd}"],
            [f": \\\"$({sub})\\\" \\'$({self.inline(depth - 1)})\\'; {cmd}"],
            [f": \"$(: \"$({sub})\")\" '$(: \"$({d})\")'; {cmd}"],
            [f': ${{unset1:-"}}"$({sub})}}; {cmd}'],
            [f": \"${{set1%'$({d})'}}\" \"${{set1/'$({d})'/x}}\" \"${{set1#'`{d}`'}}\"; {cmd}"],
            # (a fresh variable: `:=` sets it, and a set variable's default never runs)
            [f": \"${{fresh{self.k}:='$({self.bare()})'}}\" \"${{set1:+'`{self.bare()}`'}}\"; {cmd}"],
            [f": $() \"$( )\" ``; {cmd}"],
            [f": $$'{d}' $? $$ \"$$\"'$({d})'; {cmd}"],
            [f': "${{set1:-$({self.name("par")})}}" ${{set1:+"$({sub})"}}; {cmd}'],
            [f": ${{set1%$({sub})}} ${{#set1}} ${{set1:$({self.inline(depth - 1)}; echo 0)}}; {cmd}"],
            [f"{cmd} \\", "", self.simple(depth - 1)])

    def s_heredoc_edges(self, depth):
        tag = self.tagname()
        d = self.name("dat")
        cmd = self.simple(depth - 1)
        return self.pick(
            # an unquoted body joins a line ending in a backslash to the next
            # one BEFORE the delimiter is looked for
            [f"{cmd} <<{tag}", f"a $({self.inline(depth - 1)}) \\", tag,
             f"{d} x", f"b $({self.inline(depth - 1)})", tag],
            # ... a quoted body does not
            [f"{cmd} <<'{tag}'", f"$({d}) \\", tag, self.simple(depth - 1)],
            [f"{cmd} <<{tag}", f"{tag} ", f"\\$({d})", tag],
            [f"{cmd} <<{tag}; {self.simple(depth - 1)} <<'{tag}2'", f"$({self.inline(depth - 1)})",
             tag, f"$({d})", tag + "2"],
            [f"{{ {cmd} <<'{tag}'", f"$({d}) }}", tag, f"{self.simple(depth - 1)}; }}"],
            [f"( {cmd} <<{tag}", f"$({self.inline(depth - 1)}) )", tag, ")"],
            [f"{cmd} <<'{tag}' > o1 2>&1", f"{d}", tag],
            [f"{cmd} 3<<'{tag}'", f"$({d})", tag],
            [f"{cmd} << '{tag}'", f"`{d}`", tag],
            [f"{cmd} <<''", f"$({d}) it's", "", self.simple(depth - 1)],
            [f"fn_doc() {{ {cmd} <<'{tag}'", f"$({d}) }}", tag, "}", "fn_doc"],
            [f"while {cmd} <<'{tag}'", f"done {d}", tag, f"do {self.simple(depth - 1)}; break; done"],
            [f": $({cmd} <<{tag}", f"$({self.inline(depth - 1)}) \\$({d})", tag, f") {self.live_word(depth - 1)}"],
            [f"{cmd} <<{tag}", f"${{unset1:-$({self.inline(depth - 1)})}} $(( $({self.inline(depth - 1)}) + 1 ))", tag])

    def s_heredoc_closer(self, depth):
        """Inside a substitution a here-document also ends at a line that
        BEGINS with its delimiter and has a `)` further on: `EOF)`.  The rest
        of that line is shell text again.  Not so at top level, nor after a
        leading blank."""
        tag = self.tagname()
        d = self.name("dat")
        cmd = self.simple(depth - 1)
        sub = self.inline(depth - 1)
        after = self.simple(depth - 1)
        return self.pick(
            [f"v=$({cmd} <<{tag}", f"a $({sub}) \\$({d})", f"{tag})", after],
            [f"v=$({cmd} <<'{tag}'", f"$({d}) it's", f"{tag} ) ; {after}"],
            [f"v=$({cmd} <<{tag}", "body", f"{tag}{self.name('ok')}) ; {after}"],
            [f"v=$({cmd} <<{tag}", "body", f"{tag} {self.name('ok')} a) ; {after}"],
            [f"{cmd} <<{tag}", f"{tag})", f"b $({sub})", tag, after],
            [f": <({cmd} <<-{tag}", "\tbody", f"\t{tag}) ; {after}"],
            [f"v=$({cmd} <<{tag}", "body", f" {tag})", tag, f"); {after}"],
            [f": $( ( {cmd} <<{tag}", "x", f"{tag}) ) ; {after}"],
            [f": $({cmd} <<{tag}; {self.simple(depth - 1)}", f"x $({sub})", f"{tag}) {d}; {after}"],
            [f': "$({cmd} <<{tag}', f"x $({sub})", f'{tag})" ; {after}'],
            [f": $({cmd} <<{tag}", "x", f"{tag})$({sub}) ; {after}"],
            [f": $(: $({cmd} <<{tag}", "x", f"{tag})) ; {after}"],
            [f": $({cmd} <<{tag} <<'{tag}2'", f"x $({sub})", tag, f"$({d})", f"{tag}2) ; {after}"],
            [f": $({cmd} <<{tag}", "x", f"{tag}#) {d}", f"{self.simple(depth - 1)} ) ; {after}"],
            [f": $({cmd} <<{tag}", "x", f"{tag} # {d})", f"{self.simple(depth - 1)} ) ; {after}"])

    def s_after_closer(self, depth):
        """A here-document or a redirection hung on a compound command's
        closer, on a function definition, on a loop that reads it."""
        tag = self.tagname()
        d = self.name("dat")
        cmd = self.simple(depth - 1)
        sub = self.inline(depth - 1)
        self.fn += 1
        fn = f"fn{self.fn}"
        return self.pick(
            [f"while read -r v; do {cmd}; done <<{tag}", f"one $({sub}) \\$({d})", tag],
            [f"while read -r v; do {cmd}; done < <({sub}; echo one)"],
            [f"{{ {cmd}; }} <<'{tag}'", f"$({d}) it's", tag],
            [f"( {cmd} ) <<{tag} > o1", f"$({sub})", tag],
            [f"if {cmd}; then {self.simple(depth - 1)}; fi <<{tag}", f"`{self.bare()}` {d}", tag],
            [f"{fn}() {{ {cmd}; }} <<{tag}", f"$({sub}) {d}", tag, fn],
            [f"{fn}() {{ {cmd}; }} > o1 2>&1 < <({sub})", fn],
            [f"case p in p) {cmd} <<'{tag}'", f"$({d}) ;;", f"esac {d}", tag, ";; esac"],
            [f"for v in a; do {cmd}; done <<< \"$({sub})\""],
            [f": < <(: <<{tag}", f"$({sub}) {d}", tag, f") ; {cmd}"],
            [f"{{ {cmd}; }} | {{ {self.simple(depth - 1)}; }}"],
            [f"( {cmd} ) | ( {self.simple(depth - 1)} ) && {self.simple(depth - 1)}"],
            [f"until {self.simple(depth - 1, 'no')}; do {cmd}; break; done 2> o2 <<'{tag}'", d, tag])

    def s_more_words(self, depth):
        """Arrays, declarations, redirection operators and `#` where it is
        not a comment."""
        d = self.name("dat")
        cmd = self.simple(depth - 1)
        sub = self.inline(depth - 1)
        return self.pick(
            [f"arr+=( $({sub}) {d} ); {cmd}"],
            [f"declare -a arr2=( $({sub}) '{d}' ) ; {cmd}"],
            [f"arr=(); {cmd} \"${{arr[@]}}\" ${{#arr[@]}} ${{!arr[@]}}"],
            [f": $(( 16#ff + $({self.bare()}; echo 1) )); (( 2#101 )) && {cmd}"],
            [f"v=#{d} {cmd}"],
            [f"{cmd} \\# {d} \"#\" '#' a#b ${{#set1}} $# ${{set1#x}} ${{set1//#/x}}"],
            [f"{cmd} >| o1 2>&- <&-"],
            [f"{cmd} <> o1 &>> o2"],
            [f"{cmd} 3>&1 1>&2 2>&3 3>&-"],
            [f"let \"v=$({self.bare()}; echo 1)\"; {cmd}"],
            [f": $(< /dev/null) \"$(< /dev/null)\"; {cmd}"],
            [f": \"$({self.bare()} \"$({self.bare()} \"$({self.bare()})\")\")\"; {cmd}"],
            [f": `{self.bare()} \\`{self.bare()} \\\\\\`{self.bare()}\\\\\\`\\``; {cmd}"],
            [f": $(fn_in() {{ {sub}; }}; fn_in); {cmd}"],
            [f"export v=$({sub}) w={d}; readonly r{self.k}=$({self.inline(depth - 1)})"],
            [f"[[ x =~ ^$({sub})x ]] && {cmd}"],
            [f"[[ $({sub}) == $({self.inline(depth - 1)}) ]] && {cmd}"],
            [f"{cmd} <<< \"a", f"{d} $({sub})\""],
            [f"\t{cmd}  \t  {d}\t;\t{self.simple(depth - 1)}"],
            [f"{cmd};"], [f"{cmd} ; "],
            [f"time ! {self.simple(depth - 1, 'no')}"],
            [f"! time {self.simple(depth - 1, 'no')}"])

    def s_conditions(self, depth):
        """Lists as conditions: every leaf still runs."""
        ok, no = self.simple(depth - 1), self.simple(depth - 1, "no")
        cmd = self.simple(depth - 1)
        return self.pick(
            [f"if {no} || {ok}; then {cmd}; fi"],
            [f"if {ok} && {self.simple(depth - 1)}; then {cmd}; fi"],
            [f"if ! {no}; then {cmd}; fi"],
            [f"while {no} || {ok}; do {cmd}; break; done"],
            [f"until {ok} && {no}; do {cmd}; break; done"],
            [f"if {ok}; {self.simple(depth - 1)}; then {cmd}; fi"],
            [f"if {no}", f"   {ok}", "then", f"  {cmd}", "fi"],
            [f"if {ok} | {self.simple(depth - 1)}; then {cmd}; fi"],
            [f"{no} || {{ {ok}; {cmd}; }}"],
            [f"{ok} && ( {cmd} ) || {self.name('par')}"],
            [f"if {{ {ok}; }}; then {cmd}; fi"],
            [f"if ( {ok} ); then {cmd}; elif {self.name('par')}; then :; fi"])

    def gone(self, depth):
        """A word that is nothing but expansions and expands to NO word in
        this harness: bash then runs the word after it."""
        r = self.rng.randrange(16)
        if r == 0:
            return f"$({self.inline(depth - 1)})"
        if r == 1:
            return f"`{self.bare()}`"
        return self.pick(
            "$unset1", "${unset1}", "${unset1:-}", "${unset1:+x}", "$(:)", '"${empty[@]}"',
            "${empty[@]}", '"${!empty[@]}"', '"${empty[@]:1}"', '"${empty[@]}$unset1"',
            '"$unset1${empty[@]}"', "$unset1$unset1", '$unset1"${empty[@]}"', "${empty[*]}",
            '"${empty[@]}""${empty[@]}"', "${unset1:-$(:)}", "${unset1@Q}")

    def stays(self):
        """A word that is nothing but expansions and is ALWAYS a word: a
        quoted scalar, or an expansion that always has a value."""
        return self.pick(
            '"$unset1"', '"${unset1}"', '"$(:)"', '$unset1""', '""', '"${empty[*]}"', "$?", "$#",
            "${#unset1}", "$(( 1 ))", "$[ 1 ]", '"${unset1:-${empty[@]}}"', '"$unset1""${empty[@]}"',
            "${#empty[@]}", '"${empty[@]}"$?', "${?}", '"`:`"')

    def s_expansion_led(self, depth):
        """`$wrap cmd`: a command word that is nothing but expansions.  When
        it expands to no word at all, bash runs the NEXT word -- and that word
        is then the command even if it is spelled like an assignment or a
        reserved word.  A quoted scalar never vanishes: `"$empty" cmd` runs a
        command named '' with cmd as its argument."""
        gone = self.gone(depth)
        leaf = self.simple(0)
        d = self.name("dat")
        r = self.rng.randrange(18)
        if r == 0:
            return [f"{gone} {leaf} {' '.join(self.args(depth))}".rstrip()]
        if r == 1:
            return [f"{gone} {self.gone(depth)} {leaf}"]
        if r == 2:
            return [f"v=1 {gone} {leaf} {d}"]
        if r == 3:
            return [f"{gone} < /dev/null {leaf}", f"2> o2 {self.gone(depth)} {self.simple(0)}"]
        if r == 4:
            return [f"if {gone} {leaf}; then {self.simple(depth - 1)}; fi"]
        if r == 5:
            return [f"time {gone} {leaf}", f"! {self.gone(depth)} {self.simple(0, 'no')}"]
        if r == 6:
            return [f"{gone} {leaf} | {self.gone(depth)} {self.simple(0)}"]
        if r == 7:
            # never vanishes: the next word is an argument
            return [f"{self.stays()} {d} a; {self.simple(depth - 1)}"]
        if r == 8:
            # vanished, so the next word is the command whatever it looks like
            return [self.pick(f"{gone} v=1 {d}", f"{gone} time {d}", f"{gone} ! {d}", f"{gone} [[ {d} ]]",
                              f"v=1 {gone} w=2 {d}", f"{gone} > o1 v=1 {d}", f"{gone} if",
                              f"{gone} x=$({self.inline(depth - 1)}) {d}")
                    + f"; {self.simple(depth - 1)}"]
        if r == 9:
            # a value: bash runs a command named by it, the next word is its argument
            return [f"{self.pick('$set1', '${set1}', '${set1:+x}', '${unset1:-x}', '$(echo x)', '${arr[@]}')} "
                    f"{self.name('par')}; {self.simple(depth - 1)}"]
        if r == 10:
            self.fn += 1
            fn = f"fn{self.fn}"
            # inside a function called without arguments "$@" is no word
            return [f"{fn}() {{ {self.pick(chr(34) + '$@' + chr(34), '$@', '$*', chr(34) + '${@:2}' + chr(34), chr(34) + '$unset1$@' + chr(34))} {leaf}; }}", fn]
        if r == 11:
            self.fn += 1
            fn = f"fn{self.fn}"
            return [f"{fn}() {{ \"$*\" {d}; {self.simple(0)}; }}", fn]
        if r == 12:
            w = self.pick("command", "nohup", "sudo", "env")
            return [f"w={w}; {self.pick('$w', chr(34) + '$w' + chr(34), '${w}')} {self.name('wrp')} a",
                    f"{gone} command {self.name('wrp')}"]
        if r == 13:
            return [f"{{ {gone} {leaf}; }}; ( {self.gone(depth)} {self.simple(0)} )"]
        if r == 14:
            return [f"case p in p) {gone} {leaf} ;; esac"]
        if r == 15:
            return [f"{gone}", f"{gone} ; {leaf}", f"x={gone} {self.simple(0)}"]
        if r == 16:
            return [f": $({gone} {leaf}) \"$({self.gone(depth)} {self.simple(0)})\""]
        return [f"while {gone} {leaf}; do {self.gone(depth)} {self.simple(0)}; break; done"]

    def s_glued(self, depth):
        """An expansion written against the command word: bash runs the word
        with the expansion's value in it -- the bare name when that is empty
        (`${TMO:+$TMO }cmd`, `$(Q)cmd` in a recipe, `cmd${EXE}`)."""
        ok = self.name("ok")
        # (in front of a name `$unset1` would read on into it: braces there)
        e = self.pick("${unset1}", '"$unset1"', "$(:)", "`:`", '"${empty[@]}"', "${unset1:+$unset1 }",
                      '"${unset1}"', "${unset1:-}")
        r = self.rng.randrange(9)
        if r == 0:
            return [f"{e}{ok} a"]
        if r == 1:
            return [f"{ok}{self.pick(e, '$unset1')} a"]
        if r == 2:
            return [f"{e}{ok}{self.pick('$unset1', '$(:)', '`:`')}"]
        if r == 3:
            return [f'"${{unset1}}{ok}" a', f'"{self.name("ok")}$unset1"']
        if r == 4:
            # the value is not empty: a different command, and never the bare name
            if self.chance(0.5):
                # an expansion that always has a value: never the bare name
                return [f"{self.pick('$?', '${#unset1}', '$(( 1 ))', '$#')}{self.name('dat')} a; "
                        f"{self.simple(depth - 1)}"]
            # a value here: a different command (the bare name may be reported)
            return [f"{self.pick('${set1}', chr(34) + '$set1' + chr(34), '$(echo x)')}"
                    f"{self.name('par')} a; {self.simple(depth - 1)}"]
        if r == 5:
            return [f"if {e}{ok}; then {self.simple(depth - 1)}; fi"]
        if r == 6:
            return [f"v=1 {e}{ok} | {self.name('ok')}{e}"]
        if r == 7:
            return [f": $({e}{ok}) \"$({self.name('ok')}{e})\""]
        return [f"{self.gone(depth)} {e}{ok}"]

    def s_wrapped(self, depth):
        """A command behind the wrappers every reader knows.  The harness
        defines env, sudo, nohup and exec as functions that run their
        operand, so bash's log shows the command; `command` is the builtin.
        These names are `wrp`: the readers must report them, the tokenizer's
        role -- which names the wrapper -- need not."""
        w = self.name("wrp")
        wraps = ["env", "env A=1", "env -i", "env -i A=1 B=2", "nohup", "sudo", "sudo A=1", "exec"]
        chain = " ".join(self.rng.choice(wraps) for _ in range(self.rng.randint(1, 3)))
        if self.chance(0.3):
            chain += " command"      # last: the builtin does not look at functions
        gone = self.gone(depth)
        r = self.rng.randrange(10)
        if r == 0:
            return [f"{chain} {w} a"]
        if r == 1:
            # (an `env`'s operands go on after a word that vanished)
            return [self.pick(f"{chain} {gone} {w}", f"env {gone} -i A=1 {w}",
                              f"env A=1 {gone} B=2 {w}", f"sudo {gone} A=1 {w}")]
        if r == 2:
            return [f"{gone} {chain} {w} {self.name('dat')}"]
        if r == 3:
            return [f"v=1 {chain} {w}", f"if {chain} {self.name('wrp')}; then {self.simple(depth - 1)}; fi"]
        if r == 4:
            return [f"{chain} > o1 {w} 2>&1"]
        if r == 5:
            return [f"{chain} {self.pick('${unset1}', '$(:)', '${unset1:+$unset1 }')}{w}"]
        if r == 6:
            return [f"time {chain} {w}", f"! {chain} {self.name('wrp')} || {self.simple(depth - 1)}"]
        if r == 7:
            return [f": $({chain} {w}) | {chain} {self.name('wrp')}"]
        if r == 8:
            return [f"{self.rng.choice(wraps)} {gone} {self.rng.choice(wraps)} {self.gone(depth)} {w}"]
        return [f"{self.rng.choice(wraps)} {gone} < /dev/null {self.rng.choice(wraps)} {w}"]

    def s_background(self, depth):
        return self.pick(
            [f"{self.simple(depth - 1)} &", "wait"],
            [f"{self.simple(depth - 1)} & {self.simple(depth - 1)}"],
            [f"( {self.inline(depth - 1)} ) &"],
            [f"{{ {self.inline(depth - 1)}; }} &", f"{self.simple(depth - 1)}"])


def programs(seed, n):
    return [Program(seed, i) for i in range(n)]


# ------------------------------------------------------------------ execution

def bash_version():
    """The bash that supplies the answers: every O7 statement is about it."""
    r = subprocess.run([BASH, "--norc", "--noprofile", "-c", 'printf %s "$BASH_VERSION"'],
                       capture_output=True, env={"PATH": ""}, timeout=30)
    return r.stdout.decode(errors="replace") or "unknown"


def bash_n(text):
    r = subprocess.run([BASH, "--norc", "--noprofile", "-n"], input=text.encode(),
                       capture_output=True, env={"PATH": "", "LC_ALL": "C"}, timeout=60)
    return r.returncode == 0


def execute(text, work, limit=20, harness=None, errors=None):
    """Run TEXT under bash in WORK; return the set of names bash tried to run
    and could not find, or None if the program did not finish in LIMIT
    seconds.  HARNESS replaces the BASH_ENV file's text; ERRORS, a list,
    receives what bash wrote to its standard error."""
    for stale in os.listdir(work):
        if stale not in ("bin",):
            path = os.path.join(work, stale)
            if os.path.isfile(path) or os.path.islink(path):
                os.unlink(path)
    with open(os.path.join(work, "prog.sh"), "w") as f:
        f.write(text)
    r, w = os.pipe()
    with open(os.path.join(work, "harness.sh"), "w") as f:
        f.write((harness or _HARNESS) % (w, w))
    err = open(os.path.join(work, "stderr"), "wb") if errors is not None else subprocess.DEVNULL
    try:
        p = subprocess.Popen(
            [ENV, "-i", f"PATH={work}/bin", "LC_ALL=C", f"HOME={work}",
             f"BASH_ENV={work}/harness.sh", BASH, "--norc", "--noprofile", "prog.sh"],
            cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=err, pass_fds=(w,), start_new_session=True)
    finally:
        os.close(w)
        if errors is not None:
            err.close()
    # The log is read to end of file: every process that could still write a
    # name holds the pipe open, so background jobs, coprocesses and process
    # substitutions are all waited for.
    chunks = []
    finished = True

    def stop(*_):
        raise TimeoutError

    old = signal.signal(signal.SIGALRM, stop)
    signal.alarm(limit)
    try:
        while True:
            data = os.read(r, 65536)
            if not data:
                break
            chunks.append(data)
        p.wait()
    except TimeoutError:
        finished = False
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass                          # the whole group exited on its own just now
        p.wait()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)
        os.close(r)
    if errors is not None:
        with open(os.path.join(work, "stderr"), "rb") as f:
            errors.append(f.read(1 << 16).decode(errors="replace"))
    if not finished:
        return None
    # NUL-terminated: a command's name may itself hold a newline (a quoted
    # string that spans lines), and a line of it must not pass for a name.
    return set(b"".join(chunks).decode(errors="replace").split("\0")) - {""}


# ------------------------------------------------------------------ the check

def command_names(text, mod=ST, depth=0):
    """Every word the tokenizer gives role 'command', quotes removed, in TEXT
    and in every substitution body inside it.  A body is read as the
    consumers read it, up to where it stops being shell: what stands between
    backquotes, or in a `$((` that is not arithmetic, is only parsed when it
    runs, and bash runs such a body up to its error too."""
    out = set()
    toks = mod.tokenize(text) if depth == 0 else mod.tokenize_prefix(text)
    for t in toks:
        if t.kind == "word" and t.role == "command":
            out.add(mod.unquote(t.text))
            # ... and what bash runs it as when its expansions are empty:
            # `${wrap}cmd`, `cmd$(maybe)`
            bare = mod.emptied(t.text)
            if bare:
                out.add(bare)
        if depth < 12:
            for body in t.subst:
                out |= command_names(body, mod, depth + 1)
    return out


def _load(name, source=None):
    """Module NAME from tools/, or from SOURCE text in its place (a planted
    mutant).  enrolment_edges computes and prints a tree's edges when it is
    loaded: it is pointed at an empty directory and its output dropped."""
    import contextlib
    import importlib.util
    import io
    empty = tempfile.mkdtemp(prefix="shell_exec_empty.")
    argv, sys.argv = sys.argv, [sys.argv[0], empty]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            if source is None:
                return __import__(name)
            spec = importlib.util.spec_from_loader(name + "_mutant", loader=None)
            mod = importlib.util.module_from_spec(spec)
            mod.__file__ = str(HERE / (name + ".py"))
            exec(compile(source, name + "_mutant", "exec"), mod.__dict__)
            return mod
    finally:
        sys.argv = argv
        shutil.rmtree(empty, ignore_errors=True)


def deriver_reader(source=None):
    """text -> the runtime names tools/_derive_variants.py reports for it."""
    dv = _load("_derive_variants", source)

    def derived(text):
        hits = []
        dv.scan_shell(text, hits, "prog.sh")
        return {h[0] for h in hits}
    return derived


def edges_reader(source=None):
    """text -> the command words tools/enrolment_edges.py reads from it."""
    ee = _load("enrolment_edges", source)

    def edges(text):
        return {words[0] for words in ee.shell_commands(text) if words}
    return edges


PORTABILITY = HERE / "portability_parse_check.sh"
_FLAGS_OPEN = "python3 - $files >\"$GNU_FLAG_OUT\" <<'PY'\n"
_FLAGS_DRIVER = "\n# ---- driver:"


def flags_source():
    """The GNU-flag scanner's Python, up to its driver: it lives in a
    here-document of tools/portability_parse_check.sh."""
    text = PORTABILITY.read_text()
    a = text.find(_FLAGS_OPEN)
    b = text.find(_FLAGS_DRIVER, a)
    if a < 0 or b < 0:
        raise SystemExit("INSTRUMENT ERROR: cannot find the GNU-flag scanner in "
                         f"{PORTABILITY.name} (its opening line or its `# ---- driver:` line moved)")
    return text[a + len(_FLAGS_OPEN):b] + "\n"


def flags_reader(source=None):
    """text -> the command words the GNU-flag scanner reads from it."""
    ns = {"__name__": "portability_flags"}
    exec(compile(flags_source() if source is None else source, "portability_flags", "exec"), ns)

    def flags(text):
        out = set()
        for _lineno, toks in ns["shell_token_lines"](text):
            for readings in ns["commands"](toks):
                out.update(argv[0] for argv in readings)
        return out
    return flags


def judge(prog, ran, mod=ST, role=True, derived=None, edges=None, flags=None):
    """Findings for one executed program.  RAN is bash's log.  ROLE checks
    the tokenizer MOD; DERIVED, EDGES and FLAGS are the readers of the three
    consumers, or None to leave one out."""
    F = []
    name = prog.label
    ran_leaves = {x for x in ran if LEAF_RE.match(x)}
    for x in sorted(prog.live - ran_leaves):
        F.append(f"{name}: O7 INSTRUMENT the generator meant {x} to run; bash did not run it")
    for x in sorted(prog.dead & ran_leaves):
        F.append(f"{name}: O7 INSTRUMENT the generator meant {x} never to run; bash ran it")
    if role:
        try:
            ours = {x for x in command_names(prog.text, mod) if LEAF_RE.match(x)}
        except ST.ShellLexError as e:
            return F + [f"{name}: O7 role: the tokenizer stopped ({e}) on a program bash runs"]
        except RecursionError:
            return F + [f"{name}: O7 role: the tokenizer recursed without end"]
        except Exception as e:                # noqa: BLE001 -- a mutant may crash; that is a finding
            return F + [f"{name}: O7 role: the tokenizer raised {type(e).__name__}: {e}"]
        for x in sorted(ran_leaves - ours):
            if "-wrp" not in x:     # run by the `command` builtin: a consumer's wrapper rule
                F.append(f"{name}: O7 role: bash ran {x}; the tokenizer has no command word {x}")
        for x in sorted(ours - ran_leaves - prog.par):
            F.append(f"{name}: O7 role: the tokenizer has command word {x}; bash never ran it")
    for label, reader, what in (("deriver", derived, "_derive_variants does not report it"),
                                ("edges", edges, "enrolment_edges has no such command"),
                                ("flags", flags, "the GNU-flag scanner reads no such command")):
        if reader is None:
            continue
        try:
            got = reader(prog.text)
        except (SystemExit, Exception) as e:  # noqa: BLE001 -- a consumer stopping is a finding
            F.append(f"{name}: O7 {label}: the reader stopped ({type(e).__name__}: {e}) on a program bash runs")
            continue
        for x in sorted(ran_leaves - got):
            F.append(f"{name}: O7 {label}: bash ran {x}; {what}")
    return F


def run(seeds, n, mod=ST, role=True, derived=None, edges=None, flags=None, cache=None):
    """Generate, execute and judge.  Returns (findings, counts).  CACHE maps a
    program's label to bash's log, so a mutant is judged against the same
    executions as the original."""
    F, C = [], {"programs": 0, "executed": 0, "names_run": 0, "rejected_by_bash": 0,
                "unfinished": 0}
    work = None
    try:
        for seed in seeds:
            for prog in programs(seed, n):
                C["programs"] += 1
                if cache is not None and prog.label in cache:
                    ran = cache[prog.label]
                else:
                    if not bash_n(prog.text):
                        ran = "rejected"
                    else:
                        if work is None:
                            work = tempfile.mkdtemp(prefix="shell_exec_oracle.")
                            os.mkdir(os.path.join(work, "bin"))
                        ran = execute(prog.text, work)
                    if cache is not None:
                        cache[prog.label] = ran
                if ran == "rejected":
                    C["rejected_by_bash"] += 1
                    F.append(f"{prog.label}: O7 INSTRUMENT the generator wrote a program bash -n rejects")
                    continue
                if ran is None:
                    C["unfinished"] += 1
                    F.append(f"{prog.label}: O7 INSTRUMENT the program did not finish in time")
                    continue
                C["executed"] += 1
                C["names_run"] += len({x for x in ran if LEAF_RE.match(x)})
                F.extend(judge(prog, ran, mod, role, derived, edges, flags))
    finally:
        if work is not None:
            shutil.rmtree(work, ignore_errors=True)
    return F, C


# ------------------------------------------------------------------ mutants

_EDIT_CHARS = [";", "\n", " ", "'", '"', "(", ")", "{", "}", "#", "\\", "$", "<", ">", "&", "|",
               "[", "]", "!", "=", "`", "-", "\t"]
_EDIT_TOKENS = [";;", "&&", "||", "<<E", "<<-E", "<<'E'", "$(", "<(", "((", "))", "[[", "]]", "then",
                "fi", "do", "done", "esac", "in", "case", "if", "for", "while", "until", "time",
                "coproc", "function", "{", "}", "!", "\\\n", "# ", "2>&1", "> o1", "< /dev/null",
                "v=1", "arr[1]=x", "arr[", "E", ";&", "|&", "&", "<<<", "$((", "${", "`", "elif",
                "else", "select", "$unset1", '"$unset1"', "${unset1}", "E)"]
_RESERVED = frozenset({"if", "then", "else", "elif", "fi", "do", "done", "case", "esac", "while",
                       "until", "for", "select", "function", "time", "coproc", "!", "{", "}",
                       "[[", "]]", "in"})
# A mutant may recurse or spin: bound it inside bash as well as by the clock.
_MUTANT_HARNESS = _HARNESS + "FUNCNEST=40\nulimit -t 5 -f 4096 2>/dev/null\n"
# bash accepted the text and then could not run it
_CANNOT_RUN = re.compile(r"bad substitution|syntax error|unexpected EOF|command substitution:")
# ... or ran it with a here-document that never met its delimiter
_UNCLOSED = "delimited by end-of-file"


def mutate(text, rng):
    """TEXT after one to three mechanical edits."""
    for _ in range(rng.choice((1, 1, 1, 2, 2, 3))):
        if len(text) < 2:
            return text
        r = rng.randrange(9)
        i = rng.randrange(len(text))
        if r == 0:
            text = text[:i] + text[i + 1:]
        elif r == 1:
            text = text[:i] + rng.choice(_EDIT_CHARS) + text[i:]
        elif r == 2:
            text = text[:i] + rng.choice(_EDIT_CHARS) + text[i + 1:]
        elif r in (3, 4):
            blanks = [m.start() for m in re.finditer(r"[ \n]", text)]
            if blanks:
                j = rng.choice(blanks)
                text = text[:j] + " " + rng.choice(_EDIT_TOKENS) + text[j:]
        else:
            lines = text.split("\n")
            j = rng.randrange(len(lines))
            if r == 5:
                del lines[j]
            elif r == 6:
                lines.insert(j, lines[j])
            elif r == 7 and j + 1 < len(lines):
                lines[j], lines[j + 1] = lines[j + 1], lines[j]
            elif r == 8 and j + 1 < len(lines):
                lines[j:j + 2] = [lines[j] + rng.choice((" ", "; ", " && ", " | ")) + lines[j + 1]]
            text = "\n".join(lines)
    return text


def _written_names(text):
    """The leaf names written in TEXT, however they are quoted or spelled."""
    plain = text.replace("\\x73", "s").replace("\\145", "e")
    plain = re.sub(r"""\\\n|[\\"']""", "", plain)
    return set(re.findall(r"eigenscript-[a-z]+[0-9]+", plain))


def _reserved_name_in_substitution(text, depth=0):
    """Whether a substitution body of TEXT runs a command NAMED like a
    reserved word (`$(> f else x)`): bash 5.2 runs such a body from its own
    reprint, in which the name is the reserved word again."""
    try:
        toks = ST.tokenize_prefix(text)
    except RecursionError:
        return False
    for t in toks:
        if depth and t.kind == "word" and t.role == "command" and ST.unquote(t.text) in _RESERVED:
            return True
        if depth < 12 and any(_reserved_name_in_substitution(b, depth + 1) for b in t.subst):
            return True
    return False


def mutants(seeds, nbase, per, mod=ST, derived=None, edges=None, flags=None):
    """Edit NBASE generated programs per seed PER times each; run the edits
    bash accepts; judge what needs no label.  Returns (findings, counts)."""
    F, C = [], {"mutants": 0, "accepted": 0, "executed": 0, "unfinished": 0, "names_run": 0,
                "judged": 0, "cannot_run_and_stopped": 0, "reserved_name_in_substitution": 0,
                "unclosed_here_document": 0, "names_made_by_a_value": 0}
    work = tempfile.mkdtemp(prefix="shell_exec_mutants.")
    os.mkdir(os.path.join(work, "bin"))
    try:
        for seed in seeds:
            for base in programs(seed, nbase):
                rng = random.Random(f"mut/{seed}/{base.label}")
                seen = {base.text}
                for m in range(per):
                    text = mutate(base.text, rng)
                    if text in seen:
                        continue
                    seen.add(text)
                    C["mutants"] += 1
                    if not bash_n(text):
                        continue
                    C["accepted"] += 1
                    label = f"{base.label}/m{m}"
                    errors = []
                    ran = execute(text, work, limit=4, harness=_MUTANT_HARNESS, errors=errors)
                    if ran is None:
                        C["unfinished"] += 1
                        continue
                    C["executed"] += 1
                    if _UNCLOSED in errors[0]:
                        # bash itself says the program is missing a delimiter:
                        # where such a body ends is not a claim made here
                        C["unclosed_here_document"] += 1
                        continue
                    C["judged"] += 1
                    ranl = {x for x in ran if LEAF_RE.match(x)}
                    # A name bash ran that is nowhere in the text was made by
                    # an expansion's value (`eigenscript-ok6${arr[0]}` runs
                    # ...-ok60): the stated blind spot, not a reading.
                    written = _written_names(text)
                    C["names_made_by_a_value"] += len(ranl - written)
                    ranl &= written
                    C["names_run"] += len(ranl)
                    try:
                        names = command_names(text, mod)
                    except (ST.ShellLexError, RecursionError) as e:
                        if _CANNOT_RUN.search(errors[0]):
                            C["cannot_run_and_stopped"] += 1
                        else:
                            F.append((f"{label}: mutant: the tokenizer stopped ({e}) on a program "
                                      "bash runs", text))
                        continue
                    if _reserved_name_in_substitution(text):
                        C["reserved_name_in_substitution"] += 1
                    else:
                        for x in sorted(ranl - names):
                            if "-wrp" not in x:
                                F.append((f"{label}: mutant role: bash ran {x}; the tokenizer has "
                                          f"no command word {x}", text))
                    for what, reader in (("deriver", derived), ("edges", edges), ("flags", flags)):
                        if reader is None:
                            continue
                        try:
                            got = reader(text)
                        except (SystemExit, Exception) as e:  # noqa: BLE001 -- stopping is the finding
                            if not _CANNOT_RUN.search(errors[0]):
                                F.append((f"{label}: mutant {what}: the reader stopped "
                                          f"({type(e).__name__}: {e}) on a program bash runs", text))
                            continue
                        for x in sorted(ranl - got):
                            F.append((f"{label}: mutant {what}: bash ran {x}; the reader does "
                                      "not report it", text))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return F, C


def main(argv):
    seeds, n, show = [1, 2, 3], 300, None
    it = iter(argv)
    for a in it:
        if a == "--seeds":
            seeds = [int(x) for x in next(it).split(",")]
        elif a == "--n":
            n = int(next(it))
        elif a == "--show":
            show = next(it)
        elif a == "--mutants":
            seeds, nbase, per = [int(x) for x in next(it).split(",")], int(next(it)), int(next(it))
            F, C = mutants(seeds, nbase, per, derived=deriver_reader(), edges=edges_reader(),
                           flags=flags_reader())
            kinds = {}
            for line, text in F:
                kind = re.sub(r"eigenscript-[a-z]+[0-9]+|line \d+: |exec#[0-9./m]+: ", "", line)
                kinds.setdefault(kind, []).append((line, text))
            for kind, rows in sorted(kinds.items(), key=lambda kv: -len(kv[1])):
                print(f"{len(rows)} x {kind}")
                print(f"    first: {rows[0][0]}")
                if "--text" in argv:
                    print("    " + rows[0][1].replace("\n", "\n    "))
            print(f"shell-exec-mutants: bash={bash_version()} "
                  + " ".join(f"{k}={v}" for k, v in sorted(C.items())) + f" findings={len(F)}")
            return 1 if F else 0
    if not BASH or not ENV:
        print("INSTRUMENT ERROR: _shell_exec needs bash and env")
        return 2
    if show:
        seed, index = show.split(":")
        prog = Program(int(seed), int(index))
        sys.stdout.write(prog.text)
        return 0
    F, C = run(seeds, n, derived=deriver_reader(), edges=edges_reader(), flags=flags_reader())
    for f in F:
        print(f)
    print(f"shell-exec-oracle: bash={bash_version()} "
          + " ".join(f"{k}={v}" for k, v in sorted(C.items())) + f" findings={len(F)}")
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
