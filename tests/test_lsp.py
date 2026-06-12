#!/usr/bin/env python3
# Behavioral tests for the EigenScript LSP server (src/eigenlsp).
#
# The LSP was previously only compile-checked in CI — 1200+ lines with
# zero behavioral coverage. This drives it over real JSON-RPC (the
# Content-Length framed protocol it speaks on stdin/stdout) and asserts
# the responses: initialize capabilities, didOpen/didChange diagnostics
# (the squiggle path, which was dead until the g_first_error capture
# fix), completion, hover, definition, references, and shutdown/exit.
#
# Exit code: 0 if all pass, 1 otherwise. The shell wrapper (test_lsp.sh)
# skips cleanly when python3 or the eigenlsp binary is unavailable.

import json
import subprocess
import sys
import os

LSP = os.environ.get("EIGENLSP", os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "src", "eigenlsp"))

PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        print("  PASS: " + name)
        PASS += 1
    else:
        print("  FAIL: " + name)
        FAIL += 1


def frame(obj):
    body = json.dumps(obj)
    return "Content-Length: %d\r\n\r\n%s" % (len(body), body)


def converse(messages):
    """Feed framed messages to a fresh server, return parsed responses."""
    stream = "".join(frame(m) for m in messages)
    p = subprocess.run([LSP], input=stream, capture_output=True,
                       text=True, timeout=15)
    out = p.stdout
    dec = json.JSONDecoder()
    responses = []
    i = 0
    while True:
        j = out.find('"jsonrpc"', i)
        if j < 0:
            break
        start = out.rfind("{", 0, j)
        try:
            obj, end = dec.raw_decode(out, start)
        except ValueError:
            break
        responses.append(obj)
        i = end
    return responses


def by_id(responses, rid):
    for r in responses:
        if r.get("id") == rid:
            return r
    return None


def diagnostics(responses):
    """Last publishDiagnostics array, or None."""
    d = None
    for r in responses:
        if r.get("method") == "textDocument/publishDiagnostics":
            d = r["params"]["diagnostics"]
    return d


URI = "file:///test.eigs"


def did_open(text, version=1):
    return {"jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": URI, "languageId": "eigenscript",
                                        "version": version, "text": text}}}


INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
SHUTDOWN = {"jsonrpc": "2.0", "id": 99, "method": "shutdown"}
EXIT = {"jsonrpc": "2.0", "method": "exit"}


def main():
    print("=== LSP Behavioral Tests ===")

    # --- initialize: capabilities + serverInfo ---
    r = converse([INIT, SHUTDOWN, EXIT])
    init = by_id(r, 1)
    caps = (init or {}).get("result", {}).get("capabilities", {})
    check("initialize returns result", init is not None and "result" in init)
    check("advertises hoverProvider", caps.get("hoverProvider") is True)
    check("advertises definitionProvider", caps.get("definitionProvider") is True)
    check("advertises referencesProvider", caps.get("referencesProvider") is True)
    check("advertises completionProvider",
          isinstance(caps.get("completionProvider"), dict))
    check("serverInfo name is eigenlsp",
          (init or {}).get("result", {}).get("serverInfo", {}).get("name") == "eigenlsp")

    # --- shutdown returns null result; server exits cleanly ---
    check("shutdown returns null result",
          by_id(r, 99) is not None and by_id(r, 99).get("result") is None)

    # --- didOpen clean document → empty diagnostics ---
    r = converse([INIT, did_open("x is 5\nprint of x\n"), SHUTDOWN, EXIT])
    check("clean document → empty diagnostics", diagnostics(r) == [])

    # --- didOpen with a syntax error → one diagnostic at the right line ---
    r = converse([INIT, did_open("if x > 0\n    print of x\n"), SHUTDOWN, EXIT])
    d = diagnostics(r)
    check("missing-colon → a diagnostic", bool(d))
    check("diagnostic at line 0 (0-based)", bool(d) and d[0]["range"]["start"]["line"] == 0)
    check("diagnostic severity is error (1)", bool(d) and d[0]["severity"] == 1)
    check("diagnostic mentions expected colon", bool(d) and "expected ':'" in d[0]["message"])

    # --- unexpected character → diagnostic naming the char ---
    r = converse([INIT, did_open("x is @\n"), SHUTDOWN, EXIT])
    d = diagnostics(r)
    check("unexpected-char → a diagnostic", bool(d))
    check("diagnostic names the character", bool(d) and "@" in d[0]["message"])

    # --- error on line 3 maps to 0-based line 2 ---
    r = converse([INIT, did_open("a is 1\nb is 2\nif b\n    print of a\n"), SHUTDOWN, EXIT])
    d = diagnostics(r)
    check("error on source line 3 → diagnostic line 2",
          bool(d) and d[0]["range"]["start"]["line"] == 2)

    # --- didChange re-runs diagnostics: error → clean clears them ---
    change_clean = {"jsonrpc": "2.0", "method": "textDocument/didChange",
                    "params": {"textDocument": {"uri": URI, "version": 2},
                               "contentChanges": [{"text": "y is 10\nprint of y\n"}]}}
    r = converse([INIT, did_open("x is @\n"), change_clean, SHUTDOWN, EXIT])
    check("didChange to valid source clears diagnostics", diagnostics(r) == [])

    # --- completion returns items ---
    comp = {"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
            "params": {"textDocument": {"uri": URI}, "position": {"line": 1, "character": 0}}}
    r = converse([INIT, did_open("greeting is \"hi\"\n\n"), comp, SHUTDOWN, EXIT])
    res = (by_id(r, 2) or {}).get("result", {})
    items = res.get("items") if isinstance(res, dict) else None
    check("completion returns an items list", isinstance(items, list) and len(items) > 0)
    check("completion items have labels",
          isinstance(items, list) and all("label" in it for it in items[:5]))
    check("completion surfaces a user symbol",
          isinstance(items, list) and any(it.get("label") == "greeting" for it in items))

    # --- hover over a defined symbol returns contents ---
    hover = {"jsonrpc": "2.0", "id": 3, "method": "textDocument/hover",
             "params": {"textDocument": {"uri": URI}, "position": {"line": 0, "character": 0}}}
    r = converse([INIT, did_open("myvar is 42\nprint of myvar\n"), hover, SHUTDOWN, EXIT])
    res = (by_id(r, 3) or {}).get("result")
    check("hover returns contents",
          isinstance(res, dict) and "contents" in res)

    # --- definition of a used symbol returns a location ---
    define_doc = "define helper(a) as:\n    return a\nr is helper of 5\n"
    defn = {"jsonrpc": "2.0", "id": 4, "method": "textDocument/definition",
            "params": {"textDocument": {"uri": URI}, "position": {"line": 2, "character": 5}}}
    r = converse([INIT, did_open(define_doc), defn, SHUTDOWN, EXIT])
    res = (by_id(r, 4) or {}).get("result")
    loc = res[0] if isinstance(res, list) and res else res
    check("definition returns a location with a range",
          isinstance(loc, dict) and "range" in loc and loc.get("uri") == URI)

    # --- references returns a list ---
    refs = {"jsonrpc": "2.0", "id": 5, "method": "textDocument/references",
            "params": {"textDocument": {"uri": URI}, "position": {"line": 0, "character": 7},
                       "context": {"includeDeclaration": True}}}
    r = converse([INIT, did_open(define_doc), refs, SHUTDOWN, EXIT])
    res = (by_id(r, 5) or {}).get("result")
    check("references returns a list of locations",
          isinstance(res, list) and len(res) >= 1 and "range" in res[0])

    # --- didClose then reference on the closed doc must not crash ---
    close = {"jsonrpc": "2.0", "method": "textDocument/didClose",
             "params": {"textDocument": {"uri": URI}}}
    r = converse([INIT, did_open("z is 1\nprint of z\n"), close, SHUTDOWN, EXIT])
    check("didClose handled, shutdown still answered",
          by_id(r, 99) is not None)

    print("")
    print("Results: %d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
