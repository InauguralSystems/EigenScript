#!/usr/bin/env python3
"""phase2_inventory.py -- #1758 round 0: every numeric site in src/*.c and
src/*.h, classified into exactly one category.

POPULATION. A site is one occurrence, outside comments and string/char
literals, of a token in VOCAB: the value model's numeric vocabulary (the
number type tag, the slot predicates, the raw and checked payload accessors,
the constructors, the clamp, the formatter, the double parsers, and the AST
literal fields). The key is the TOKEN, so the blind spot is code that handles
a number without naming one of them. Two derived checks bound that blind spot:
  - every function in src/ that returns or writes out a `double` AND reads a
    payload (a raw or checked read appears in its body) is a numeric accessor;
    it must be in VOCAB (its call sites are then sites) or in WRAPPERS with a
    reason. A new accessor nobody reviewed is UNCLASSIFIED.
  - every VAL_NUM must sit in a syntactic position the classifier recognizes
    (test, case, tag store, type yield, emitter immediate); any other position
    is UNCLASSIFIED.
Not in the population: src/freestanding/ (outside the src/*.c glob), and code
that computes on a double already extracted by a counted read.

CATEGORIES (first matching rule wins; ROLE rules by file/function come first,
then the token's own kind):
  a type tests        b payload reads       c producers
  d JIT emitters/guards                     e number formatting
  f equality, ordering and hashing          g tape encode/decode
  h JSON, store and db encoders             i observer numeric paths
  j embed API

BUILTINS. The registration table (env_set_local_owned(env, "name",
make_builtin(fn)) lines and the ext_names.h X-lists) is the builtin
population (calibrated once against `eigenscript --api --json`: 311 = 311).
A builtin is numeric if its function, or a same-file function it calls or
names as a value (a comparator, an op table entry; closure depth 4), contains
a site, or if it calls the shared formatter or equality (SEMANTIC_LEAVES).
Every numeric builtin must have exactly one row in the classification table
of docs/design/phase2-numbers.md (class and loss columns from closed token
sets), every row must name a numeric builtin, and a LOSS row must have a
double path in its closure.

Usage: tools/phase2_inventory.py [--src DIR] [--doc FILE] [--out FILE]
                                 [--no-write] [--sites]
Prints `examined=N classified=N unclassified=0` and the builtin line; exits 1
if any site or builtin is unclassified, a table row is stale, a rule or
token never fires, or nothing was examined.
"""
import argparse
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- vocabulary: token -> kind -------------------------------------------
# Kinds decide the default category (a/b/c/e) when no role rule matches.
VOCAB = {
    # (a) type tests and type derivations
    'VAL_NUM': 'TAG',              # position decides: TEST/CASE/TAGSET/YIELD/EMIT
    'slot_is_num': 'TEST',
    'slot_is_numeric': 'TEST',
    'NUM_REUSE': 'TEST',
    'AST_NUM': 'TAG',
    # (b) payload reads
    'VAL_NUM_RAW': 'RAW',          # an lvalue: `VAL_NUM_RAW(v) = x` is a WRITE
    'SLOT_NUM_RAW': 'RAW',
    'VAL_NUM_OFFSET': 'RAW',
    'slot_as_double': 'READ',
    'eigs_num_arg': 'READ',
    'eigs_num_arg_slow': 'READ',
    'eigs_list_num': 'READ',
    'eigs_opt_num': 'READ',
    'eigs_elem_num': 'READ',
    'eigs_slot_num': 'READ',
    'eigs_slot_elem_num': 'READ',
    'eigs_slot_opt_num': 'READ',
    'list_get_num': 'READ',
    'dict_value_get_num': 'READ',
    'buffer_read_num': 'READ',
    'num_to_i64_exact': 'READ',
    'finite_num_to_byte': 'READ',
    'buffer_read_byte': 'READ',    # a buffer element as a byte (Q1: N5, no wrap)
    'buf_num_arg': 'READ',         # builtins_buf.c wrapper of eigs_list_num
    'eigs_value_as_num': 'READ',   # embed API accessor
    'num_val': 'RAW',              # lexer token payload (double)
    # (c) producers
    'make_num': 'PRODUCE',
    'make_num_permanent': 'PRODUCE',
    'slot_from_num': 'PRODUCE',
    'list_set_num': 'PRODUCE',
    'list_append_num': 'PRODUCE',
    'dict_value_set_num': 'PRODUCE',
    'list_rewrite_num': 'PRODUCE',
    'dict_value_rewrite_num': 'PRODUCE',
    'num_guard': 'GUARD',
    'num_guard_named': 'GUARD',
    'EIGS_NUM_MAX': 'GUARD',
    'strtod': 'PARSE',
    'atof': 'PARSE',
    # (e) formatting
    'eigs_num_text': 'FORMAT',
}
# JIT-only vocabulary (jit.c, jit.h, jit_smoke.c): the emitted guards test
# raw tag bits and never name a VOCAB token, so a token scan alone sees almost
# none of them. These are the tag-range immediates and the emitters that
# assume an operand or result is a double. Category (d).
JIT_FILES = re.compile(r'^(jit\.c|jit\.h|jit_smoke\.c)$')
JIT_TOKEN_RE = re.compile(
    r'\b(0x[Ff]{3}[89A-Fa-f](?:0{12})?(?:ULL|ull)?|max_normal_bits|'
    r'emit_immediate_num_check_r[a-z]{2}|emit_load_numeric_operand|emit_overflow_check_rax|'
    r'emit_(?:add|sub|mul|div)sd_xmm0_xmm1|emit_ucomisd_\w+|emit_cvttsd2si_\w+|'
    r'emit_cvtsi2sd_\w+|emit_btr_63_\w+|fmod)\b')

# `data.num` is the AST literal's double (`data.num_` is the Value member,
# reached only through VAL_NUM_RAW); matched as a member access, below.
AST_NUM_FIELD = re.compile(r'(?:->|\.)data\.num\b(?!_)')

KIND_CATEGORY = {
    'TEST': 'a', 'CASE': 'a', 'YIELD': 'a', 'DATA': 'a',
    'READ': 'b', 'RAW': 'b',
    'TAGSET': 'c', 'WRITE': 'c', 'PRODUCE': 'c', 'GUARD': 'c', 'PARSE': 'c',
    'EMIT': 'd',
    'FORMAT': 'e',
}

CATEGORY_NAMES = {
    'a': 'type tests',
    'b': 'payload reads',
    'c': 'producers',
    'd': 'JIT emitters and guards',
    'e': 'number formatting',
    'f': 'equality, ordering and hashing',
    'g': 'tape encode and decode',
    'h': 'JSON, store and db encoders',
    'i': 'observer numeric paths',
    'j': 'embed API',
}

# Functions that return/write a double from a payload read, reviewed: their
# call sites are NOT sites, because the read inside them already is one and
# changes with them. (Derived check: a new such function must be added to
# VOCAB or here, with a reason.)
WRAPPERS = {
    'compute_entropy_impl': 'observer: returns an entropy, not the number; its payload read is the site',
    'ent_child_slot': 'observer: returns a child entropy, not the number; its payload read is the site',
    'observer_entropy_now': 'observer: writes an entropy, not the number; its payload read is the site',
    'numerical_loss': 'tensor: reads the loss callback result once; that read is the site',
    'tensor_flatten_recursive': 'tensor: bulk element flattener into a double array; the per-element read is the site',
    'tensor_to_flat': 'tensor: bulk element flattener into a double array; the per-element read is the site',
}

# ---- role rules: (category, file regex, scope regex), first match wins ----
# A scope is the enclosing function, `#define NAME`, `<file scope>`, or for
# the two dispatchers `vm_run_ex/CASE(X)` and `jit_compile_to_thunk/OP_X`.
ROLE_RULES = [
    ('d', r'^(jit\.c|jit\.h|jit_smoke\.c)$', r'.*'),
    ('j', r'^(eigs_embed\.[ch]|embed_smoke\.c|embed_concurrent\.c|embed_roads\.c)$', r'.*'),
    ('g', r'^(trace\.[ch]|tape_read\.[ch]|eigsdap\.c|step\.c)$', r'.*'),
    ('h', r'^(ext_store\.c|ext_store_internal\.h|ext_db\.c|ext_db_internal\.h)$', r'.*'),
    ('h', r'.*', r'(^|_)json(_|$)|^eigs_json|^builtin_json'),
    ('i', r'.*', r'observer|^obs_|_obs_|^ent_|entropy|^jit_sample_num|'
                 r'^builtin_(observe|classify|report|get_observer_thresholds|record_history|state_at)$|'
                 r'CASE\((OBSERVE|PREDICATE|REPORT|INTERROGATE|LOOP_STALL)'),
    ('f', r'.*', r'^(values_equal_impl|values_equal|values_equal_op|const_equal|const_hash_value|'
                 r'cmp_[a-z_]*|[a-z_]*_cmp|builtin_(list_contains|list_index_of|sort|sort_by|secure_equals))$|'
                 r'CASE\((EQ|NE)\)|^#define NUM_CMP$'),
    ('e', r'.*', r'^(eigs_num_text|value_to_string|chunk_disassemble|slot_type_name|'
                 r'builtin_(str|print|write|hex))$'),
]

# Functions that dispatch on an opcode, and how an arm is spelled. Sites in
# them are attributed per arm (`fn/OP_X`), and executor_arms() below derives
# the executor matrix from the same arms.
DISPATCHERS = {
    'vm_run_ex': 'CASE',                  # the interpreter
    'jit_supported_prefix': 'IF',         # the JIT scanner
    'jit_compile_to_thunk': 'IF',         # the JIT emitter
    'chunk_scan_leaf_accessor': 'LABEL',  # the leaf scanner (#366)
    'vm_leaf_accessor_exec': 'LABEL',     # the leaf evaluator (#366)
}

TOKEN_RE = re.compile(r'\b(' + '|'.join(sorted(VOCAB, key=len, reverse=True)) + r')\b')
# Raw union members: the Value's double (`num_`) and the slot's (`d_`). Only
# the accessor macros may name them; anywhere else is a bypass.
RAW_MEMBER = re.compile(r'(?:\.|->)(d_|num_)\b')
RAW_MEMBER_HOMES = {'#define VAL_NUM_RAW', '#define SLOT_NUM_RAW', '#define VAL_NUM_OFFSET'}
C_KEYWORDS = {'if', 'while', 'for', 'switch', 'return', 'sizeof', 'do', 'else',
              'case', 'defined', '__attribute__', '__typeof__', '_Generic'}


def strip_c(text, keep_strings=False):
    """Blank comments and (unless keep_strings) string/char literals, keeping
    every newline (so line numbers survive) and every other column."""
    out = []
    i, n = 0, len(text)
    state = 'code'
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if state == 'code':
            if c == '/' and nxt == '/':
                state = 'line'; out.append('  '); i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block'; out.append('  '); i += 2; continue
            if c == '"':
                state = 'str'; out.append('"'); i += 1; continue
            if c == "'":
                state = 'chr'; out.append("'"); i += 1; continue
            out.append(c); i += 1; continue
        if state == 'line':
            if c == '\n':
                state = 'code'; out.append('\n')
            else:
                out.append('\\' if c == '\\' and nxt == '\n' else ' ')
            i += 1; continue
        if state == 'block':
            if c == '*' and nxt == '/':
                state = 'code'; out.append('  '); i += 2; continue
            # keep a line-continuation backslash: a comment inside a
            # multi-line #define must not end the macro early
            out.append(c if c in '\n\\' and (c == '\n' or nxt == '\n') else ' '); i += 1; continue
        # string or char literal
        quote = '"' if state == 'str' else "'"
        if c == '\\' and i + 1 < n:
            if keep_strings or text[i + 1] == '\n':
                out.append(text[i:i + 2])
            else:
                out.append('  ')
            i += 2; continue
        if c == quote:
            state = 'code'; out.append(quote); i += 1; continue
        out.append(c if keep_strings or c == '\n' else ' '); i += 1
    return ''.join(out)


def scopes_for(stripped, fname, sigs=None):
    """Return a list: scope name per line (1-based index; [0] unused).
    `sigs`, if given, collects each function's signature text."""
    lines = stripped.split('\n')
    scope = ['<file scope>'] * (len(lines) + 1)
    depth = 0
    sig = ''              # text since the last top-level ; or } (signature)
    cur = '<file scope>'
    sub = None            # dispatcher sub-scope (CASE(X) / OP_X)
    arm_depth = None      # brace depth of a LABEL dispatcher's arms
    prev_label = False
    in_macro = None
    for ln, line in enumerate(lines, 1):
        # #define bodies (with continuations) are their own scope
        if in_macro is not None:
            scope[ln] = in_macro
            if not line.rstrip().endswith('\\'):
                in_macro = None
            continue
        m = re.match(r'\s*#\s*define\s+([A-Za-z_]\w*)', line)
        if m:
            scope[ln] = '#define ' + m.group(1)
            if line.rstrip().endswith('\\'):
                in_macro = '#define ' + m.group(1)
            continue
        if re.match(r'\s*#', line):
            scope[ln] = cur if depth > 0 else '<file scope>'
            continue
        if depth > 0 and cur in DISPATCHERS:
            style = DISPATCHERS[cur]
            if style == 'CASE':
                mc = re.match(r'\s*CASE\((\w+)\)', line)
                if mc:
                    sub = 'CASE(%s)' % mc.group(1)
            elif style == 'IF':
                mo = re.search(r'\b(?:if|else if)\s*\(\s*op\s*==\s*(OP_\w+)', line)
                if mo and depth <= 3:
                    sub = mo.group(1)
            else:   # LABEL: the outermost `case OP_X:` labels of the dispatch switch
                labels = re.findall(r'\bcase\s+(OP_\w+)\s*:', line)
                if labels and arm_depth is None:
                    arm_depth = depth
                if labels and depth == arm_depth:
                    # consecutive label lines name one grouped arm
                    sub = (sub + '|' if prev_label and sub else '') + '|'.join(labels)
                    # a line holding only labels continues into the next label line
                    prev_label = line.rstrip().endswith(':')
                elif line.strip():
                    prev_label = False
        line_scope = cur if depth > 0 else '<file scope>'
        if depth > 0 and sub and cur in DISPATCHERS:
            line_scope = cur + '/' + sub
        for ch in line:
            if ch == '{':
                if depth == 0:
                    cur = function_name(sig)
                    if sigs is not None and not cur.startswith('<'):
                        sigs.setdefault(cur, sig)
                    sub = None
                    arm_depth = None
                    line_scope = cur
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    sig = ''
                    cur = '<file scope>'
                    sub = None
            elif ch == ';' and depth == 0:
                sig = ''
            elif depth == 0:
                sig += ch
        if depth == 0 and line.strip() and not line.strip().startswith('}'):
            sig += '\n'
        scope[ln] = line_scope
    return scope


def function_name(sig):
    """The identifier before the last top-level parenthesized group of a
    definition's signature; '<file scope>' for struct/enum/array bodies."""
    s = re.sub(r'__attribute__\s*\(\(.*?\)\)', ' ', sig, flags=re.S)
    if '(' not in s or '=' in s.split('(')[0]:
        return '<file scope>'
    # find the last balanced (...) group at nesting level 0
    depth, last_open = 0, -1
    for idx, ch in enumerate(s):
        if ch == '(':
            if depth == 0:
                last_open = idx
            depth += 1
        elif ch == ')':
            depth -= 1
    if last_open < 0:
        return '<file scope>'
    head = s[:last_open]
    ids = re.findall(r'[A-Za-z_]\w*', head)
    ids = [i for i in ids if i not in C_KEYWORDS]
    return ids[-1] if ids else '<file scope>'


def val_num_kind(line, start, end, token):
    """Syntactic role of a VAL_NUM / AST_NUM occurrence."""
    before = line[:start].rstrip()
    after = line[end:].lstrip()
    if re.search(r'(==|!=)\s*$', before) or re.match(r'(==|!=)', after):
        return 'TEST'
    if re.search(r'\bcase\s*$', before):
        return 'CASE'
    if re.search(r'(?<![=!<>])=\s*$', before):
        return 'TAGSET'
    if re.search(r'\breturn\s*$', before) or re.search(r'[?:]\s*$', before):
        return 'YIELD'
    if re.search(r'\(\s*uint32_t\s*\)\s*$', before):
        return 'EMIT'            # JIT immediate operand of a type compare
    if (re.search(r'[({,]\s*$', before) or not before) and re.match(r'[)},]', after):
        return 'DATA'            # the tag as data: enumerator, kind table, argument
    return 'UNKNOWN'


def raw_kind(line, end):
    """VAL_NUM_RAW(...)/SLOT_NUM_RAW(...) followed by a plain `=` is a write."""
    depth, i = 0, end
    while i < len(line):
        ch = line[i]
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                rest = line[i + 1:].lstrip()
                if re.match(r'=(?!=)', rest):
                    return 'WRITE'
                return 'RAW'
        elif depth == 0 and not ch.isspace():
            return 'RAW'
        i += 1
    return 'RAW'


def scan_file(path, rel):
    with open(path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    stripped = strip_c(text)
    sigs = {}
    scope = scopes_for(stripped, rel, sigs)
    sites = []
    for ln, line in enumerate(stripped.split('\n'), 1):
        for m in TOKEN_RE.finditer(line):
            tok = m.group(1)
            kind = VOCAB[tok]
            if kind == 'TAG':
                kind = val_num_kind(line, m.start(), m.end(), tok)
            elif tok in ('VAL_NUM_RAW', 'SLOT_NUM_RAW'):
                kind = raw_kind(line, m.end())
            sites.append((rel, ln, scope[ln], tok, kind))
        if JIT_FILES.match(rel):
            for m in JIT_TOKEN_RE.finditer(line):
                tok = m.group(1)
                tok = 'TAG-IMM ' + tok[:6] if tok.lower().startswith('0xfff') else tok
                sites.append((rel, ln, scope[ln], tok, 'EMIT'))
        for m in RAW_MEMBER.finditer(line):
            kind = 'RAW' if scope[ln] in RAW_MEMBER_HOMES else 'BYPASS'
            sites.append((rel, ln, scope[ln], m.group(1), kind))
        for m in AST_NUM_FIELD.finditer(line):
            rest = line[m.end():].lstrip()
            kind = 'WRITE' if re.match(r'=(?!=)', rest) else 'RAW'
            sites.append((rel, ln, scope[ln], 'data.num', kind))
    return sites, stripped, scope, sigs


def classify(site):
    rel, ln, scope, tok, kind = site
    if kind in ('UNKNOWN', 'BYPASS'):
        return None, None
    base = scope.split('/')[-1] if '/' in scope else scope
    for idx, (cat, frx, srx) in enumerate(ROLE_RULES):
        if re.search(frx, rel) and (re.search(srx, scope) or re.search(srx, base)):
            return cat, idx
    return KIND_CATEGORY[kind], None


# ---- derived accessor check ----------------------------------------------
READ_IN_BODY = re.compile(r'\b(VAL_NUM_RAW|SLOT_NUM_RAW|eigs_num_arg|eigs_list_num|'
                          r'eigs_slot_num|list_get_num|dict_value_get_num|slot_as_double)\b|'
                          r'(?:\.|->)(?:d_|num_)\b')


def derived_accessors(stripped_by_file, scope_by_file, sigs_by_file):
    """Functions whose signature returns `double` (or has a `double *` out
    parameter) and whose body performs a payload read."""
    found = {}
    for rel, stripped in stripped_by_file.items():
        sigs = sigs_by_file[rel]
        lines = stripped.split('\n')
        scope = scope_by_file[rel]
        bodies = {}
        for ln, line in enumerate(lines, 1):
            s = scope[ln]
            if s.startswith('<') or s.startswith('#define') or '/' in s:
                continue
            bodies.setdefault(s, []).append(line)
        for fn, blines in bodies.items():
            body = '\n'.join(blines)
            if not READ_IN_BODY.search(body):
                continue
            sigtext = sigs.get(fn)
            if not sigtext or fn not in sigtext:
                continue
            cut = sigtext.rindex(fn)
            ret, params = sigtext[:cut], sigtext[cut + len(fn):]
            if re.search(r'\bdouble\b', ret) or re.search(r'\bdouble\s*\*', params):
                found.setdefault(fn, rel)
    return found


# ---- builtins ------------------------------------------------------------
REG_DIRECT = re.compile(r'env_set_local_owned\(\s*\w+\s*,\s*"([A-Za-z_]\w*)"\s*,\s*'
                        r'make_builtin\(\s*(\w+)\s*\)\s*\)')
REG_XLIST = re.compile(r'\bX\(\s*([A-Za-z_]\w*)\s*,\s*(\w+)\s*\)')


def registered_builtins(src):
    regs = {}
    for path in sorted(glob.glob(os.path.join(src, '*.c'))):
        with open(path, encoding='utf-8', errors='replace') as f:
            text = strip_c(f.read(), keep_strings=True)
        for m in REG_DIRECT.finditer(text):
            regs.setdefault(m.group(1), m.group(2))
    names_h = os.path.join(src, 'ext_names.h')
    if os.path.exists(names_h):
        with open(names_h, encoding='utf-8', errors='replace') as f:
            text = strip_c(f.read())
        for m in REG_XLIST.finditer(text):
            if m.group(1) != 'name':
                regs.setdefault(m.group(1), m.group(2))
    return regs


def function_bodies(stripped_by_file, scope_by_file):
    """fn -> (file, body text), for every top-level function definition."""
    out = {}
    for rel, stripped in stripped_by_file.items():
        lines = stripped.split('\n')
        scope = scope_by_file[rel]
        for ln, line in enumerate(lines, 1):
            s = scope[ln].split('/')[0]
            if s.startswith('<') or s.startswith('#define'):
                continue
            f_rel, buf = out.setdefault(s, (rel, []))
            if f_rel == rel:
                buf.append(line)
    return {k: (v[0], '\n'.join(v[1])) for k, v in out.items()}


# Cross-file functions whose numeric semantics a builtin inherits by calling
# them: number text (N6) and equality (N2). Followed from any file.
SEMANTIC_LEAVES = {'value_to_string': 'eigs_num_text', 'eigs_num_text': 'eigs_num_text',
                   'values_equal': 'values_equal', 'values_equal_op': 'values_equal'}


def numeric_builtins(regs, sites, bodies):
    sites_by_fn = {}
    for (rel, ln, scope, tok, kind) in sites:
        fn = scope.split('/')[0]
        sites_by_fn.setdefault(fn, []).append(tok)
    # a callee is any same-file function the body names: a call, or a
    # reference passed as a value (a comparator or an op table entry)
    ident = re.compile(r'\b([A-Za-z_]\w*)\b')
    result = {}
    for name, fn in regs.items():
        seen, frontier, toks = {fn}, [fn], []
        depth = 0
        while frontier and depth <= 4:
            nxt = []
            for f in frontier:
                toks.extend(sites_by_fn.get(f, []))
                if f not in bodies:
                    continue
                f_rel, body = bodies[f]
                for callee in ident.findall(body):
                    if callee in SEMANTIC_LEAVES:
                        toks.append(SEMANTIC_LEAVES[callee])
                    if callee in seen or callee not in bodies:
                        continue
                    if bodies[callee][0] != f_rel and not callee.startswith('builtin_'):
                        continue          # same-file helpers only (closure)
                    seen.add(callee)
                    nxt.append(callee)
            frontier = nxt
            depth += 1
        if toks:
            result[name] = (fn, sorted(set(toks)))
    return result


# ---- opcode executors, derived from the DISPATCHERS' arms ------------------
ROLE_OF = {'vm_run_ex': 'interp', 'jit_supported_prefix': 'jit_scan',
           'jit_compile_to_thunk': 'jit_emit', 'chunk_scan_leaf_accessor': 'leaf_scan',
           'vm_leaf_accessor_exec': 'leaf_exec'}
ROLES = ['interp', 'jit_scan', 'jit_emit', 'leaf_scan', 'leaf_exec']


def executor_arms(stripped_by_file, scope_by_file):
    """opcode -> set of roles that have an arm for it; and each dispatcher
    arm's opcode chain, keyed by its scope (`fn/sub`)."""
    arms, chains = {}, {}
    # a macro whose body spells CASE(<its first parameter>) generates an
    # interpreter arm at each invocation (NUM_BINOP(SUB, ...), NUM_CMP(LT, ...))
    defs = []
    for stripped in stripped_by_file.values():
        for m in re.finditer(r'#\s*define\s+(\w+)\(\s*(\w+)[^)]*\)((?:[^\n]*\\\n)*[^\n]*)', stripped):
            defs.append((m.group(1), m.group(2), m.group(3)))
    case_macros, grew = set(), True
    while grew:   # closed over chains: INT_BINOP -> INT_BINOP_R -> CASE(NAME)
        grew = False
        for name, p1, body in defs:
            if name in case_macros:
                continue
            calls = ['CASE'] + sorted(case_macros)
            if re.search(r'\b(%s)\(\s*%s\b' % ('|'.join(calls), re.escape(p1)), body):
                case_macros.add(name); grew = True
    gen = re.compile(r'^\s*(%s)\(\s*(\w+)' % '|'.join(sorted(case_macros))) if case_macros else None
    for rel, stripped in stripped_by_file.items():
        scope = scope_by_file[rel]
        for ln, line in enumerate(stripped.split('\n'), 1):
            fn, _, sub = scope[ln].partition('/')
            if gen and fn == 'vm_run_ex':
                mg = gen.match(line)
                if mg:
                    arms.setdefault('OP_' + mg.group(2), set()).add('interp')
            if fn not in DISPATCHERS:
                continue
            if DISPATCHERS[fn] == 'IF':
                ops = re.findall(r'\bop\s*==\s*(OP_\w+)', line)
            elif sub.startswith('CASE('):
                ops = ['OP_' + sub[5:-1]]
            else:
                ops = [o for o in sub.split('|') if o]
            for op in ops:
                arms.setdefault(op, set()).add(ROLE_OF[fn])
            if sub and ops:
                chains.setdefault(fn + '/' + sub, set()).update(ops)
    return arms, chains


# ---- slot classifiers (R1.1's worklist) ------------------------------------
# Every function (or dispatcher arm) that tests, dereferences or types an
# EigsSlot. D1 holds a number test, so the rename forces it; D2 dereferences
# with no number test; D3 tests other tags or bits; T only reads slot_type.
# Every D2 and D3 entry needs a reviewed disposition in the design doc.
SLOT_TEST = {'slot_is_num', 'slot_is_numeric', 'slot_as_double'}
SLOT_OTHER = {'slot_is_null', 'slot_is_bool', 'slot_is_heap', 'slot_is_ptr'}
SLOT_DEREF = {'slot_as_ptr', 'slot_as_heap', 'eigs_slot_ref'}
SLOT_TYPE = {'slot_type', 'list_elem_type', 'dict_value_type'}
SLOT_BITS = {'SLOT_QNAN_MASK', 'SLOT_TAG_MASK', 'SLOT_PAYLOAD_MASK', 'TAG_HEAP', 'TAG_BOOL',
             'TAG_SENTINEL', 'SLOT_NULL_BITS', 'SLOT_TRUE_BITS', 'SLOT_FALSE_BITS'}
SLOT_RE = re.compile(r'\b(' + '|'.join(sorted(SLOT_TEST | SLOT_OTHER | SLOT_DEREF | SLOT_TYPE | SLOT_BITS,
                                            key=len, reverse=True)) + r')\b')
DISPOSITIONS = {'guarded', 'smi-arm', 'refuse', 'not-a-classifier'}


def slot_classifiers(stripped_by_file, scope_by_file):
    toks = {}
    for rel, stripped in stripped_by_file.items():
        scope = scope_by_file[rel]
        for ln, line in enumerate(stripped.split('\n'), 1):
            for m in SLOT_RE.finditer(line):
                k = scope[ln]
                if k.split('/')[0] not in DISPATCHERS:
                    k = k.split('/')[0]
                if k.startswith('#define ') and k[8:] in SLOT_BITS:
                    continue          # the constant's own definition
                toks.setdefault((rel, k), {}).setdefault(m.group(1), 0)
                toks[(rel, k)][m.group(1)] += 1
    out = {}
    for key, c in toks.items():
        t = set(c)
        cls = ('D1' if t & SLOT_TEST else 'D2' if t & SLOT_DEREF else
               'D3' if t & (SLOT_OTHER | SLOT_BITS) else 'T')
        out[key] = (cls, c)
    return out


def read_marked_table(doc, tag, row_re):
    """Rows between <!-- tag:begin --> and <!-- tag:end -->; an unparsed
    line inside the markers is refused, never skipped."""
    rows, bad = {}, []
    if not os.path.exists(doc):
        return None, ['%s missing' % doc]
    inside = False
    with open(doc, encoding='utf-8') as f:
        for ln, line in enumerate(f, 1):
            if line.startswith('<!-- %s:begin -->' % tag):
                inside = True; continue
            if line.startswith('<!-- %s:end -->' % tag):
                inside = False; continue
            if not inside or not line.strip():
                continue
            m = row_re.match(line)
            if not m:
                if not re.match(r'^\|\s*(name|builtin|-+)\s*\|', line.strip()):
                    bad.append('%s:%d: unparsed %s line: %s' % (doc, ln, tag, line.strip()[:60]))
                continue
            if m.group(1) in rows:
                bad.append('%s:%d: `%s` has two %s rows' % (doc, ln, m.group(1), tag))
            rows[m.group(1)] = (ln,) + m.groups()[1:]
    return rows, bad


SLOT_ROW = re.compile(r'^\|\s*`([^`]+)`\s*\|\s*([a-z-]+)\s*\|')


TABLE_ROW = re.compile(r'^\|\s*`([A-Za-z_]\w*)`\s*\|\s*([a-z-]+)\s*\|\s*(\S+)\s*\|')
CLASSES = {'int-preserving', 'float-producing', 'int-requiring', 'other'}
LOSS_MARKS = {'LOSS', '-'}
# A LOSS row claims the body computes through a double; it must have one.
DOUBLE_PATH = {'eigs_num_arg', 'eigs_list_num', 'eigs_slot_num', 'eigs_opt_num', 'eigs_slot_opt_num',
               'eigs_slot_elem_num', 'eigs_elem_num', 'buffer_read_num', 'make_num', 'slot_as_double',
               'VAL_NUM_RAW', 'SLOT_NUM_RAW', 'strtod', 'atof', 'num_guard', 'list_set_num'}


def read_table(doc):
    rows, bad = {}, []
    if not os.path.exists(doc):
        return None, ['classification table %s missing' % doc]
    with open(doc, encoding='utf-8') as f:
        in_table = False
        for ln, line in enumerate(f, 1):
            if line.startswith('<!-- builtin-table:begin -->'):
                in_table = True; continue
            if line.startswith('<!-- builtin-table:end -->'):
                in_table = False; continue
            if not in_table:
                continue
            m = TABLE_ROW.match(line)
            if not m:
                # inside the markers only the header and separator may fail
                # to parse; anything else is refused, never skipped
                if line.strip() and not re.match(r'^\|\s*(builtin|-+)\s*\|', line.strip()):
                    bad.append('%s:%d: unparsed table line: %s' % (doc, ln, line.strip()[:60]))
                continue
            name, cls, loss = m.group(1), m.group(2), m.group(3)
            if cls not in CLASSES:
                bad.append('%s:%d: `%s` has unknown class %r' % (doc, ln, name, cls))
            if loss not in LOSS_MARKS:
                bad.append('%s:%d: `%s` has unknown loss mark %r' % (doc, ln, name, loss))
            if name in rows:
                bad.append('%s:%d: `%s` has two rows' % (doc, ln, name))
            rows[name] = (cls, loss)
    return rows, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=os.path.join(ROOT, 'src'))
    ap.add_argument('--doc', default=os.path.join(ROOT, 'docs/design/phase2-numbers.md'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs/design/phase2-inventory.txt'))
    ap.add_argument('--no-write', action='store_true')
    ap.add_argument('--sites', action='store_true', help='print every site')
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.src, '*.c')) + glob.glob(os.path.join(args.src, '*.h')))
    sites, stripped_by_file, scope_by_file, sigs_by_file = [], {}, {}, {}
    for path in files:
        rel = os.path.basename(path)
        s, stripped, scope, sigs = scan_file(path, rel)
        sites.extend(s)
        stripped_by_file[rel] = stripped
        scope_by_file[rel] = scope
        sigs_by_file[rel] = sigs

    examined = len(sites)
    classified, unclassified = [], []
    rule_hits = [0] * len(ROLE_RULES)
    token_hits = {t: 0 for t in VOCAB}
    token_hits.update({'d_': 0, 'num_': 0})
    for site in sites:
        cat, rule = classify(site)
        if site[3] in token_hits:
            token_hits[site[3]] += 1
        if cat is None:
            why = ('raw union member outside its accessor macro' if site[4] == 'BYPASS'
                   else 'VAL_NUM/AST_NUM in an unrecognized position')
            unclassified.append((site, why))
            continue
        if rule is not None:
            rule_hits[rule] += 1
        classified.append((site, cat))

    # derived: numeric accessors must be reviewed
    acc = derived_accessors(stripped_by_file, scope_by_file, sigs_by_file)
    unreviewed = sorted(fn for fn in acc if fn not in VOCAB and fn not in WRAPPERS)
    for fn in unreviewed:
        unclassified.append(((acc[fn], 0, fn, fn, 'ACCESSOR'),
                             'reads a payload and returns/writes a double; not in VOCAB or WRAPPERS'))
    stale_wrappers = sorted(w for w in WRAPPERS if w not in acc)
    dead_tokens = sorted(t for t, c in token_hits.items() if c == 0)
    dead_rules = [i for i, c in enumerate(rule_hits) if c == 0]

    # builtins
    regs = registered_builtins(args.src)
    bodies = function_bodies(stripped_by_file, scope_by_file)
    nb = numeric_builtins(regs, sites, bodies)
    table, table_bad = read_table(args.doc)
    b_unclassified = sorted(n for n in nb if table is None or n not in table)
    b_stale = sorted(n for n in (table or {}) if n not in nb)
    loss_rows = sorted(n for n, (c, l) in (table or {}).items() if l == 'LOSS')
    for n in loss_rows:
        if n in nb and not (set(nb[n][1]) & DOUBLE_PATH):
            table_bad.append('`%s` is marked LOSS but its closure has no double-path token' % n)
    class_count = {}
    for n, (c, l) in (table or {}).items():
        class_count[c] = class_count.get(c, 0) + 1

    # executors: the leaf scanner and evaluator must name the same opcodes
    arms, chains = executor_arms(stripped_by_file, scope_by_file)
    leaf_scan = {o for o, r in arms.items() if 'leaf_scan' in r}
    leaf_exec = {o for o, r in arms.items() if 'leaf_exec' in r}
    exec_bad = ['leaf scanner admits %s but the leaf evaluator has no arm' % o
                for o in sorted(leaf_scan - leaf_exec)]
    exec_bad += ['leaf evaluator has an arm for %s the leaf scanner never admits' % o
                 for o in sorted(leaf_exec - leaf_scan)]
    found = {r for rs in arms.values() for r in rs}
    exec_bad += ['dispatcher %s (%s) attributed no opcode arm' % (f, r)
                 for f, r in sorted(ROLE_OF.items()) if r not in found]

    # slot classifiers: every D2/D3 entry has a reviewed disposition row
    slots = slot_classifiers(stripped_by_file, scope_by_file)
    slot_cls = {}
    for key, (cls, c) in slots.items():
        slot_cls[cls] = slot_cls.get(cls, 0) + 1
    need = {'%s:%s' % k for k, (cls, c) in slots.items() if cls in ('D2', 'D3')}
    srows, sbad = read_marked_table(args.doc, 'slot-table', SLOT_ROW)
    srows = srows or {}
    for name, (ln, disp) in srows.items():
        if disp not in DISPOSITIONS:
            sbad.append('%s:%d: `%s` has unknown disposition %r' % (args.doc, ln, name, disp))
    slot_missing = sorted(need - set(srows))
    slot_stale = sorted(set(srows) - need)
    if not any(slot_cls.get(k) for k in ('D1', 'D2', 'D3')):
        sbad.append('slot classifiers: examined=0 (no D1/D2/D3 entry found)')

    # ---- report ----
    cats = 'abcdefghij'
    per_cat = {c: 0 for c in cats}
    per_file = {}
    per_cat_file = {}
    per_kind = {}
    for (rel, ln, scope, tok, kind), cat in classified:
        per_cat[cat] += 1
        per_file[rel] = per_file.get(rel, 0) + 1
        per_cat_file.setdefault(cat, {}).setdefault(rel, 0)
        per_cat_file[cat][rel] += 1
        per_kind.setdefault(cat, {}).setdefault(kind, 0)
        per_kind[cat][kind] += 1

    out = []
    out.append('# docs/design/phase2-inventory.txt -- generated by tools/phase2_inventory.py; do not edit.')
    out.append('# Population: VOCAB token occurrences in src/*.c src/*.h, comments and literals stripped.')
    out.append('examined=%d classified=%d unclassified=%d' % (examined + len(unreviewed),
               len(classified), len(unclassified)))
    out.append('files=%d tokens=%d role_rules=%d derived_accessors=%d wrappers=%d' % (
        len(files), len(VOCAB), len(ROLE_RULES), len(acc), len(WRAPPERS)))
    out.append('')
    out.append('## Per category')
    for c in cats:
        kinds = ' '.join('%s=%d' % (k, v) for k, v in sorted(per_kind.get(c, {}).items()))
        out.append('(%s) %-34s %5d   %s' % (c, CATEGORY_NAMES[c], per_cat[c], kinds))
    out.append('')
    out.append('## Per token')
    for t in sorted(token_hits, key=lambda t: (-token_hits[t], t)):
        out.append('%-24s %5d' % (t, token_hits[t]))
    out.append('%-24s %5d' % ('data.num (AST)', sum(1 for s in sites if s[3] == 'data.num')))
    out.append('')
    out.append('## Per file (category counts)')
    for rel in sorted(per_file, key=lambda r: (-per_file[r], r)):
        parts = ' '.join('%s=%d' % (c, per_cat_file.get(c, {}).get(rel, 0)) for c in cats
                         if per_cat_file.get(c, {}).get(rel, 0))
        out.append('%-24s %5d   %s' % (rel, per_file[rel], parts))
    out.append('')
    out.append('## Executors (arms per opcode; roles: %s)' % ' '.join(ROLES))
    interesting = sorted(o for o, r in arms.items() if r - {'interp'})
    for o in interesting:
        out.append('%-24s %s' % (o, ' '.join(r if r in arms[o] else '-' for r in ROLES)))
    out.append('')
    # the MAP's L/F/O rows must exercise every JIT-emitter and leaf arm that
    # holds a numeric site (tests/phase2/MAP.md `ops:`; design §9.2)
    num_arms = sorted({sc.split(' ')[0] for (r_, l_, sc, t_, k_), c_ in classified
                       if sc.split('/')[0] in ('jit_compile_to_thunk', 'vm_leaf_accessor_exec')
                       and '/' in sc.split(' ')[0]})
    out.append('## Numeric arms (JIT emitter and leaf evaluator arms holding a numeric site)')
    for sc in num_arms:
        out.append('%-9s %-24s %s' % (ROLE_OF[sc.split('/')[0]], sc.split('/', 1)[1],
                                      ' '.join(sorted(chains.get(sc, ())))))
    out.append('')
    out.append('## Slot classifiers (R1.1 worklist)')
    out.append(' '.join('%s=%d' % (k, slot_cls.get(k, 0)) for k in ('D1', 'D2', 'D3', 'T')) +
               ' dispositions=%d missing=%d stale=%d' % (len(srows), len(slot_missing), len(slot_stale)))
    for key in sorted(slots, key=lambda k: (slots[k][0], k)):
        cls, c = slots[key]
        if cls in ('D1', 'D2', 'D3'):
            disp = 'forced' if cls == 'D1' else srows.get('%s:%s' % key, (0, '-'))[1]
            out.append('%s %-42s %-16s %s' % (cls, '%s:%s' % key, disp,
                       ' '.join('%s=%d' % kv for kv in sorted(c.items()))))
    out.append('')
    out.append('## Builtins')
    out.append('registered=%d numeric=%d classified=%d unclassified=%d stale=%d' % (
        len(regs), len(nb), len(nb) - len(b_unclassified), len(b_unclassified), len(b_stale)))
    out.append('classes: ' + ' '.join('%s=%d' % (c, class_count.get(c, 0)) for c in sorted(CLASSES)))
    out.append('LOSS (%d): %s' % (len(loss_rows), ' '.join(loss_rows)))
    for name in sorted(nb):
        fn, toks = nb[name]
        cls, loss = (table or {}).get(name, ('-', '-'))
        out.append('%-28s %-34s %-16s %-5s %s' % (name, fn, cls, loss, ','.join(toks)))
    out.append('')
    out.append('## Sites (file:line scope token kind category)')
    for (rel, ln, scope, tok, kind), cat in sorted(classified, key=lambda x: (x[0][0], x[0][1], x[0][3])):
        out.append('%s:%d %s %s %s %s' % (rel, ln, scope, tok, kind, cat))
    text = '\n'.join(out) + '\n'

    if not args.no_write:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, 'w', encoding='utf-8') as f:
            f.write(text)

    # stdout: the summary (not the site list unless --sites)
    summary_end = text.index('## Builtins')
    sys.stdout.write(text[:summary_end])
    if args.sites:
        sys.stdout.write(text[summary_end:])
    fail = []
    for (site, why) in unclassified:
        rel, ln, scope, tok, kind = site
        print('UNCLASSIFIED: %s:%d %s %s (%s)' % (rel, ln, scope, tok, why))
    for w in stale_wrappers:
        fail.append('stale WRAPPERS row: %s is no longer a payload-reading double accessor' % w)
    for t in dead_tokens:
        fail.append('VOCAB token never occurs: %s' % t)
    for i in dead_rules:
        fail.append('role rule %d (%s %s) matched no site' % (i, ROLE_RULES[i][0], ROLE_RULES[i][2][:40]))
    for b in table_bad:
        fail.append(b)
    for n in b_unclassified:
        fail.append('numeric builtin `%s` (%s) has no classification row' % (n, nb[n][0]))
    for n in b_stale:
        fail.append('classification row `%s` names no numeric registered builtin' % n)
    fail.extend(exec_bad)
    fail.extend(sbad)
    for n in slot_missing:
        fail.append('slot classifier `%s` has no disposition row' % n)
    for n in slot_stale:
        fail.append('disposition row `%s` names no D2/D3 slot classifier' % n)
    for f_ in fail:
        print('FAIL: ' + f_)
    print('builtins: registered=%d numeric=%d classified=%d unclassified=%d stale=%d' % (
        len(regs), len(nb), len(nb) - len(b_unclassified), len(b_unclassified), len(b_stale)))
    print('slot classifiers: %s dispositions=%d missing=%d stale=%d' % (
        ' '.join('%s=%d' % (k, slot_cls.get(k, 0)) for k in ('D1', 'D2', 'D3', 'T')),
        len(srows), len(slot_missing), len(slot_stale)))
    print('executors: leaf_scan=%d leaf_exec=%d mismatches=%d' % (
        len(leaf_scan), len(leaf_exec), len(exec_bad)))
    print('examined=%d classified=%d unclassified=%d' % (examined + len(unreviewed),
          len(classified), len(unclassified)))
    if examined <= 0 or not regs or unclassified or fail:
        print('phase2-inventory: FAIL')
        return 1
    print('phase2-inventory: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
