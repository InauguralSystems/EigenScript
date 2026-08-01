/* ================================================================
 * EigenScript DAP server — `eigsdap` (#539 v3, the eigsdap endgame)
 * ================================================================
 * A Debug Adapter Protocol server over stdio, driving the SAME tape
 * model as the CLI stepper (src/tape_read.c): position is an index
 * into the tape's L records, bindings are a fold of A records, the
 * call chain comes from the v2 S records. The tape is never executed,
 * so stepBack / reverseContinue are first-class — exactly as cheap as
 * forward — which is the capability this server exists to put in a
 * standard debugger UI ("time-travel in VS Code").
 *
 * Launch configuration (editors/vscode contributes type
 * "eigenscript-tape"):
 *   { "type": "eigenscript-tape", "request": "launch",
 *     "tape": "/path/to/run.tape", "source": "/path/to/prog.eigs" }
 *
 * Variables pane: each binding shows its folded value plus the
 * runtime's own #294 trajectory label, and expands into its assign
 * history (the `t <name>` view) as child nodes.
 *
 * Transport and JSON discipline follow src/eigenlsp.c: Content-Length
 * framing, string-scanning field extraction (the requests used here
 * are flat), strbuf-built responses. Version policy is tape_open's:
 * a tape is valid only for the format+runtime that recorded it (#411);
 * a mismatched launch fails with the reader's stderr reason.
 */

#include "eigenscript.h"
#include "state.h"
#include "trace.h"
#include "tape_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   /* strncasecmp for header parsing */

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

/* ---- transport (the eigenlsp shape) ------------------------------ */

static int g_seq = 1;   /* outgoing sequence numbers */

static void dap_send(const char *json) {
    fprintf(stdout, "Content-Length: %d\r\n\r\n%s", (int)strlen(json), json);
    fflush(stdout);
}

/* Read one framed message from stdin. Returns malloc'd body or NULL on
 * EOF/malformed header. */
static char *dap_read_message(void) {
    int content_length = -1;
    char header[1024];
    for (;;) {
        if (!fgets(header, sizeof(header), stdin)) return NULL;
        if (strcmp(header, "\r\n") == 0 || strcmp(header, "\n") == 0) break;
        if (strncasecmp(header, "Content-Length:", 15) == 0)
            content_length = atoi(header + 15);
    }
    if (content_length <= 0 || content_length > 16 * 1024 * 1024) return NULL;
    char *body = malloc((size_t)content_length + 1);
    if (!body) return NULL;
    if (fread(body, 1, (size_t)content_length, stdin) != (size_t)content_length) {
        free(body);
        return NULL;
    }
    body[content_length] = '\0';
    return body;
}

/* ---- request-field extraction (flat requests only) --------------- */

static char *json_get_string(const char *json, const char *key) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    while (*p == ' ') p++;
    if (*p != '"') return NULL;
    p++;
    strbuf sb;
    strbuf_init(&sb);
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n': strbuf_append_char(&sb, '\n'); break;
                case 't': strbuf_append_char(&sb, '\t'); break;
                case '\\': strbuf_append_char(&sb, '\\'); break;
                case '"': strbuf_append_char(&sb, '"'); break;
                case '/': strbuf_append_char(&sb, '/'); break;
                default: strbuf_append_char(&sb, '\\');
                         strbuf_append_char(&sb, *p); break;
            }
        } else {
            strbuf_append_char(&sb, *p);
        }
        p++;
    }
    return strbuf_finish(&sb);
}

static int json_get_int(const char *json, const char *key, int fallback) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *p = strstr(json, pattern);
    if (!p) return fallback;
    p += strlen(pattern);
    while (*p == ' ') p++;
    return atoi(p);
}

static void json_escape_to(strbuf *sb, const char *s) {
    strbuf_append_char(sb, '"');
    for (; *s; s++) {
        switch (*s) {
            case '"': strbuf_append(sb, "\\\""); break;
            case '\\': strbuf_append(sb, "\\\\"); break;
            case '\n': strbuf_append(sb, "\\n"); break;
            case '\r': strbuf_append(sb, "\\r"); break;
            case '\t': strbuf_append(sb, "\\t"); break;
            default:
                if ((unsigned char)*s < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof(esc), "\\u%04x", (unsigned char)*s);
                    strbuf_append(sb, esc);
                } else {
                    strbuf_append_char(sb, *s);
                }
        }
    }
    strbuf_append_char(sb, '"');
}

/* ---- DAP message builders ---------------------------------------- */

static void dap_response(int request_seq, const char *command,
                         const char *body_json) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb,
        "{\"seq\":%d,\"type\":\"response\",\"request_seq\":%d,"
        "\"success\":true,\"command\":\"%s\"", g_seq++, request_seq, command);
    if (body_json) strbuf_append_fmt(&sb, ",\"body\":%s", body_json);
    strbuf_append_char(&sb, '}');
    dap_send(sb.data);
    strbuf_free(&sb);
}

static void dap_error(int request_seq, const char *command,
                      const char *message) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb,
        "{\"seq\":%d,\"type\":\"response\",\"request_seq\":%d,"
        "\"success\":false,\"command\":\"%s\",\"message\":",
        g_seq++, request_seq, command);
    json_escape_to(&sb, message);
    strbuf_append_char(&sb, '}');
    dap_send(sb.data);
    strbuf_free(&sb);
}

static void dap_event(const char *event, const char *body_json) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb, "{\"seq\":%d,\"type\":\"event\",\"event\":\"%s\"",
                      g_seq++, event);
    if (body_json) strbuf_append_fmt(&sb, ",\"body\":%s", body_json);
    strbuf_append_char(&sb, '}');
    dap_send(sb.data);
    strbuf_free(&sb);
}

static void dap_stopped(const char *reason) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb, "{\"reason\":\"%s\",\"threadId\":1,"
                      "\"allThreadsStopped\":true}", reason);
    dap_event("stopped", sb.data);
    strbuf_free(&sb);
}

/* ---- debugger state ---------------------------------------------- */

static Tape g_tape;
static int g_loaded = 0;
static int g_pos = 0;
static char *g_source_path = NULL;   /* client-side path for frame sources */

#define MAX_BP 64
static int g_bp[MAX_BP];
static int g_nbp = 0;

/* Reference encoding — no dynamic tables, refs derive from stable tape
 * indices (valid across the whole session, which DAP permits):
 *   frameId:            1 = base frame (scope 0), i+2 = t.scopes[i]
 *   locals reference:   VR_LOCALS + frameId
 *   trajectory ref:     VR_TRAJ + (name-history index)               */
#define VR_LOCALS 1000000
#define VR_TRAJ   2000000

static uint32_t frame_id_to_serial(int fid) {
    if (fid <= 1) return 0;
    int idx = fid - 2;
    if (idx < 0 || idx >= g_tape.nscopes) return 0;
    return g_tape.scopes[idx].serial;
}

static int serial_to_frame_id(uint32_t serial) {
    if (serial == 0) return 1;
    for (int i = 0; i < g_tape.nscopes; i++)
        if (g_tape.scopes[i].serial == serial) return i + 2;
    return 1;
}

static int cur_line(void) {
    return g_tape.recs[g_tape.steps[g_pos]].line;
}

/* Last source line at which frame `serial` was active at or before the
 * current position — the current line for the innermost frame, the
 * call-progress line for outer ones. 0 when the frame never assigned. */
static int frame_line_at(uint32_t serial) {
    int bound = (g_pos + 1 < g_tape.nsteps) ? g_tape.steps[g_pos + 1]
                                            : g_tape.nrecs;
    for (int i = bound - 1; i >= 0; i--)
        if (g_tape.recs[i].scope == serial)
            return g_tape.recs[g_tape.steps[g_tape.recs[i].step]].line;
    return 0;
}

static void append_source(strbuf *sb) {
    if (!g_source_path) return;
    strbuf_append(sb, ",\"source\":{\"path\":");
    json_escape_to(sb, g_source_path);
    strbuf_append_char(sb, '}');
}

/* value + trajectory label, the `p` view's cell */
static void append_binding_value(strbuf *sb, const NameHist *h) {
    const Assign *last = tape_latest_at(h, g_pos);
    strbuf sv;
    strbuf_init(&sv);
    strbuf_append(&sv, last ? last->value : "?");
    const char *label = tape_classify_at(h, g_pos, NULL);
    if (label) strbuf_append_fmt(&sv, "  [%s]", label);
    json_escape_to(sb, sv.data ? sv.data : "");
    strbuf_free(&sv);
}

/* ---- request handlers -------------------------------------------- */

static void handle_stack_trace(int rseq) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"stackFrames\":[");
    uint32_t sc = tape_scope_at(&g_tape, g_pos);
    int n = 0;
    for (;;) {
        const ScopeInfo *si = tape_scope_info(&g_tape, sc);
        const char *name = sc == 0 ? "<module>" : (si ? si->name : "?");
        int line = n == 0 ? cur_line() : frame_line_at(sc);
        if (n) strbuf_append_char(&sb, ',');
        strbuf_append_fmt(&sb, "{\"id\":%d,\"name\":", serial_to_frame_id(sc));
        json_escape_to(&sb, name);
        strbuf_append_fmt(&sb, ",\"line\":%d,\"column\":1", line);
        append_source(&sb);
        strbuf_append_char(&sb, '}');
        n++;
        /* The module chunk's own S record (depth 0) is the outermost real
         * frame; its parent is the synthetic pre-S scope 0, which would
         * render as a second "<module>" row. Emit scope 0 only when the
         * tape has no S records at all (it is then the only frame). */
        if (sc == 0 || (si && si->depth == 0)) break;
        sc = si ? si->parent : 0;
    }
    strbuf_append_fmt(&sb, "],\"totalFrames\":%d}", n);
    dap_response(rseq, "stackTrace", sb.data);
    strbuf_free(&sb);
}

static void handle_scopes(int rseq, const char *msg) {
    int fid = json_get_int(msg, "frameId", 1);
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb,
        "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":%d,"
        "\"expensive\":false}]}", VR_LOCALS + fid);
    dap_response(rseq, "scopes", sb.data);
    strbuf_free(&sb);
}

static void handle_variables(int rseq, const char *msg) {
    int ref = json_get_int(msg, "variablesReference", 0);
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"variables\":[");
    int n = 0;
    if (ref >= VR_TRAJ) {
        /* a binding's assign history — the stepper's `t <name>` view */
        int idx = ref - VR_TRAJ;
        if (idx >= 0 && idx < g_tape.nnames) {
            const NameHist *h = &g_tape.names[idx];
            ObserverSlot s;
            memset(&s, 0, sizeof s);
            for (int i = 0; i < h->n && h->a[i].step <= g_pos; i++) {
                const char *label = NULL;
                if (h->a[i].is_num) {
                    observer_slot_record_value(&s, h->a[i].num);
                    label = observer_slot_report_value(&s);
                }
                if (n) strbuf_append_char(&sb, ',');
                strbuf_append_fmt(&sb, "{\"name\":\"#%d\",\"value\":", n + 1);
                strbuf sv;
                strbuf_init(&sv);
                strbuf_append_fmt(&sv, "line %d: %s",
                    g_tape.recs[g_tape.steps[h->a[i].step]].line,
                    h->a[i].value);
                if (label) strbuf_append_fmt(&sv, "  [%s]", label);
                json_escape_to(&sb, sv.data);
                strbuf_free(&sv);
                strbuf_append(&sb, ",\"variablesReference\":0}");
                n++;
            }
            free(s.v_window);
            free(s.vr_window);
            free(s.dh_window);
        }
    } else if (ref >= VR_LOCALS) {
        uint32_t serial = frame_id_to_serial(ref - VR_LOCALS);
        for (int i = 0; i < g_tape.nnames; i++) {
            const NameHist *h = &g_tape.names[i];
            if (h->scope != serial) continue;
            if (trace_name_is_internal(h->name)) continue;
            if (!tape_latest_at(h, g_pos)) continue;
            if (n) strbuf_append_char(&sb, ',');
            strbuf_append(&sb, "{\"name\":");
            json_escape_to(&sb, h->name);
            strbuf_append(&sb, ",\"value\":");
            append_binding_value(&sb, h);
            strbuf_append_fmt(&sb, ",\"variablesReference\":%d}", VR_TRAJ + i);
            n++;
        }
    }
    strbuf_append(&sb, "]}");
    dap_response(rseq, "variables", sb.data);
    strbuf_free(&sb);
}

static void handle_set_breakpoints(int rseq, const char *msg) {
    g_nbp = 0;
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"breakpoints\":[");
    /* Scan "line": occurrences inside the breakpoints array — the
     * request's only other "line" fields live in the same array's
     * source-breakpoint objects, so a flat scan is exact here. */
    const char *arr = strstr(msg, "\"breakpoints\":");
    int n = 0;
    if (arr) {
        const char *p = arr;
        while ((p = strstr(p, "\"line\":")) != NULL) {
            int line = atoi(p + 7);
            p += 7;
            int verified = 0;
            if (g_loaded) {
                for (int q = 0; q < g_tape.nsteps; q++)
                    if (g_tape.recs[g_tape.steps[q]].line == line) {
                        verified = 1;
                        break;
                    }
            }
            if (g_nbp < MAX_BP) g_bp[g_nbp++] = line;
            if (n) strbuf_append_char(&sb, ',');
            strbuf_append_fmt(&sb, "{\"verified\":%s,\"line\":%d}",
                              verified ? "true" : "false", line);
            n++;
        }
    }
    strbuf_append(&sb, "]}");
    dap_response(rseq, "setBreakpoints", sb.data);
    strbuf_free(&sb);
}

/* continue / reverseContinue: run to the next breakpoint stop in `dir`,
 * else to the tape edge. Always ends in a stopped event — a tape
 * session never terminates by running off the end (that would forfeit
 * stepBack, the whole point). */
static void run_to_breakpoint(int dir) {
    int q = g_pos, hit = 0;
    while (q + dir >= 0 && q + dir < g_tape.nsteps) {
        q += dir;
        int line = g_tape.recs[g_tape.steps[q]].line;
        for (int k = 0; k < g_nbp; k++)
            if (g_bp[k] == line) { hit = 1; break; }
        if (hit) break;
    }
    g_pos = q;
    dap_stopped(hit ? "breakpoint" : "step");
}

static void handle_evaluate(int rseq, const char *msg) {
    char *expr = json_get_string(msg, "expression");
    if (!expr) { dap_error(rseq, "evaluate", "no expression"); return; }
    /* Resolve from the requested frame outward (hover/watch semantics);
     * bare names only — the tape holds folds, not an evaluator. */
    int fid = json_get_int(msg, "frameId", 0);
    uint32_t sc = fid > 0 ? frame_id_to_serial(fid) : tape_scope_at(&g_tape, g_pos);
    const NameHist *h = NULL;
    for (;;) {
        h = tape_hist_for(&g_tape, expr, sc, 0);
        if (h && tape_latest_at(h, g_pos)) break;
        h = NULL;
        if (sc == 0) break;
        const ScopeInfo *si = tape_scope_info(&g_tape, sc);
        sc = si ? si->parent : 0;
    }
    if (!h) {
        strbuf sb;
        strbuf_init(&sb);
        strbuf_append_fmt(&sb, "no binding '%s' at this point", expr);
        dap_error(rseq, "evaluate", sb.data);
        strbuf_free(&sb);
        free(expr);
        return;
    }
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"result\":");
    append_binding_value(&sb, h);
    strbuf_append_fmt(&sb, ",\"variablesReference\":%d}",
                      VR_TRAJ + (int)(h - g_tape.names));
    dap_response(rseq, "evaluate", sb.data);
    strbuf_free(&sb);
    free(expr);
}

static void handle_launch(int rseq, const char *msg) {
    char *tape_path = json_get_string(msg, "tape");
    if (!tape_path) {
        dap_error(rseq, "launch",
                  "launch needs a \"tape\" path (record one with "
                  "EIGS_TRACE=run.tape eigenscript prog.eigs)");
        return;
    }
    free(g_source_path);
    g_source_path = json_get_string(msg, "source");
    if (g_loaded) { tape_free(&g_tape); g_loaded = 0; }
    int rc = tape_open(&g_tape, tape_path, NULL);
    if (rc != 0) {
        strbuf sb;
        strbuf_init(&sb);
        strbuf_append_fmt(&sb, rc == 3
            ? "tape '%s' refused (version/format mismatch or empty — "
              "stderr has the reason; a tape is valid only for the "
              "EigenScript that recorded it, docs/TRACE.md)"
            : rc == 4
            ? "tape '%s' has no line events — nothing to step"
            : "cannot read tape '%s'", tape_path);
        dap_error(rseq, "launch", sb.data);
        strbuf_free(&sb);
        free(tape_path);
        return;
    }
    g_loaded = 1;
    g_pos = 0;
    dap_response(rseq, "launch", NULL);
    {
        int nA = 0, nN = 0;
        for (int i = 0; i < g_tape.nrecs; i++) {
            if (g_tape.recs[i].kind == 'A') nA++;
            if (g_tape.recs[i].kind == 'N') nN++;
        }
        strbuf sb;
        strbuf_init(&sb);
        strbuf_append(&sb, "{\"category\":\"console\",\"output\":");
        strbuf sv;
        strbuf_init(&sv);
        strbuf_append_fmt(&sv, "tape %s: %d steps, %d assigns (%d bindings), "
                          "%d nondet records\n",
                          tape_path, g_tape.nsteps, nA, g_tape.nnames, nN);
        json_escape_to(&sb, sv.data);
        strbuf_free(&sv);
        strbuf_append_char(&sb, '}');
        dap_event("output", sb.data);
        strbuf_free(&sb);
    }
    free(tape_path);
}

/* ---- main loop ---------------------------------------------------- */

int main(void) {
    /* Like --step (main.c): a pure tape reader, but the trajectory
     * classifier reads the observer thresholds through the attached
     * EigsState — without one, the first classify is a NULL deref. */
    EigsState *st = eigs_state_new();
    eigs_thread_attach(st);
    /* stdout carries the protocol; stderr is the log channel. */
    for (;;) {
        char *msg = dap_read_message();
        if (!msg) break;
        char *command = json_get_string(msg, "command");
        int rseq = json_get_int(msg, "seq", 0);
        if (!command) { free(msg); continue; }

        if (strcmp(command, "initialize") == 0) {
            dap_response(rseq, "initialize",
                "{\"supportsConfigurationDoneRequest\":true,"
                "\"supportsStepBack\":true,"
                "\"supportsEvaluateForHovers\":true}");
            dap_event("initialized", NULL);
        } else if (strcmp(command, "launch") == 0) {
            handle_launch(rseq, msg);
        } else if (strcmp(command, "setBreakpoints") == 0) {
            handle_set_breakpoints(rseq, msg);
        } else if (strcmp(command, "setExceptionBreakpoints") == 0) {
            dap_response(rseq, "setExceptionBreakpoints", NULL);
        } else if (strcmp(command, "configurationDone") == 0) {
            dap_response(rseq, "configurationDone", NULL);
            if (g_loaded) dap_stopped("entry");
        } else if (strcmp(command, "threads") == 0) {
            dap_response(rseq, "threads",
                "{\"threads\":[{\"id\":1,\"name\":\"tape\"}]}");
        } else if (!g_loaded) {
            dap_error(rseq, command, "no tape loaded");
        } else if (strcmp(command, "stackTrace") == 0) {
            handle_stack_trace(rseq);
        } else if (strcmp(command, "scopes") == 0) {
            handle_scopes(rseq, msg);
        } else if (strcmp(command, "variables") == 0) {
            handle_variables(rseq, msg);
        } else if (strcmp(command, "evaluate") == 0) {
            handle_evaluate(rseq, msg);
        } else if (strcmp(command, "next") == 0 ||
                   strcmp(command, "stepIn") == 0 ||
                   strcmp(command, "stepOut") == 0) {
            /* One tape position forward — on a recorded tape the three
             * granularities coincide (an L record IS the statement). */
            if (g_pos + 1 < g_tape.nsteps) g_pos++;
            dap_response(rseq, command, NULL);
            dap_stopped("step");
        } else if (strcmp(command, "stepBack") == 0) {
            if (g_pos > 0) g_pos--;
            dap_response(rseq, "stepBack", NULL);
            dap_stopped("step");
        } else if (strcmp(command, "continue") == 0) {
            dap_response(rseq, "continue", "{\"allThreadsContinued\":true}");
            run_to_breakpoint(1);
        } else if (strcmp(command, "reverseContinue") == 0) {
            dap_response(rseq, "reverseContinue", NULL);
            run_to_breakpoint(-1);
        } else if (strcmp(command, "pause") == 0) {
            dap_response(rseq, "pause", NULL);   /* a tape is always paused */
            dap_stopped("pause");
        } else if (strcmp(command, "disconnect") == 0) {
            dap_response(rseq, "disconnect", NULL);
            free(command);
            free(msg);
            break;
        } else {
            dap_error(rseq, command, "unsupported request");
        }
        free(command);
        free(msg);
    }
    if (g_loaded) tape_free(&g_tape);
    free(g_source_path);
    eigs_thread_detach();
    eigs_state_destroy(st);
    return 0;
}
