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
    check("advertises documentSymbolProvider", caps.get("documentSymbolProvider") is True)
    check("advertises workspaceSymbolProvider", caps.get("workspaceSymbolProvider") is True)
    check("advertises documentFormattingProvider", caps.get("documentFormattingProvider") is True)
    check("advertises renameProvider", caps.get("renameProvider") is True)
    check("advertises codeActionProvider", caps.get("codeActionProvider") is True)
    stp = caps.get("semanticTokensProvider")
    check("advertises semanticTokensProvider (full)",
          isinstance(stp, dict) and stp.get("full") is True)
    legend = (stp or {}).get("legend", {}).get("tokenTypes", [])
    check("semantic legend lists function/keyword/parameter",
          all(k in legend for k in ("function", "keyword", "parameter")))
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

    # --- documentSymbol: outline of functions + top-level vars ---
    ds_doc = "config is 1\ndefine helper(a) as:\n    return a\ndefine main() as:\n    return 0\n"
    dsym = {"jsonrpc": "2.0", "id": 6, "method": "textDocument/documentSymbol",
            "params": {"textDocument": {"uri": URI}}}
    r = converse([INIT, did_open(ds_doc), dsym, SHUTDOWN, EXIT])
    res = (by_id(r, 6) or {}).get("result")
    names = [s.get("name") for s in res] if isinstance(res, list) else []
    check("documentSymbol lists functions", "helper" in names and "main" in names)
    check("documentSymbol lists top-level var", "config" in names)
    check("documentSymbol entries have range + selectionRange",
          isinstance(res, list) and all("range" in s and "selectionRange" in s for s in res))
    check("documentSymbol function kind is 12 (Function)",
          isinstance(res, list) and any(s.get("name") == "helper" and s.get("kind") == 12 for s in res))

    # --- workspace/symbol: case-insensitive filter across open docs ---
    wsym = {"jsonrpc": "2.0", "id": 7, "method": "workspace/symbol",
            "params": {"query": "HELP"}}
    r = converse([INIT, did_open(ds_doc), wsym, SHUTDOWN, EXIT])
    res = (by_id(r, 7) or {}).get("result")
    check("workspace/symbol filters by query (case-insensitive)",
          isinstance(res, list) and any(s.get("name") == "helper" for s in res)
          and all(s.get("name") != "main" for s in res))
    check("workspace/symbol carries a location uri+range",
          isinstance(res, list) and res and res[0].get("location", {}).get("uri") == URI
          and "range" in res[0]["location"])

    # --- formatting: whole-doc TextEdit with normalized source ---
    fmt = {"jsonrpc": "2.0", "id": 8, "method": "textDocument/formatting",
           "params": {"textDocument": {"uri": URI},
                      "options": {"tabSize": 4, "insertSpaces": True}}}
    r = converse([INIT, did_open("define f(x,y) as:\n  return x+y\n"), fmt, SHUTDOWN, EXIT])
    res = (by_id(r, 8) or {}).get("result")
    check("formatting returns a single TextEdit",
          isinstance(res, list) and len(res) == 1 and "newText" in res[0])
    check("formatting normalizes spacing",
          isinstance(res, list) and res and "x + y" in res[0]["newText"]
          and "f(x, y)" in res[0]["newText"])

    # --- rename: WorkspaceEdit with an edit at every occurrence ---
    rename_doc = "count is 0\ncount is count + 1\nprint of count\n"
    rn = {"jsonrpc": "2.0", "id": 9, "method": "textDocument/rename",
          "params": {"textDocument": {"uri": URI}, "position": {"line": 0, "character": 0},
                     "newName": "total"}}
    r = converse([INIT, did_open(rename_doc), rn, SHUTDOWN, EXIT])
    res = (by_id(r, 9) or {}).get("result")
    edits = (res or {}).get("changes", {}).get(URI) if isinstance(res, dict) else None
    check("rename returns a WorkspaceEdit with >=2 edits",
          isinstance(edits, list) and len(edits) >= 2)
    check("rename edits all carry the new name",
          isinstance(edits, list) and bool(edits) and all(e.get("newText") == "total" for e in edits))

    # --- rename of a builtin/keyword is refused (null) ---
    rn_kw = {"jsonrpc": "2.0", "id": 10, "method": "textDocument/rename",
             "params": {"textDocument": {"uri": URI}, "position": {"line": 2, "character": 0},
                        "newName": "nope"}}
    r = converse([INIT, did_open(rename_doc), rn_kw, SHUTDOWN, EXIT])
    check("rename refuses a non-user symbol (print)", (by_id(r, 10) or {}).get("result") is None)

    # --- lint warnings surface as coded diagnostics (severity 2) ---
    r = converse([INIT, did_open("leftover is 5\nprint of \"hi\"\n"), SHUTDOWN, EXIT])
    d = diagnostics(r)
    check("lint warning surfaces as a diagnostic",
          bool(d) and any(x.get("code") == "W001" for x in d))
    check("lint diagnostic severity is warning (2)",
          bool(d) and any(x.get("severity") == 2 for x in d))

    # --- codeAction offers a quickfix for the W001 diagnostic ---
    ca = {"jsonrpc": "2.0", "id": 11, "method": "textDocument/codeAction",
          "params": {"textDocument": {"uri": URI},
                     "range": {"start": {"line": 0, "character": 0},
                               "end": {"line": 0, "character": 0}},
                     "context": {"diagnostics": []}}}
    r = converse([INIT, did_open("leftover is 5\nprint of \"hi\"\n"), ca, SHUTDOWN, EXIT])
    res = (by_id(r, 11) or {}).get("result")
    check("codeAction offers a quickfix for unused variable",
          isinstance(res, list) and any(
              a.get("kind") == "quickfix" and "Remove unused variable" in a.get("title", "")
              for a in res))
    action = res[0] if isinstance(res, list) and res else None
    check("codeAction carries a WorkspaceEdit for the document",
          isinstance(action, dict) and URI in action.get("edit", {}).get("changes", {}))

    # --- codeAction on a clean line returns no fixes ---
    ca2 = dict(ca); ca2 = json.loads(json.dumps(ca)); ca2["id"] = 12
    ca2["params"]["range"] = {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}}
    r = converse([INIT, did_open("leftover is 5\nprint of \"hi\"\n"), ca2, SHUTDOWN, EXIT])
    check("codeAction on a clean line is empty", (by_id(r, 12) or {}).get("result") == [])

    # --- semanticTokens: classified, delta-encoded token stream ---
    st_doc = "define add(a, b) as:\n    return a + b\nsum is add of [1, 22]\n"
    st = {"jsonrpc": "2.0", "id": 13, "method": "textDocument/semanticTokens/full",
          "params": {"textDocument": {"uri": URI}}}
    r = converse([INIT, did_open(st_doc), st, SHUTDOWN, EXIT])
    res = (by_id(r, 13) or {}).get("result")
    data = res.get("data") if isinstance(res, dict) else None
    check("semanticTokens returns data in 5-int records",
          isinstance(data, list) and len(data) > 0 and len(data) % 5 == 0)
    toks, ln, ch = [], 0, 0
    if isinstance(data, list):
        for i in range(0, len(data), 5):
            dl, dc, L, ty, _mod = data[i:i + 5]
            ln += dl
            ch = (ch + dc) if dl == 0 else dc
            toks.append((ln, ch, L, ty))
    fi = legend.index("function") if "function" in legend else 1
    ni = legend.index("number") if "number" in legend else 4
    check("semanticTokens classifies the defined function (add)",
          any(ty == fi for (_, _, _, ty) in toks))
    check("semanticTokens carries accurate lengths (22 → len 2)",
          any(ty == ni and L == 2 for (_, _, L, ty) in toks))

    print("")
    print("Results: %d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
