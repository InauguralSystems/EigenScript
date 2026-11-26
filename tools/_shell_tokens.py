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
    to the `<<` / `<<-` token, so it is never read as commands;
  * `case` patterns (`a)` closes a pattern, not a substitution) and `[[ ]]`
    (whose `<`, `&&`, `(` are operands, not shell operators).

The expected answers come from outside this file: tools/shell_oracle.py checks
the tokenizer against `bash -n`, `dash -n`, bash's own reprint of a parsed
function (`declare -f`), and bash's own quote removal.  See that file for the
measured resolution and blind spots.

Tokens are (kind, text, line, start, end, subst, heredoc):

  kind     'word' | 'pattern' (a case pattern) | 'arith' (a `(( ))` command or
           `for (( ))` header) | 'op' | 'redir' | 'newline'
  text     a word's source text with line continuations removed (quotes kept;
           unquote() removes them), or the operator text without IO number
  line     1-based line of the token's first character
  subst    for a word: the bodies of $(...), `...`, <(...), >(...) found at
           any quoting depth of that word -- in quotes, ${...}, $((...)),
           an assignment's [subscript] and an array value (not nested inside
           each other: a consumer recurses by tokenizing a body); for a
           `<<`/`<<-` redirection with an unquoted delimiter, the bodies of
           the $(...) and `...` in the here-document body
  heredoc  for a `<<`/`<<-` redirection: the body text, else None

tokenize() raises ShellLexError for text the shell would reject lexically:
an unterminated quote, substitution, expansion or `[[`.  A here-document with
no delimiter line is NOT an error: bash and dash accept it (bash warns) and
read the body to end of file.
"""
from __future__ import annotations

import bisect
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


# Longest first: the scanner takes the first that matches.
OPERATORS = (
    ";;&", "<<<", "<<-", "&>>",
    ";;", ";&", "&&", "||", "|&", "&>", "<<", "<>", "<&", ">&", ">>", ">|",
    "<", ">", "|", "&", ";", "(", ")",
)
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


class _Lexer:
    def __init__(self, text: str):
        self.text = text
        self.n = len(text)
        self.cuts: set[int] = set()       # positions of removed `\`+newline
        self.comments: list[tuple[int, int]] = []        # [start, end) spans
        self.heredocs: list[tuple[int, int, bool]] = []  # body spans, <<- flag
        self.arith_memo: dict[int, bool] = {}
        self.openers: list[int] = []   # offsets of every recorded $( / <( / >( body's opener
        self.line_starts = [0]
        for i, c in enumerate(text):
            if c == "\n":
                self.line_starts.append(i + 1)

    def line_of(self, pos: int) -> int:
        return bisect.bisect_right(self.line_starts, pos)

    def err(self, message: str, pos: int):
        raise ShellLexError(message, self.line_of(min(pos, max(self.n - 1, 0))))

    def clean(self, start: int, end: int) -> str:
        """Source slice with line continuations removed."""
        end = min(end, self.n)
        if not self.cuts:
            return self.text[start:end]
        return "".join(
            self.text[i] for i in range(start, end)
            if i not in self.cuts and i - 1 not in self.cuts)

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
        if t.startswith("$((", j) and self.arith_closes(j + 3):
            return self.arith(j + 3, j, subst)
        if nxt == "(":
            return self.cmdsub(j + 2, subst, j)
        if nxt == "{":
            return self.param(j + 2, subst, j)
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
                return j + 1
            body.append(c)
            j += 1
        self.err("unterminated backquote", i)

    def cmdsub(self, body_start: int, subst: list, opener: int) -> int:
        sub = _Body(self, body_start, closer=")")
        end = sub.run()
        if end is None:
            self.err("unterminated $(...)", opener)
        subst.append(self.clean(body_start, end))
        self.openers.append(opener)
        return end + 1

    def procsub(self, body_start: int, subst: list, opener: int) -> int:
        sub = _Body(self, body_start, closer=")")
        end = sub.run()
        if end is None:
            self.err("unterminated process substitution", opener)
        subst.append(self.clean(body_start, end))
        self.openers.append(opener)
        return end + 1

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
        cuts = set(self.cuts)
        comments, heredocs, openers = list(self.comments), list(self.heredocs), list(self.openers)
        try:
            result = self.arith_scan(j, []) is not None
        except ShellLexError:
            result = False
        finally:
            self.cuts, self.comments, self.heredocs = cuts, comments, heredocs
            self.openers = openers
        self.arith_memo[j] = result
        return result

    def arith(self, j: int, opener: int, subst: list) -> int:
        end = self.arith_scan(j, subst)
        if end is None:
            self.err("unterminated $((...))", opener)
        return end

    def param(self, j: int, subst: list, opener: int) -> int:   # after ${
        while j < self.n:
            c = self.text[j]
            if c == "\\":
                if self.text[j + 1:j + 2] == "\n":
                    self.cuts.add(j)
                j += 2
                continue
            if c == "}":
                return j + 1
            if c == "'":
                j = self.single(j)
                continue
            if c == '"':
                j = self.double(j, subst)
                continue
            if c in "$`":
                j = self.dollar_or_backtick(j, subst, in_double=False)
                continue
            j += 1
        self.err("unterminated ${...}", opener)

    def subscript(self, j: int, close: int, subst: list) -> int:
        """Read an assignment subscript `[...]` from j up to its `]` at close,
        recording $( ), backquote and ${ } bodies (they run).  Returns the
        index after the `]`."""
        while j < close:
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
            j += 1
        return close + 1

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
            if array and c in "<>" and self.text[j + 1:j + 2] == "(" \
                    and self.text[j - 1] in " \t\n(":
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
        self.after_for = False         # `for` was just read: `((` is arithmetic
        self.after_time = False        # `time` was just read: its -p keeps cmdpos
        self.assigned = False          # this command began with NAME=value
        self.after_coproc = False      # `coproc` was just read
        self.after_function = False    # `function` was just read: next is the NAME
        self.split_next = False        # a word here starts a new command
        self.for_header = 0            # 1: `for` read; 2: its NAME read

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
            if c == "[" and self.cmdpos and lx.clean(start, j).isidentifier():
                close = _subscript_end(t, j)  # `a[1<<3]=x`: an assignment's subscript
                if close is not None and t[close:close + 1] in ("=", "+"):
                    j = lx.subscript(j + 1, close - 1, subst)
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
                self.i += 1                   # `[[ a &&<newline> b ]]`: one command
                continue
            if c == "\n":
                self.emit(Token("newline", "\n", lx.line_of(self.i), self.i, self.i + 1))
                self.i += 1
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
                # `(( x )) then` / `for ((...)) do`: a reserved word may
                # follow a compound command with no separator.
                self.cmdpos = True
                continue
            self.after_for = False
            op = None if (self.dbracket and self.regex_next) else self.match_op()
            if op and not (self.dbracket and op not in (";", "\n")):
                self.handle_op(op)
                continue
            # A word (or, inside [[ ]], an operator-looking operand).
            if self.dbracket and op:
                end = self.i + len(op)
                self.emit(Token("word", op, lx.line_of(self.i), self.i, end))
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
            self.after_word(text)
        if self.closer:
            return None
        if self.dbracket:
            lx.err("unterminated [[", lx.n - 1)
        return lx.n

    def match_op(self) -> str | None:
        t, i = self.lx.text, self.i
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
            return
        if op == "(":
            if not self.in_pattern():         # `(a)` pattern: the optional lead
                self.parens += 1
            self.after_separator()
        elif op == ")":
            if self.in_pattern():
                self.case[-1] = "body"
                self.cmdpos = True
                return
            self.parens = max(0, self.parens - 1)
            self.cmdpos = True                # `f()` is followed by its body
            self.assigned = False             # `(v=1) then`: the subshell's assignment ended
            self.after_time = False
        elif op in (";;", ";&", ";;&"):
            if self.case:
                self.case[-1] = "pattern"
            self.after_separator()
        else:
            self.after_separator()

    def after_separator(self):
        self.cmdpos = True
        self.assigned = False
        self.after_coproc = False
        self.after_time = False

    def in_pattern(self) -> bool:
        return bool(self.case) and self.case[-1] == "pattern"

    def after_word(self, word: str):
        if self.expect_delim is not None:
            idx, strip = self.expect_delim
            self.expect_delim = None
            quoted = any(c in word for c in "'\"\\")
            self.pending.append((idx, unquote(word), strip, quoted))
            return
        if self.dbracket:
            if word == "=~":
                self.regex_next = True
            if word == "]]":
                self.dbracket = False
                self.cmdpos = True                # `[[ x ]] then`: a reserved word may follow
                self.split_next = True
            return
        if self.case and self.case[-1] == "word":
            self.case[-1] = "in" if word else "word"
            return
        if self.case and self.case[-1] == "in":
            if word == "in":
                self.case[-1] = "pattern"
            return
        if self.case and self.case[-1] == "pattern":
            if word == "esac":
                self.case.pop()
                self.cmdpos = True
            return
        if self.for_header == 1:              # `for NAME`
            self.for_header = 2
            return
        if self.for_header == 2:
            self.for_header = 0
            if word == "do":                  # `for NAME do` (implicit "$@")
                self.cmdpos = True
                self.split_next = True
                return
        if word == "{" and self.cmdpos:
            self.split_next = True
            return                            # a group or function body opens
        if self.cmdpos and self.after_time and word.startswith("-"):
            return                            # `time -p`: still a command position
        self.after_time = False
        if self.cmdpos and self.assigned:
            # After `NAME=value` the next word is a command NAME, never a
            # keyword: `x=1 [[ a ]]` runs a command called `[[`.
            if not _is_assignment(word):
                self.cmdpos = False
            return
        if self.cmdpos and word in ("for", "select"):
            self.after_for = True
            self.for_header = 1
        if self.cmdpos and word == "time":
            self.after_time = True
        if self.cmdpos and self.after_coproc:
            self.after_coproc = False
            rest = self.lx.text[self.i:].lstrip(" \t")
            if _plain_ident(word) and rest[:1] in ("{", "("):
                self.split_next = True
                return                        # `coproc NAME { ...; }`: NAME, then a compound
        if self.cmdpos and word == "coproc":
            self.after_coproc = True
            return
        if self.cmdpos and _is_assignment(word):
            self.assigned = True
            return
        if self.cmdpos and word == "function":
            self.after_function = True
            self.cmdpos = False
            return
        if self.after_function:
            self.after_function = False
            self.cmdpos = True                # `function NAME {` / `function NAME ()`
            self.split_next = True
            return
        if self.cmdpos and word in COMPOUND_CLOSERS:
            self.split_next = True
            return                            # `done then`, `fi }`: still a reserved-word position
        if self.cmdpos:
            if word == "case":
                self.case.append("word")
                self.cmdpos = False
                return
            if word == "esac" and self.case:
                self.case.pop()
                return
            if word == "[[":
                self.dbracket = True
                self.cmdpos = False
                return
            if word in RESERVED_OPENERS or _is_assignment(word):
                return                        # still a command position
            self.cmdpos = False

    def emit(self, tok: Token):
        self.split_next = False
        self.tokens.append(tok)

    def read_heredocs(self):
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


def _subscript_end(t: str, j: int) -> int | None:
    """Index after the `]` matching the `[` at j, or None."""
    depth = 0
    k = j
    while k < len(t):
        c = t[k]
        if c == "\\":
            k += 2
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return k + 1
        elif c == "\n":
            return None
        k += 1
    return None


def _is_fd_name(word: str) -> bool:
    """`{name}` before a redirection: bash's named file descriptor."""
    return len(word) > 2 and word[0] == "{" and word[-1] == "}" and _plain_ident(word[1:-1])


def _plain_ident(name: str) -> bool:
    return name.isidentifier() and name.isascii()


def _is_assignment(word: str) -> bool:
    eq = word.find("=")
    if eq <= 0:
        return False
    name = word[:eq]
    if name.endswith("+"):
        name = name[:-1]
    if "[" in name and name.endswith("]"):
        name = name[:name.index("[")]
    return name.isidentifier() and name.isascii()


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


def tokenize_file(text: str, name: str) -> list[Token]:
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
        return tokenize(text)
    except ShellLexError as e:
        if _bash_accepts(text):
            raise TokenizerGap(f"{name}:{e.line}: the shell tokenizer stopped ({e.reason}) "
                               "on a file `bash -n` accepts; everything after that line "
                               "would go unread") from None
        return tokenize_prefix(text)


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


def all_substitutions(text: str):
    """Bodies of $(...), `...`, <(...), >(...) in a fragment of shell text."""
    out = []
    for tok in tokenize(text):
        out.extend(tok.subst)
    return out


_ANSI = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
         "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
         "'": "'", '"': '"', "?": "?"}


def unquote(word: str) -> str:
    """Quote removal (POSIX 2.6.7) with expansions left as literal text."""
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
                    k = _skip_expansion(word, j)
                    out.append(word[j:k])
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
            k = _skip_expansion(word, i)
            out.append(word[i:k])
            i = k
        else:
            out.append(c)
            i += 1
    return "".join(out)


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


def _skip_expansion(word: str, i: int) -> int:
    """End of the expansion at word[i] ($(..), ${..}, `..`), kept literal."""
    lx = _Lexer(word)
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
