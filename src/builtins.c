/*
 * EigenScript built-in functions.
 * All 119 language builtins plus the registration table.
 * Extension builtins (HTTP, DB, model) live in ext_*.c and model_*.c.
 */

#include "eigenscript.h"
#include "builtins_internal.h"
#include <pthread.h>
#include <termios.h>

#if EIGENSCRIPT_EXT_HTTP
#include "ext_http_internal.h"
#endif

#if EIGENSCRIPT_EXT_DB
#include "ext_db_internal.h"
#endif

#if EIGENSCRIPT_EXT_MODEL
#include "model_internal.h"
#endif

/* Internal helpers defined in eigenscript.c. */
void runtime_error(int line, const char *fmt, ...);
Value* make_num_permanent(double n);
const char* val_type_name(ValType t);
int dict_has(Value *dict, const char *key);
void dict_remove(Value *dict, const char *key);
extern int g_try_depth;

Value* builtin_print(Value *arg) {
    char *s = value_to_string(arg);
    printf("%s\n", s);
    fflush(stdout);
    free(s);
    return make_null();
}

/* write of value — output without trailing newline */
Value* builtin_write(Value *arg) {
    char *s = value_to_string(arg);
    fputs(s, stdout);
    free(s);
    return make_null();
}

/* flush of null — flush stdout */
Value* builtin_flush(Value *arg) {
    (void)arg;
    fflush(stdout);
    return make_null();
}

/* raw_key of null — non-blocking single keypress read.
 * Returns the key as a string, or "" if no key pressed.
 * Sets terminal to raw mode on first call, restores on exit. */
static struct termios g_orig_termios;
static int g_raw_mode = 0;

static void restore_terminal(void) {
    if (g_raw_mode) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
        g_raw_mode = 0;
    }
}

static void enable_raw_mode(void) {
    if (g_raw_mode) return;
    tcgetattr(STDIN_FILENO, &g_orig_termios);
    atexit(restore_terminal);
    struct termios raw = g_orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON);
    raw.c_cc[VMIN] = 0;   /* non-blocking */
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    g_raw_mode = 1;
}

Value* builtin_raw_key(Value *arg) {
    (void)arg;
    enable_raw_mode();
    char buf[4] = {0};
    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
    if (n <= 0) return make_str("");
    buf[n] = '\0';
    /* Arrow keys come as ESC [ A/B/C/D */
    if (buf[0] == 27 && n >= 3 && buf[1] == '[') {
        switch (buf[2]) {
            case 'A': return make_str("up");
            case 'B': return make_str("down");
            case 'C': return make_str("right");
            case 'D': return make_str("left");
        }
    }
    return make_str(buf);
}

/* usleep of microseconds — pause execution */
Value* builtin_usleep(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    int us = (int)arg->data.num;
    if (us > 0) usleep(us);
    return make_null();
}

/* screen_put of [row, col, char, color_code] — write a character at terminal position */
Value* builtin_screen_put(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    int row = (int)arg->data.list.items[0]->data.num;
    int col = (int)arg->data.list.items[1]->data.num;
    const char *ch = arg->data.list.items[2]->type == VAL_STR ? arg->data.list.items[2]->data.str : " ";
    int color = (arg->data.list.count >= 4 && arg->data.list.items[3]->type == VAL_NUM)
                ? (int)arg->data.list.items[3]->data.num : 0;
    if (color > 0)
        printf("\033[%d;%dH\033[%dm%s", row, col, color, ch);
    else
        printf("\033[%d;%dH%s", row, col, ch);
    return make_null();
}

/* screen_clear of null — clear terminal and hide cursor */
Value* builtin_screen_clear(Value *arg) {
    (void)arg;
    printf("\033[2J\033[H\033[?25l");
    fflush(stdout);
    return make_null();
}

/* screen_end of null — show cursor and reset */
Value* builtin_screen_end(Value *arg) {
    (void)arg;
    printf("\033[?25h\033[0m\n");
    fflush(stdout);
    return make_null();
}

/* screen_render of [entities_list, screen_w, screen_h, player_x, player_y, world_w, world_h]
 * entities_list: [[wx, wy, char, color], ...]
 * Clears screen, projects all entities, flushes once. All in C. */
Value* builtin_screen_render(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 7) return make_null();
    Value *entities = arg->data.list.items[0];
    int sw = (int)arg->data.list.items[1]->data.num;
    int sh = (int)arg->data.list.items[2]->data.num;
    double px = arg->data.list.items[3]->data.num;
    double py = arg->data.list.items[4]->data.num;
    double ww = arg->data.list.items[5]->data.num;
    double wh = arg->data.list.items[6]->data.num;

    if (!entities || entities->type != VAL_LIST) return make_null();

    double vw = sw * 0.5;
    double vh = sh * 0.5;
    double hvw = vw / 2.0;
    double hvh = vh / 2.0;

    /* Allocate screen buffer */
    int buf_size = sw * sh;
    char *chars = calloc(buf_size, 1);
    int *cols = calloc(buf_size, sizeof(int));
    memset(chars, ' ', buf_size);

    /* Project entities */
    for (int i = 0; i < entities->data.list.count; i++) {
        Value *ent = entities->data.list.items[i];
        if (!ent || ent->type != VAL_LIST || ent->data.list.count < 4) continue;
        double ex = ent->data.list.items[0]->data.num;
        double ey = ent->data.list.items[1]->data.num;
        const char *ch = ent->data.list.items[2]->type == VAL_STR ? ent->data.list.items[2]->data.str : " ";
        int color = (int)ent->data.list.items[3]->data.num;

        /* Torus delta */
        double dx = ex - px;
        double half_ww = ww * 0.5;
        if (dx > half_ww) dx -= ww;
        else if (dx < -half_ww) dx += ww;
        double dy = ey - py;
        double half_wh = wh * 0.5;
        if (dy > half_wh) dy -= wh;
        else if (dy < -half_wh) dy += wh;

        int col = (int)((dx + hvw) / vw * sw);
        int row = (int)((dy + hvh) / vh * sh);
        if (col >= 0 && col < sw && row >= 0 && row < sh) {
            int idx = row * sw + col;
            chars[idx] = ch[0];
            cols[idx] = color;
        }
    }

    /* Dump to terminal */
    printf("\033[H"); /* home */
    int prev_color = 0;
    for (int row = 0; row < sh; row++) {
        for (int col = 0; col < sw; col++) {
            int idx = row * sw + col;
            int c = cols[idx];
            if (c != prev_color) {
                if (c > 0) printf("\033[%dm", c);
                else printf("\033[0m");
                prev_color = c;
            }
            putchar(chars[idx]);
        }
        putchar('\n');
    }
    printf("\033[0m");
    fflush(stdout);

    free(chars);
    free(cols);
    return make_null();
}

/* join of [list, separator] — concatenate list elements into a string.
 * C-backed for performance — single allocation instead of O(n²) concat. */
Value* builtin_join(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    Value *list = arg->data.list.items[0];
    Value *sep_val = arg->data.list.items[1];
    if (!list || list->type != VAL_LIST) return make_str("");
    const char *sep = (sep_val && sep_val->type == VAL_STR) ? sep_val->data.str : "";
    int sep_len = strlen(sep);

    /* First pass: compute total length */
    int count = list->data.list.count;
    if (count == 0) return make_str("");

    char **parts = malloc(count * sizeof(char*));
    int *lengths = malloc(count * sizeof(int));
    int total = 0;
    for (int i = 0; i < count; i++) {
        parts[i] = value_to_string(list->data.list.items[i]);
        lengths[i] = strlen(parts[i]);
        total += lengths[i];
        if (i > 0) total += sep_len;
    }

    /* Single allocation */
    char *result = malloc(total + 1);
    int pos = 0;
    for (int i = 0; i < count; i++) {
        if (i > 0 && sep_len > 0) {
            memcpy(result + pos, sep, sep_len);
            pos += sep_len;
        }
        memcpy(result + pos, parts[i], lengths[i]);
        pos += lengths[i];
        free(parts[i]);
    }
    result[pos] = '\0';
    free(parts);
    free(lengths);

    Value *v = make_str(result);
    free(result);
    return v;
}

/* ==== Bitwise operations ====
 * Semantics: operate on 32-bit two's-complement ints. Shift amounts are
 * masked to [0,31] so large/negative shifts are defined behavior, not UB.
 * Non-numeric args yield 0. */

static int bit_pair(Value *arg, uint32_t *a_out, uint32_t *b_out) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return 0;
    Value *va = arg->data.list.items[0];
    Value *vb = arg->data.list.items[1];
    if (!va || va->type != VAL_NUM || !vb || vb->type != VAL_NUM) return 0;
    *a_out = (uint32_t)(int32_t)va->data.num;
    *b_out = (uint32_t)(int32_t)vb->data.num;
    return 1;
}

Value* builtin_bit_and(Value *arg) {
    uint32_t a, b;
    if (!bit_pair(arg, &a, &b)) return make_num(0);
    return make_num((double)(int32_t)(a & b));
}

Value* builtin_bit_or(Value *arg) {
    uint32_t a, b;
    if (!bit_pair(arg, &a, &b)) return make_num(0);
    return make_num((double)(int32_t)(a | b));
}

Value* builtin_bit_xor(Value *arg) {
    uint32_t a, b;
    if (!bit_pair(arg, &a, &b)) return make_num(0);
    return make_num((double)(int32_t)(a ^ b));
}

Value* builtin_bit_not(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    uint32_t a = (uint32_t)(int32_t)arg->data.num;
    return make_num((double)(int32_t)(~a));
}

Value* builtin_bit_shift_left(Value *arg) {
    uint32_t a, b;
    if (!bit_pair(arg, &a, &b)) return make_num(0);
    return make_num((double)(int32_t)(a << (b & 31)));
}

Value* builtin_bit_shift_right(Value *arg) {
    uint32_t a, b;
    if (!bit_pair(arg, &a, &b)) return make_num(0);
    return make_num((double)(a >> (b & 31)));
}

Value* builtin_len(Value *arg) {
    if (arg->type == VAL_LIST)
        return make_num(arg->data.list.count);
    if (arg->type == VAL_STR)
        return make_num(strlen(arg->data.str));
    if (arg->type == VAL_DICT)
        return make_num(arg->data.dict.count);
    return make_num(0);
}

Value* builtin_str(Value *arg) {
    char *s = value_to_string(arg);
    Value *v = make_str(s);
    free(s);
    return v;
}

Value* builtin_num(Value *arg) {
    if (!arg) return make_num(0);
    if (arg->type == VAL_NUM) return arg;
    if (arg->type == VAL_STR) return make_num(strtod(arg->data.str, NULL));
    if (arg->type == VAL_NULL) return make_num(0);
    return make_num(0);
}

Value* builtin_append(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *target = arg->data.list.items[0];
    Value *item = arg->data.list.items[1];
    if (target->type == VAL_LIST) {
        list_append(target, item);
    }
    return target;
}


Value* builtin_report(Value *arg) {
    if (!arg) return make_str("equilibrium");
    double dh = arg->dH;
    double h = arg->entropy;
    double prev_dh = arg->prev_dH;
    if (prev_dh != 0.0 && dh * prev_dh < 0 && fabs(dh) > 0.001)
        return make_str("oscillating");
    if (dh > 0.01) return make_str("diverging");
    if (dh < -0.01) return make_str("improving");
    if (fabs(dh) < 0.001 && h < 0.1) return make_str("converged");
    if (fabs(dh) < 0.001) return make_str("equilibrium");
    if (fabs(dh) < 0.01 && h >= 0.1) return make_str("stable");
    return make_str("stable");
}

Value* builtin_assert(Value *arg) {
    if (arg->type == VAL_LIST && arg->data.list.count >= 2) {
        Value *cond = arg->data.list.items[0];
        Value *msg = arg->data.list.items[1];
        if (!is_truthy(cond)) {
            char *msg_str = value_to_string(msg);
            fprintf(stderr, "ASSERT FAIL: %s\n", msg_str);
            free(msg_str);
            exit(1);
        }
        return make_null();
    }
    if (!is_truthy(arg)) {
        fprintf(stderr, "ASSERT FAIL\n");
        exit(1);
    }
    return make_null();
}

Value* builtin_throw(Value *arg) {
    char *msg = value_to_string(arg);
    snprintf(g_error_msg, sizeof(g_error_msg), "%s", msg);
    g_has_error = 1;
    if (g_try_depth == 0) {
        fprintf(stderr, "%s\n", g_error_msg);
    }
    free(msg);
    return make_null();
}

/* ==== Dict builtins ==== */

Value* builtin_keys(Value *arg) {
    if (arg->type == VAL_DICT) {
        Value *list = make_list(arg->data.dict.count);
        for (int i = 0; i < arg->data.dict.count; i++)
            list_append(list, make_str(arg->data.dict.keys[i]));
        return list;
    }
    return make_list(0);
}

Value* builtin_values(Value *arg) {
    if (arg->type == VAL_DICT) {
        Value *list = make_list(arg->data.dict.count);
        for (int i = 0; i < arg->data.dict.count; i++)
            list_append(list, arg->data.dict.vals[i]);
        return list;
    }
    return make_list(0);
}

Value* builtin_has_key(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    if (d->type != VAL_DICT || key->type != VAL_STR) return make_num(0);
    return make_num(dict_has(d, key->data.str) ? 1 : 0);
}

Value* builtin_dict_set(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    Value *val = arg->data.list.items[2];
    if (d->type != VAL_DICT || key->type != VAL_STR) return make_null();
    dict_set(d, key->data.str, val);
    return d;
}

Value* builtin_dict_remove(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    if (d->type != VAL_DICT || key->type != VAL_STR) return make_null();
    dict_remove(d, key->data.str);
    return d;
}

Value* builtin_observe(Value *arg) {
    Value *list = make_list(4);
    if (!arg) {
        list_append(list, make_str("equilibrium"));
        list_append(list, make_num(0.0));
        list_append(list, make_num(0.0));
        list_append(list, make_num(0.0));
        return list;
    }
    Value *rep = builtin_report(arg);
    list_append(list, rep);
    list_append(list, make_num(arg->entropy));
    list_append(list, make_num(arg->dH));
    list_append(list, make_num(arg->prev_dH));
    return list;
}

Value* builtin_type(Value *arg) {
    if (!arg) return make_str("none");
    switch (arg->type) {
        case VAL_NUM: return make_str("num");
        case VAL_STR: return make_str("str");
        case VAL_LIST: return make_str("list");
        case VAL_FN: return make_str("fn");
        case VAL_BUILTIN: return make_str("builtin");
        case VAL_NULL: return make_str("none");
        case VAL_JSON_RAW: return make_str("json_raw");
        case VAL_DICT: return make_str("dict");
    }
    return make_str("none");
}

static void eigs_json_encode_value(Value *v, strbuf *out) {
    if (!v || v->type == VAL_NULL || v->type == VAL_FN || v->type == VAL_BUILTIN) {
        strbuf_append(out, "null");
        return;
    }
    switch (v->type) {
        case VAL_NUM: {
            double n = v->data.num;
            if (n == (int)n && fabs(n) < 1e15)
                strbuf_append_fmt(out, "%d", (int)n);
            else
                strbuf_append_fmt(out, "%.15g", n);
            break;
        }
        case VAL_STR: {
            strbuf_append_char(out, '"');
            for (const char *c = v->data.str; *c; c++) {
                switch (*c) {
                    case '"': strbuf_append_n(out, "\\\"", 2); break;
                    case '\\': strbuf_append_n(out, "\\\\", 2); break;
                    case '\n': strbuf_append_n(out, "\\n", 2); break;
                    case '\r': strbuf_append_n(out, "\\r", 2); break;
                    case '\t': strbuf_append_n(out, "\\t", 2); break;
                    default: strbuf_append_char(out, *c); break;
                }
            }
            strbuf_append_char(out, '"');
            break;
        }
        case VAL_LIST: {
            strbuf_append_char(out, '[');
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) strbuf_append_char(out, ',');
                eigs_json_encode_value(v->data.list.items[i], out);
            }
            strbuf_append_char(out, ']');
            break;
        }
        default:
            strbuf_append(out, "null");
            break;
    }
}

Value* builtin_json_encode(Value *arg) {
    strbuf out;
    strbuf_init(&out);
    eigs_json_encode_value(arg, &out);
    Value *result = make_str(out.data);
    strbuf_free(&out);
    return result;
}

Value* eigs_json_parse_value(const char *s, int *pos);

static void eigs_json_skip_ws(const char *s, int *pos) {
    while (s[*pos] && (s[*pos] == ' ' || s[*pos] == '\t' || s[*pos] == '\n' || s[*pos] == '\r'))
        (*pos)++;
}

static Value* eigs_json_parse_string(const char *s, int *pos) {
    if (s[*pos] != '"') return NULL;
    (*pos)++;
    strbuf buf;
    strbuf_init(&buf);
    while (s[*pos] && s[*pos] != '"') {
        if (s[*pos] == '\\') {
            (*pos)++;
            switch (s[*pos]) {
                case '"': strbuf_append_char(&buf, '"'); break;
                case '\\': strbuf_append_char(&buf, '\\'); break;
                case 'n': strbuf_append_char(&buf, '\n'); break;
                case 'r': strbuf_append_char(&buf, '\r'); break;
                case 't': strbuf_append_char(&buf, '\t'); break;
                case '/': strbuf_append_char(&buf, '/'); break;
                default: strbuf_append_char(&buf, s[*pos]); break;
            }
        } else {
            strbuf_append_char(&buf, s[*pos]);
        }
        (*pos)++;
    }
    if (s[*pos] == '"') (*pos)++;
    Value *v = make_str(buf.data);
    strbuf_free(&buf);
    return v;
}

static Value* eigs_json_parse_number(const char *s, int *pos) {
    char numbuf[64];
    int len = 0;
    if (s[*pos] == '-') numbuf[len++] = s[(*pos)++];
    while (s[*pos] && (isdigit(s[*pos]) || s[*pos] == '.' || s[*pos] == 'e' || s[*pos] == 'E' || s[*pos] == '+') && len < 63) {
        numbuf[len++] = s[(*pos)++];
    }
    numbuf[len] = '\0';
    return make_num(atof(numbuf));
}

static Value* eigs_json_parse_array(const char *s, int *pos) {
    (*pos)++;
    Value *list = make_list(8);
    eigs_json_skip_ws(s, pos);
    if (s[*pos] == ']') { (*pos)++; return list; }
    while (s[*pos]) {
        eigs_json_skip_ws(s, pos);
        Value *val = eigs_json_parse_value(s, pos);
        if (val) list_append(list, val);
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == ']') { (*pos)++; break; }
        break;
    }
    return list;
}

static Value* eigs_json_parse_object(const char *s, int *pos) {
    (*pos)++;
    Value *list = make_list(8);
    eigs_json_skip_ws(s, pos);
    if (s[*pos] == '}') { (*pos)++; return list; }
    while (s[*pos]) {
        eigs_json_skip_ws(s, pos);
        Value *key = eigs_json_parse_string(s, pos);
        if (!key) break;
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ':') (*pos)++;
        eigs_json_skip_ws(s, pos);
        Value *val = eigs_json_parse_value(s, pos);
        list_append(list, key);
        list_append(list, val ? val : make_null());
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == '}') { (*pos)++; break; }
        break;
    }
    return list;
}

Value* eigs_json_parse_value(const char *s, int *pos) {
    eigs_json_skip_ws(s, pos);
    if (!s[*pos]) return make_null();
    if (s[*pos] == '"') return eigs_json_parse_string(s, pos);
    if (s[*pos] == '[') return eigs_json_parse_array(s, pos);
    if (s[*pos] == '{') return eigs_json_parse_object(s, pos);
    if (s[*pos] == '-' || isdigit(s[*pos])) return eigs_json_parse_number(s, pos);
    if (strncmp(s + *pos, "null", 4) == 0) { *pos += 4; return make_null(); }
    if (strncmp(s + *pos, "true", 4) == 0) { *pos += 4; return make_num(1); }
    if (strncmp(s + *pos, "false", 5) == 0) { *pos += 5; return make_num(0); }
    return make_null();
}

Value* builtin_json_decode(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        fprintf(stderr, "Type error: json_decode requires a string, got %s\n",
                arg ? val_type_name(arg->type) : "null");
        return make_null();
    }
    int pos = 0;
    return eigs_json_parse_value(arg->data.str, &pos);
}

Value* builtin_coalesce(Value *arg) {
    /* coalesce of [value, default] — returns value unless empty/null */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return arg ? arg : make_null();
    Value *val = arg->data.list.items[0];
    Value *def = arg->data.list.items[1];
    if (!val || val->type == VAL_NULL) return def;
    if (val->type == VAL_STR && val->data.str[0] == '\0') return def;
    return val;
}

Value* builtin_json_build(Value *arg) {
    /* json_build of [key1, val1, key2, val2, ...] — properly escaped JSON object */
    if (!arg || arg->type != VAL_LIST) return make_str("{}");
    int count = arg->data.list.count;
    int buf_size = count * 256 + 64;
    if (buf_size < 1024) buf_size = 1024;
    char *buf = xcalloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "{");
    for (int i = 0; i + 1 < count && pos < buf_size - 64; i += 2) {
        if (i > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
        char *key = value_to_string(arg->data.list.items[i]);
        Value *val = arg->data.list.items[i + 1];
        pos += snprintf(buf + pos, buf_size - pos, "\"%s\": ", key);
        free(key);
        if (val->type == VAL_STR) {
            char *vs = val->data.str;
            buf[pos++] = '"';
            for (int j = 0; vs[j] && pos < buf_size - 10; j++) {
                if (vs[j] == '"') { buf[pos++] = '\\'; buf[pos++] = '"'; }
                else if (vs[j] == '\\') { buf[pos++] = '\\'; buf[pos++] = '\\'; }
                else if (vs[j] == '\n') { buf[pos++] = '\\'; buf[pos++] = 'n'; }
                else if (vs[j] == '\t') { buf[pos++] = '\\'; buf[pos++] = 't'; }
                else buf[pos++] = vs[j];
            }
            buf[pos++] = '"';
        } else if (val->type == VAL_NUM) {
            double d = val->data.num;
            if (d == (double)(int)d && d >= -1e9 && d <= 1e9)
                pos += snprintf(buf + pos, buf_size - pos, "%d", (int)d);
            else
                pos += snprintf(buf + pos, buf_size - pos, "%.6f", d);
        } else if (val->type == VAL_NULL) {
            pos += snprintf(buf + pos, buf_size - pos, "null");
        } else if (val->type == VAL_JSON_RAW) {
            pos += snprintf(buf + pos, buf_size - pos, "%s", val->data.str);
        } else {
            char *vs = value_to_string(val);
            pos += snprintf(buf + pos, buf_size - pos, "\"%s\"", vs);
            free(vs);
        }
    }
    pos += snprintf(buf + pos, buf_size - pos, "}");
    Value *result = make_str(buf);
    free(buf);
    return result;
}

Value* builtin_json_raw(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    Value *v = xmalloc(sizeof(Value));
    memset(v, 0, sizeof(Value));
    v->type = VAL_JSON_RAW;
    v->data.str = xstrdup(arg->data.str);
    return v;
}

/* ================================================================
 * GENERIC STRING PRIMITIVES — language-level, no product logic
 * ================================================================ */

Value* builtin_str_lower(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *s = xstrdup(arg->data.str);
    for (int i = 0; s[i]; i++) s[i] = tolower((unsigned char)s[i]);
    Value *r = make_str(s);
    free(s);
    return r;
}

Value* builtin_contains(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    const char *haystack = "", *needle = "";
    if (arg->data.list.items[0]->type == VAL_STR) haystack = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) needle = arg->data.list.items[1]->data.str;
    return make_num(strstr(haystack, needle) != NULL ? 1 : 0);
}

Value* builtin_starts_with(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    const char *str = "", *prefix = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) prefix = arg->data.list.items[1]->data.str;
    return make_num(strncmp(str, prefix, strlen(prefix)) == 0 ? 1 : 0);
}

Value* builtin_split(Value *arg) {
    const char *str = "", *delim = " ";
    if (arg && arg->type == VAL_STR) {
        str = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
        if (arg->data.list.count >= 2 && arg->data.list.items[1]->type == VAL_STR)
            delim = arg->data.list.items[1]->data.str;
    }
    Value *list = make_list(0);
    char *copy = xstrdup(str);
    char *saveptr;
    char *token = strtok_r(copy, delim, &saveptr);
    while (token) {
        list_append(list, make_str(token));
        token = strtok_r(NULL, delim, &saveptr);
    }
    free(copy);
    return list;
}

Value* builtin_trim(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    while (*s && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')) s++;
    int len = strlen(s);
    while (len > 0 && (s[len-1] == ' ' || s[len-1] == '\t' || s[len-1] == '\n' || s[len-1] == '\r')) len--;
    char *r = xmalloc(len + 1);
    memcpy(r, s, len);
    r[len] = '\0';
    Value *result = make_str(r);
    free(r);
    return result;
}

Value* builtin_str_replace(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    const char *str = "", *old_s = "", *new_s = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) old_s = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_STR) new_s = arg->data.list.items[2]->data.str;
    int old_len = strlen(old_s), new_len = strlen(new_s), str_len = strlen(str);
    if (old_len == 0) return make_str(str);
    /* Count occurrences to size buffer */
    int count = 0;
    const char *p = str;
    while ((p = strstr(p, old_s)) != NULL) { count++; p += old_len; }
    int result_len = str_len + count * (new_len - old_len);
    char *result = xmalloc(result_len + 1);
    char *dst = result;
    p = str;
    while (*p) {
        if (strncmp(p, old_s, old_len) == 0) {
            memcpy(dst, new_s, new_len);
            dst += new_len;
            p += old_len;
        } else {
            *dst++ = *p++;
        }
    }
    *dst = '\0';
    Value *r = make_str(result);
    free(result);
    return r;
}

/* ==== BUILTIN: match — regex match, return list of groups ==== */
/* match of [string, pattern] -> [full_match, group1, ...] or [] */
Value* builtin_match(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_list(0);
    if (arg->data.list.items[0]->type != VAL_STR || arg->data.list.items[1]->type != VAL_STR)
        return make_list(0);
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;

    regex_t re;
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) return make_list(0);

    regmatch_t matches[16];
    if (regexec(&re, str, 16, matches, 0) != 0) {
        regfree(&re);
        return make_list(0);
    }

    Value *result = make_list(8);
    for (int i = 0; i < 16 && matches[i].rm_so >= 0; i++) {
        int len = matches[i].rm_eo - matches[i].rm_so;
        char *buf = xmalloc(len + 1);
        memcpy(buf, str + matches[i].rm_so, len);
        buf[len] = '\0';
        list_append(result, make_str(buf));
        free(buf);
    }
    regfree(&re);
    return result;
}

/* ==== BUILTIN: match_all — find all matches of pattern ==== */
/* match_all of [string, pattern] -> [match1, match2, ...] */
Value* builtin_match_all(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_list(0);
    if (arg->data.list.items[0]->type != VAL_STR || arg->data.list.items[1]->type != VAL_STR)
        return make_list(0);
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;

    regex_t re;
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) return make_list(0);

    Value *result = make_list(16);
    regmatch_t m[1];
    const char *p = str;
    while (regexec(&re, p, 1, m, 0) == 0) {
        int len = m[0].rm_eo - m[0].rm_so;
        char *buf = xmalloc(len + 1);
        memcpy(buf, p + m[0].rm_so, len);
        buf[len] = '\0';
        list_append(result, make_str(buf));
        free(buf);
        p += m[0].rm_eo;
        if (len == 0) p++; /* avoid infinite loop on zero-length match */
        if (!*p) break;
    }
    regfree(&re);
    return result;
}

/* ==== BUILTIN: regex_replace — replace all matches ==== */
/* regex_replace of [string, pattern, replacement] -> string */
Value* builtin_regex_replace(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    if (arg->data.list.items[0]->type != VAL_STR ||
        arg->data.list.items[1]->type != VAL_STR ||
        arg->data.list.items[2]->type != VAL_STR)
        return make_str("");
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;
    const char *replacement = arg->data.list.items[2]->data.str;

    regex_t re;
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) return make_str(str);

    strbuf out;
    strbuf_init(&out);
    const char *p = str;
    regmatch_t m[1];
    size_t rep_len = strlen(replacement);

    while (regexec(&re, p, 1, m, 0) == 0) {
        strbuf_append_n(&out, p, (size_t)m[0].rm_so);
        strbuf_append_n(&out, replacement, rep_len);
        p += m[0].rm_eo;
        if (m[0].rm_eo == m[0].rm_so) {
            if (*p) strbuf_append_char(&out, *p++);
            else break;
        }
    }
    strbuf_append(&out, p);

    regfree(&re);
    Value *v = make_str(out.data);
    strbuf_free(&out);
    return v;
}

/* ==== BUILTIN: str_upper ==== */
Value* builtin_str_upper(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *s = xstrdup(arg->data.str);
    for (int i = 0; s[i]; i++) s[i] = toupper((unsigned char)s[i]);
    Value *r = make_str(s);
    free(s);
    return r;
}

/* ==== BUILTIN: char_at ==== */
/* char_at of [string, index] → single character as string, or "" if out of range */
Value* builtin_char_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    Value *str_val = arg->data.list.items[0];
    Value *idx_val = arg->data.list.items[1];
    if (!str_val || str_val->type != VAL_STR || !idx_val || idx_val->type != VAL_NUM)
        return make_str("");
    int idx = (int)idx_val->data.num;
    int len = strlen(str_val->data.str);
    if (idx < 0 || idx >= len) return make_str("");
    char buf[2] = { str_val->data.str[idx], '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: ends_with ==== */
Value* builtin_ends_with(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    const char *str = "", *suffix = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) suffix = arg->data.list.items[1]->data.str;
    int slen = strlen(str), xlen = strlen(suffix);
    if (xlen > slen) return make_num(0);
    return make_num(strcmp(str + slen - xlen, suffix) == 0 ? 1 : 0);
}

/* ==== BUILTIN: substr ==== */
/* substr of [string, start, length] → substring */
Value* builtin_substr(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    Value *str_val = arg->data.list.items[0];
    Value *start_val = arg->data.list.items[1];
    Value *len_val = arg->data.list.items[2];
    if (!str_val || str_val->type != VAL_STR) return make_str("");
    if (!start_val || start_val->type != VAL_NUM) return make_str("");
    if (!len_val || len_val->type != VAL_NUM) return make_str("");
    int slen = strlen(str_val->data.str);
    int start = (int)start_val->data.num;
    int rlen = (int)len_val->data.num;
    if (start < 0) start = 0;
    if (start >= slen) return make_str("");
    if (rlen < 0) rlen = 0;
    if (start + rlen > slen) rlen = slen - start;
    char *buf = xmalloc(rlen + 1);
    memcpy(buf, str_val->data.str + start, rlen);
    buf[rlen] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* ==== BUILTIN: index_of ==== */
/* index_of of [haystack, needle] → first index, or -1 */
Value* builtin_index_of(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(-1);
    const char *haystack = "", *needle = "";
    if (arg->data.list.items[0]->type == VAL_STR) haystack = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) needle = arg->data.list.items[1]->data.str;
    const char *p = strstr(haystack, needle);
    if (!p) return make_num(-1);
    return make_num((double)(p - haystack));
}

/* ================================================================
 * MATH BUILTINS — trig, rounding, abs
 * ================================================================ */

Value* builtin_sin(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(sin(arg->data.num));
}

Value* builtin_cos(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(cos(arg->data.num));
}

Value* builtin_tan(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(tan(arg->data.num));
}

Value* builtin_asin(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(asin(arg->data.num));
}

Value* builtin_acos(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(acos(arg->data.num));
}

Value* builtin_atan(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(atan(arg->data.num));
}

Value* builtin_atan2(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *y = arg->data.list.items[0];
    Value *x = arg->data.list.items[1];
    if (!y || y->type != VAL_NUM || !x || x->type != VAL_NUM) return make_num(0);
    return make_num(atan2(y->data.num, x->data.num));
}

Value* builtin_floor(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(floor(arg->data.num));
}

Value* builtin_ceil(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(ceil(arg->data.num));
}

Value* builtin_round(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(round(arg->data.num));
}

Value* builtin_abs(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(fabs(arg->data.num));
}

Value* builtin_min(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_NUM || !b || b->type != VAL_NUM) return make_num(0);
    return make_num(a->data.num < b->data.num ? a->data.num : b->data.num);
}

Value* builtin_max(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_NUM || !b || b->type != VAL_NUM) return make_num(0);
    return make_num(a->data.num > b->data.num ? a->data.num : b->data.num);
}

Value* builtin_pi(Value *arg) {
    (void)arg;
    return make_num(3.14159265358979323846);
}

/* ================================================================
 * SYSTEM BUILTINS — random, args, paths, filesystem
 * ================================================================ */

static int g_random_seeded = 0;

static void ensure_random_seeded(void) {
    if (!g_random_seeded) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        srand48(ts.tv_sec ^ ts.tv_nsec ^ getpid());
        g_random_seeded = 1;
    }
}

/* random of null → float in [0, 1) */
Value* builtin_random(Value *arg) {
    (void)arg;
    ensure_random_seeded();
    return make_num(drand48());
}

/* random_int of [lo, hi] → integer in [lo, hi] inclusive */
Value* builtin_random_int(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *lo = arg->data.list.items[0];
    Value *hi = arg->data.list.items[1];
    if (!lo || lo->type != VAL_NUM || !hi || hi->type != VAL_NUM)
        return make_num(0);
    ensure_random_seeded();
    int lo_i = (int)lo->data.num;
    int hi_i = (int)hi->data.num;
    if (hi_i < lo_i) return make_num(lo_i);
    return make_num(lo_i + (lrand48() % (hi_i - lo_i + 1)));
}

/* seed_random of n → seeds the RNG, returns 1 */
Value* builtin_seed_random(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    srand48((long)arg->data.num);
    g_random_seeded = 1;
    return make_num(1);
}

/* ================================================================
 * STREAMING BINARY WRITER — write tensor-format data incrementally
 * ================================================================
 * stream_open of ["path", count]  → opens file, writes header with count, returns 1
 * stream_write of value           → writes one float64, returns 1
 * stream_close of null            → closes the stream file, returns 1
 *
 * Format: [uint32 ndim=1][uint32 rows=1][uint32 cols=count][uint32 flags=0]
 *         then count × float64 values (written one at a time via stream_write)
 */

static FILE *g_stream_file = NULL;

Value* builtin_stream_open(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *count_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR || !count_val || count_val->type != VAL_NUM)
        return make_num(0);
    if (g_stream_file) { fclose(g_stream_file); g_stream_file = NULL; }
    g_stream_file = fopen(path_val->data.str, "wb");
    if (!g_stream_file) return make_num(0);
    uint32_t count = (uint32_t)count_val->data.num;
    uint32_t header[4] = { 1, 1, count, 0 }; /* ndim=1, rows=1, cols=count, flags=0 */
    fwrite(header, sizeof(uint32_t), 4, g_stream_file);
    return make_num(1);
}

Value* builtin_stream_write(Value *arg) {
    if (!g_stream_file || !arg || arg->type != VAL_NUM) return make_num(0);
    double val = arg->data.num;
    fwrite(&val, sizeof(double), 1, g_stream_file);
    return make_num(1);
}

Value* builtin_stream_close(Value *arg) {
    (void)arg;
    if (!g_stream_file) return make_num(0);
    int ok = (fclose(g_stream_file) == 0);
    g_stream_file = NULL;
    return make_num(ok ? 1 : 0);
}

/* ---- Command-line arguments ---- */
static int g_argc = 0;
static char **g_argv = NULL;

void eigenscript_set_args(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}

/* args of null → list of command-line arguments (after the script name) */
Value* builtin_args(Value *arg) {
    (void)arg;
    Value *list = make_list(g_argc > 2 ? g_argc - 2 : 0);
    /* g_argv[0] = eigenscript, g_argv[1] = script.eigs, g_argv[2..] = user args */
    for (int i = 2; i < g_argc; i++) {
        list_append(list, make_str(g_argv[i]));
    }
    return list;
}

/* ---- Path manipulation ---- */

/* path_join of [a, b] → "a/b" */
Value* builtin_path_join(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_str("");
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_STR || !b || b->type != VAL_STR)
        return make_str("");
    int alen = strlen(a->data.str);
    int blen = strlen(b->data.str);
    /* Skip trailing slash on a, skip leading slash on b */
    int strip_a = (alen > 0 && a->data.str[alen-1] == '/') ? 1 : 0;
    int skip_b = (blen > 0 && b->data.str[0] == '/') ? 1 : 0;
    int rlen = (alen - strip_a) + 1 + (blen - skip_b);
    char *buf = xmalloc(rlen + 1);
    memcpy(buf, a->data.str, alen - strip_a);
    buf[alen - strip_a] = '/';
    memcpy(buf + alen - strip_a + 1, b->data.str + skip_b, blen - skip_b);
    buf[rlen] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* path_dir of "a/b/c.txt" → "a/b" */
Value* builtin_path_dir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    if (!last) return make_str(".");
    if (last == s) return make_str("/");
    int len = last - s;
    char *buf = xmalloc(len + 1);
    memcpy(buf, s, len);
    buf[len] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* path_base of "a/b/c.txt" → "c.txt" */
Value* builtin_path_base(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    return make_str(last ? last + 1 : s);
}

/* path_ext of "a/b/c.txt" → ".txt" */
Value* builtin_path_ext(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *base = strrchr(arg->data.str, '/');
    const char *s = base ? base + 1 : arg->data.str;
    const char *dot = strrchr(s, '.');
    return make_str(dot ? dot : "");
}

/* ---- Filesystem ---- */

/* mkdir of "path" → 1 on success, 0 on failure. Creates parents. */
Value* builtin_mkdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    /* Simple recursive mkdir */
    char *path = xstrdup(arg->data.str);
    int len = strlen(path);
    for (int i = 1; i <= len; i++) {
        if (path[i] == '/' || path[i] == '\0') {
            char saved = path[i];
            path[i] = '\0';
            mkdir(path, 0755); /* ignore errors on intermediate dirs */
            path[i] = saved;
        }
    }
    free(path);
    struct stat st;
    return make_num(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : 0);
}

/* ls of "path" → list of filenames in directory, or [] on failure.
 * Matches `ls -1` default behavior: hidden entries (starting with '.') are excluded. */
Value* builtin_ls(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    Value *list = make_list(0);
    DIR *d = opendir(arg->data.str);
    if (!d) return list;
    struct dirent *entry;
    while ((entry = readdir(d))) {
        if (entry->d_name[0] == '.') continue;
        list_append(list, make_str(entry->d_name));
    }
    closedir(d);
    return list;
}

/* getcwd of null → current working directory as string */
Value* builtin_getcwd(Value *arg) {
    (void)arg;
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) return make_str(buf);
    return make_str("");
}

/* chdir of "path" → 1 on success, 0 on failure */
Value* builtin_chdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(chdir(arg->data.str) == 0 ? 1 : 0);
}

/* mktemp of null → path to a new temporary file */
Value* builtin_mktemp(Value *arg) {
    (void)arg;
    char tmpl[] = "/tmp/eigen_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return make_str("");
    close(fd);
    return make_str(tmpl);
}

/* free_val of value → frees a heap-allocated Value tree. Returns null.
 * Use this to release large temporary results (e.g. tokenize_with_names output)
 * when the arena is not active. No-op on arena-allocated values. */
Value* builtin_free_val(Value *arg) {
    if (arg && !g_arena.active) free_value(arg);
    return make_null();
}

/* rm of "path" → 1 on success, 0 on failure */
Value* builtin_rm(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(unlink(arg->data.str) == 0 ? 1 : 0);
}

/* ================================================================
 * BUILTIN: build_corpus — 3-pass corpus builder in C
 * ================================================================
 * build_corpus of [file_list, top_n, stream_path, vocab_path]
 *
 * file_list:    list of strings (paths to .eigs files)
 * top_n:        number of identifier tokens to promote (e.g. 64)
 * stream_path:  output path for binary token stream
 * vocab_path:   output path for identifier vocab JSON
 *
 * Returns: [stream_length, distinct_identifiers, files_found]
 */

/* Identifier frequency entry */
typedef struct {
    char *name;
    int count;
} IdentEntry;

Value* builtin_build_corpus(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4)
        return make_null();

    Value *file_list = arg->data.list.items[0];
    Value *topn_val = arg->data.list.items[1];
    Value *stream_path_val = arg->data.list.items[2];
    Value *vocab_path_val = arg->data.list.items[3];

    if (!file_list || file_list->type != VAL_LIST) return make_null();
    if (!topn_val || topn_val->type != VAL_NUM) return make_null();
    if (!stream_path_val || stream_path_val->type != VAL_STR) return make_null();
    if (!vocab_path_val || vocab_path_val->type != VAL_STR) return make_null();

    int top_n = (int)topn_val->data.num;
    int n_files = file_list->data.list.count;
    const int FIRST_IDENT = 54;
    const int BASE_VOCAB = 54;

    /* ---- Pass 1: tokenize all files, count identifier frequencies ---- */
    IdentEntry *idents = NULL;
    int n_idents = 0;
    int idents_cap = 0;

    int *file_tok_counts = xcalloc(n_files, sizeof(int));
    int total_tokens = 0;
    int files_found = 0;

    for (int fi = 0; fi < n_files; fi++) {
        Value *path_val = file_list->data.list.items[fi];
        if (!path_val || path_val->type != VAL_STR) { file_tok_counts[fi] = 0; continue; }
        const char *path = path_val->data.str;

        /* Read file */
        long fsize = 0;
        char *source = read_file_util(path, &fsize);
        if (!source) {
            fprintf(stderr, "  skip: %s\n", path);
            file_tok_counts[fi] = 0;
            continue;
        }

        /* Tokenize */
        TokenList tl = tokenize(source);
        file_tok_counts[fi] = tl.count;
        total_tokens += tl.count;
        files_found++;

        /* Count identifiers */
        for (int i = 0; i < tl.count; i++) {
            if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                const char *name = tl.tokens[i].str_val;
                /* Linear scan for existing entry */
                int found = -1;
                for (int j = 0; j < n_idents; j++) {
                    if (strcmp(idents[j].name, name) == 0) { found = j; break; }
                }
                if (found >= 0) {
                    idents[found].count++;
                } else {
                    if (n_idents >= idents_cap) {
                        idents_cap = idents_cap < 256 ? 256 : idents_cap * 2;
                        idents = xrealloc_array(idents, idents_cap, sizeof(IdentEntry));
                    }
                    idents[n_idents].name = xstrdup(name);
                    idents[n_idents].count = 1;
                    n_idents++;
                }
            }
        }

        fprintf(stderr, "  %s: %d tokens\n", path, tl.count);
        free_tokenlist(&tl);
        free(source);
    }

    fprintf(stderr, "\nFiles: %d/%d\n", files_found, n_files);
    fprintf(stderr, "Distinct identifiers: %d\n", n_idents);

    /* ---- Pass 2: pick top-N identifiers ---- */
    int actual_top = top_n < n_idents ? top_n : n_idents;
    if (actual_top <= 0) actual_top = 0;
    char **top_names = xcalloc(actual_top > 0 ? actual_top : 1, sizeof(char*));
    int *top_ids = xcalloc(actual_top > 0 ? actual_top : 1, sizeof(int));

    /* Work on a copy of counts */
    int *work_counts = xmalloc_array(n_idents, sizeof(int));
    for (int i = 0; i < n_idents; i++) work_counts[i] = idents[i].count;

    for (int t = 0; t < actual_top; t++) {
        int best_idx = -1, best_val = -1;
        for (int j = 0; j < n_idents; j++) {
            if (work_counts[j] > best_val) { best_val = work_counts[j]; best_idx = j; }
        }
        if (best_idx < 0) break;
        top_names[t] = idents[best_idx].name;
        top_ids[t] = FIRST_IDENT + t;
        work_counts[best_idx] = -1;
    }
    free(work_counts);

    fprintf(stderr, "\nTop %d identifiers:\n", actual_top);
    for (int i = 0; i < 10 && i < actual_top; i++) {
        fprintf(stderr, "  %3d  %-20s  %d uses\n", top_ids[i], top_names[i],
                idents[top_ids[i] - FIRST_IDENT].count);
    }

    /* ---- Pass 3: re-tokenize and write binary stream ---- */
    int stream_size = total_tokens + files_found * 2; /* +2 EOF per file */

    FILE *stream_file = fopen(stream_path_val->data.str, "wb");
    if (!stream_file) {
        fprintf(stderr, "Error: cannot open %s\n", stream_path_val->data.str);
        free(file_tok_counts); free(top_names); free(top_ids);
        for (int i = 0; i < n_idents; i++) free(idents[i].name);
        free(idents);
        return make_null();
    }

    /* Write header: ndim=1, rows=1, cols=stream_size, flags=0 */
    uint32_t header[4] = { 1, 1, (uint32_t)stream_size, 0 };
    fwrite(header, sizeof(uint32_t), 4, stream_file);
    int stream_pos = 0;

    for (int fi = 0; fi < n_files; fi++) {
        if (file_tok_counts[fi] <= 0) continue;

        Value *path_val = file_list->data.list.items[fi];
        long fsize = 0;
        char *source = read_file_util(path_val->data.str, &fsize);
        if (!source) continue;

        /* Write double-EOF separator */
        double eof_val = (double)TOK_EOF;
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        stream_pos += 2;

        TokenList tl = tokenize(source);

        for (int i = 0; i < tl.count; i++) {
            int tid = tl.tokens[i].type;
            /* Replace known identifiers with extended IDs */
            if (tid == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                for (int j = 0; j < actual_top; j++) {
                    if (strcmp(top_names[j], tl.tokens[i].str_val) == 0) {
                        tid = top_ids[j];
                        break;
                    }
                }
            }
            double d = (double)tid;
            fwrite(&d, sizeof(double), 1, stream_file);
            stream_pos++;
        }

        free_tokenlist(&tl);
        free(source);
    }

    fclose(stream_file);
    fprintf(stderr, "\nWritten: %s (%d tokens)\n", stream_path_val->data.str, stream_pos);

    /* ---- Write identifier vocab JSON ---- */
    FILE *vocab_file = fopen(vocab_path_val->data.str, "w");
    if (vocab_file) {
        fprintf(vocab_file, "{\"first_ident_id\": %d, \"ext_vocab_size\": %d, \"top_n\": %d, \"names\": [",
                FIRST_IDENT, BASE_VOCAB + top_n, top_n);
        for (int i = 0; i < actual_top; i++) {
            if (i > 0) fprintf(vocab_file, ", ");
            fprintf(vocab_file, "\"%s\"", top_names[i]);
        }
        fprintf(vocab_file, "]}");
        fclose(vocab_file);
        fprintf(stderr, "Written: %s\n", vocab_path_val->data.str);
    }

    /* ---- Cleanup ---- */
    free(file_tok_counts);
    free(top_names);
    free(top_ids);
    for (int i = 0; i < n_idents; i++) free(idents[i].name);
    free(idents);

    /* Return [stream_length, distinct_identifiers, files_found] */
    Value *result = make_list(3);
    list_append(result, make_num(stream_pos));
    list_append(result, make_num(n_idents));
    list_append(result, make_num(files_found));
    return result;
}

/* ================================================================
 * GENERIC HTTP CLIENT — language-level, no product logic
 * ================================================================ */


/* ================================================================
 * JSON PATH — dot-notation extraction from nested JSON
 * ================================================================ */

/* json_obj_get: needed by json_path, defined here if model extension is disabled */
#if !(EIGENSCRIPT_EXT_MODEL)
static Value* json_obj_get(Value *obj, const char *key) {
    if (!obj || obj->type != VAL_LIST) return NULL;
    for (int i = 0; i + 1 < obj->data.list.count; i += 2) {
        Value *k = obj->data.list.items[i];
        if (k && k->type == VAL_STR && strcmp(k->data.str, key) == 0)
            return obj->data.list.items[i + 1];
    }
    return NULL;
}
#endif

Value* builtin_json_path(Value *arg) {
    /* json_path of [json_string, "dot.path"] -> value as string, or "" */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    const char *json_str = "", *path = "";
    if (arg->data.list.items[0]->type == VAL_STR) json_str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) path = arg->data.list.items[1]->data.str;

    int pos = 0;
    Value *current = eigs_json_parse_value(json_str, &pos);
    if (!current) return make_str("");

    char path_copy[1024];
    strncpy(path_copy, path, sizeof(path_copy) - 1);
    path_copy[sizeof(path_copy) - 1] = '\0';
    char *saveptr;
    char *segment = strtok_r(path_copy, ".", &saveptr);

    while (segment && current) {
        if (current->type == VAL_LIST) {
            /* Could be an object (key-value pairs) or array */
            /* Try numeric index first */
            char *endp;
            long idx = strtol(segment, &endp, 10);
            if (*endp == '\0') {
                /* Numeric: treat as array index */
                /* Arrays from json_decode are VAL_LIST with sequential elements */
                if (idx >= 0 && idx < current->data.list.count) {
                    current = current->data.list.items[idx];
                } else {
                    return make_str("");
                }
            } else {
                /* String key: treat as object lookup */
                current = json_obj_get(current, segment);
                if (!current) return make_str("");
            }
        } else {
            return make_str("");
        }
        segment = strtok_r(NULL, ".", &saveptr);
    }

    if (!current) return make_str("");
    if (current->type == VAL_STR) return make_str(current->data.str);
    if (current->type == VAL_NUM) {
        char buf[64];
        double d = current->data.num;
        if (d == (double)(int)d && fabs(d) < 1e9)
            snprintf(buf, sizeof(buf), "%d", (int)d);
        else
            snprintf(buf, sizeof(buf), "%.6f", d);
        return make_str(buf);
    }
    if (current->type == VAL_NULL) return make_str("");
    /* For complex types, json_encode them */
    strbuf out;
    strbuf_init(&out);
    eigs_json_encode_value(current, &out);
    Value *r = make_str(out.data);
    strbuf_free(&out);
    return r;
}


/* ================================================================
 * LOAD_FILE — include mechanism for .eigs modules
 * ================================================================ */

/* File I/O helper — used by load_file and main() */
char* read_file_util(const char *path, long *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = xmalloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, size, f);
    fclose(f);
    if ((long)got != size) { free(buf); return NULL; }
    buf[size] = '\0';
    if (out_size) *out_size = size;
    return buf;
}

Value* builtin_load_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        fprintf(stderr, "load_file: requires a string path argument\n");
        return make_null();
    }
    const char *path = arg->data.str;
    long size = 0;
    char *source = read_file_util(path, &size);

    /* Fallback: try relative to script directory, then its parent */
    char resolved[8192];
    if (!source && path[0] != '/') {
        snprintf(resolved, sizeof(resolved), "%.4000s/%.4000s", g_script_dir, path);
        source = read_file_util(resolved, &size);
        if (source) path = resolved;
    }
    if (!source && path[0] != '/') {
        snprintf(resolved, sizeof(resolved), "%.4000s/../%.4000s", g_script_dir, path);
        source = read_file_util(resolved, &size);
        if (source) path = resolved;
    }

    if (!source) {
        fprintf(stderr, "load_file: cannot read '%s'\n", arg->data.str);
        return make_null();
    }
    fprintf(stderr, "[load_file] Loading %s (%ld bytes)\n", path, size);
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    Value *result = eval_node(ast, g_global_env);
    free(source);
    free_tokenlist(&tl);
    return result ? result : make_null();
}

/* ================================================================
 * THIN BUILTINS — individual capabilities for .eigs orchestration
 * ================================================================ */


/* ================================================================
 * CORE PLATFORM BUILTINS (always available)
 * ================================================================ */

Value* builtin_file_exists(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    FILE *f = fopen(arg->data.str, "r");
    if (f) { fclose(f); return make_num(1); }
    return make_num(0);
}

Value* builtin_env_get(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *val = getenv(arg->data.str);
    return make_str(val ? val : "");
}

/* ==== BUILTIN: read_text ==== */
/* read_text of "path" → file contents as string, or "" on failure. */
Value* builtin_read_text(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    FILE *f = fopen(arg->data.str, "r");
    if (!f) return make_str("");
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 10 * 1024 * 1024) { /* 10 MB cap */
        fclose(f);
        return make_str("");
    }
    char *buf = xmalloc(len + 1);
    if (!buf) { fclose(f); return make_str(""); }
    size_t read = fread(buf, 1, len, f);
    fclose(f);
    buf[read] = '\0';
    Value *result = make_str(buf);
    free(buf);
    return result;
}

/* ==== BUILTIN: write_text ==== */
/* write_text of ["path", text] → 1 on success, 0 on failure. */
Value* builtin_write_text(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *text_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR ||
        !text_val || text_val->type != VAL_STR)
        return make_num(0);
    FILE *f = fopen(path_val->data.str, "w");
    if (!f) return make_num(0);
    size_t len = strlen(text_val->data.str);
    size_t written = fwrite(text_val->data.str, 1, len, f);
    int close_ok = (fclose(f) == 0);
    return make_num(written == len && close_ok ? 1 : 0);
}

/* ==== BUILTIN: exec_capture ==== */
/* exec_capture of ["cmd", "arg1", ...]               → [exit_code, stdout_text]
 * exec_capture of [["cmd", "arg1", ...], timeout_sec] → same, with timeout
 *
 * Runs a subprocess with fork/exec, captures stdout. No shell.
 * Child stdin is /dev/null. 10 MB output cap.
 *
 * Timeout form: pass a 2-element list where the first element is the
 * command list and the second is the timeout in seconds.
 * On timeout the child is killed and the return is [-2, partial_stdout].
 *
 * Always returns a 2-item list. Returns [-1, ""] on failure. */

static Value* exec_capture_result(int code, const char *text) {
    Value *result = make_list(2);
    result->data.list.items[0] = make_num(code);
    result->data.list.items[1] = make_str(text);
    result->data.list.count = 2;
    return result;
}

Value* builtin_exec_capture(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1)
        return exec_capture_result(-1, "");

    /* Detect timeout form: [["cmd", ...], timeout_num] */
    double timeout_sec = -1;
    Value *cmd_list = arg;
    if (arg->data.list.count == 2
        && arg->data.list.items[0] && arg->data.list.items[0]->type == VAL_LIST
        && arg->data.list.items[1] && arg->data.list.items[1]->type == VAL_NUM) {
        cmd_list = arg->data.list.items[0];
        timeout_sec = arg->data.list.items[1]->data.num;
        if (cmd_list->data.list.count < 1)
            return exec_capture_result(-1, "");
    }

    int total = cmd_list->data.list.count;

    /* Build argv array */
    char **argv = xmalloc_array((size_t)total + 1, sizeof(char*));
    if (!argv) return exec_capture_result(-1, "");
    for (int i = 0; i < total; i++) {
        Value *v = cmd_list->data.list.items[i];
        if (!v || v->type != VAL_STR) {
            free(argv);
            return exec_capture_result(-1, "");
        }
        argv[i] = v->data.str;
    }
    argv[total] = NULL;

    /* Create pipe for stdout capture */
    int pipefd[2];
    if (pipe(pipefd) != 0) { free(argv); return exec_capture_result(-1, ""); }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return exec_capture_result(-1, "");
    }

    if (pid == 0) {
        /* Child: redirect stdout to pipe, stdin to /dev/null */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        execvp(argv[0], argv);
        _exit(127); /* exec failed */
    }

    /* Parent: read from pipe, close write end */
    close(pipefd[1]);
    free(argv);

    /* Compute deadline */
    struct timespec deadline;
    int has_timeout = (timeout_sec >= 0);
    if (has_timeout) {
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += (time_t)timeout_sec;
        deadline.tv_nsec += (long)((timeout_sec - (time_t)timeout_sec) * 1e9);
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000L;
        }
    }

    size_t cap = 4096, len = 0;
    char *buf = xmalloc(cap + 1);
    if (!buf) {
        close(pipefd[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return exec_capture_result(-1, "");
    }

    int timed_out = 0;

    /* Read loop with optional timeout via poll() */
    for (;;) {
        int poll_ms = -1; /* infinite */
        if (has_timeout) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long remaining_ms = (deadline.tv_sec - now.tv_sec) * 1000
                              + (deadline.tv_nsec - now.tv_nsec) / 1000000;
            if (remaining_ms <= 0) { timed_out = 1; break; }
            poll_ms = (int)remaining_ms;
        }

        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        int pr = poll(&pfd, 1, poll_ms);
        if (pr == 0) { timed_out = 1; break; }       /* timeout */
        if (pr < 0) { if (errno == EINTR) continue; break; } /* error */

        ssize_t n = read(pipefd[0], buf + len, cap - len);
        if (n <= 0) break; /* EOF or error */
        len += n;
        if (len >= cap) {
            if (cap >= 10 * 1024 * 1024) break;
            size_t newcap = cap * 2;
            if (newcap > 10 * 1024 * 1024) newcap = 10 * 1024 * 1024;
            char *newbuf = xrealloc(buf, newcap + 1);
            if (!newbuf) break;
            buf = newbuf;
            cap = newcap;
        }
    }
    close(pipefd[0]);
    buf[len] = '\0';

    int exit_code;
    if (timed_out) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        exit_code = -2;
    } else {
        int status = 0;
        waitpid(pid, &status, 0);
        exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    Value *result = exec_capture_result(exit_code, buf);
    free(buf);
    return result;
}

/* ==== BUILTIN: arena_mark ==== */
/* arena_mark of null — saves current arena position. All Values allocated
 * after this point will be reclaimed on arena_reset. Call before a training step. */
Value* builtin_arena_mark(Value *arg) {
    (void)arg;
    arena_mark_pos();
    return make_null();
}

/* ==== BUILTIN: arena_reset ==== */
/* arena_reset of null — reclaims all Values allocated since the last arena_mark.
 * Call after a training step, when gradient tensors and intermediates are no longer needed. */
Value* builtin_arena_reset(Value *arg) {
    (void)arg;
    arena_reset_to_mark();
    return make_null();
}

/* ==== BUILTIN: arena_stats ==== */
/* arena_stats of null — returns total bytes allocated through the arena. */
Value* builtin_arena_stats(Value *arg) {
    (void)arg;
    return make_num((double)g_arena.total_allocated);
}

/* Free a TokenList's malloc'd storage (token array and str_vals) */
void free_tokenlist(TokenList *tl) {
    if (!tl->tokens) return;
    for (int i = 0; i < tl->count; i++) {
        if (tl->tokens[i].str_val) {
            free(tl->tokens[i].str_val);
            tl->tokens[i].str_val = NULL;
        }
    }
    free(tl->tokens);
    tl->tokens = NULL;
    tl->count = 0;
}

/* ==== BUILTIN: tokenize_ids ==== */
/* tokenize_ids of string → list of token type IDs (integers).
 * Exposes the runtime's own tokenizer to .eigs code.
 * The learner sees its world the way the runtime does. */
Value* builtin_tokenize_ids(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_list(0);

    TokenList tl = tokenize(src);
    Value *result = make_list(tl.count);
    for (int i = 0; i < tl.count; i++) {
        list_append(result, make_num((double)tl.tokens[i].type));
    }
    free_tokenlist(&tl);
    return result;
}

/* ==== BUILTIN: tokenize_with_names ==== */
/* tokenize_with_names of string → list of [type_id, name_str] pairs.
 * Like tokenize_ids, but preserves the identifier name (for IDENT), the
 * string content (for STR), and the number as a string (for NUM). Other
 * token types get an empty string. Used by corpus builders that need
 * per-identifier information for vocabulary enrichment. */
Value* builtin_tokenize_with_names(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_list(0);

    TokenList tl = tokenize(src);
    Value *result = make_list(tl.count);
    char numbuf[64];
    for (int i = 0; i < tl.count; i++) {
        Value *pair = make_list(2);
        list_append(pair, make_num((double)tl.tokens[i].type));
        const char *name = "";
        if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val) {
            name = tl.tokens[i].str_val;
        } else if (tl.tokens[i].type == TOK_STR && tl.tokens[i].str_val) {
            name = tl.tokens[i].str_val;
        } else if (tl.tokens[i].type == TOK_NUM) {
            double d = tl.tokens[i].num_val;
            if (d == (double)(long)d) {
                snprintf(numbuf, sizeof(numbuf), "%ld", (long)d);
            } else {
                snprintf(numbuf, sizeof(numbuf), "%g", d);
            }
            name = numbuf;
        }
        list_append(pair, make_str(name)); /* make_str copies the string */
        list_append(result, pair);
    }
    free_tokenlist(&tl);
    return result;
}

/* ==== BUILTIN: token_name ==== */
/* token_name of id → string name of token type (for display) */
Value* builtin_token_name(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_str("?");
    int id = (int)arg->data.num;
    static const char *names[] = {
        "NUM", "STR", "IDENT",
        "IS", "OF", "DEFINE", "AS",
        "IF", "ELSE", "ELIF", "LOOP", "WHILE",
        "RETURN", "AND", "OR", "NOT",
        "FOR", "IN", "NULL",
        "WHAT", "WHO", "WHEN", "WHERE", "WHY", "HOW",
        "CONVERGED", "STABLE", "IMPROVING", "OSCILLATING", "DIVERGING", "EQUILIBRIUM",
        "+", "-", "*", "/", "%",
        "<", ">", "<=", ">=", "==", "!=", "=",
        "(", ")", "[", "]",
        ",", ":", ".",
        "NEWLINE", "INDENT", "DEDENT",
        "EOF"
    };
    if (id >= 0 && id < 54) return make_str(names[id]);
    return make_str("?");
}

/* ==== BUILTIN: random_hex ==== */
/* random_hex of n → string of n random hex characters from /dev/urandom.
 * Capability builtin: provides randomness so .eigs libraries can generate tokens. */
Value* builtin_random_hex(Value *arg) {
    int n = (arg && arg->type == VAL_NUM) ? (int)arg->data.num : 0;
    if (n <= 0 || n > 256) return make_str("");
    int bytes_needed = (n + 1) / 2;
    unsigned char raw[128];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (!urand) return make_str("");
    size_t got = fread(raw, 1, bytes_needed, urand);
    fclose(urand);
    if ((int)got < bytes_needed) return make_str("");
    char hex[257];
    for (int i = 0; i < bytes_needed && i * 2 < n; i++)
        sprintf(hex + i * 2, "%02x", raw[i]);
    hex[n] = '\0';
    return make_str(hex);
}

/* ==== BUILTIN: http_request_headers ==== */
/* http_request_headers of null → raw request headers as string.
 * Only meaningful during HTTP request handling. */

/* ==== BUILTIN: chr ==== */
/* chr of n → single-character string from ASCII code */
Value* builtin_chr(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_str("");
    int code = (int)arg->data.num;
    if (code < 0 || code > 127) return make_str("");
    char buf[2] = { (char)code, '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: try_parse ==== */
/* try_parse of string → 1 if valid EigenScript syntax, 0 if not.
 * Tokenizes and parses without executing. Suppresses stderr. */
Value* builtin_try_parse(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_num(0);

    /* Suppress stderr during parse attempt */
    int saved_stderr = dup(STDERR_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }

    /* Reset parse error counter before parsing */
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);

    int errors = g_parse_errors;
    g_parse_errors = saved_errors; /* restore for caller */

    /* Restore stderr */
    if (saved_stderr >= 0) { dup2(saved_stderr, STDERR_FILENO); close(saved_stderr); }

    /* Valid only if: non-null AST, at least one statement, AND no parse errors */
    int valid = (ast != NULL && ast->type == AST_PROGRAM
                 && ast->data.program.count > 0 && errors == 0) ? 1 : 0;
    free_tokenlist(&tl);
    /* AST intentionally leaked — try_parse called rarely enough that this
     * is acceptable, and free_ast has edge cases with partial parses. */
    return make_num(valid);
}

/* ==== BUILTIN: eval ==== */
/* eval of code_string — execute EigenScript code and return result */
Value* builtin_eval(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_null();

    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);

    if (g_parse_errors > 0 || !ast) {
        g_parse_errors = saved_errors;
        free_tokenlist(&tl);
        runtime_error(0, "eval: parse error in code string");
        return make_null();
    }
    g_parse_errors = saved_errors;

    Value *result = eval_node(ast, g_global_env);
    free_tokenlist(&tl);
    return result ? result : make_null();
}

/* ==== BUILTIN: tensor_save ==== */
/* tensor_save of [tensor, path] — save 1D or 2D list to binary file.
 * Format: [uint32 ndim][uint32 rows][uint32 cols][uint32 flags]
 *         [float64 × N: data]
 *         [float64 × N × 5: observer state (entropy, dH, last_entropy, obs_age, prev_dH)]
 * flags bit 0 = has observer state */
/* ==== BUILTIN: copy_into ==== */
/* copy_into of [dest, dest_offset, src]
 * Copies elements from src into dest starting at dest_offset.
 * Both must be 1D lists. Mutates dest in-place, returns dest. */
Value* builtin_copy_into(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *dest = arg->data.list.items[0];
    int offset = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
    Value *src = arg->data.list.items[2];
    if (!dest || dest->type != VAL_LIST || !src || src->type != VAL_LIST) return make_null();
    for (int i = 0; i < src->data.list.count && offset + i < dest->data.list.count; i++)
        dest->data.list.items[offset + i] = src->data.list.items[i];
    return dest;
}

/* ==== BUILTIN: num_copy ==== */
/* num_copy of val → fresh heap-allocated copy of a numeric Value.
 * Use to extract a scalar from arena before arena_reset. */
Value* builtin_num_copy(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    return make_num_permanent(arg->data.num);
}

/* ==== BUILTIN: concat ==== */
/* concat of [list_a, list_b] → new 1D list with a's elements then b's */
Value* builtin_concat(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_LIST || !b || b->type != VAL_LIST) return make_null();
    int total = a->data.list.count + b->data.list.count;
    Value *result = make_list(total);
    for (int i = 0; i < a->data.list.count; i++)
        list_append(result, a->data.list.items[i]);
    for (int i = 0; i < b->data.list.count; i++)
        list_append(result, b->data.list.items[i]);
    return result;
}

/* ==== BUILTIN: range ==== */
/* range of n → [0, 1, ..., n-1]
 * range of [start, end] → [start, start+1, ..., end-1]
 * range of [start, end, step] → [start, start+step, ...] while < end (or > end if step < 0) */
Value* builtin_range(Value *arg) {
    int start = 0, end = 0, step = 1;

    if (!arg) return make_list(0);

    if (arg->type == VAL_NUM) {
        /* range of n */
        end = (int)arg->data.num;
    } else if (arg->type == VAL_LIST) {
        int argc = arg->data.list.count;
        if (argc >= 1 && arg->data.list.items[0]->type == VAL_NUM)
            start = (int)arg->data.list.items[0]->data.num;
        if (argc >= 2 && arg->data.list.items[1]->type == VAL_NUM)
            end = (int)arg->data.list.items[1]->data.num;
        else
            { end = start; start = 0; } /* single-element list: treat as range of n */
        if (argc >= 3 && arg->data.list.items[2]->type == VAL_NUM) {
            step = (int)arg->data.list.items[2]->data.num;
            if (step == 0) step = 1;
        }
    } else {
        return make_list(0);
    }

    /* Cap at 1M elements to prevent accidental OOM */
    int count = (step > 0) ? ((end - start + step - 1) / step)
                           : ((start - end - step - 1) / (-step));
    if (count < 0) count = 0;
    if (count > 1000000) count = 1000000;

    Value *result = make_list(count);
    if (step > 0) {
        for (int i = start; i < end; i += step)
            list_append(result, make_num((double)i));
    } else {
        for (int i = start; i > end; i += step)
            list_append(result, make_num((double)i));
    }
    return result;
}

/* ==== BUILTIN: set_at — mutate a list element in place ==== */
/* set_at of [list, index, value] — sets list[index] = value, returns list */
/* set_at of [list, row, col, value] — sets list[row][col] = value for 2D */
Value* builtin_set_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int argc = arg->data.list.count;
    if (argc == 3) {
        /* 1D: set_at of [list, index, value] */
        Value *list = arg->data.list.items[0];
        int idx = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        Value *val = arg->data.list.items[2];
        if (list->type == VAL_LIST && idx >= 0 && idx < list->data.list.count)
            list->data.list.items[idx] = val;
        return list;
    }
    if (argc == 4) {
        /* 2D: set_at of [list, row, col, value] */
        Value *list = arg->data.list.items[0];
        int row = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        int col = (arg->data.list.items[2]->type == VAL_NUM) ? (int)arg->data.list.items[2]->data.num : 0;
        Value *val = arg->data.list.items[3];
        if (list->type == VAL_LIST && row >= 0 && row < list->data.list.count) {
            Value *rowv = list->data.list.items[row];
            if (rowv->type == VAL_LIST && col >= 0 && col < rowv->data.list.count)
                rowv->data.list.items[col] = val;
        }
        return list;
    }
    return make_null();
}

/* ==== BUILTIN: get_at — read a list element ==== */
/* get_at of [list, index] or get_at of [list, row, col] */
Value* builtin_get_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int argc = arg->data.list.count;
    if (argc == 2) {
        Value *list = arg->data.list.items[0];
        int idx = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        if (list->type == VAL_LIST && idx >= 0 && idx < list->data.list.count)
            return list->data.list.items[idx];
        return make_num(0.0);
    }
    if (argc == 3) {
        Value *list = arg->data.list.items[0];
        int row = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        int col = (arg->data.list.items[2]->type == VAL_NUM) ? (int)arg->data.list.items[2]->data.num : 0;
        if (list->type == VAL_LIST && row >= 0 && row < list->data.list.count) {
            Value *rowv = list->data.list.items[row];
            if (rowv->type == VAL_LIST && col >= 0 && col < rowv->data.list.count)
                return rowv->data.list.items[col];
        }
        return make_num(0.0);
    }
    return make_null();
}

void register_builtins(Env *env) {
    /* ---- Core language builtins (always available) ---- */
    env_set_local(env, "print", make_builtin(builtin_print));
    env_set_local(env, "write", make_builtin(builtin_write));
    env_set_local(env, "flush", make_builtin(builtin_flush));
    env_set_local(env, "raw_key", make_builtin(builtin_raw_key));
    env_set_local(env, "usleep", make_builtin(builtin_usleep));
    env_set_local(env, "join", make_builtin(builtin_join));
    env_set_local(env, "bit_and", make_builtin(builtin_bit_and));
    env_set_local(env, "bit_or", make_builtin(builtin_bit_or));
    env_set_local(env, "bit_xor", make_builtin(builtin_bit_xor));
    env_set_local(env, "bit_not", make_builtin(builtin_bit_not));
    env_set_local(env, "bit_shl", make_builtin(builtin_bit_shift_left));
    env_set_local(env, "bit_shr", make_builtin(builtin_bit_shift_right));
    env_set_local(env, "screen_put", make_builtin(builtin_screen_put));
    env_set_local(env, "screen_clear", make_builtin(builtin_screen_clear));
    env_set_local(env, "screen_end", make_builtin(builtin_screen_end));
    env_set_local(env, "screen_render", make_builtin(builtin_screen_render));
    env_set_local(env, "len", make_builtin(builtin_len));
    env_set_local(env, "str", make_builtin(builtin_str));
    env_set_local(env, "num", make_builtin(builtin_num));
    env_set_local(env, "append", make_builtin(builtin_append));
    env_set_local(env, "report", make_builtin(builtin_report));
    env_set_local(env, "assert", make_builtin(builtin_assert));
    env_set_local(env, "throw", make_builtin(builtin_throw));
    env_set_local(env, "keys", make_builtin(builtin_keys));
    env_set_local(env, "values", make_builtin(builtin_values));
    env_set_local(env, "has_key", make_builtin(builtin_has_key));
    env_set_local(env, "dict_set", make_builtin(builtin_dict_set));
    env_set_local(env, "dict_remove", make_builtin(builtin_dict_remove));
    env_set_local(env, "observe", make_builtin(builtin_observe));
    env_set_local(env, "type", make_builtin(builtin_type));
    env_set_local(env, "json_encode", make_builtin(builtin_json_encode));
    env_set_local(env, "json_decode", make_builtin(builtin_json_decode));
    env_set_local(env, "coalesce", make_builtin(builtin_coalesce));
    env_set_local(env, "json_build", make_builtin(builtin_json_build));
    env_set_local(env, "json_raw", make_builtin(builtin_json_raw));
    env_set_local(env, "json_path", make_builtin(builtin_json_path));
    env_set_local(env, "str_lower", make_builtin(builtin_str_lower));
    env_set_local(env, "str_upper", make_builtin(builtin_str_upper));
    env_set_local(env, "char_at", make_builtin(builtin_char_at));
    env_set_local(env, "ends_with", make_builtin(builtin_ends_with));
    env_set_local(env, "substr", make_builtin(builtin_substr));
    env_set_local(env, "index_of", make_builtin(builtin_index_of));
    env_set_local(env, "sin", make_builtin(builtin_sin));
    env_set_local(env, "cos", make_builtin(builtin_cos));
    env_set_local(env, "tan", make_builtin(builtin_tan));
    env_set_local(env, "asin", make_builtin(builtin_asin));
    env_set_local(env, "acos", make_builtin(builtin_acos));
    env_set_local(env, "atan", make_builtin(builtin_atan));
    env_set_local(env, "atan2", make_builtin(builtin_atan2));
    env_set_local(env, "floor", make_builtin(builtin_floor));
    env_set_local(env, "ceil", make_builtin(builtin_ceil));
    env_set_local(env, "round", make_builtin(builtin_round));
    env_set_local(env, "abs", make_builtin(builtin_abs));
    env_set_local(env, "min", make_builtin(builtin_min));
    env_set_local(env, "max", make_builtin(builtin_max));
    env_set_local(env, "pi", make_builtin(builtin_pi));
    env_set_local(env, "random", make_builtin(builtin_random));
    env_set_local(env, "random_int", make_builtin(builtin_random_int));
    env_set_local(env, "seed_random", make_builtin(builtin_seed_random));
    env_set_local(env, "args", make_builtin(builtin_args));
    env_set_local(env, "path_join", make_builtin(builtin_path_join));
    env_set_local(env, "path_dir", make_builtin(builtin_path_dir));
    env_set_local(env, "path_base", make_builtin(builtin_path_base));
    env_set_local(env, "path_ext", make_builtin(builtin_path_ext));
    env_set_local(env, "mkdir", make_builtin(builtin_mkdir));
    env_set_local(env, "ls", make_builtin(builtin_ls));
    env_set_local(env, "getcwd", make_builtin(builtin_getcwd));
    env_set_local(env, "chdir", make_builtin(builtin_chdir));
    env_set_local(env, "mktemp", make_builtin(builtin_mktemp));
    env_set_local(env, "rm", make_builtin(builtin_rm));
    env_set_local(env, "free_val", make_builtin(builtin_free_val));
    env_set_local(env, "stream_open", make_builtin(builtin_stream_open));
    env_set_local(env, "stream_write", make_builtin(builtin_stream_write));
    env_set_local(env, "stream_close", make_builtin(builtin_stream_close));
    env_set_local(env, "build_corpus", make_builtin(builtin_build_corpus));
    env_set_local(env, "contains", make_builtin(builtin_contains));
    env_set_local(env, "starts_with", make_builtin(builtin_starts_with));
    env_set_local(env, "split", make_builtin(builtin_split));
    env_set_local(env, "trim", make_builtin(builtin_trim));
    env_set_local(env, "str_replace", make_builtin(builtin_str_replace));
    env_set_local(env, "regex_match", make_builtin(builtin_match));
    env_set_local(env, "regex_find", make_builtin(builtin_match_all));
    env_set_local(env, "regex_replace", make_builtin(builtin_regex_replace));
    env_set_local(env, "load_file", make_builtin(builtin_load_file));
    env_set_local(env, "file_exists", make_builtin(builtin_file_exists));
    env_set_local(env, "env_get", make_builtin(builtin_env_get));
    env_set_local(env, "read_text", make_builtin(builtin_read_text));
    env_set_local(env, "write_text", make_builtin(builtin_write_text));
    env_set_local(env, "exec_capture", make_builtin(builtin_exec_capture));

    /* ---- Tensor / math stdlib (always available) ---- */
    env_set_local(env, "matmul", make_builtin(builtin_tensor_matmul));
    env_set_local(env, "add", make_builtin(builtin_tensor_add));
    env_set_local(env, "subtract", make_builtin(builtin_tensor_subtract));
    env_set_local(env, "multiply", make_builtin(builtin_tensor_multiply));
    env_set_local(env, "divide", make_builtin(builtin_tensor_divide));
    env_set_local(env, "pow", make_builtin(builtin_tensor_pow));
    env_set_local(env, "sqrt", make_builtin(builtin_tensor_sqrt));
    env_set_local(env, "exp", make_builtin(builtin_tensor_exp));
    env_set_local(env, "log", make_builtin(builtin_tensor_log));
    env_set_local(env, "negative", make_builtin(builtin_tensor_negative));
    env_set_local(env, "softmax", make_builtin(builtin_tensor_softmax));
    env_set_local(env, "log_softmax", make_builtin(builtin_tensor_log_softmax));
    env_set_local(env, "relu", make_builtin(builtin_tensor_relu));
    env_set_local(env, "leaky_relu", make_builtin(builtin_tensor_leaky_relu));
    env_set_local(env, "mean", make_builtin(builtin_tensor_mean));
    env_set_local(env, "sum", make_builtin(builtin_tensor_sum));
    env_set_local(env, "zeros", make_builtin(builtin_tensor_zeros));
    env_set_local(env, "zeros_like", make_builtin(builtin_tensor_zeros_like));
    env_set_local(env, "gather", make_builtin(builtin_tensor_gather));
    env_set_local(env, "set_at", make_builtin(builtin_set_at));
    env_set_local(env, "get_at", make_builtin(builtin_get_at));
    env_set_local(env, "random_normal", make_builtin(builtin_random_normal));
    env_set_local(env, "shape", make_builtin(builtin_tensor_shape));
    env_set_local(env, "numerical_grad", make_builtin(builtin_numerical_grad));
    env_set_local(env, "numerical_grad_rows", make_builtin(builtin_numerical_grad_rows));
    env_set_local(env, "sgd_update", make_builtin(builtin_sgd_update));
    env_set_local(env, "sgd_update_rows", make_builtin(builtin_sgd_update_rows));
    env_set_local(env, "numerical_grad_cols", make_builtin(builtin_numerical_grad_cols));
    env_set_local(env, "sgd_update_cols", make_builtin(builtin_sgd_update_cols));
    env_set_local(env, "tokenize_ids", make_builtin(builtin_tokenize_ids));
    env_set_local(env, "tokenize_with_names", make_builtin(builtin_tokenize_with_names));
    env_set_local(env, "token_name", make_builtin(builtin_token_name));
    env_set_local(env, "chr", make_builtin(builtin_chr));
    env_set_local(env, "random_hex", make_builtin(builtin_random_hex));
    env_set_local(env, "try_parse", make_builtin(builtin_try_parse));
    env_set_local(env, "eval", make_builtin(builtin_eval));
    env_set_local(env, "tensor_save", make_builtin(builtin_tensor_save));
    env_set_local(env, "tensor_load", make_builtin(builtin_tensor_load));
    env_set_local(env, "copy_into", make_builtin(builtin_copy_into));
    env_set_local(env, "num_copy", make_builtin(builtin_num_copy));
    env_set_local(env, "concat", make_builtin(builtin_concat));
    env_set_local(env, "range", make_builtin(builtin_range));
    env_set_local(env, "arena_mark", make_builtin(builtin_arena_mark));
    env_set_local(env, "arena_reset", make_builtin(builtin_arena_reset));
    env_set_local(env, "arena_stats", make_builtin(builtin_arena_stats));

#if EIGENSCRIPT_EXT_HTTP
    register_http_builtins(env);
#endif

#if EIGENSCRIPT_EXT_DB
    register_db_builtins(env);
#endif

#if EIGENSCRIPT_EXT_MODEL
    register_model_builtins(env);
#endif


}


