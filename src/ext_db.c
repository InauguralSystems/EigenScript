/*
 * EigenScript Database Extension
 * PostgreSQL client, API key management, SHA256.
 */

#include "eigenscript.h"
#if EIGENSCRIPT_EXT_DB

PGconn *g_db_conn = NULL;

Value* builtin_db_connect(Value *arg) {
    (void)arg;
    const char *url = getenv("DATABASE_URL");
    if (!url || !url[0]) {
        return make_str("{\"status\": \"no_database\", \"message\": \"DATABASE_URL not set\"}");
    }

    char conn_str[4096];
    if (strchr(url, '?')) {
        snprintf(conn_str, sizeof(conn_str), "%s&connect_timeout=3", url);
    } else {
        snprintf(conn_str, sizeof(conn_str), "%s?connect_timeout=3", url);
    }
    g_db_conn = PQconnectdb(conn_str);

    if (PQstatus(g_db_conn) != CONNECTION_OK) {
        char buf[1024];
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"%s\"}", PQerrorMessage(g_db_conn));
        PQfinish(g_db_conn);
        g_db_conn = NULL;
        return make_str(buf);
    }

    return make_str("{\"status\": \"connected\", \"driver\": \"libpq\"}");
}

/* ---- SHA256 ---- */
static const uint32_t sha256_k[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define SHA256_ROTR(x,n) (((x)>>(n))|((x)<<(32-(n))))
#define SHA256_CH(x,y,z) (((x)&(y))^((~(x))&(z)))
#define SHA256_MAJ(x,y,z) (((x)&(y))^((x)&(z))^((y)&(z)))
#define SHA256_EP0(x) (SHA256_ROTR(x,2)^SHA256_ROTR(x,13)^SHA256_ROTR(x,22))
#define SHA256_EP1(x) (SHA256_ROTR(x,6)^SHA256_ROTR(x,11)^SHA256_ROTR(x,25))
#define SHA256_SIG0(x) (SHA256_ROTR(x,7)^SHA256_ROTR(x,18)^((x)>>3))
#define SHA256_SIG1(x) (SHA256_ROTR(x,17)^SHA256_ROTR(x,19)^((x)>>10))

static void sha256_hash(const unsigned char *data, size_t len, unsigned char out[32]) {
    uint32_t h0=0x6a09e667, h1=0xbb67ae85, h2=0x3c6ef372, h3=0xa54ff53a;
    uint32_t h4=0x510e527f, h5=0x9b05688c, h6=0x1f83d9ab, h7=0x5be0cd19;

    size_t new_len = len + 1;
    while (new_len % 64 != 56) new_len++;
    new_len += 8;

    unsigned char *msg = calloc(new_len, 1);
    memcpy(msg, data, len);
    msg[len] = 0x80;

    uint64_t bits_len = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++)
        msg[new_len - 1 - i] = (unsigned char)(bits_len >> (i * 8));

    for (size_t offset = 0; offset < new_len; offset += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)msg[offset+i*4]<<24) | ((uint32_t)msg[offset+i*4+1]<<16) |
                    ((uint32_t)msg[offset+i*4+2]<<8) | (uint32_t)msg[offset+i*4+3];
        for (int i = 16; i < 64; i++)
            w[i] = SHA256_SIG1(w[i-2]) + w[i-7] + SHA256_SIG0(w[i-15]) + w[i-16];

        uint32_t a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7;
        for (int i = 0; i < 64; i++) {
            uint32_t t1 = h + SHA256_EP1(e) + SHA256_CH(e,f,g) + sha256_k[i] + w[i];
            uint32_t t2 = SHA256_EP0(a) + SHA256_MAJ(a,b,c);
            h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        }
        h0+=a; h1+=b; h2+=c; h3+=d; h4+=e; h5+=f; h6+=g; h7+=h;
    }
    free(msg);

    uint32_t hh[8] = {h0,h1,h2,h3,h4,h5,h6,h7};
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (hh[i]>>24)&0xff;
        out[i*4+1] = (hh[i]>>16)&0xff;
        out[i*4+2] = (hh[i]>>8)&0xff;
        out[i*4+3] = hh[i]&0xff;
    }
}

static void sha256_hex(const char *input, char hex_out[65]) {
    unsigned char hash[32];
    sha256_hash((const unsigned char*)input, strlen(input), hash);
    for (int i = 0; i < 32; i++)
        sprintf(hex_out + i*2, "%02x", hash[i]);
    hex_out[64] = '\0';
}


static void ensure_api_keys_table(void) {
    if (!g_db_conn) return;
    PQexec(g_db_conn,
        "CREATE TABLE IF NOT EXISTS api_keys ("
        "id SERIAL PRIMARY KEY, "
        "name TEXT, "
        "key_hash TEXT, "
        "key_prefix TEXT, "
        "created_at TIMESTAMP DEFAULT NOW(), "
        "last_used TIMESTAMP, "
        "is_active BOOLEAN DEFAULT TRUE)");
    PGresult *r = PQexec(g_db_conn, "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS key_prefix TEXT");
    PQclear(r);
}

/* ---- DB query builtins ---- */
Value* builtin_db_query_value(Value *arg) {
    /* Run a SQL query and return the value from row 0 col 0 as a string.
     * Usage: db_query_value of "SELECT COUNT(*) FROM table"
     * Returns "" if no DB, query fails, or no rows. */
    if (!arg || arg->type != VAL_STR) return make_str("");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("");
    PGresult *res = PQexec(g_db_conn, arg->data.str);
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return make_str("");
    }
    const char *val = PQgetvalue(res, 0, 0);
    Value *result = make_str(val ? val : "");
    PQclear(res);
    return result;
}

Value* builtin_db_execute(Value *arg) {
    /* Run a SQL command with optional params. Returns "ok" or "error".
     * Usage: db_execute of "INSERT INTO ..." (no params)
     *    or: db_execute of ["INSERT INTO t (a) VALUES ($1)", param1] */
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("no_db");
    PGresult *res = NULL;

    if (arg && arg->type == VAL_STR) {
        res = PQexec(g_db_conn, arg->data.str);
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        const char *sql = "";
        if (arg->data.list.items[0]->type == VAL_STR) sql = arg->data.list.items[0]->data.str;
        int nparams = arg->data.list.count - 1;
        if (nparams == 0) {
            res = PQexec(g_db_conn, sql);
        } else {
            const char *params[16];
            char numbuf[16][64];
            if (nparams > 16) nparams = 16;
            for (int i = 0; i < nparams; i++) {
                Value *v = arg->data.list.items[i + 1];
                if (v->type == VAL_STR) {
                    params[i] = v->data.str;
                } else if (v->type == VAL_NUM) {
                    snprintf(numbuf[i], sizeof(numbuf[i]), "%g", v->data.num);
                    params[i] = numbuf[i];
                } else {
                    params[i] = "";
                }
            }
            res = PQexecParams(g_db_conn, sql, nparams, NULL, params, NULL, NULL, 0);
        }
    } else {
        return make_str("error");
    }

    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK || PQresultStatus(res) == PGRES_TUPLES_OK);
    PQclear(res);
    return make_str(ok ? "ok" : "error");
}

Value* builtin_db_query_json(Value *arg) {
    /* Run SQL and return all rows as a JSON array of objects.
     * Usage: db_query_json of "SELECT id, name FROM table"
     * Returns "[]" if no DB, error, or no rows. */
    if (!arg || arg->type != VAL_STR) return make_str("[]");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("[]");
    PGresult *res = PQexec(g_db_conn, arg->data.str);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        PQclear(res);
        return make_str("[]");
    }
    int nrows = PQntuples(res);
    int ncols = PQnfields(res);
    if (nrows == 0 || ncols == 0) { PQclear(res); return make_str("[]"); }

    int buf_size = nrows * ncols * 256 + 256;
    if (buf_size > 1048576) buf_size = 1048576;
    char *buf = calloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "[");
    for (int r = 0; r < nrows && pos < buf_size - 512; r++) {
        if (r > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
        pos += snprintf(buf + pos, buf_size - pos, "{");
        for (int c = 0; c < ncols && pos < buf_size - 256; c++) {
            if (c > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
            const char *colname = PQfname(res, c);
            const char *val = PQgetvalue(res, r, c);
            /* Escape value for JSON */
            char escaped[512];
            int ei = 0;
            for (int i = 0; val[i] && ei < 500; i++) {
                if (val[i] == '"') { escaped[ei++] = '\\'; escaped[ei++] = '"'; }
                else if (val[i] == '\\') { escaped[ei++] = '\\'; escaped[ei++] = '\\'; }
                else if (val[i] == '\n') { escaped[ei++] = '\\'; escaped[ei++] = 'n'; }
                else escaped[ei++] = val[i];
            }
            escaped[ei] = '\0';
            pos += snprintf(buf + pos, buf_size - pos, "\"%s\": \"%s\"", colname, escaped);
        }
        pos += snprintf(buf + pos, buf_size - pos, "}");
    }
    pos += snprintf(buf + pos, buf_size - pos, "]");

    PQclear(res);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

/* ---- API key builtins ---- */
Value* builtin_generate_api_key(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("{}");
    const char *name = arg->data.str;

    unsigned char raw_bytes[16];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (urand) {
        if (fread(raw_bytes, 1, 16, urand) != 16) {
            fclose(urand);
            return make_str("{\"error\": \"Failed to read random bytes\"}");
        }
        fclose(urand);
    } else {
        for (int i = 0; i < 16; i++) raw_bytes[i] = (unsigned char)(rand() ^ (rand() << 8));
    }
    char raw_key[40];
    int kp = 0;
    kp += sprintf(raw_key + kp, "eig_");
    for (int i = 0; i < 16; i++) kp += sprintf(raw_key + kp, "%02x", raw_bytes[i]);

    char key_hash[65];
    sha256_hex(raw_key, key_hash);

    char key_prefix[16];
    snprintf(key_prefix, sizeof(key_prefix), "eig_%.8s", raw_key + 4);

    /* Store in DB if available */
    if (g_db_conn && PQstatus(g_db_conn) == CONNECTION_OK) {
        ensure_api_keys_table();
        const char *params[3] = {name, key_hash, key_prefix};
        PGresult *res = PQexecParams(g_db_conn,
            "INSERT INTO api_keys (name, key_hash, key_prefix) VALUES ($1, $2, $3)",
            3, NULL, params, NULL, NULL, 0);
        PQclear(res);
    }

    char buf[256];
    snprintf(buf, sizeof(buf), "{\"success\": true, \"key\": \"%s\"}", raw_key);
    return make_str(buf);
}

Value* builtin_validate_api_key(Value *arg) {
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"valid\": false, \"error\": \"no key provided\"}");
    }
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) {
        return make_str("{\"valid\": false, \"error\": \"no database\"}");
    }

    char key_hash[65];
    sha256_hex(arg->data.str, key_hash);

    ensure_api_keys_table();
    const char *params[1] = {key_hash};
    PGresult *res = PQexecParams(g_db_conn,
        "SELECT id, name FROM api_keys WHERE key_hash = $1 AND is_active = TRUE",
        1, NULL, params, NULL, NULL, 0);

    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return make_str("{\"valid\": false}");
    }

    const char *name = PQgetvalue(res, 0, 1);
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"valid\": true, \"name\": \"%s\"}", name);
    PQclear(res);

    /* Update last_used */
    const char *update_params[1] = {key_hash};
    PGresult *upd = PQexecParams(g_db_conn,
        "UPDATE api_keys SET last_used = NOW() WHERE key_hash = $1",
        1, NULL, update_params, NULL, NULL, 0);
    PQclear(upd);

    return make_str(buf);
}


void register_db_builtins(Env *env) {
    env_set_local(env, "db_connect", make_builtin(builtin_db_connect));
    env_set_local(env, "db_query_value", make_builtin(builtin_db_query_value));
    env_set_local(env, "db_execute", make_builtin(builtin_db_execute));
    env_set_local(env, "db_query_json", make_builtin(builtin_db_query_json));
    env_set_local(env, "generate_api_key", make_builtin(builtin_generate_api_key));
    env_set_local(env, "validate_api_key", make_builtin(builtin_validate_api_key));
}

#endif /* EIGENSCRIPT_EXT_DB */
