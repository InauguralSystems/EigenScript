#!/usr/bin/env python3
"""O7, the execution oracle of tools/shell_oracle.py: bash RUNS a generated
program, and the commands it ran are the expected answer.

    python3 tools/_shell_exec.py [--seeds 1,2,3] [--n 400] [--show SEED:INDEX]

A seeded generator writes shell programs over a closed vocabulary.  Every
command a program runs is a name no machine has (`eigenscript-ok12`), so bash
calls `command_not_found_handle`, and the handler writes the name down.  That
log -- not the generator's intent, and not the tokenizer -- says what ran.

  role     the words the tokenizer gives role 'command' (substitution bodies
           included) must be EXACTLY the names bash ran: a name bash ran and
           we do not have is a command a gate would never see; a name we have
           and bash never ran is data read as a command.
  deriver  tools/_derive_variants.py must report every name bash ran.
  edges    tools/enrolment_edges.py must return a command for every name
           bash ran.

The generator keeps every command live so that "ran" and "is a command" are
the same set: a condition is a leaf whose status is in its name (`...-okN`
returns 0, `...-noN` returns 1), every `case` arm is selected, every loop body
runs.  Two kinds of name must NOT run and are there to be mistaken for
commands: `...-datN` (data: quoted text, comments, here-document bodies,
arguments, case patterns) and `...-parN` (text bash parses as a substitution
but this program never expands: inside `NAME[i]=...` before a command, which
bash rejects as "not a valid identifier" before expanding anything, or the
unused side of `${set:-...}`; reporting those is allowed, running them is
not).  `...-wrpN` is run by the `command` builtin: the consumers must report
it, the tokenizer's role need not.  `...-ambN` carries no claim at all -- is
`$((a); b)` arithmetic? does `"${x:-'$(a)'}"` run a? -- bash's log decides
and the tokenizer must agree.

INSTRUMENT findings are about the generator, not the tokenizer: a program
`bash -n` rejects, a name the generator meant to run that did not, a `dat`/
`par` name that ran, a program that did not finish.  With any of those the
run proves nothing and says so.

What is executed: only programs this file generates -- builtins, reserved
words and names that do not exist -- in an empty temporary directory, with
PATH pointing at an empty directory, no environment, stdin /dev/null, and a
time limit.  Nothing read from a file or the network is ever run.

BLIND SPOTS: what the vocabulary does not hold (aliases, `eval`, traps,
`select`, extglob, commands named by an expansion, wrappers that are programs
-- `env`, `timeout`, `sudo`: only the `command` builtin is run); bash's
dialect only, and only the bash on this machine; a command bash parses and
the program never reaches is kept out by construction, so dead code (`else`
arms not taken, code after `exit`) is covered by the parse oracles O1-O6,
not here.  The generator's shapes are the ones its author thought of: a
second generator by someone else is worth more than more seeds of this one.
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
  printf '%%s\n' "$1" >&9
  case $1 in *-no[0-9]*) return 1 ;; esac
  return 0
}
declare -A map
arr=(0 1)
set1=1
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
            [f"(({a})", f" {b})"], [f": $((", f" {a} ))"])

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


def execute(text, work):
    """Run TEXT under bash in WORK; return the set of names bash tried to run
    and could not find, or None if the program did not finish in time."""
    for stale in os.listdir(work):
        if stale not in ("bin",):
            path = os.path.join(work, stale)
            if os.path.isfile(path) or os.path.islink(path):
                os.unlink(path)
    with open(os.path.join(work, "prog.sh"), "w") as f:
        f.write(text)
    r, w = os.pipe()
    with open(os.path.join(work, "harness.sh"), "w") as f:
        f.write(_HARNESS % (w, w))
    try:
        p = subprocess.Popen(
            [ENV, "-i", f"PATH={work}/bin", "LC_ALL=C", f"HOME={work}",
             f"BASH_ENV={work}/harness.sh", BASH, "--norc", "--noprofile", "prog.sh"],
            cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, pass_fds=(w,), start_new_session=True)
    finally:
        os.close(w)
    # The log is read to end of file: every process that could still write a
    # name holds the pipe open, so background jobs, coprocesses and process
    # substitutions are all waited for.
    chunks = []
    finished = True

    def stop(*_):
        raise TimeoutError

    old = signal.signal(signal.SIGALRM, stop)
    signal.alarm(20)
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
    if not finished:
        return None
    return set(b"".join(chunks).decode(errors="replace").split("\n")) - {""}


# ------------------------------------------------------------------ the check

def command_names(text, mod=ST, depth=0):
    """Every word the tokenizer gives role 'command', quotes removed, in TEXT
    and in every substitution body inside it."""
    out = set()
    toks = mod.tokenize(text)
    for t in toks:
        if t.kind == "word" and t.role == "command":
            out.add(mod.unquote(t.text))
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


def judge(prog, ran, mod=ST, role=True, derived=None, edges=None):
    """Findings for one executed program.  RAN is bash's log.  ROLE checks
    the tokenizer MOD; DERIVED and EDGES are the consumers' readers, or None
    to leave a consumer out."""
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
                                ("edges", edges, "enrolment_edges has no such command")):
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


def run(seeds, n, mod=ST, role=True, derived=None, edges=None, cache=None):
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
                F.extend(judge(prog, ran, mod, role, derived, edges))
    finally:
        if work is not None:
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
    if not BASH or not ENV:
        print("INSTRUMENT ERROR: _shell_exec needs bash and env")
        return 2
    if show:
        seed, index = show.split(":")
        prog = Program(int(seed), int(index))
        sys.stdout.write(prog.text)
        return 0
    F, C = run(seeds, n, derived=deriver_reader(), edges=edges_reader())
    for f in F:
        print(f)
    print(f"shell-exec-oracle: bash={bash_version()} "
          + " ".join(f"{k}={v}" for k, v in sorted(C.items())) + f" findings={len(F)}")
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
