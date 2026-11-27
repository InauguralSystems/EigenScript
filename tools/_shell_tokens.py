#!/usr/bin/env python3
"""A quoting-aware shell tokenizer for the repository's shell-reading gates.

The gates used to read shell one physical line at a time with regexes and a
hand-copied quote tracker per tool (tools/_derive_variants.py,
tools/enrolment_edges.py).  That shape cannot see a quoted string, a `$(...)`
or a `[[ ]]` that spans lines, and every copy of the quote tracker drifted
from the others.  This module is the one lexer they share.  It reads WHOLE
TEXT, not lines, and knows:

  * quoting: '...', "...", $'...', $"...", backslash, and backslash-newline
    line continuation (removed outside single quotes, as bash does);
  * nesting: $(...), `...`, ${...}, $((...)), <(...) / >(...), extglob
    groups, `name=(...)` array values -- each is part of the word it sits in,
    and the bodies of $(...), `...` and <(...)/>(...) are recorded on the
    word because they are shell, wherever they sit;
  * comments: `#` at the start of a word, to end of line;
  * operators: control operators and redirections (with an IO number such as
    the `2` of `2>&1` folded into the redirection);
  * here-documents: the body after the opener's line is consumed and attached
    to the `<<` / `<<-` token, so it is never read as commands -- also when
    the opener sits in a `$( )` that closes on its own line (`x=$(cat <<E)`),
    where bash 5.2 reads the body from the lines below, and when the
    delimiter shares its line with the `)` that closes the substitution
    (`EOF)`), where the rest of that line is shell text again;
  * `case` patterns (`a)` closes a pattern, not a substitution) and `[[ ]]`
    (whose `<`, `&&`, `(` are operands, not shell operators).

The expected answers come from outside this file: tools/shell_oracle.py checks
the tokenizer against `bash -n`, `dash -n`, bash's own reprint of a parsed
function (`declare -f`), bash's own quote removal, and -- for which words are
commands -- what bash RUNS when it executes generated programs.  See that file
for the measured resolution and blind spots.

Tokens are (kind, text, line, start, end, subst, heredoc, role):

  kind     'word' | 'pattern' (a case pattern) | 'arith' (a `(( ))` command or
           `for (( ))` header) | 'op' | 'redir' | 'newline'
  text     a word's source text with line continuations removed (quotes kept;
           unquote() removes them; emptied() also takes its expansions as
           empty), or the operator text without IO number.  A word holding a
           here-document that ends in mid-line (`$(cat <<E` ... `E)`) gets a
           newline after that delimiter, so that it reads the same on its own.
  line     1-based line of the token's first character
  subst    for a word: the bodies of $(...), `...`, <(...), >(...) found at
           any quoting depth of that word -- in quotes, ${...}, $((...)),
           an assignment's [subscript] and an array value (not nested inside
           each other: a consumer recurses by tokenizing a body; bodies are
           str subclasses retaining their immediate quoted-$(...) context); for a
           `<<`/`<<-` redirection with an unquoted delimiter, the bodies of
           the $(...) and `...` in the here-document body
  heredoc  for a `<<`/`<<-` redirection: the body text, else None
  role     for a word, what the shell takes it for where it stands:
             'command'     the word a simple command runs
             'assignment'  NAME=value before the command word
             'argument'    a word after the command word
             'reserved'    a reserved word recognised as one (`if`, `do`, `{`,
                           `in`, `]]`, the `-p` of `time -p`...)
             'name'        a `for`/`select` variable, or the NAME of a function
                           or coproc being defined
             'list'        a word of a `for NAME in ...` list
             'subject'     the word a `case` matches
             'pattern'     a case pattern
             'test'        an operand or operator inside [[ ]]
             'target'      a redirection's target
             'delimiter'   a here-document's delimiter word
           The 'command' word of a simple command is the first word,
           redirections aside, that bash's assignment test rejects (`x=1 <f
           y=2 cmd` runs `cmd`; `"A=1" cmd` runs `A=1`).  There is a second
           one after a command word that is nothing but expansions and can
           expand to no word at all (`$wrap cmd`, `$(maybe) cmd`, `"$@" cmd`):
           bash runs the next word then, so it is a 'command' too, whatever
           it is spelled like (may_vanish()).  Consumers read the role
           instead of guessing a position from the text.

tokenize() raises ShellLexError for text the shell would reject lexically:
an unterminated quote, substitution, expansion or `[[`.  A here-document with
no delimiter line is NOT an error: bash and dash accept it (bash warns) and
read the body to end of file.
"""
from __future__ import annotations

import bisect
import functools
import re
from contextlib import contextmanager
from contextvars import ContextVar
from typing import NamedTuple


class ShellLexError(ValueError):
    def __init__(self, message: str, line: int):
        super().__init__(f"line {line}: {message}")
        self.line = line
        self.reason = message


class Token(NamedTuple):
    kind: str
    text: str
    line: int
    start: int
    end: int
    subst: tuple = ()
    heredoc: str | None = None
    role: str = ""


# Longest first: the scanner takes the first that matches.
OPERATORS = (
    ";;&", "<<<", "<<-", "&>>",
    ";;", ";&", "&&", "||", "|&", "&>", "<<", "<>", "<&", ">&", ">>", ">|",
    "<", ">", "|", "&", ";", "(", ")",
)
OPERATOR_STARTS = frozenset(op[0] for op in OPERATORS)
REDIRECTIONS = frozenset({
    "<<<", "<<-", "&>>", "&>", "<<", "<>", "<&", ">&", ">>", ">|", "<", ">",
})
HEREDOC_OPS = frozenset({"<<", "<<-"})
METACHARS = frozenset(" \t\n;&|()<>")
# Words after which the next word is again in command position.
RESERVED_OPENERS = frozenset({
    "if", "then", "else", "elif", "while", "until", "do", "!", "{", "time",
    "coproc",
})
EXTGLOB_LEADS = frozenset("?*+@!")
# Closers after which another reserved word may follow with no separator.
COMPOUND_CLOSERS = frozenset({"fi", "done", "esac", "}"})


class ShellText(str):
    """A substitution body keeps its immediate parser quote context.
    Bash removes ANSI quotes in arithmetic parsed inside a quoted $(...),
    but not in an unquoted nested $(...) or in backquotes (parse.y P_DQUOTE).
    Slices retain it so Token.text and Expansion operands do not lose it.
    """
    def __new__(cls, value, quoted_substitution=False, source_line=None):
        obj = super().__new__(cls, value)
        obj.quoted_substitution = quoted_substitution
        obj.source_line = source_line
        return obj

    def __getitem__(self, key):
        value = super().__getitem__(key)
        return ShellText(value, self.quoted_substitution) if isinstance(key, slice) else value


class _Lexer:
    def __init__(self, text: str, roles: bool = True):
        self.text = text
        self.n = len(text)
        # False for a lexer that only measures one word (where does this
        # expansion end?).  Such a lexer must not ask in turn whether the
        # command words inside it can vanish: that lexes each of them again,
        # and the work doubles with every level of nesting.
        self.roles = roles
        self.cuts: set[int] = set()       # positions of removed `\`+newline
        self.breaks: set[int] = set()     # positions a newline is put in front of
        self.comments: list[tuple[int, int]] = []        # [start, end) spans
        self.heredocs: list[tuple[int, int, bool]] = []  # body spans, <<- flag
        self.arith_memo: dict[int, bool] = {}
        self.arith_substitutions: dict[int, tuple] = {}
        self.command_substitutions: dict[int, tuple] = {}
        self.array_indices: list[tuple[int, int, int]] = []
        self.openers: list[int] = []   # offsets of every recorded $( / <( / >( body's opener
        # `$(cat <<E)`: a here-document still pending when its substitution
        # closes is read from the lines after the current one (bash 5.2,
        # measured).  newline offset -> where reading resumes after the bodies.
        self.skips: dict[int, int] = {}
        self.skips_taken: set[int] = set()
        self.line_starts = [0]
        for i, c in enumerate(text):
            if c == "\n":
                self.line_starts.append(i + 1)

    def line_of(self, pos: int) -> int:
        return bisect.bisect_right(self.line_starts, pos)

    def err(self, message: str, pos: int):
        raise ShellLexError(message, self.line_of(min(pos, max(self.n - 1, 0))))

    def clean(self, start: int, end: int) -> str:
        """Source slice with line continuations removed -- and a newline put
        after a here-document delimiter that bash ends in mid-line (`EOF)`
        inside a substitution), so that the slice reads the same on its own."""
        end = min(end, self.n)
        # Every cut is a backslash followed by a newline, and removes both:
        # with none of those in or just before the slice there is nothing to
        # remove.  (One continuation anywhere in a file must not make every
        # later slice of it a character-by-character copy.)
        if not self.breaks and (not self.cuts
                                or self.text.find("\\\n", max(start - 1, 0), end + 1) < 0):
            return self.text[start:end]
        cleaned = "".join(
            ("\n" if i in self.breaks else "") + self.text[i] for i in range(start, end)
            if i not in self.cuts and i - 1 not in self.cuts)
        return ShellText(cleaned, getattr(self.text, "quoted_substitution", False))

    # ---- quoted and nested word parts.  Each takes the position of the
    # ---- opening character(s) and returns the position after the close.

    def single(self, i: int) -> int:
        j = self.text.find("'", i + 1)
        if j < 0:
            self.err("unterminated single quote", i)
        return j + 1

    def ansi_c(self, i: int) -> int:          # $'...' ; i at the $
        j = i + 2
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                j += 2
                continue
            if c == "'":
                return j + 1
            j += 1
        self.err("unterminated $'...' quote", i)

    def double(self, i: int, subst: list) -> int:   # i at the opening "
        j = i + 1
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                if self.text[j + 1:j + 2] == "\n":
                    self.cuts.add(j)
                j += 2
                continue
            if c == '"':
                return j + 1
            if c == "$" or c == "`":
                j = self.dollar_or_backtick(j, subst, in_double=True)
                continue
            j += 1
        self.err("unterminated double quote", i)

    def dollar_or_backtick(self, j: int, subst: list, in_double: bool) -> int:
        t = self.text
        if t[j] == "`":
            return self.backtick(j, subst, in_double)
        nxt = t[j + 1:j + 2]
        if t.startswith("$((", j):
            if self.arith_closes(j + 3):
                return self.arith(j + 3, j, subst)
            # Not arithmetic.  bash's lexer still ends `$((` by counting
            # parentheses, never by parsing commands (so `bash -n` sees no
            # syntax error inside it, and a case pattern's `)` closes it);
            # what is inside is a command list only when it runs.
            end = self.paren_group(j + 2, [], j)
            subst.append(self.clean(j + 2, end - 1))
            self.openers.append(j)
            return end
        if nxt == "(":
            return self.cmdsub(j + 2, subst, j, in_double)
        if nxt == "{":
            return self.param(j + 2, subst, j, in_double)
        if nxt == "[":
            return self.old_arith(j + 2, subst, j)
        if nxt and nxt in "$?#!-@*0123456789":
            return j + 2                      # `$$`, `$?`, `$1`...: the next `'` is a plain quote
        if nxt == "'" and not in_double:
            return self.ansi_c(j)
        if nxt == '"' and not in_double:
            return self.double(j + 1, subst)
        return j + 1

    def old_arith(self, j: int, subst: list, opener: int) -> int:
        """`$[ expr ]`, bash's obsolete arithmetic: brackets balance, and
        `<` `>` `(` inside are arithmetic, not shell operators."""
        start, first = j, len(subst)
        depth = 0
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                j += 2
                continue
            if c == "'":
                j = self.single(j)
                continue
            if c == '"':
                j = self.double(j, subst)
                continue
            if c in "$`":
                j = self.dollar_or_backtick(j, subst, in_double=False)
                continue
            if c == "[":
                depth += 1
            elif c == "]":
                if depth == 0:
                    self.expanded_in_quotes(start, j, subst, first)
                    return j + 1
                depth -= 1
            j += 1
        self.err("unterminated $[...]", opener)

    def backtick(self, i: int, subst: list, in_double: bool = False) -> int:
        j = i + 1
        escapable = "$`\\\"" if in_double else "$`\\"
        body = []
        while j < self.n:
            c = self.text[j]
            if c == "\\" and j + 1 < self.n:
                nxt = self.text[j + 1]
                # Inside backquotes a backslash keeps its literal meaning
                # except before $ ` \ (POSIX 2.6.3); newline is a continuation.
                if nxt == "\n":
                    self.cuts.add(j)
                elif nxt in escapable:
                    body.append(nxt)
                else:
                    body.append(c + nxt)
                j += 2
                continue
            if c == "`":
                subst.append("".join(body))
                subst[-1] = ShellText(subst[-1], source_line=self.line_of(i + 1))
                return j + 1
            body.append(c)
            j += 1
        self.err("unterminated backquote", i)

    def cmdsub(self, body_start: int, subst: list, opener: int, in_double=False) -> int:
        return self.substitution(body_start, subst, opener, "$(...)", in_double)

    def procsub(self, body_start: int, subst: list, opener: int) -> int:
        return self.substitution(body_start, subst, opener, "process substitution")

    def substitution(self, body_start: int, subst: list, opener: int, what: str, in_double=False) -> int:
        sub = _Body(self, body_start, closer=")")
        end = sub.run()
        if end is None:
            self.err(f"unterminated {what}", opener)
        body = self.clean(body_start, end)
        if end in self.breaks:
            body += "\n"                     # the delimiter shared its line with this `)`
        if sub.pending:
            # `$(cat <<E)` closing before its here-document was read: bash
            # reads the body from the lines after this one.  The recorded
            # body gets it in line, as bash's own reprint lays it out.
            body += "\n" + self.deferred_heredocs(sub, end)
        subst.append(ShellText(body, in_double, self.line_of(body_start)))
        if what == "$(...)":
            self.command_substitutions[opener] = (end + 1, subst[-1])
        self.openers.append(opener)
        return end + 1

    def deferred_heredocs(self, sub: "_Body", close: int) -> str:
        """Read SUB's pending here-documents from the lines after the one
        holding CLOSE; return that text (bodies and their delimiter lines)."""
        nl = self.text.find("\n", close)
        if nl < 0:
            nl = self.n                       # no later line: delimited by end of file
        start = self.skips.get(nl, min(nl + 1, self.n))
        sub.i = start
        sub.read_heredocs(below=True)
        self.skips[nl] = sub.i
        return self.text[start:sub.i]

    def arith_scan(self, j: int, subst: list) -> int | None:
        """End (after `))`) of an arithmetic body starting at j, or None if
        its parentheses do not close as `))`.  Quotes, ${...}, $(...) and
        backquotes inside are read as such; their bodies go to SUBST."""
        depth = 0
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                if self.text[j + 1:j + 2] == "\n":
                    self.cuts.add(j)
                j += 2
                continue
            if c == "'":
                j = self.single(j)
                continue
            if c == '"':
                j = self.double(j, subst)
                continue
            if c in "$`":
                j = self.dollar_or_backtick(j, subst, in_double=False)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    return j + 2 if self.text[j + 1:j + 2] == ")" else None
                depth -= 1
            j += 1
        return None

    def arith_closes(self, j: int) -> bool:
        """Whether `$((` at j-3 is arithmetic: its parens close as `))`.
        Memoized: nested `$(( $(( ...` would otherwise rescan per level."""
        if j in self.arith_memo:
            return self.arith_memo[j]
        cuts, breaks = set(self.cuts), set(self.breaks)
        comments, heredocs, openers = list(self.comments), list(self.heredocs), list(self.openers)
        skips = dict(self.skips)
        try:
            result = self.arith_scan(j, []) is not None
        except ShellLexError:
            result = False
        finally:
            self.cuts, self.breaks = cuts, breaks
            self.comments, self.heredocs = comments, heredocs
            self.openers, self.skips = openers, skips
        self.arith_memo[j] = result
        return result

    def arith(self, j: int, opener: int, subst: list) -> int:
        first = len(subst)
        end = self.arith_scan(j, subst)
        if end is None:
            self.err("unterminated $((...))", opener)
        # Parsing pairs quotes; expansion subsequently uses Q_DOUBLE_QUOTES.
        self.expanded_in_quotes(j, end - 2, subst, first)
        self.arith_substitutions[opener] = (end, tuple(subst[first:]))
        return end

    def param(self, j: int, subst: list, opener: int, in_double: bool = False) -> int:
        """`${ ... }`; j is after the `${`.  IN_DOUBLE: the expansion sits in
        double quotes or a here-document body.

        The closing `}` is found with quotes paired, as bash's parser pairs
        them (`"${x:-it's}"` is a syntax error).  What RUNS is a second
        question inside double quotes: there the word of `${x:-word}` is
        expanded with its single quotes as plain characters, so
        `"${x:-'$(cmd)'}"` runs cmd -- unless the operator takes a pattern
        (`%`, `#`, `/`, `^`, `,`), where the quotes do quote.  (bash 5.2,
        measured; the state names are parse.y's dolbrace_state.)"""
        start, first = j, len(subst)
        state = "param"            # -> "op" -> "word", or "quote" for a pattern operator
        literal_quotes = False
        while j < self.n:
            c = self.text[j]
            if state == "param" and c in "%#/^," and j > start:
                state = "quote"
            elif state == "param" and c in "#%^,~:-=?+/":
                state = "op"
            elif state == "op" and c not in "#%^,~:-=?+/":
                state = "word"
            if c == "\\":
                if self.text[j + 1:j + 2] == "\n":
                    self.cuts.add(j)
                j += 2
                continue
            if c == "}":
                if literal_quotes:
                    self.expanded_in_quotes(start, j, subst, first)
                return j + 1
            if c == "'":
                if in_double and state != "quote":
                    literal_quotes = True
                j = self.single(j)
                continue
            if c == '"':
                j = self.double(j, subst)
                continue
            if c in "$`":
                j = self.dollar_or_backtick(j, subst, in_double)
                continue
            j += 1
        self.err("unterminated ${...}", opener)

    def expanded_in_quotes(self, a: int, b: int, subst: list, first: int):
        """Replace the bodies recorded for text[a:b] (SUBST[first:]) by the
        ones that run when that text is expanded inside double quotes, where
        a single quote is a plain character.  bash parses none of the newly
        seen ones before run time, so no opener, comment or here-document
        span is recorded for them."""
        saved = (list(self.comments), list(self.heredocs), list(self.openers), dict(self.skips))
        found: list = []
        try:
            k = a
            while k < b:
                c = self.text[k]
                if c == "\\":
                    k += 2
                elif c in "$`":
                    if self.text.startswith("$((", k) and k in self.arith_substitutions:
                        k, bodies = self.arith_substitutions[k]
                        found.extend(bodies)
                    elif self.text.startswith("$(", k) and k in self.command_substitutions:
                        # The parser already read this body. Re-reading it at
                        # every runtime quote pass doubles work per nesting.
                        k, body = self.command_substitutions[k]
                        found.append(body)
                    else:
                        opener, first_new = k, len(found)
                        k = self.dollar_or_backtick(k, found, in_double=True)
                        # Q_DOUBLE_QUOTES controls expansion here. A command
                        # first parsed at runtime does not inherit P_DQUOTE.
                        found[first_new:] = [ShellText(body, False, getattr(body, 'source_line', None))
                                             for body in found[first_new:]]
                        if opener in self.command_substitutions and found[first_new:]:
                            self.command_substitutions[opener] = (k, found[first_new])
                else:
                    k += 1
        except ShellLexError:
            return                 # keep the parser's reading
        finally:
            self.comments, self.heredocs, self.openers, self.skips = saved
        subst[first:] = found

    def match_subscript(self, j: int, subst: list, lexer: bool = False) -> int | None:
        """j is at a `[`.  The index after the `]` that closes it, or None if it
        never closes.  Nested [ ], quotes, $( ), ${ }, $[ ], $(( )) and
        backquotes inside do not close it, and a newline does not end it.
        Bodies of the substitutions inside go to SUBST.

        bash closes a subscript in two places that do not agree, and both are
        modelled (measured on bash 5.2: `m[<(c ])]=1 d` runs `c ]`, not `d`):
          * LEXER -- where the WORD ends (parse_matched_pair with P_ARRAYSUB):
            a `<(` or `>(` inside the subscript is parsed as a process
            substitution, a command list of its own, so a `]` inside it does
            not close (and a syntax error inside it is one: `bash -n` rejects
            `m[<(&& c)]=1`).
          * not LEXER -- whether the finished word is an ASSIGNMENT
            (skipsubscript): `<(` is not special there, so the first `]` it
            meets closes, and `m[<(c ])]=1` is not an assignment.
        A process substitution inside the subscript of a word that IS an
        assignment is parsed and never run; it is recorded all the same."""
        depth = 0
        k = j
        gtlt = False        # bash's LEX_GTLT: the last character was a lone < or >
        while k < self.n:
            c = self.text[k]
            if c == "\\":
                if self.text[k + 1:k + 2] == "\n":
                    self.cuts.add(k)
                k += 2
                gtlt = False
                continue
            if c == "'":
                k = self.single(k)
                gtlt = False
                continue
            if c == '"':
                k = self.double(k, subst)
                gtlt = False
                continue
            if c in "$`":
                k = self.dollar_or_backtick(k, subst, in_double=False)
                gtlt = False
                continue
            if c == "(" and gtlt and lexer:
                k = self.procsub(k + 1, subst, k - 1)
                gtlt = False
                continue
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    return k + 1
            gtlt = c in "<>" and not gtlt
            k += 1
        return None

    def paren_group(self, j: int, subst: list, opener: int, array: bool = False) -> int:
        """A balanced ( ... ) that is part of a word: an extglob group or an
        array value `name=( ... )`.  j is after the `(`.  Only an array value
        holds comments and process substitutions."""
        depth = 0
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                if self.text[j + 1:j + 2] == "\n":
                    self.cuts.add(j)
                j += 2
                continue
            if c == "'":
                j = self.single(j)
                continue
            if c == '"':
                j = self.double(j, subst)
                continue
            if c in "$`":
                j = self.dollar_or_backtick(j, subst, in_double=False)
                continue
            if array and depth == 0 and c == "[" and self.text[j - 1] in " \t\n(":
                # `[subscript]=value` element: at the start of an element bash
                # matches the subscript to its `]` (so `[ ( ]=x` is one word)
                close = self.match_subscript(j, subst, lexer=True)
                if close is None:
                    self.err("unterminated [ subscript", j)
                if self.text.startswith(('=', '+='), close):
                    self.array_indices.append((opener, j + 1, close - 1))
                j = close
                continue
            if array and c in "<>" and self.text[j + 1:j + 2] == "(":
                # anywhere in an element: `[k]=<(cmd)`, `x<(cmd)` (DevBox r6)
                j = self.procsub(j + 2, subst, j)
                continue
            if array and c == "#" and (self.text[j - 1] in " \t\n("):
                nl = self.text.find("\n", j)
                end = self.n if nl < 0 else nl
                self.comments.append((j, end))
                j = end
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    return j + 1
                depth -= 1
            j += 1
        self.err("unterminated ( ... ) inside a word", opener)


class _Body:
    """Tokenizes a list of commands: the whole text, or a $( ) / <( ) body
    ending at an unmatched `)`."""

    def __init__(self, lx: _Lexer, start: int, closer: str | None):
        self.lx = lx
        self.i = start
        self.closer = closer
        self.tokens: list[Token] = []
        self.pending: list[tuple[int, str, bool, bool]] = []  # idx, delim, strip, quoted
        self.parens = 0
        self.cmdpos = True
        self.case: list[str] = []      # per open case: 'word' | 'in' | 'pattern' | 'body'
        self.dbracket = False
        self.expect_delim = None       # (token idx, strip) awaiting the delimiter word
        self.regex_next = False        # the word after `=~` inside [[ ]]
        # The three facts bash's lexer keeps about the last token read, which
        # decide what the next word may be (parse.y: reserved_word_acceptable,
        # assignment_acceptable, PST_REDIRLIST):
        #   cmdpos       a reserved word (and `((`, `[[`) may start here
        #   last_assign  the last word was an assignment word
        #   redir_only   only redirections have been read in this simple command
        # An assignment -- and NAME[ opening a subscript matched to its `]` --
        # is acceptable when any of the three holds (assign_ok()).
        self.last_assign = False
        self.redir_only = False
        self.expect_target = False     # the next word is a redirection's target
        self.after_for = False         # `for` was just read: `((` is arithmetic
        self.after_time = 0            # 1: `time` was just read; 2: `time -p`
        self.after_coproc = False      # `coproc` was just read
        self.after_function = False    # `function` was just read: next is the NAME
        self.split_next = False        # a word here starts a new command
        self.for_header = 0            # 1: `for` read; 2: its NAME read
        self.for_list = False          # reading the words of `for NAME in ...`
        self.has_command = False       # this simple command's command word was read
        self.vanishing = False         # ... and it may expand to no word at all

    # ------------------------------------------------------------------ words
    def read_word(self, start: int) -> tuple[int, list]:
        lx, t = self.lx, self.lx.text
        subst: list = []
        j = start
        while j < lx.n:
            c = t[j]
            if c == "\\":
                if t[j + 1:j + 2] == "\n":
                    lx.cuts.add(j)
                j += 2
                continue
            if c == "'":
                j = lx.single(j)
                continue
            if c == '"':
                j = lx.double(j, subst)
                continue
            if c in "$`":
                j = lx.dollar_or_backtick(j, subst, in_double=False)
                continue
            if c == "[" and self.assign_ok() and _plain_ident(lx.clean(start, j)):
                # NAME[ where an assignment is acceptable: bash reads on to the
                # matching `]` whatever is inside (`a[1<<3]=x`, `m[ ( ]=v`),
                # and whatever follows it.
                close = lx.match_subscript(j, subst, lexer=True)
                if close is None:
                    lx.err("unterminated [ subscript", j)
                j = close
                continue
            if c == "(":
                prefix = lx.clean(start, j)
                if _is_array_assign(prefix) or (prefix and prefix[-1] in EXTGLOB_LEADS
                                                 and not self.cmdpos):
                    # (at a command position `!(cmd)` negates a subshell and
                    # `f+()` defines a function: bash scripts run with extglob off)
                    j = lx.paren_group(j + 1, subst, j, array=_is_array_assign(prefix))
                    continue
                break
            if c in "<>" and t[j + 1:j + 2] == "(":
                j = lx.procsub(j + 2, subst, j)
                continue
            if c in METACHARS:
                if self.dbracket and c in "<>()" and j == start:
                    j += 1
                    continue
                break
            j += 1
        return min(j, lx.n), subst

    def read_regex(self, start: int) -> tuple[int, list]:
        """The right operand of `=~` in [[ ]]: bash reads ( ) | < > as part
        of the regex word; only unparenthesised blanks end it."""
        lx, t = self.lx, self.lx.text
        subst: list = []
        depth = 0
        j = start
        while j < lx.n:
            c = t[j]
            if c == "\\":
                j += 2
                continue
            if c == "'":
                j = lx.single(j)
                continue
            if c == '"':
                j = lx.double(j, subst)
                continue
            if c in "$`":
                j = lx.dollar_or_backtick(j, subst, in_double=False)
                continue
            if c == "(":
                depth += 1
            elif c == ")" and depth:
                depth -= 1
            elif c in " \t\n" and depth == 0:
                break
            elif c in ";&" and depth == 0:
                break
            j += 1
        return min(j, lx.n), subst

    # -------------------------------------------------------------- the loop
    def run(self) -> int | None:
        lx, t = self.lx, self.lx.text
        while self.i < lx.n:
            c = t[self.i]
            if c in " \t":
                self.i += 1
                continue
            if c == "\\" and t[self.i + 1:self.i + 2] == "\n":
                lx.cuts.add(self.i)
                self.i += 2
                continue
            if c == "#":
                nl = t.find("\n", self.i)
                end = lx.n if nl < 0 else nl
                lx.comments.append((self.i, end))
                self.i = end
                continue
            if c == "\n" and self.dbracket and not self.pending:
                self.next_line()              # `[[ a &&<newline> b ]]`: one command
                continue
            if c == "\n":
                self.emit(Token("newline", "\n", lx.line_of(self.i), self.i, self.i + 1))
                self.next_line()
                if self.pending:
                    self.read_heredocs()
                self.after_separator()
                continue
            if self.closer and c == ")" and self.parens == 0 and not self.in_pattern() \
                    and not self.dbracket:
                return self.i
            if t.startswith("((", self.i) and not self.dbracket and \
                    (self.cmdpos or self.after_for) and lx.arith_closes(self.i + 2):
                subst: list = []
                end = lx.arith(self.i + 2, self.i, subst)
                self.emit(Token("arith", lx.clean(self.i, end), lx.line_of(self.i),
                                self.i, end, tuple(subst)))
                self.i = end
                self.after_for = False
                self.for_header = 0           # `for ((...))` has no NAME: `do` comes next
                # `(( x )) then` / `for ((...)) do`: a reserved word may
                # follow a compound command with no separator.
                self.cmdpos = True
                self.last_assign = self.redir_only = False
                continue
            self.after_for = False
            op = None if (self.dbracket and self.regex_next) else self.match_op()
            if op and not (self.dbracket and op not in (";", "\n")):
                self.handle_op(op)
                continue
            # A word (or, inside [[ ]], an operator-looking operand).
            if self.dbracket and op:
                end = self.i + len(op)
                self.emit(Token("word", op, lx.line_of(self.i), self.i, end, role="test"))
                self.i = end
                continue
            if self.dbracket and self.regex_next:
                end, subst = self.read_regex(self.i)
            else:
                end, subst = self.read_word(self.i)
            self.regex_next = False
            if end == self.i:                 # defensive: never spin
                end = self.i + 1
            text = lx.clean(self.i, end)
            if ((text.isdigit() and text.isascii()) or _is_fd_name(text)) and t[end:end + 1] in ("<", ">") \
                    and not self.dbracket:
                self.i = end                  # IO number / {name}: folded into the redirection
                continue
            # A case pattern is matched against, never run: its own kind.
            kind = "pattern" if self.in_pattern() and text != "esac" \
                and self.expect_delim is None else "word"
            if self.split_next and kind == "word":
                # `[[ x ]] then cmd`, `function f { cmd`: bash ends the
                # previous command here; a zero-width `;` says so.
                self.emit(Token("op", ";", lx.line_of(self.i), self.i, self.i))
            self.emit(Token(kind, text, lx.line_of(self.i), self.i, end, tuple(subst)))
            self.i = end
            at = len(self.tokens) - 1
            role = self.after_word(text)
            self.tokens[at] = self.tokens[at]._replace(role=role)
        if self.closer:
            return None
        if self.dbracket:
            lx.err("unterminated [[", lx.n - 1)
        return lx.n

    def next_line(self):
        """Step over the newline at self.i -- and over here-document bodies a
        substitution on this line already read from the lines below."""
        resume = self.lx.skips.get(self.i)
        if resume is None:
            self.i += 1
        else:
            self.lx.skips_taken.add(self.i)
            self.i = resume

    def match_op(self) -> str | None:
        t, i = self.lx.text, self.i
        if t[i:i + 1] not in OPERATOR_STARTS:     # most words: no operator starts here
            return None
        for op in OPERATORS:
            if t.startswith(op, i):
                if op in ("<", ">") and t[i + 1:i + 2] == "(" :
                    return None               # process substitution: a word
                return op
        return None

    def handle_op(self, op: str):
        lx = self.lx
        start = self.i
        self.i += len(op)
        kind = "redir" if op in REDIRECTIONS else "op"
        self.emit(Token(kind, op, lx.line_of(start), start, self.i))
        if kind == "redir":
            if op in HEREDOC_OPS:
                self.expect_delim = (len(self.tokens) - 1, op == "<<-")
            else:
                self.expect_target = True
            return
        if op == "(":
            prev = self.tokens[-2] if len(self.tokens) > 1 else None
            if prev is not None and prev.kind == "word" and prev.role == "command" \
                    and lx.text[self.i:].lstrip(" \t")[:1] == ")":
                # `NAME()` / `NAME ( )`: a function definition; NAME is not run here
                self.tokens[-2] = prev._replace(role="name")
            if not self.in_pattern():         # `(a)` pattern: the optional lead
                self.parens += 1
            self.after_separator()
        elif op == ")":
            if self.in_pattern():
                self.case[-1] = "body"
                self.after_separator()
                return
            self.parens = max(0, self.parens - 1)
            self.after_separator()            # `f()` is followed by its body; `(v=1) then`
        elif op in (";;", ";&", ";;&"):
            if self.case:
                self.case[-1] = "pattern"
            self.after_separator()
        else:
            self.after_separator()

    def after_separator(self):
        self.cmdpos = True
        self.last_assign = False
        self.redir_only = False
        self.expect_target = False
        self.after_coproc = False
        self.after_time = 0
        self.for_list = False
        self.has_command = False
        self.vanishing = False

    def in_pattern(self) -> bool:
        return bool(self.case) and self.case[-1] == "pattern"

    def assign_ok(self) -> bool:
        """bash's assignment_acceptable(): the next word may be an assignment,
        and NAME[ opens a subscript, at the start of a command, after an
        assignment word, or while only redirections have been read -- not in
        a case pattern, a `for`/`case`/`function` header or `[[ ]]`.
        (Measured against bash 5.2 with `m[ ( ]=v`, which only parses where
        the subscript is matched: accepted after `<f`, `x=1`, `!`, `time -p`,
        `coproc`; rejected after `x=1 <f`, `local`, a command word.)"""
        if self.dbracket or self.for_header or self.after_function \
                or self.expect_delim is not None or self.expect_target:
            return False
        if self.case and self.case[-1] != "body":
            return False
        return self.cmdpos or self.last_assign or self.redir_only

    def after_redirection_word(self):
        """After a redirection's target or a here-document delimiter.  For bash
        the last token is then a plain word: a reserved word no longer starts
        anything (`<f if x` runs a command named `if`), but an assignment is
        still acceptable while only redirections have been read."""
        if self.cmdpos or self.redir_only:
            self.redir_only = True
        self.cmdpos = False
        self.last_assign = False
        self.after_coproc = False
        self.after_time = 0

    def after_word(self, word: str) -> str:
        """Advance the state past WORD; return the role it has here."""
        if self.expect_delim is not None:
            idx, strip = self.expect_delim
            self.expect_delim = None
            quoted = any(c in word for c in "'\"\\")
            self.pending.append((idx, unquote(word), strip, quoted))
            self.after_redirection_word()
            return "delimiter"
        if self.expect_target:
            self.expect_target = False
            self.after_redirection_word()
            return "target"
        if self.dbracket:
            if word == "=~":
                self.regex_next = True
            if word == "]]":
                self.dbracket = False
                self.after_separator()            # `[[ x ]] then`: a reserved word may follow
                self.split_next = True
                return "reserved"
            return "test"
        if self.case and self.case[-1] == "word":
            self.case[-1] = "in" if word else "word"
            return "subject"
        if self.case and self.case[-1] == "in":
            if word == "in":
                self.case[-1] = "pattern"
                return "reserved"
            return "subject"
        if self.case and self.case[-1] == "pattern":
            if word == "esac":
                self.case.pop()
                self.after_separator()
                self.split_next = True
                return "reserved"
            return "pattern"
        if self.for_header == 1:              # `for NAME`
            self.for_header = 2
            return "name"
        if self.for_header == 2:
            self.for_header = 0
            if word == "do":                  # `for NAME do` (implicit "$@")
                self.after_separator()
                self.split_next = True
                return "reserved"
            if word == "in":
                self.for_list = True
                return "reserved"
        if self.after_function:
            self.after_function = False
            self.after_separator()            # `function NAME {` / `function NAME ()`
            self.split_next = True
            return "name"
        acceptable = self.cmdpos or self.last_assign or self.redir_only
        self.last_assign = False
        if not self.cmdpos:
            # Not a reserved-word position.  Where an assignment is still
            # acceptable (after one, or after leading redirections) the word
            # is an assignment or the command word; otherwise an argument.
            if acceptable:
                self.last_assign = assignment_split(word) is not None
                self.redir_only = False
            return self.word_role(word)
        # ---- a reserved word may start here
        if word == "{":
            self.after_coproc = False         # #2586: `coproc { WORD while` names nothing
            self.split_next = True
            return "reserved"                 # a group or function body opens
        if self.after_time and (word == "--" or (word == "-p" and self.after_time == 1)):
            self.after_time = 0 if word == "--" else 2
            return "reserved"                 # `time -p`, `time --`: still a command position
        self.after_time = 0
        if self.after_coproc:
            self.after_coproc = False
            rest = re.sub(r"\\\n", "", self.lx.text[self.i:]).lstrip(" \t")
            nameable = (word not in (RESERVED_OPENERS - {"time"}) | COMPOUND_CLOSERS
                        and word not in ("for", "select", "case", "function", "[[", "in", "]]")
                        and assignment_split(word) is None)
            if nameable and (rest[:1] == "(" or (rest[:1] == "{" and rest[1:2] in ("", " ", "\t", "\n"))
                             or re.match(r"(?:while|until|for|select|if|case|\[\[)(?=$|[ \t\n;&|()]|[<>](?!\())", rest)):
                # #2586: bash takes ANY word but a reserved one (`time` is not, here)
                # or an assignment before a compound for its name, rejecting
                # non-identifiers only at runtime; a reserved word starts an
                # unnamed coproc whatever follows it. Quotes and keyword suffixes
                # do not introduce a compound. Backslash-newlines join tokens.
                self.split_next = True
                return "name"
        if word in ("for", "select"):
            self.after_for = True
            self.for_header = 1
            self.cmdpos = False
            return "reserved"
        if word == "time":
            self.after_time = 1
            return "reserved"
        if word == "coproc":
            self.after_coproc = True
            return "reserved"
        if word == "function":
            self.after_function = True
            self.cmdpos = False
            return "reserved"
        if word == "esac" and self.case:
            self.case.pop()
        if word in COMPOUND_CLOSERS:
            self.split_next = True
            return "reserved"                 # `done then`, `fi }`: still a reserved-word position
        if word == "case":
            self.case.append("word")
            self.cmdpos = False
            return "reserved"
        if word == "[[":
            self.dbracket = True
            self.cmdpos = False
            return "reserved"
        if word in RESERVED_OPENERS:
            return "reserved"                 # still a command position
        # An assignment word, or the command word of this simple command.
        self.last_assign = assignment_split(word) is not None
        self.cmdpos = False
        self.redir_only = False
        return self.word_role(word)

    def word_role(self, word: str) -> str:
        """The role of an ordinary word of a simple command, decided the way
        bash decides it when the command runs (separate_out_assignments): the
        leading words its assignment test accepts are assignments, the next
        word is the command, the rest are arguments -- wherever redirections
        sit between them."""
        if self.for_list:
            return "list"
        if self.has_command:
            return "argument"
        if not self.vanishing and assignment_split(word) is not None:
            return "assignment"
        # The command word.  If it is nothing but expansions that can expand
        # to no word at all (`$wrap cmd`, `$(maybe) cmd`, `"$@" cmd`), bash
        # runs the NEXT word when they do -- and that word is then the
        # command even if it looks like an assignment (`$empty v=1` runs a
        # command named v=1).  So the next word is a command word too.
        self.vanishing = self.lx.roles and may_vanish(word)
        self.has_command = not self.vanishing
        return "command"

    def emit(self, tok: Token):
        self.split_next = False
        self.tokens.append(tok)

    def read_heredocs(self, below: bool = False):
        """Read the bodies of the pending here-documents from self.i.  BELOW:
        they are read after the substitution that opened them has closed."""
        lx, t = self.lx, self.lx.text
        for idx, delim, strip, quoted in self.pending:
            body_start = self.i
            while self.i < lx.n:
                nl = t.find("\n", self.i)
                line_end = lx.n if nl < 0 else nl
                line = t[self.i:line_end]
                # With an unquoted delimiter, backslash-newline joins body
                # lines before the delimiter is looked for (bash and dash).
                while not quoted and nl >= 0 and \
                        (len(line) - len(line.rstrip("\\"))) % 2 == 1:
                    nl = t.find("\n", line_end + 1)
                    nxt_end = lx.n if nl < 0 else nl
                    line = line[:-1] + t[line_end + 1:nxt_end]
                    line_end = nxt_end
                cmp = line.lstrip("\t") if strip else line
                if cmp == delim:
                    body = t[body_start:self.i]
                    self.i = line_end + 1 if nl >= 0 else lx.n
                    break
                if self.closer == ")" and cmp.startswith(delim) and ")" in cmp[len(delim):]:
                    # Inside a substitution bash also ends the document at a
                    # line that BEGINS with the delimiter and has a `)` later
                    # on it, and reads the rest of that line as shell text:
                    # `$(cat <<EOF` ... `EOF)` (parse.y, "backwards
                    # compatibility"; measured: `Ex)` after `<<E` runs `x`).
                    if below:
                        lx.err("a here-document read below its substitution ends on a line "
                               "that goes on as shell text", self.i)
                    body = t[body_start:self.i]
                    self.i += (len(line) - len(cmp) if strip else 0) + len(delim)
                    lx.breaks.add(self.i)
                    break
                self.i = line_end + 1 if nl >= 0 else lx.n
            else:
                body = t[body_start:lx.n]     # delimited by end of file
            lx.heredocs.append((body_start, body_start + len(body), strip))
            tok = self.tokens[idx]
            # An unquoted delimiter means the body is expanded: its $( ) and
            # backquotes run when the command does, so they are recorded.
            if quoted:
                subst = ()
            else:
                found, openers = _body_substitutions(body)
                subst = tuple(found)
                lx.openers.extend(body_start + o for o in openers)
            self.tokens[idx] = tok._replace(heredoc=body, subst=subst)
        self.pending = []


def _body_substitutions(body: str) -> list:
    """($( ) / backquote / ${ } bodies, $( openers) in an expanded
    here-document body; opener offsets are relative to the body."""
    lx = _Lexer(body)
    out: list = []
    j = 0
    while j < lx.n:
        c = body[j]
        if c == "\\":
            j += 2
            continue
        if c in "$`":
            try:
                nxt = body[j + 1:j + 2]
                if c == "$" and nxt in ("'", '"'):
                    j += 1                    # no quote removal in a here-document body
                    continue
                j = lx.dollar_or_backtick(j, out, in_double=True)
            except ShellLexError:
                j += 1
            continue
        j += 1
    return out, lx.openers


def _is_fd_name(word: str) -> bool:
    """`{name}` before a redirection: bash's named file descriptor."""
    return len(word) > 2 and word[0] == "{" and word[-1] == "}" and _plain_ident(word[1:-1])


def redirection_fd_names(text: str, tokens) -> list[str]:
    """Names that `{name}>file` binds (bash allocates a descriptor into NAME).
    The lexer folds a `{name}` IO word into its redirection, so the name is
    recovered from the span between the previous token and the operator.
    TOKENS must come from tokenizing TEXT."""
    out, prev_end = [], 0
    for tok in tokens:
        if tok.kind == "redir":
            span = text[prev_end:tok.start]
            word = span.lstrip(" \t")
            if span.endswith(word) and _is_fd_name(word):
                out.append(word[1:-1])
        prev_end = tok.end
    return out


def _plain_ident(name: str) -> bool:
    return name.isidentifier() and name.isascii()


@functools.lru_cache(maxsize=8192)
def assignment_split(word: str):
    """(name, value) if WORD -- a token's text, quotes kept -- is an assignment
    word as bash's assignment() decides it: NAME=value, NAME+=value,
    NAME[subscript]=value or NAME[subscript]+=value.  Otherwise None.

    The subscript closes the way bash's skipsubscript closes it
    (match_subscript), so `m[${k[1]}]=v`, `m[$[ 1 ]]=v` and `h["]"]=v` are
    assignments and `m[<(c ])]=1` is not.  This is the one recogniser: the
    lexer's own state and every consumer use it, so "is this word an
    assignment" has a single answer.

    (Remembered per word: the lexer asks about every word, the subscript of a
    word is lexed to answer, and a subscript may hold words to ask about --
    `a[$(a[$(...)]=1)]=1` -- so without a memory the work triples with each
    level of nesting.)"""
    n = len(word)
    if not n or not (word[0].isascii() and (word[0].isalpha() or word[0] == "_")):
        return None
    i = 1
    while i < n and word[i].isascii() and (word[i].isalnum() or word[i] == "_"):
        i += 1
    name = word[:i]
    if i < n and word[i] == "[":
        try:
            i = _Lexer(word, roles=False).match_subscript(i, [])
        except ShellLexError:
            return None
        if i is None:
            return None
    if word.startswith("+=", i):
        return name, word[i + 2:]
    if word.startswith("=", i):
        return name, word[i + 1:]
    return None


# A double-quoted `$@` or `${name[@]}` (also `${!name[@]}`, `${!prefix@}`)
# expands to one word per element: to no word at all when there are none.
_LIST_EXPANSION = re.compile(
    r"^\$(@|\{(@|!?[A-Za-z_][A-Za-z0-9_]*\[@\]|![A-Za-z_][A-Za-z0-9_]*@\}))")
# An expansion that always has a value: `$?`, `$#`, `$$`, `$0`, a length
# `${#name}`, arithmetic.  (Not `${?%0}`: an operator can empty it.)
_ALWAYS_VALUED = re.compile(
    r"^(\$[?#$0]$|\$\{[?$0]\}$"
    r"|\$\{#(?:[A-Za-z_][A-Za-z0-9_]*(?:\[.*\])?|[0-9]+|[@*#?$!-])?\}$"
    r"|\$\[|\$\(\()", re.S)


def _expansions(word: str):
    """The expansions of a word that is nothing but expansions -- `$v`,
    `${v:-x}`, `$(cmd)`, `` `cmd` ``, `"$@"`, several in a row -- else None.
    A list of groups (inside double quotes, [expansion text, ...]): an
    unquoted expansion is a group of its own, a pair of double quotes is one
    group holding the expansions written inside it (none, for `""`)."""
    if word[:1] not in ('"', "$", "`"):      # most words: not an expansion from the start
        return None
    lx = _Lexer(word, roles=False)
    n, i, group, out = len(word), 0, None, []
    try:
        while i < n:
            c = word[i]
            if c == '"':
                if group is None:
                    group = []
                else:
                    out.append((True, group))
                    group = None
                i += 1
                continue
            in_dq = group is not None
            if c == "`":
                j = lx.backtick(i, [], in_dq)
            elif c == "$":
                nxt = word[i + 1:i + 2]
                if nxt.isascii() and (nxt.isalpha() or nxt == "_"):
                    j = i + 2
                    while j < n and word[j].isascii() and (word[j].isalnum() or word[j] == "_"):
                        j += 1
                elif nxt and nxt in "({[@*#?-$!0123456789":
                    j = lx.dollar_or_backtick(i, [], in_dq)
                else:
                    return None
            else:
                return None
            if in_dq:
                group.append(word[i:j])
            else:
                out.append((False, [word[i:j]]))
            i = j
    except ShellLexError:
        return None
    return None if group is not None or not out else out


def expansion_only(word: str) -> bool:
    """Whether WORD (a token's text) is nothing but expansions.  At a command
    position such a word may hold a wrapper or nothing at all, so the word
    after it is the one that ends up run: `$TIMEOUT cmd`, `"${wrap[@]}" cmd`."""
    groups = _expansions(word)
    return bool(groups) and any(texts for _, texts in groups)


def may_vanish(word: str) -> bool:
    """Whether WORD can expand to no word at all, as bash expands it
    (measured, bash 5.2): it is nothing but expansions, none of them always
    has a value, and each pair of double quotes holds a list expansion --
    `"$@"`, `"${a[@]}"`, and `"$x$@"` too.  A quoted scalar cannot vanish:
    `"$empty" cmd` runs a command named '' with cmd as its argument."""
    groups = _expansions(word)
    if not groups:
        return False
    for quoted, texts in groups:
        if quoted and not any(_LIST_EXPANSION.match(t) for t in texts):
            return False
        if any(_ALWAYS_VALUED.match(t) for t in texts):
            return False
    return True


def _is_assignment(word: str) -> bool:
    return assignment_split(word) is not None


def _is_array_assign(prefix: str) -> bool:
    return prefix.endswith("=") and _is_assignment(prefix)


def tokenize(text: str) -> list[Token]:
    return scan(text)[0]


def scan(text: str):
    """(tokens, comment spans, here-document body spans) for whole text."""
    return scan_full(text)[:3]


def scan_full(text: str):
    """scan() plus the sorted offsets of every $( / <( / >( whose body was
    recorded, at any depth (for the oracle's O6)."""
    lx = _Lexer(text)
    body = _Body(lx, 0, closer=None)
    body.run()
    untaken = sorted(p for p in lx.skips if p not in lx.skips_taken and p < lx.n)
    if untaken:
        # the line a substitution's here-document was read after ends inside a
        # quoted string or another multi-line word: not modelled, so stop
        # (tokenize_file turns this into a refusal, never a silent misread)
        lx.err("a here-document opened inside a substitution that closes first is "
               "read from inside a multi-line word", untaken[0])
    return body.tokens, sorted(lx.comments), sorted(lx.heredocs), sorted(set(lx.openers))


# ------------------------------------------------------------- consumers' API

def tokenize_prefix(text: str) -> list[Token]:
    """tokenize(), or -- for text the shell rejects -- the tokens of the text
    before the line where tokenizing stopped.  bash executes the commands it
    parsed before a syntax error, so that prefix is what the text runs."""
    while True:
        try:
            return tokenize(text)
        except ShellLexError as e:
            cut = 0
            for _ in range(e.line - 1):
                cut = text.index("\n", cut) + 1
            if cut <= 0:
                return []
            text = text[:cut]


class TokenizerGap(RuntimeError):
    """The tokenizer stopped early on a whole file the shell accepts: a gate
    reading only the prefix would check less without saying so."""


# Test seam, like EIGS_PLAN_PLANT: a whole file holding this marker is treated
# as if the tokenizer stopped there, so a gate's refusal can be shown red.
_GAP_PLANT = "SHELL_TOKENS_PLANT_GAP"


def tokenize_file(text: str, name: str, *, effects=False) -> list[Token]:
    """Tokens of a WHOLE tracked file, for a gate.  Text the shell rejects too
    is read up to the line where tokenizing stopped (tokenize_prefix); text
    `bash -n` accepts but the tokenizer stops on raises TokenizerGap naming
    the file and line, so the gate fails instead of passing on a prefix."""
    import os
    marker = os.environ.get(_GAP_PLANT)
    try:
        if marker and marker in text:
            line = text[:text.index(marker)].count("\n") + 1
            raise ShellLexError(f"planted gap ({_GAP_PLANT})", line)
        return runtime_substitutions(tokenize(text)) if effects else tokenize(text)
    except ShellLexError as e:
        if _bash_accepts(text):
            raise TokenizerGap(f"{name}:{e.line}: the shell tokenizer stopped ({e.reason}) "
                               "on a file `bash -n` accepts; everything after that line "
                               "would go unread") from None
        return runtime_substitutions(tokenize_prefix(text)) if effects else tokenize_prefix(text)


def _bash_accepts(text: str) -> bool:
    import shutil
    import subprocess
    bash = shutil.which("bash")
    if bash is None:
        return True          # cannot confirm the shell rejects it: refuse to read a prefix
    r = subprocess.run([bash, "--norc", "--noprofile", "-n"], input=text.encode(
        errors="surrogateescape"), capture_output=True, env={"PATH": "", "LC_ALL": "C"},
        timeout=60)
    return r.returncode == 0


def parsed_prefix(text: str):
    """logical_lines() over tokenize_prefix(text)."""
    return _group_lines(tokenize_prefix(text))


def logical_lines(text: str):
    """Yield (line, [tokens]) per top-level newline-terminated command line.

    Comments, line continuations and here-document bodies are gone; a quoted
    string or substitution spanning several physical lines stays in the
    line it started on."""
    return _group_lines(tokenize(text))


def _group_lines(tokens):
    group: list[Token] = []
    for tok in tokens:
        if tok.kind == "newline":
            if group:
                yield group[0].line, group
            group = []
            continue
        group.append(tok)
    if group:
        yield group[0].line, group


def simple_commands(tokens):
    """Split a token list into simple commands: lists of WORD tokens, with
    redirections (and each redirection's target word) removed."""
    out: list[list[Token]] = []
    cur: list[Token] = []
    skip_target = False
    for tok in tokens:
        if tok.kind == "redir":
            skip_target = True
            continue
        if tok.kind == "word":
            if skip_target:
                skip_target = False
                continue
            cur.append(tok)
            continue
        skip_target = False
        if cur:
            out.append(cur)
        cur = []
    if cur:
        out.append(cur)
    return out


_ANSI = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
         "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
         "'": "'", '"': '"', "?": "?"}


_NOTHING_TO_UNQUOTE = re.compile(r"[^'\"\\$`]*\Z")


def unquote(word: str, expansions: list | None = None) -> str:
    """Quote removal (POSIX 2.6.7) with expansions left as literal text.
    Given a list EXPANSIONS, each expansion is appended to it and left OUT of
    the result instead (see emptied())."""
    if _NOTHING_TO_UNQUOTE.match(word):      # most words: nothing to remove
        return word
    if expansions is None:
        return _unquoted(word)
    return _unquote(word, expansions)


@functools.lru_cache(maxsize=65536)
def _unquoted(word: str) -> str:
    """unquote() of a word, remembered: the readers ask about the same words
    once for each reading of a command."""
    return _unquote(word, None)


def _unquote(word: str, expansions: list | None) -> str:
    out = []
    i, n = 0, len(word)
    while i < n:
        c = word[i]
        if c == "'":
            j = word.find("'", i + 1)
            j = n if j < 0 else j
            out.append(word[i + 1:j])
            i = j + 1
        elif c == "$" and word[i + 1:i + 2] == "'":
            j = i + 2
            seg = []
            while j < n and word[j] != "'":
                if word[j] == "\\" and j + 1 < n:
                    text, j = _ansi_escape(word, j)
                    seg.append(text)
                    continue
                seg.append(word[j])
                j += 1
            seg_text = "".join(seg)
            nul = seg_text.find("\0")         # bash ends this $'...' part at a NUL
            out.append(seg_text if nul < 0 else seg_text[:nul])
            i = j + 1
        elif c == '"' or (c == "$" and word[i + 1:i + 2] == '"'):
            j = i + (2 if c == "$" else 1)
            while j < n and word[j] != '"':
                if word[j] == "\\" and j + 1 < n and word[j + 1] in '$`"\\\n':
                    if word[j + 1] != "\n":
                        out.append(word[j + 1])
                    j += 2
                    continue
                if word[j] in "$`":
                    if expansions is None:
                        k = _skip_expansion(word, j)
                        out.append(word[j:k])
                    else:
                        k = _expansion_end(word, j, in_double=True)
                        (expansions if k > j + 1 else out).append(Expansion(word[j:k], True, j))
                    j = k
                    continue
                out.append(word[j])
                j += 1
            i = j + 1
        elif c == "\\" and i + 1 < n:
            if word[i + 1] != "\n":
                out.append(word[i + 1])
            i += 2
        elif c in "$`":
            if expansions is None:
                k = _skip_expansion(word, i)
                out.append(word[i:k])
            else:
                k = _expansion_end(word, i)
                (expansions if k > i + 1 else out).append(Expansion(word[i:k], False, i))
            i = k
        else:
            out.append(c)
            i += 1
    return "".join(out)


@functools.lru_cache(maxsize=65536)
def emptied(word: str):
    """WORD (a token's text) after quote removal with every expansion taken
    as empty: what bash runs it as when they all expand to nothing --
    `${TMO:+$TMO }cmd`, `$(Q)cmd`, `cmd${EXE}` are `cmd`.  None when the word
    has no expansion, or one that always has a value (`$?`, `${#v}`,
    arithmetic): then there is no such reading."""
    if "$" not in word and "`" not in word:  # most words: no expansion to empty
        return None
    found: list = []
    text = unquote(word, found)
    if not found or any(_ALWAYS_VALUED.match(x) for x in found):
        return None
    return text


def _byte(b: int) -> str:
    """A byte as str: ASCII as itself, others as surrogate escapes (so they
    encode back to the same byte, as bash emits it)."""
    b &= 0xFF
    return chr(b) if b < 0x80 else chr(0xDC00 + b)


def _ansi_escape(word: str, j: int) -> tuple[str, int]:
    """Decode the escape at word[j] (a backslash) inside $'...' as bash 5.2
    does.  Never raises: an escape bash leaves alone stays literal."""
    n = len(word)
    e = word[j + 1]
    if e in _ANSI:
        return _ANSI[e], j + 2
    if e in "01234567":
        k = j + 1
        while k < n and k < j + 4 and word[k] in "01234567":
            k += 1
        return _byte(int(word[j + 1:k], 8)), k
    hexd = "0123456789abcdefABCDEF"
    if e == "x" and word[j + 2:j + 3] == "{":
        close = word.find("}", j + 3)
        digits = word[j + 3:close] if close > 0 else ""
        if digits and all(c in hexd for c in digits):
            return _byte(int(digits, 16)), close + 1
        return word[j:j + 2], j + 2
    if e in "xuU":
        width = {"x": 2, "u": 4, "U": 8}[e]
        k = j + 2
        while k < n and k < j + 2 + width and word[k] in hexd:
            k += 1
        if k == j + 2:
            return word[j:j + 2], j + 2
        value = int(word[j + 2:k], 16)
        if e == "x":
            return _byte(value), k
        if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
            return word[j:k], k               # not a character: kept as written
        return chr(value), k
    if e == "c":
        if j + 2 >= n or word[j + 2] == "'":
            return "\\c", j + 2                # `\c` with nothing after it
        x = word[j + 2]
        if x == "\\" and word[j + 3:j + 4] == "\\":
            return "\x1c", j + 4
        if x == "?":
            return "\x7f", j + 3
        return _byte(ord(x.upper()) & 0x1F) if ord(x) < 0x80 else x, j + 3
    return word[j:j + 2], j + 2


def _expansion_end(word: str, i: int, in_double: bool = False) -> int:
    """End of the expansion at word[i] -- `$name`, `$1`, `$@`, `${..}`,
    `$(..)`, `$((..))`, `$[..]`, `` `..` `` -- or i + 1 where the `$` starts
    none."""
    n = len(word)
    nxt = word[i + 1:i + 2]
    if word[i] == "`" or nxt in ("(", "{", "["):
        try:
            return _Lexer(word, roles=False).dollar_or_backtick(i, [], in_double)
        except ShellLexError:
            return n
    if nxt.isascii() and (nxt.isalpha() or nxt == "_"):
        j = i + 2
        while j < n and word[j].isascii() and (word[j].isalnum() or word[j] == "_"):
            j += 1
        return j
    if nxt and nxt in "@*#?-$!0123456789":
        return i + 2
    return i + 1


def _skip_expansion(word: str, i: int) -> int:
    """End of the expansion at word[i] ($(..), ${..}, `..`), kept literal."""
    lx = _Lexer(word, roles=False)
    try:
        return lx.dollar_or_backtick(i, [], in_double=False) if word[i] == "`" or \
            word[i + 1:i + 2] in ("(", "{") else i + 1
    except ShellLexError:
        return len(word)


def function_definitions(tokens):
    """Names of the shell functions TOKENS define at their own level:
    `name ( )` or `function name` where the name is the first word of a
    command.  A definition inside a here-document, a quoted string, a comment
    or a $(...) body (a subshell) is not one."""
    names = []
    prev = None
    depth = 0                         # open ( ) subshells
    for i, tok in enumerate(tokens):
        if tok.kind == "op" and tok.text in ("(", ")"):
            nxt = tokens[i + 1] if i + 1 < len(tokens) else None
            fn_parens = (tok.text == "(" and prev is not None and prev.kind == "word"
                         and nxt is not None and nxt.text == ")") or \
                        (tok.text == ")" and prev is not None and prev.text == "(")
            pattern = (tok.text == "(" and nxt is not None and nxt.kind == "pattern") or \
                      (tok.text == ")" and prev is not None and prev.kind == "pattern")
            if not fn_parens and not pattern:
                depth += 1 if tok.text == "(" else -1
                depth = max(depth, 0)
        closes_pattern = prev is not None and prev.text == ")" and i >= 2 \
            and tokens[i - 2].kind == "pattern"
        at_start = prev is None or prev.kind in ("op", "newline") and prev.text != ")" \
            or closes_pattern \
            or (prev.kind == "word" and prev.text in RESERVED_OPENERS)
        if tok.kind == "word" and at_start and depth == 0:
            nxt = tokens[i + 1:i + 3]
            if tok.text == "function" and nxt and nxt[0].kind == "word" \
                    and _plain_name(nxt[0].text):
                names.append(nxt[0].text)
            elif len(nxt) == 2 and nxt[0].kind == "op" and nxt[0].text == "(" \
                    and nxt[1].kind == "op" and nxt[1].text == ")" and _plain_name(tok.text):
                names.append(tok.text)
        prev = tok
    return names


def _plain_name(word: str) -> bool:
    return bool(word) and not any(c in word for c in "'\"\\$`=/") and not word[0].isdigit()

# Variable effects are a tokenizer API, so consumers never parse ${...} or
# arithmetic/expanded here-document text themselves. Offsets are source-relative.
class Expansion(ShellText):
    def __new__(cls, value, quoted=False, start=0):
        obj = super().__new__(cls, value)
        obj.quoted, obj.start = quoted, start
        obj.quoted_substitution = getattr(value, 'quoted_substitution', False)
        return obj


_IDENT = re.compile(r'[a-zA-Z_][a-zA-Z_0-9]*')


_PARAMETER_OPERATORS = (':-', ':=', ':+', ':?', '##', '%%', '//', '^^', ',,',
                        '-', '=', '+', '?', '#', '%', '/', '^', ',', ':', '@')
_POSITIONAL_OR_SPECIAL = re.compile(r'[0-9]+|[@*#?$!-]')


def parameter_parts(expansion):
    """(name, operator, operand, operand offset, subscript, indirect/length).
    EXPANSION is one ${...} supplied by unquote(), not arbitrary shell text.
    """
    body = expansion[2:-1]
    prefix = body[:1] if body[:1] in ('!', '#') and len(body) > 1 else ''
    pos = len(prefix)
    match = _IDENT.match(body, pos)
    if not match:
        # Positional and special parameters (${1:-$X}, ${@:$N}) carry no
        # name to check, but their operator operands are still expanded.
        special = _POSITIONAL_OR_SPECIAL.match(body, pos)
        if not special and prefix:     # ${#:+x}, ${!:-x}: the prefix is the parameter
            prefix, pos = '', 0
            special = _POSITIONAL_OR_SPECIAL.match(body, pos)
        if not special:
            return '', '', '', 2, '', prefix
        pos = special.end()
        tail = body[pos:]
        op = next((o for o in _PARAMETER_OPERATORS if tail.startswith(o)), '')
        return '', op, tail[len(op):], 2 + pos + len(op), '', prefix
    name, pos = match.group(), match.end()
    sub = ''
    if body[pos:pos + 1] == '[':
        end = _Lexer(body, roles=False).match_subscript(pos, [])
        if end:
            sub, pos = body[pos + 1:end - 1], end
    tail = body[pos:]
    op = next((o for o in _PARAMETER_OPERATORS if tail.startswith(o)), '')
    # ${!prefix*} and ${!prefix@} enumerate names, not prefix's value.
    if prefix == '!' and tail in ('*', '@'):
        name = ''
    return name, op, tail[len(op):], 2 + pos + len(op), sub, prefix


def expanded_expressions(text):
    """Expansions where quotes are literal (heredocs and arithmetic).
    Also return escaped literal atoms, used only by the arithmetic reader.
    Nested command/parameter boundaries use the shared lexer, not delimiters.
    """
    found, escaped = [], []
    i = 0
    while i < len(text):
        if text[i] == "\\":
            nxt = text[i + 1:i + 2]
            if nxt in ('$', '`'):
                escaped.append((i, _expansion_end(text, i + 1, in_double=True)))
            elif _IDENT.match(text, i + 1):
                escaped.append((i, _IDENT.match(text, i + 1).end()))
            i += 2; continue
        if text[i] in '$`' and text[i:i + 2] not in ("$'", '$"'):
            end = _expansion_end(text, i, in_double=True)
            if end > i + 1:
                found.append(Expansion(text[i:end], True, i))
                i = end; continue
        i += 1
    return found, escaped


def arithmetic_source(text):
    """ANSI quote removal during arithmetic parsing in a quoted $(...).
    Return cooked text and source offsets. Nested expansions keep their own
    boundaries and are processed by expansion_effects, not by this pass.
    """
    if not getattr(text, 'quoted_substitution', False):
        return text, list(range(len(text)))
    out, origins, i = [], [], 0
    lx = _Lexer(text, roles=False)
    while i < len(text):
        if text.startswith("$'", i):
            end = lx.ansi_c(i)
            cooked = unquote(text[i:end])
            out.append(cooked)
            positions, k = [], i + 2
            while k < end - 1:
                decoded, stop = _ansi_escape(text, k) if text[k] == "\\" else (text[k], k + 1)
                positions.extend([k] * len(decoded)); k = stop
            origins.extend(positions[:len(cooked)])
        else:
            end = i + 2 if text[i] == "\\" else (_expansion_end(text, i, True) if text[i] in '$`' else i + 1)
            end = min(end, len(text))
            out.append(text[i:end]); origins.extend(range(i, end))
        i = end
    return ShellText(''.join(out), True), origins


_ASSOCIATIVES = ContextVar('shell_associative_arrays', default=frozenset())


@contextmanager
def array_context(names):
    """Supply derived Bash/source array attributes to variable-effect APIs."""
    token = _ASSOCIATIVES.set(frozenset(names))
    try:
        yield
    finally:
        _ASSOCIATIVES.reset(token)


@functools.lru_cache(maxsize=8192)
def assignment_indices(word):
    """Source spans of actual lvalue indices, including compound array entries.
    The existing array lexer identifies element boundaries and quoted literals;
    a data word such as '[NAME]=text' never becomes a designator after unquote.
    """
    pair = assignment_split(word)
    if not pair:
        return ()
    name, value = pair
    lexer = _Lexer(word, roles=False)
    result = []
    if word[len(name):len(name) + 1] == '[':
        close = lexer.match_subscript(len(name), [])
        result.append((len(name) + 1, close - 1))
    start = len(word) - len(value)
    if value.startswith('('):
        lexer.paren_group(start + 1, [], start, array=True)
        result.extend((a, b) for opener, a, b in lexer.array_indices if opener == start)
    return tuple(result)


def index_effects(word, start, end):
    """Explicit expansions in assignment indices; bare index names are ignored."""
    name, value = assignment_split(word)
    index = word[start:end]
    compound = value.startswith('(') and start > len(word) - len(value)
    if name in _ASSOCIATIVES.get():
        if not compound:
            index, _ = arithmetic_source(index)
        return variable_effects(index)
    if compound:
        reads, sets = variable_effects(ShellText(unquote(index), False), expanded=True)
        return [(n, max(0, index.find(n))) for n, _ in reads], sets
    return variable_effects(ShellText(index, False), expanded=True)

def arithmetic_indices(text):
    """Bare array-reference indices in arithmetic, outside opaque expansions
    and literal single-quoted arithmetic text. Boundaries use match_subscript.
    """
    if '[' not in text:
        return []
    found, escaped = expanded_expressions(text)
    chars = list(text)
    for a, b in escaped + [(e.start, e.start + len(e)) for e in found]:
        chars[a:b] = [' '] * (b - a)
    masked = ''.join(chars)
    i, result = 0, []
    while i < len(masked):
        if masked[i] == "'":
            i = _Lexer(masked, roles=False).single(i); continue
        match = _IDENT.match(masked, i)
        if not match:
            i += 1; continue
        end = match.end()
        while end < len(text) and text[end].isspace():
            end += 1
        if text[end:end + 1] == '[':
            close = _Lexer(text, roles=False).match_subscript(end, [])
            if close:
                result.append((match.group(), end + 1, close - 1)); i = close; continue
        i = match.end()
    return result

def arithmetic_effects(text):
    """Shell expansion first, then arithmetic identifiers and lvalues.
    Command bodies stay opaque; Token.subst owns their independent reading.
    Single quotes survive expansion as literal arithmetic characters, while
    shell double quotes are removed by unquote(). Source offsets are retained.
    """
    text, source_origins = arithmetic_source(text)
    extra_reads, extra_sets = [], set()
    chars = list(text)
    for name, a, b in arithmetic_indices(text):
        if name in _ASSOCIATIVES.get():
            r, st = variable_effects(text[a:b])
            extra_reads.extend((n, a + pos) for n, pos in r); extra_sets.update(st)
            chars[a:b] = ['\n' if c == '\n' else ' ' for c in chars[a:b]]
    text = ShellText(''.join(chars), getattr(text, 'quoted_substitution', False))
    found, escaped = expanded_expressions(text)
    chars = list(text)
    for start, end in escaped + [(e.start, e.start + len(e)) for e in found]:
        chars[start:end] = ['\n' if c == '\n' else ' ' for c in chars[start:end]]
    masked = ''.join(chars)
    single = []
    i = 0
    while i < len(masked):
        if masked[i] == "'":
            end = _Lexer(masked, roles=False).single(i)
            single.append((i, end)); i = end
        else:
            i += 1
    reads, sets = extra_reads, extra_sets
    for exp in found:
        quoted = any(a < exp.start < b for a, b in single)
        r, s = expansion_effects(exp, arithmetic=not quoted)
        reads.extend((n, exp.start + p) for n, p in r); sets.update(s)
    for start, end in single:
        chars[start:end] = ['\n' if c == '\n' else ' ' for c in chars[start:end]]
    masked = ''.join(chars)
    literal = unquote(masked)
    origins, cursor = [], 0
    # Quote removal here only deletes punctuation: all identifier characters
    # are unchanged, so their earliest subsequence origin is exact.
    for char in literal:
        cursor = masked.index(char, cursor)
        origins.append(cursor); cursor += 1
    i = 0
    while i < len(literal):
        if literal[i] in "'\"":
            lx = _Lexer(literal, roles=False)
            i = lx.single(i) if literal[i] == "'" else lx.double(i, [])
            continue
        if literal[i].isdigit():
            m = re.match(r'[0-9][a-zA-Z0-9_#@]*', literal[i:])
            i += len(m.group()); continue
        m = _IDENT.match(literal, i)
        if not m:
            i += 1; continue
        name, end = m.group(), m.end()
        after = literal[end:].lstrip()
        if after.startswith('['):
            opening = end + len(literal[end:]) - len(after)
            close = _Lexer(literal, roles=False).match_subscript(opening, [])
            if close:
                r, s = (variable_effects(literal[opening + 1:close - 1]) if name in _ASSOCIATIVES.get() else arithmetic_effects(literal[opening + 1:close - 1]))
                reads.extend((n, origins[opening + 1 + pos]) for n, pos in r); sets.update(s)
                after = literal[close:].lstrip(); end = close
        assign = re.match(r'(?:<<|>>|[+*/%&^|\-])?=(?!=)', after)
        increment = after.startswith(('++', '--')) or literal[:i].rstrip().endswith(('++', '--'))
        if assign or increment:
            sets.add(name)
        if not assign or assign.group() != '=':
            reads.append((name, origins[i]))
        i = end
    return [(n, source_origins[p]) for n, p in reads], sets


def expansion_effects(expansion, *, arithmetic=False):
    """Variable reads and setters of ONE expansion from unquote().
    Default/alternate/assignment operators exempt their parameter, while their
    operands are still visited. Pattern and substring operands expand too.
    """
    exp = expansion
    if exp.startswith('${'):
        name, op, operand, offset, sub, prefix = parameter_parts(exp)
        safe = op in (':-', '-', ':=', '=', ':+', '+')
        reads = [(name, 2 + len(prefix))] if name and not safe else []
        sets = {name} if name and op in (':=', '=') else set()
        if sub and sub not in ('@', '*'):
            r, s = (arithmetic_effects(ShellText(sub, False)) if arithmetic and name not in _ASSOCIATIVES.get()
                    else variable_effects(sub, expanded=name not in _ASSOCIATIVES.get()))
            reads.extend((n, 2 + len(name) + p) for n, p in r); sets.update(s)
        # Single quotes are literal in a default operand inside double quotes;
        # pattern operators instead retain normal quote removal (parse.y).
        quoted = getattr(expansion, 'quoted', False) and op in (':-', '-', ':=', '=', ':+', '+', ':?', '?')
        if arithmetic and (safe or op == ':'):
            r, s = arithmetic_effects(operand)
        else:
            r, s = variable_effects(operand, expanded=quoted or op == ':')
        reads.extend((n, offset + p) for n, p in r); sets.update(s)
        return reads, sets
    if exp.startswith('$((') and _Lexer(exp, roles=False).arith_closes(3):
        reads, sets = arithmetic_effects(ShellText(exp[3:-2], getattr(exp, 'quoted_substitution', False) and not exp.quoted))
        return [(name, pos + 3) for name, pos in reads], sets
    if exp.startswith('$['):
        reads, sets = variable_effects(exp[2:-1], expanded=True)
        return [(name, pos + 2) for name, pos in reads], sets
    if exp.startswith('$') and _IDENT.fullmatch(exp[1:]):
        return [(exp[1:], 1)], set()
    return [], set()                 # command bodies come from Token.subst


def variable_effects(word, *, expanded=False, arithmetic=False, assignment=False):
    """(reads, setters) for explicit expansions or a $(( )) / (( )) body.
    expanded=True means here-document quoting: quotes are literal and only
    backslash before $, backtick, backslash or newline suppresses expansion.
    Command bodies are deliberately left to the consumer's Token.subst walk.
    """
    if arithmetic:
        return arithmetic_effects(word)
    extra, assigned = [], set()
    pair = assignment_split(word) if assignment else None
    indices = assignment_indices(word) if pair else ()
    if indices:
        chars = list(word)
        for start, end in indices:
            r, st = index_effects(word, start, end)
            extra.extend((n, start + pos) for n, pos in r); assigned.update(st)
            chars[start:end] = ['\n' if c == '\n' else ' ' for c in chars[start:end]]
        word = ShellText(''.join(chars), getattr(word, 'quoted_substitution', False))
    if '$' not in word and '`' not in word:
        return extra, assigned
    found = []
    if expanded:
        found, _ = expanded_expressions(word)
    else:
        # Process substitutions are shell bodies, not ordinary word text.
        # Reuse the lexer's recorded openers and matching reader; masking
        # preserves offsets while leaving their reads to Token.subst recursion.
        if '<(' in word or '>(' in word:
            lx = _Lexer(word, roles=False)
            for opener in scan_full(word)[3]:
                if word[opener:opener + 2] in ('<(', '>('):
                    end = lx.procsub(opener + 2, [], opener)
                    word = word[:opener] + 'x' * (end - opener) + word[end:]
        unquote(word, found)
    reads, sets = extra, assigned
    for exp in found:
        r, s = expansion_effects(exp)
        reads.extend((n, exp.start + p) for n, p in r); sets.update(s)
    return reads, sets


def setter_targets(command):
    """Builtin operands only, from a simple command's command/argument roles."""
    operands = [t for t in command if t.role in ('command', 'argument')]
    names = set()
    for i, token in enumerate(operands):
        if token.role == 'command':
            words = [unquote(t.text) for t in operands[i:]]
            names.update(_setter_operands(words[:]))
            empty = emptied(token.text)
            if empty is not None:
                names.update(_setter_operands([empty, *words[1:]]))
    return names


def _setter_operands(words):
    while words and words[0] in ('builtin', 'command'):
        wrapper = words.pop(0)
        if wrapper == 'command' and words and words[0] in ('-v', '-V'):
            return set()
        if wrapper == 'command' and words and words[0] == '-p':
            words.pop(0)
        if words and words[0] == '--':
            words.pop(0)
    if not words:
        return set()
    cmd, args = words[0], words[1:]
    names = set()
    if cmd in ('export', 'local', 'declare', 'typeset', 'readonly'):
        parsed = declaration_options(words)
        if parsed is None:
            return names
        options, args = parsed
        nonsetting = 'pfF' if cmd in ('declare', 'local', 'typeset') else 'fF'
        if any(c in options for c in nonsetting):
            return names
        for arg in args:
            pair = assignment_split(arg)
            if pair:
                names.add(pair[0])
    elif cmd in ('read', 'mapfile', 'readarray'):
        operands, array_target, poll_only = [], None, False
        takes_value = 'adinNptu' if cmd == 'read' else 'dnOsuCc'
        flags = 'ers' if cmd == 'read' else 't'
        i = 0
        while i < len(args):
            arg = args[i]; i += 1
            if arg == '--':
                operands.extend(args[i:]); break
            if not arg.startswith('-') or arg == '-':
                operands.append(arg); continue
            for pos, option in enumerate(arg[1:], 2):
                if option in takes_value:
                    value = arg[pos:]
                    if not value:
                        if i >= len(args):
                            return set()
                        value = args[i]; i += 1
                    if cmd == 'read' and option == 'a':
                        array_target = value
                    if cmd == 'read' and option == 't':
                        try:
                            poll_only = float(value) == 0
                        except ValueError:
                            pass        # a non-numeric -t is bash's usage error, not a poll
                    break
                if option not in flags:
                    return set()
        if poll_only:
            return set()
        if cmd == 'read':
            # -a ignores the other destination operands (bash read.def).
            names.update(operands if array_target is None else [array_target])
        else:
            names.update(operands[:1])
    elif cmd == 'printf':
        target, i = None, 0
        while i < len(args):
            arg = args[i]; i += 1
            if arg == '--':
                break
            if not arg.startswith('-') or arg == '-':
                i -= 1; break
            if not arg.startswith('-v'):
                return set()
            target = arg[2:]
            if not target:
                if i >= len(args):
                    return set()
                target = args[i]; i += 1
        if target is not None and i < len(args):
            names.add(target)
    elif cmd == 'getopts':
        names.update(args[1:2])
    elif cmd == 'let':
        for arg in args:
            names.update(_literal_arithmetic_effects(arg)[1])
    return {n for n in names if not n.endswith('+')
            and (_IDENT.fullmatch(n) or cmd in ('read', 'printf'))
            and (pair := assignment_split(n + '=')) and pair[1] == ''}


def setter_names(command):
    """Variable bases genuinely assigned by builtin operands, from roles."""
    return {assignment_split(target + '=')[0] for target in setter_targets(command)}


def _literal_arithmetic_effects(text):
    """After shell quote removal, literal dollars/backquotes do not expand again."""
    chars = list(text)
    found, _ = expanded_expressions(text)
    indices = arithmetic_indices(text)
    for exp in found:
        if not any(a <= exp.start < b for _, a, b in indices):
            chars[exp.start:exp.start + len(exp)] = [' '] * len(exp)
    if ''.join(chars).lstrip().startswith('['):
        return [], set()
    return arithmetic_effects(''.join(chars))


def _builtin_readings(command):
    return _cached_builtin_readings(tuple((t.role, t.text) for t in command if t.role in ('command', 'argument')))


@functools.lru_cache(maxsize=8192)
def _cached_builtin_readings(operands):
    # Pure role/quote-removal result, independent of type attributes and lines.
    words = [unquote(text) for _, text in operands]
    result = []
    for i, (role, text) in enumerate(operands):
        if role != 'command':
            continue
        for first in (words[i], emptied(text)):
            if first is None:
                continue
            rest = [first, *words[i + 1:]]
            while rest and rest[0] in ('builtin', 'command'):
                wrapper = rest.pop(0)
                if wrapper == 'command' and rest and rest[0] in ('-v', '-V'):
                    rest = []; break
                if wrapper == 'command' and rest and rest[0] == '-p':
                    rest.pop(0)
                if rest and rest[0] == '--':
                    rest.pop(0)
            if rest:
                result.append(tuple(rest))


    return tuple(result)


def declaration_options(words):
    """Validated prefix options and operands of the variable declarations."""
    if not words:
        return None
    cmd, args = words[0], words[1:]
    flags = ('aAfFgiIlnrtuxp' if cmd in ('declare', 'local', 'typeset') else
             'aAfp' if cmd == 'readonly' else 'fnp' if cmd == 'export' else '')
    if not flags:
        return None
    active, i = set(), 0
    while i < len(args) and args[i].startswith(('-', '+')) and args[i] not in ('-', '+'):
        option = args[i]; i += 1
        if option == '--':
            break
        if any(c not in flags for c in option[1:]):
            return None
        if option[0] == '-':
            active.update(option[1:])
        else:
            active.difference_update(option[1:])
    return active, args[i:]


def declared_attributes(tokens, attribute):
    result = set()
    for command in simple_commands(tokens):
        for words in _builtin_readings(command):
            parsed = declaration_options(words)
            if parsed is None:
                continue
            options, args = parsed
            if attribute in options and not options.intersection('pfF'):
                for arg in args:
                    pair = assignment_split(arg)
                    name = pair[0] if pair else arg
                    if _IDENT.fullmatch(name):
                        result.add(name)
    return result


def associative_declarations(tokens):
    return declared_attributes(tokens, 'A')


def assignment_words(tokens):
    for token in tokens:
        if token.role == 'assignment':
            yield token, token.text
    for command in simple_commands(tokens):
        declarations = False
        for words in _builtin_readings(command):
            parsed = declaration_options(words)
            if parsed is not None:
                options, _ = parsed
                nonsetting = 'pfF' if words[0] in ('declare', 'local', 'typeset') else 'fF'
                declarations |= not any(c in options for c in nonsetting)
        if declarations:
            for token in command:
                if token.role == 'argument':
                    word = token.text if assignment_split(token.text) else unquote(token.text)
                    if assignment_split(word):
                        yield token, word


def implicit_arithmetic_effects(tokens):
    """Explicit expansions in declaration/builtin indices after quote removal.
    Retained from the implicit reader for dollar reads only: bare names in
    these indices, numeric tests, integer values and let are not read here.
    """
    for token, word in assignment_words(tokens):
        if word == token.text:
            continue  # ordinary word expansion is already read by the consumer
        for start, end in assignment_indices(word):
            refs, sets = index_effects(word, start, end)
            if refs or sets:
                yield token, [(n, max(0, token.text.find(n))) for n, _ in refs], sets
    for command in simple_commands(tokens):
        for target in setter_targets(command):
            if '[' not in target:
                continue
            token = next((t for t in command if target in unquote(t.text)), None)
            if token is not None:
                refs, sets = variable_effects(target + '=', assignment=True)
                normal, _ = variable_effects(token.text)
                extra = [(n, max(0, token.text.find(n))) for n, _ in refs
                         if n not in {name for name, _ in normal}]
                if extra or sets:
                    yield token, extra, sets


def word_substitutions(word):
    found, bodies = [], []
    unquote(word, found)
    lexer = _Lexer(word, roles=False)
    for exp in found:
        lexer.dollar_or_backtick(exp.start, bodies, getattr(exp, 'quoted', False))
    return bodies


def runtime_substitutions(tokens):
    """Complete Token.subst from role-derived lvalue and parameter indices.
    Indexed keys expand as arithmetic; associative keys retain shell quoting.
    Bodies that exist only in the former carry a type guard for consumers.
    """
    if not any('[' in t.text or "$'" in t.text for t in tokens if t.kind == 'word'):
        return tokens
    indices = {}
    def target(token, word):
        pair = assignment_split(word)
        if pair:
            indices.setdefault(token.start, []).extend((pair[0], word[a:b], word == token.text) for a, b in assignment_indices(word))
    for token, word in assignment_words(tokens):
        target(token, word)
    for command in simple_commands(tokens):
        if any(w[0] in ('read', 'printf') for w in _builtin_readings(command)):
            for name in setter_targets(command):
                if '[' in name:
                    token = next((t for t in command if name in unquote(t.text)), None)
                    if token is not None:
                        target(token, name + '=')
    for token in tokens:
        if token.kind != 'word' or '${' not in token.text or '[' not in token.text:
            continue
        found = []; unquote(token.text, found)
        for exp in found:
            if exp.startswith('${'):
                name, _, _, _, sub, _ = parameter_parts(exp)
                if sub and sub not in ('@', '*'):
                    indices.setdefault(token.start, []).append((name, sub, True))
    if not indices:
        return tokens
    from collections import Counter
    result = []
    for token in tokens:
        bodies = list(token.subst)
        used = Counter()
        for name, index, guard_existing in indices.get(token.start, ()):
            math = []
            lexer = _Lexer(ShellText(index, False), roles=False)
            lexer.expanded_in_quotes(0, len(index), math, 0)
            ordinary = Counter(map(str, word_substitutions(index)))
            for body in math:
                matching = [i for i, old in enumerate(bodies) if str(old) == str(body)]
                pos = matching[used[str(body)]] if used[str(body)] < len(matching) else None
                guarded = not ordinary[str(body)] and (pos is None or guard_existing)
                if ordinary[str(body)]:
                    ordinary[str(body)] -= 1
                if pos is None:
                    body = ShellText(body, getattr(body, 'quoted_substitution', False))
                    bodies.append(body)
                else:
                    body = bodies[pos]
                if guarded:
                    body = ShellText(body, getattr(body, 'quoted_substitution', False), getattr(body, 'source_line', None))
                    body.array_guard = name
                    if pos is None:
                        bodies[-1] = body
                    else:
                        bodies[pos] = body
                used[str(body)] += 1
        result.append(token._replace(subst=tuple(bodies)))
    return result


# Public role-derived command readings, shared with literal source consumers.
builtin_readings = _builtin_readings
