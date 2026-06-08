/*
 * EigenStore — native embedded database for EigenScript.
 * Zero external dependencies. Page-based storage with linked-list collections.
 */

#include "ext_store_internal.h"

/* ================================================================
 * Bounded record iteration — validates all on-disk lengths before use.
 *
 * Record format within a page:
 *   [key_len:2][key:key_len][json_len:4][json:json_len]
 * Deleted records: key_len=0, followed by [json_len:4][json:json_len]
 *
 * store_record_next() advances offset safely, returning -1 on corruption.
 * ================================================================ */

typedef struct {
    uint16_t key_len;       /* 0 = deleted */
    int key_offset;         /* offset of key data within page.data */
    uint32_t json_len;
    int json_offset;        /* offset of json data within page.data */
    int next_offset;        /* offset after this record */
} StoreRecord;

/* Parse one record from page.data starting at *offset.
 * Returns 0 on success (fills rec), -1 on bounds violation. */
static int store_record_next(const Page *page, int *offset, StoreRecord *rec) {
    int off = *offset;
    int limit = STORE_PAGE_DATA_SIZE;

    /* Read key_len (2 bytes) */
    if (off + 2 > limit) return -1;
    rec->key_len = (uint16_t)((unsigned char)page->data[off] |
                               ((unsigned char)page->data[off + 1] << 8));
    off += 2;

    if (rec->key_len == 0) {
        /* Deleted record: skip json_len + json */
        if (off + 4 > limit) return -1;
        rec->json_len = (uint32_t)((unsigned char)page->data[off] |
                                    ((unsigned char)page->data[off + 1] << 8) |
                                    ((unsigned char)page->data[off + 2] << 16) |
                                    ((unsigned char)page->data[off + 3] << 24));
        off += 4;
        rec->key_offset = 0;
        rec->json_offset = off;
        if (rec->json_len > (uint32_t)(limit - off)) return -1;
        off += rec->json_len;
    } else {
        /* Live record: key + json_len + json */
        if (rec->key_len > (uint32_t)(limit - off)) return -1;
        rec->key_offset = off;
        off += rec->key_len;

        if (off + 4 > limit) return -1;
        rec->json_len = (uint32_t)((unsigned char)page->data[off] |
                                    ((unsigned char)page->data[off + 1] << 8) |
                                    ((unsigned char)page->data[off + 2] << 16) |
                                    ((unsigned char)page->data[off + 3] << 24));
        off += 4;
        rec->json_offset = off;
        if (rec->json_len > (uint32_t)(limit - off)) return -1;
        off += rec->json_len;
    }

    rec->next_offset = off;
    *offset = off;
    return 0;
}

/* ================================================================
 * JSON helpers for dicts (the core json_encode doesn't handle VAL_DICT)
 * ================================================================ */

static void store_json_encode(Value *v, strbuf *out);

static int page_data_used(Page *page);

static void store_json_encode(Value *v, strbuf *out) {
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
            eigs_json_escape_string(out, v->data.str);
            break;
        }
        case VAL_LIST: {
            strbuf_append_char(out, '[');
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) strbuf_append_char(out, ',');
                store_json_encode(v->data.list.items[i], out);
            }
            strbuf_append_char(out, ']');
            break;
        }
        case VAL_DICT: {
            strbuf_append_char(out, '{');
            int first = 1;
            for (int i = 0; i < v->data.dict.count; i++) {
                const char *key = v->data.dict.keys[i];
                /* Skip internal pointer fields */
                if (key[0] == '_' && (strcmp(key, "_store") == 0)) continue;
                if (!first) strbuf_append_char(out, ',');
                first = 0;
                eigs_json_escape_string(out, key);
                strbuf_append_char(out, ':');
                store_json_encode(v->data.dict.vals[i], out);
            }
            strbuf_append_char(out, '}');
            break;
        }
        default:
            strbuf_append(out, "null");
            break;
    }
}

static char* store_dict_to_json(Value *dict) {
    strbuf out;
    strbuf_init(&out);
    store_json_encode(dict, &out);
    char *result = xstrdup(out.data);
    strbuf_free(&out);
    return result;
}

/* JSON decode that produces dicts (not the core alternating-list format) */
static void store_json_skip_ws(const char *s, int *pos) {
    while (s[*pos] && (s[*pos] == ' ' || s[*pos] == '\t' || s[*pos] == '\n' || s[*pos] == '\r'))
        (*pos)++;
}

static Value* store_json_parse_value(const char *s, int *pos);

/* Strict JSON parser for on-disk store data.
 * Returns NULL on any malformed input — missing separators, unterminated
 * strings, trailing garbage, unknown tokens. */

static Value* store_json_parse_string(const char *s, int *pos) {
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
                default: strbuf_free(&buf); return NULL;  /* invalid escape */
            }
        } else {
            strbuf_append_char(&buf, s[*pos]);
        }
        (*pos)++;
    }
    if (s[*pos] != '"') { strbuf_free(&buf); return NULL; }  /* unterminated */
    (*pos)++;
    Value *v = make_str(buf.data);
    strbuf_free(&buf);
    return v;
}

static Value* store_json_parse_number(const char *s, int *pos) {
    char *end = NULL;
    double val = strtod(s + *pos, &end);
    if (end == s + *pos) return NULL;  /* no digits consumed */
    *pos = (int)(end - s);
    return make_num(val);
}

static Value* store_json_parse_array(const char *s, int *pos) {
    if (s[*pos] != '[') return NULL;
    (*pos)++;
    Value *list = make_list(8);
    store_json_skip_ws(s, pos);
    if (s[*pos] == ']') { (*pos)++; return list; }
    while (1) {
        store_json_skip_ws(s, pos);
        Value *val = store_json_parse_value(s, pos);
        if (!val) return NULL;
        list_append(list, val);
        store_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == ']') { (*pos)++; return list; }
        return NULL;  /* expected , or ] */
    }
}

static Value* store_json_parse_object(const char *s, int *pos) {
    if (s[*pos] != '{') return NULL;
    (*pos)++;
    Value *dict = make_dict(8);
    store_json_skip_ws(s, pos);
    if (s[*pos] == '}') { (*pos)++; return dict; }
    while (1) {
        store_json_skip_ws(s, pos);
        Value *key = store_json_parse_string(s, pos);
        if (!key) return NULL;
        store_json_skip_ws(s, pos);
        if (s[*pos] != ':') return NULL;  /* require colon */
        (*pos)++;
        store_json_skip_ws(s, pos);
        Value *val = store_json_parse_value(s, pos);
        if (!val) return NULL;
        dict_set(dict, key->data.str, val);
        store_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == '}') { (*pos)++; return dict; }
        return NULL;  /* expected , or } */
    }
}

static Value* store_json_parse_value(const char *s, int *pos) {
    store_json_skip_ws(s, pos);
    if (!s[*pos]) return NULL;
    if (s[*pos] == '"') return store_json_parse_string(s, pos);
    if (s[*pos] == '[') return store_json_parse_array(s, pos);
    if (s[*pos] == '{') return store_json_parse_object(s, pos);
    if (s[*pos] == '-' || isdigit(s[*pos])) return store_json_parse_number(s, pos);
    if (strncmp(s + *pos, "null", 4) == 0) { *pos += 4; return make_null(); }
    if (strncmp(s + *pos, "true", 4) == 0) { *pos += 4; return make_num(1); }
    if (strncmp(s + *pos, "false", 5) == 0) { *pos += 5; return make_num(0); }
    return NULL;  /* unknown token */
}

/* Strict decode: parse value, then require only whitespace/end remaining */
static Value* store_json_decode(const char *s) {
    int pos = 0;
    Value *v = store_json_parse_value(s, &pos);
    if (!v) return NULL;
    store_json_skip_ws(s, &pos);
    if (s[pos] != '\0') return NULL;  /* trailing garbage */
    return v;
}

/* ================================================================
 * Page I/O helpers
 * ================================================================ */

static int store_read_page(Store *store, uint32_t page_num, Page *page) {
    long offset = STORE_HEADER_SIZE + (long)page_num * STORE_PAGE_SIZE;
    if (fseek(store->fp, offset, SEEK_SET) != 0) return -1;
    /* Read page header: type(1) + count(2) + next(4) = 7 bytes */
    unsigned char hdr[7];
    if (fread(hdr, 1, 7, store->fp) != 7) return -1;
    page->type = hdr[0];
    page->count = (uint16_t)(hdr[1] | (hdr[2] << 8));
    page->next_page = (uint32_t)(hdr[3] | (hdr[4] << 8) | (hdr[5] << 16) | (hdr[6] << 24));
    /* Read data area */
    if (fread(page->data, 1, STORE_PAGE_DATA_SIZE, store->fp) != STORE_PAGE_DATA_SIZE) return -1;
    return 0;
}

static int store_write_page(Store *store, uint32_t page_num, Page *page) {
    long offset = STORE_HEADER_SIZE + (long)page_num * STORE_PAGE_SIZE;
    if (fseek(store->fp, offset, SEEK_SET) != 0) return -1;
    unsigned char hdr[7];
    hdr[0] = page->type;
    hdr[1] = (uint8_t)(page->count & 0xFF);
    hdr[2] = (uint8_t)((page->count >> 8) & 0xFF);
    hdr[3] = (uint8_t)(page->next_page & 0xFF);
    hdr[4] = (uint8_t)((page->next_page >> 8) & 0xFF);
    hdr[5] = (uint8_t)((page->next_page >> 16) & 0xFF);
    hdr[6] = (uint8_t)((page->next_page >> 24) & 0xFF);
    if (fwrite(hdr, 1, 7, store->fp) != 7) return -1;
    if (fwrite(page->data, 1, STORE_PAGE_DATA_SIZE, store->fp) != STORE_PAGE_DATA_SIZE) return -1;
    fflush(store->fp);
    return 0;
}

static uint32_t store_alloc_page(Store *store) {
    if (store->free_page != 0) {
        uint32_t pg = store->free_page;
        Page page;
        store_read_page(store, pg, &page);
        store->free_page = page.next_page;
        memset(&page, 0, sizeof(Page));
        store_write_page(store, pg, &page);
        return pg;
    }
    uint32_t pg = store->page_count;
    store->page_count++;
    /* Extend file with zeroed page */
    Page page;
    memset(&page, 0, sizeof(Page));
    store_write_page(store, pg, &page);
    return pg;
}

static int store_write_header(Store *store) {
    if (fseek(store->fp, 0, SEEK_SET) != 0) return -1;
    unsigned char hdr[STORE_HEADER_SIZE];
    memset(hdr, 0, STORE_HEADER_SIZE);
    memcpy(hdr, STORE_MAGIC, 4);
    /* version (LE) */
    hdr[4] = STORE_VERSION & 0xFF;
    hdr[5] = (STORE_VERSION >> 8) & 0xFF;
    hdr[6] = (STORE_VERSION >> 16) & 0xFF;
    hdr[7] = (STORE_VERSION >> 24) & 0xFF;
    /* page_size */
    hdr[8]  = STORE_PAGE_SIZE & 0xFF;
    hdr[9]  = (STORE_PAGE_SIZE >> 8) & 0xFF;
    hdr[10] = (STORE_PAGE_SIZE >> 16) & 0xFF;
    hdr[11] = (STORE_PAGE_SIZE >> 24) & 0xFF;
    /* page_count */
    hdr[12] = store->page_count & 0xFF;
    hdr[13] = (store->page_count >> 8) & 0xFF;
    hdr[14] = (store->page_count >> 16) & 0xFF;
    hdr[15] = (store->page_count >> 24) & 0xFF;
    /* free_page */
    hdr[16] = store->free_page & 0xFF;
    hdr[17] = (store->free_page >> 8) & 0xFF;
    hdr[18] = (store->free_page >> 16) & 0xFF;
    hdr[19] = (store->free_page >> 24) & 0xFF;
    if (fwrite(hdr, 1, STORE_HEADER_SIZE, store->fp) != STORE_HEADER_SIZE) return -1;
    fflush(store->fp);
    return 0;
}

static int store_read_header(Store *store) {
    if (fseek(store->fp, 0, SEEK_SET) != 0) return -1;
    unsigned char hdr[STORE_HEADER_SIZE];
    if (fread(hdr, 1, STORE_HEADER_SIZE, store->fp) != STORE_HEADER_SIZE) return -1;

    /* Magic, version, page size */
    if (memcmp(hdr, STORE_MAGIC, 4) != 0) return -1;
    uint32_t version = (uint32_t)(hdr[4] | (hdr[5] << 8) | (hdr[6] << 16) | (hdr[7] << 24));
    if (version != STORE_VERSION) {
        fprintf(stderr, "store_open: version %u, expected %d\n", version, STORE_VERSION);
        return -1;
    }
    uint32_t page_size = (uint32_t)(hdr[8] | (hdr[9] << 8) | (hdr[10] << 16) | (hdr[11] << 24));
    if (page_size != STORE_PAGE_SIZE) {
        fprintf(stderr, "store_open: page_size %u, expected %d\n", page_size, STORE_PAGE_SIZE);
        return -1;
    }

    store->page_count = (uint32_t)(hdr[12] | (hdr[13] << 8) | (hdr[14] << 16) | (hdr[15] << 24));
    store->free_page  = (uint32_t)(hdr[16] | (hdr[17] << 8) | (hdr[18] << 16) | (hdr[19] << 24));

    /* Exact file size validation */
    if (fseek(store->fp, 0, SEEK_END) != 0) return -1;
    long file_size = ftell(store->fp);
    fseek(store->fp, STORE_HEADER_SIZE, SEEK_SET);
    if (file_size < (long)STORE_HEADER_SIZE) return -1;
    long data_size = file_size - STORE_HEADER_SIZE;
    if (data_size % STORE_PAGE_SIZE != 0) {
        fprintf(stderr, "store_open: file not page-aligned (data=%ld, page_size=%d)\n",
            data_size, STORE_PAGE_SIZE);
        return -1;
    }
    uint32_t file_pages = (uint32_t)(data_size / STORE_PAGE_SIZE);
    if (store->page_count < 1 || store->page_count != file_pages) {
        fprintf(stderr, "store_open: page_count %u != file pages %u\n",
            store->page_count, file_pages);
        return -1;
    }

    if (store->free_page != 0 && store->free_page >= store->page_count) {
        fprintf(stderr, "store_open: free_page %u out of range\n", store->free_page);
        return -1;
    }

    /* Validate free-list chain with visited bitmap */
    uint8_t *visited = xcalloc((store->page_count + 7) / 8, 1);
    uint32_t fp = store->free_page;
    while (fp != 0) {
        if (fp >= store->page_count) { free(visited); return -1; }
        uint32_t byte = fp / 8, bit = fp % 8;
        if (visited[byte] & (1 << bit)) {
            fprintf(stderr, "store_open: cycle in free-list at page %u\n", fp);
            free(visited);
            return -1;
        }
        visited[byte] |= (1 << bit);
        Page page;
        if (store_read_page(store, fp, &page) != 0) { free(visited); return -1; }
        if (page.type != PAGE_FREE) {
            fprintf(stderr, "store_open: free-list page %u has type %d\n", fp, page.type);
            free(visited);
            return -1;
        }
        fp = page.next_page;
    }
    free(visited);
    return 0;
}

/* ================================================================
 * Catalog I/O — stored as JSON in page 0 (catalog page)
 * ================================================================ */

static int store_flush_catalog(Store *store) {
    if (!store->dirty) return 0;
    char *json = store_dict_to_json(store->catalog);
    size_t json_len = strlen(json);

    /* Write catalog across page 0 (and overflow pages if needed) */
    size_t written = 0;
    uint32_t pg = 0; /* catalog always starts at page 0 */

    while (written < json_len) {
        Page page;
        memset(&page, 0, sizeof(Page));
        page.type = PAGE_CATALOG;
        size_t chunk = json_len - written;
        if (chunk > STORE_PAGE_DATA_SIZE) chunk = STORE_PAGE_DATA_SIZE;
        memcpy(page.data, json + written, chunk);
        written += chunk;

        if (written < json_len) {
            /* Need overflow page */
            Page old;
            if (store_read_page(store, pg, &old) == 0 && old.next_page != 0) {
                page.next_page = old.next_page;
            } else {
                page.next_page = store_alloc_page(store);
            }
        } else {
            page.next_page = 0;
        }
        page.count = (uint16_t)chunk;
        store_write_page(store, pg, &page);
        pg = page.next_page;
    }

    free(json);
    store->dirty = 0;
    store_write_header(store);
    return 0;
}

static int store_load_catalog(Store *store) {
    strbuf buf;
    strbuf_init(&buf);
    uint32_t pg = 0;
    size_t bmp_size = (store->page_count + 7) / 8;
    uint8_t *cat_visited = xcalloc(bmp_size, 1);

    while (1) {
        if (pg >= store->page_count) {
            fprintf(stderr, "store_open: catalog page %u out of range\n", pg);
            goto cat_fail;
        }
        uint32_t byte = pg / 8, bit = pg % 8;
        if (cat_visited[byte] & (1 << bit)) {
            fprintf(stderr, "store_open: cycle in catalog chain at page %u\n", pg);
            goto cat_fail;
        }
        cat_visited[byte] |= (1 << bit);

        Page page;
        if (store_read_page(store, pg, &page) != 0) {
            fprintf(stderr, "store_open: cannot read catalog page %u\n", pg);
            goto cat_fail;
        }
        if (page.type != PAGE_CATALOG) {
            fprintf(stderr, "store_open: page %u is type %d, expected catalog\n", pg, page.type);
            goto cat_fail;
        }
        if (page.count > STORE_PAGE_DATA_SIZE) {
            fprintf(stderr, "store_open: catalog page %u has invalid count %u\n", pg, page.count);
            goto cat_fail;
        }
        if (page.count > 0) {
            strbuf_append_n(&buf, page.data, page.count);
        }
        if (page.next_page == 0) break;
        pg = page.next_page;
    }
    free(cat_visited);

    if (buf.len == 0) {
        fprintf(stderr, "store_open: empty catalog\n");
        strbuf_free(&buf);
        return -1;
    }

    store->catalog = store_json_decode(buf.data);
    strbuf_free(&buf);
    if (!store->catalog || store->catalog->type != VAL_DICT) {
        fprintf(stderr, "store_open: catalog is not valid JSON dict\n");
        return -1;
    }

    /* Validate every collection: strict schema + walk record chains */
    uint8_t *visited = xcalloc((store->page_count + 7) / 8, 1);
    /* Mark page 0 (catalog) as owned */
    visited[0] |= 1;

    for (int i = 0; i < store->catalog->data.dict.count; i++) {
        const char *name = store->catalog->data.dict.keys[i];
        Value *col = store->catalog->data.dict.vals[i];

        /* Strict schema: must be dict with numeric "root" and "next_id" */
        if (!col || col->type != VAL_DICT) {
            fprintf(stderr, "store_open: collection '%s' is not a dict\n", name);
            free(visited);
            return -1;
        }
        Value *rv = dict_get(col, "root");
        Value *nv = dict_get(col, "next_id");
        if (!rv || rv->type != VAL_NUM || !nv || nv->type != VAL_NUM) {
            fprintf(stderr, "store_open: collection '%s' missing root or next_id\n", name);
            free(visited);
            return -1;
        }
        uint32_t root = (uint32_t)rv->data.num;
        if (root == 0 || root >= store->page_count) {
            fprintf(stderr, "store_open: collection '%s' has invalid root %u\n", name, root);
            free(visited);
            return -1;
        }

        /* Walk the record chain: validate page types, records, no cycles */
        uint32_t pg = root;
        while (pg != 0) {
            if (pg >= store->page_count) {
                fprintf(stderr, "store_open: collection '%s' page %u out of range\n", name, pg);
                free(visited);
                return -1;
            }
            uint32_t byte = pg / 8, bit = pg % 8;
            if (visited[byte] & (1 << bit)) {
                fprintf(stderr, "store_open: collection '%s' page %u already owned\n", name, pg);
                free(visited);
                return -1;
            }
            visited[byte] |= (1 << bit);

            Page page;
            if (store_read_page(store, pg, &page) != 0) {
                fprintf(stderr, "store_open: collection '%s' cannot read page %u\n", name, pg);
                free(visited);
                return -1;
            }
            if (page.type != PAGE_RECORDS) {
                fprintf(stderr, "store_open: collection '%s' page %u type %d, expected RECORDS\n",
                    name, pg, page.type);
                free(visited);
                return -1;
            }
            if (page_data_used(&page) < 0) {
                fprintf(stderr, "store_open: collection '%s' page %u has corrupt records\n", name, pg);
                free(visited);
                return -1;
            }
            pg = page.next_page;
        }
    }

    free(visited);
    return 0;

cat_fail:
    free(cat_visited);
    strbuf_free(&buf);
    return -1;
}

/* ================================================================
 * Store handle extraction (same pattern as get_channel)
 * ================================================================ */

static Store* get_store(Value *v) {
    if (!v || v->type != VAL_DICT) return NULL;
    Value *sv = dict_get(v, "_store_id");
    if (!sv || sv->type != VAL_NUM) return NULL;
    return (Store*)handle_lookup((int)sv->data.num, HANDLE_STORE);
}

/* ================================================================
 * Data offset helper: compute used bytes in a record page
 * ================================================================ */

/*
 * Deleted record format: [key_len=0 : 2 bytes][skip_len : 4 bytes][skip_len bytes of dead data]
 * skip_len = original_key_len + original_json_len  (key data + json data; the 4-byte json_len header is replaced by skip_len)
 *
 * Live record format:    [key_len : 2 bytes][key_data : key_len bytes][json_len : 4 bytes][json_data : json_len bytes]
 */

/* Compute bytes used by records in a page. Uses store_record_next for safe bounds checking.
 * Returns -1 if corrupt data is encountered. */
static int page_data_used(Page *page) {
    int offset = 0;
    for (int i = 0; i < (int)page->count; i++) {
        StoreRecord rec;
        if (store_record_next(page, &offset, &rec) != 0) return -1;
    }
    return offset;
}

/* ================================================================
 * Builtins
 * ================================================================ */

/* store_open(path) -> handle dict */
static Value* builtin_store_open(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        runtime_error(0, "store_open requires a string path\n");
        return make_null();
    }
    const char *path = arg->data.str;

    Store *store = xcalloc(1, sizeof(Store));
    strncpy(store->path, path, sizeof(store->path) - 1);

    /* Check if file exists */
    FILE *fp = fopen(path, "r+b");
    if (fp) {
        /* Existing file */
        store->fp = fp;
        if (store_read_header(store) != 0) {
            runtime_error(0, "store_open: invalid database file '%s'\n", path);
            fclose(fp);
            free(store);
            return make_null();
        }
        if (store_load_catalog(store) != 0) {
            runtime_error(0, "store_open: corrupt catalog in '%s'\n", path);
            fclose(fp);
            free(store);
            return make_null();
        }
    } else {
        /* Create new file */
        fp = fopen(path, "w+b");
        if (!fp) {
            runtime_error(0, "store_open: cannot create '%s'\n", path);
            free(store);
            return make_null();
        }
        store->fp = fp;
        store->page_count = 1; /* page 0 = catalog */
        store->free_page = 0;
        store->catalog = make_dict(8);
        store->dirty = 1;

        /* Write initial header */
        store_write_header(store);

        /* Write empty catalog page */
        Page page;
        memset(&page, 0, sizeof(Page));
        page.type = PAGE_CATALOG;
        page.count = 2; /* "{}" */
        page.data[0] = '{';
        page.data[1] = '}';
        store_write_page(store, 0, &page);
        store->dirty = 0;
    }

    int hid = handle_register(store, HANDLE_STORE);
    if (hid < 0) {
        fclose(store->fp);
        free(store);
        return make_null();
    }
    Value *handle = make_dict(8);
    dict_set(handle, "_store_id", make_num((double)hid));
    dict_set(handle, "_type", make_str("eigenstore"));
    return handle;
}

/* store_close(handle) -> null */
static Value* builtin_store_close(Value *arg) {
    Store *store = get_store(arg);
    if (!store) {
        runtime_error(0, "store_close requires a store handle\n");
        return make_null();
    }
    /* Release handle BEFORE freeing memory to prevent use-after-free
     * if another thread calls get_store() concurrently. */
    Value *id_val = (arg && arg->type == VAL_DICT) ? dict_get(arg, "_store_id") : NULL;
    int hid = (id_val && id_val->type == VAL_NUM) ? (int)id_val->data.num : -1;
    handle_release(hid);
    store->dirty = 1; /* Force flush */
    store_flush_catalog(store);
    fclose(store->fp);
    free(store);
    /* Invalidate handle */
    if (arg && arg->type == VAL_DICT) {
        dict_set(arg, "_store_id", make_null());
    }
    return make_null();
}

/* store_put([handle, collection, record]) -> key string */
static Value* builtin_store_put(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        runtime_error(0, "store_put requires [handle, collection, record]\n");
        return make_null();
    }
    Store *store = get_store(arg->data.list.items[0]);
    Value *col_val = arg->data.list.items[1];
    Value *record = arg->data.list.items[2];
    if (!store || !col_val || col_val->type != VAL_STR) {
        runtime_error(0, "store_put: invalid handle or collection\n");
        return make_null();
    }
    if (!record || record->type != VAL_DICT) {
        runtime_error(0, "store_put: record must be a dict\n");
        return make_null();
    }
    const char *collection = col_val->data.str;

    /* Get or create collection entry in catalog */
    Value *col_info = dict_get(store->catalog, collection);
    uint32_t root_page;
    int next_id;

    if (!col_info || col_info->type != VAL_DICT) {
        /* New collection */
        root_page = store_alloc_page(store);
        next_id = 1;
        col_info = make_dict(4);
        dict_set(col_info, "root", make_num(root_page));
        dict_set(col_info, "next_id", make_num(next_id));
        dict_set(store->catalog, collection, col_info);
        store->dirty = 1;

        /* Initialize root page */
        Page page;
        memset(&page, 0, sizeof(Page));
        page.type = PAGE_RECORDS;
        page.count = 0;
        page.next_page = 0;
        store_write_page(store, root_page, &page);
    } else {
        Value *rv = dict_get(col_info, "root");
        Value *nv = dict_get(col_info, "next_id");
        root_page = (uint32_t)(rv ? rv->data.num : 0);
        next_id = (int)(nv ? nv->data.num : 1);
    }

    /* Determine key */
    char key_buf[STORE_MAX_KEY_LEN];
    Value *id_val = dict_get(record, "_id");
    if (id_val && id_val->type == VAL_STR && id_val->data.str[0] != '\0') {
        strncpy(key_buf, id_val->data.str, STORE_MAX_KEY_LEN - 1);
        key_buf[STORE_MAX_KEY_LEN - 1] = '\0';
    } else {
        snprintf(key_buf, STORE_MAX_KEY_LEN, "%d", next_id);
        next_id++;
        dict_set(col_info, "next_id", make_num(next_id));
        store->dirty = 1;
    }

    /* Set _id on record */
    dict_set(record, "_id", make_str(key_buf));

    /* Serialize record to JSON */
    char *json = store_dict_to_json(record);
    size_t json_len = strlen(json);
    size_t key_len = strlen(key_buf);

    if (key_len > 0xFFFF || json_len > 0xFFFFFFFF) {
        runtime_error(0, "store_put: record too large\n");
        free(json);
        return make_null();
    }

    size_t record_size = 2 + key_len + 4 + json_len;
    if (record_size > STORE_PAGE_DATA_SIZE) {
        runtime_error(0, "store_put: record exceeds page size\n");
        free(json);
        return make_null();
    }

    /* Find last page in chain with space. Fail on any corruption. */
    uint32_t pg = root_page;
    Page page;

    for (int hops = 0; hops < STORE_MAX_PAGE_HOPS; hops++) {
        if (store_read_page(store, pg, &page) != 0) { free(json); return make_null(); }
        if (page.type != PAGE_RECORDS) { free(json); return make_null(); }
        int used = page_data_used(&page);
        if (used < 0) { free(json); return make_null(); }

        if ((size_t)(used + record_size) <= STORE_PAGE_DATA_SIZE) {
            /* Fits in this page */
            int off = used;
            page.data[off] = (char)(key_len & 0xFF);
            page.data[off + 1] = (char)((key_len >> 8) & 0xFF);
            off += 2;
            memcpy(page.data + off, key_buf, key_len);
            off += key_len;
            page.data[off] = (char)(json_len & 0xFF);
            page.data[off + 1] = (char)((json_len >> 8) & 0xFF);
            page.data[off + 2] = (char)((json_len >> 16) & 0xFF);
            page.data[off + 3] = (char)((json_len >> 24) & 0xFF);
            off += 4;
            memcpy(page.data + off, json, json_len);
            page.count++;
            store_write_page(store, pg, &page);
            free(json);
            store->dirty = 1;
            store_flush_catalog(store);
            return make_str(key_buf);
        }
        if (page.next_page == 0 || page.next_page >= store->page_count) break;
        pg = page.next_page;
    }

    /* Need new page — link from current (last valid) page */
    uint32_t new_pg = store_alloc_page(store);
    page.next_page = new_pg;
    store_write_page(store, pg, &page);

    Page new_page;
    memset(&new_page, 0, sizeof(Page));
    new_page.type = PAGE_RECORDS;
    new_page.count = 1;
    new_page.next_page = 0;
    int off = 0;
    new_page.data[off] = (char)(key_len & 0xFF);
    new_page.data[off + 1] = (char)((key_len >> 8) & 0xFF);
    off += 2;
    memcpy(new_page.data + off, key_buf, key_len);
    off += key_len;
    new_page.data[off] = (char)(json_len & 0xFF);
    new_page.data[off + 1] = (char)((json_len >> 8) & 0xFF);
    new_page.data[off + 2] = (char)((json_len >> 16) & 0xFF);
    new_page.data[off + 3] = (char)((json_len >> 24) & 0xFF);
    off += 4;
    memcpy(new_page.data + off, json, json_len);
    store_write_page(store, new_pg, &new_page);

    free(json);
    store->dirty = 1;
    store_flush_catalog(store);
    return make_str(key_buf);
}

/* store_get([handle, collection, key]) -> record dict or null */
static Value* builtin_store_get(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        runtime_error(0, "store_get requires [handle, collection, key]\n");
        return make_null();
    }
    Store *store = get_store(arg->data.list.items[0]);
    Value *col_val = arg->data.list.items[1];
    Value *key_val = arg->data.list.items[2];
    if (!store || !col_val || col_val->type != VAL_STR) return make_null();

    const char *collection = col_val->data.str;
    char key_buf[STORE_MAX_KEY_LEN];
    if (key_val->type == VAL_STR) {
        strncpy(key_buf, key_val->data.str, STORE_MAX_KEY_LEN - 1);
        key_buf[STORE_MAX_KEY_LEN - 1] = '\0';
    } else if (key_val->type == VAL_NUM) {
        snprintf(key_buf, STORE_MAX_KEY_LEN, "%d", (int)key_val->data.num);
    } else {
        return make_null();
    }

    Value *col_info = dict_get(store->catalog, collection);
    if (!col_info || col_info->type != VAL_DICT) return make_null();
    Value *rv = dict_get(col_info, "root");
    if (!rv) return make_null();
    uint32_t pg = (uint32_t)rv->data.num;

    size_t target_key_len = strlen(key_buf);

    for (int _hops = 0; pg != 0 && _hops < STORE_MAX_PAGE_HOPS; _hops++) {
        Page page;
        if (store_read_page(store, pg, &page) != 0) break;
        if (page.type != PAGE_RECORDS) break;

        int offset = 0;
        for (int i = 0; i < (int)page.count; i++) {
            StoreRecord rec;
            if (store_record_next(&page, &offset, &rec) != 0) return make_null();
            if (rec.key_len == 0) continue;  /* deleted */

            if (rec.key_len == target_key_len &&
                memcmp(page.data + rec.key_offset, key_buf, rec.key_len) == 0) {
                char *json = xmalloc(rec.json_len + 1);
                memcpy(json, page.data + rec.json_offset, rec.json_len);
                json[rec.json_len] = '\0';
                Value *result = store_json_decode(json);
                free(json);
                return result;
            }
        }
        pg = page.next_page; if (pg >= store->page_count) break;
    }
    return make_null();
}

/* store_delete([handle, collection, key]) -> 1 or 0 */
static Value* builtin_store_delete(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        runtime_error(0, "store_delete requires [handle, collection, key]\n");
        return make_num(0);
    }
    Store *store = get_store(arg->data.list.items[0]);
    Value *col_val = arg->data.list.items[1];
    Value *key_val = arg->data.list.items[2];
    if (!store || !col_val || col_val->type != VAL_STR) return make_num(0);

    const char *collection = col_val->data.str;
    char key_buf[STORE_MAX_KEY_LEN];
    if (key_val->type == VAL_STR) {
        strncpy(key_buf, key_val->data.str, STORE_MAX_KEY_LEN - 1);
        key_buf[STORE_MAX_KEY_LEN - 1] = '\0';
    } else if (key_val->type == VAL_NUM) {
        snprintf(key_buf, STORE_MAX_KEY_LEN, "%d", (int)key_val->data.num);
    } else {
        return make_num(0);
    }

    Value *col_info = dict_get(store->catalog, collection);
    if (!col_info || col_info->type != VAL_DICT) return make_num(0);
    Value *rv = dict_get(col_info, "root");
    if (!rv) return make_num(0);
    uint32_t pg = (uint32_t)rv->data.num;
    size_t target_key_len = strlen(key_buf);

    for (int _hops = 0; pg != 0 && _hops < STORE_MAX_PAGE_HOPS; _hops++) {
        Page page;
        if (store_read_page(store, pg, &page) != 0) break;
        if (page.type != PAGE_RECORDS) break;

        int offset = 0;
        for (int i = 0; i < (int)page.count; i++) {
            int kl_offset = offset;
            StoreRecord rec;
            if (store_record_next(&page, &offset, &rec) != 0) return make_num(0);
            if (rec.key_len == 0) continue;  /* deleted */

            if (rec.key_len == target_key_len &&
                memcmp(page.data + rec.key_offset, key_buf, rec.key_len) == 0) {
                /* Mark deleted: set key_len to 0, write skip_len at offset+2 */
                uint32_t skip = (uint32_t)rec.key_len + rec.json_len;
                page.data[kl_offset] = 0;
                page.data[kl_offset + 1] = 0;
                page.data[kl_offset + 2] = (char)(skip & 0xFF);
                page.data[kl_offset + 3] = (char)((skip >> 8) & 0xFF);
                page.data[kl_offset + 4] = (char)((skip >> 16) & 0xFF);
                page.data[kl_offset + 5] = (char)((skip >> 24) & 0xFF);
                store_write_page(store, pg, &page);
                return make_num(1);
            }
        }
        pg = page.next_page; if (pg >= store->page_count) break;
    }
    return make_num(0);
}

/* store_query([handle, collection]) -> list of all records */
static Value* builtin_store_query(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        runtime_error(0, "store_query requires [handle, collection]\n");
        return make_list(0);
    }
    Store *store = get_store(arg->data.list.items[0]);
    Value *col_val = arg->data.list.items[1];
    if (!store || !col_val || col_val->type != VAL_STR) return make_list(0);

    const char *collection = col_val->data.str;
    Value *col_info = dict_get(store->catalog, collection);
    if (!col_info || col_info->type != VAL_DICT) return make_list(0);
    Value *rv = dict_get(col_info, "root");
    if (!rv) return make_list(0);
    uint32_t pg = (uint32_t)rv->data.num;

    Value *results = make_list(16);

    for (int _hops = 0; pg != 0 && _hops < STORE_MAX_PAGE_HOPS; _hops++) {
        Page page;
        if (store_read_page(store, pg, &page) != 0) break;
        if (page.type != PAGE_RECORDS) break;

        int offset = 0;
        for (int i = 0; i < (int)page.count; i++) {
            StoreRecord rec;
            if (store_record_next(&page, &offset, &rec) != 0) return results;
            if (rec.key_len == 0) continue;  /* deleted */

            char *json = xmalloc(rec.json_len + 1);
            memcpy(json, page.data + rec.json_offset, rec.json_len);
            json[rec.json_len] = '\0';
            Value *val = store_json_decode(json);
            free(json);
            list_append(results, val);
        }
        pg = page.next_page; if (pg >= store->page_count) break;
    }
    return results;
}

/* store_count([handle, collection]) -> number */
static Value* builtin_store_count(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        runtime_error(0, "store_count requires [handle, collection]\n");
        return make_num(0);
    }
    Store *store = get_store(arg->data.list.items[0]);
    Value *col_val = arg->data.list.items[1];
    if (!store || !col_val || col_val->type != VAL_STR) return make_num(0);

    const char *collection = col_val->data.str;
    Value *col_info = dict_get(store->catalog, collection);
    if (!col_info || col_info->type != VAL_DICT) return make_num(0);
    Value *rv = dict_get(col_info, "root");
    if (!rv) return make_num(0);
    uint32_t pg = (uint32_t)rv->data.num;

    int count = 0;
    for (int _hops = 0; pg != 0 && _hops < STORE_MAX_PAGE_HOPS; _hops++) {
        Page page;
        if (store_read_page(store, pg, &page) != 0) break;
        if (page.type != PAGE_RECORDS) break;

        int offset = 0;
        for (int i = 0; i < (int)page.count; i++) {
            StoreRecord rec;
            if (store_record_next(&page, &offset, &rec) != 0) return make_num(count);
            if (rec.key_len == 0) continue;  /* deleted */
            count++;
        }
        pg = page.next_page; if (pg >= store->page_count) break;
    }
    return make_num(count);
}

/* store_update([handle, collection, key, record]) -> 1 or 0 */
static Value* builtin_store_update(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) {
        runtime_error(0, "store_update requires [handle, collection, key, record]\n");
        return make_num(0);
    }
    Value *handle = arg->data.list.items[0];
    Value *col_val = arg->data.list.items[1];
    Value *key_val = arg->data.list.items[2];
    Value *record = arg->data.list.items[3];

    /* Delete old record */
    Value *del_args = make_list(3);
    list_append(del_args, handle);
    list_append(del_args, col_val);
    list_append(del_args, key_val);
    Value *del_result = builtin_store_delete(del_args);

    if (!del_result || del_result->data.num == 0) return make_num(0);

    /* Set _id on new record */
    char key_buf[STORE_MAX_KEY_LEN];
    if (key_val->type == VAL_STR) {
        strncpy(key_buf, key_val->data.str, STORE_MAX_KEY_LEN - 1);
        key_buf[STORE_MAX_KEY_LEN - 1] = '\0';
    } else if (key_val->type == VAL_NUM) {
        snprintf(key_buf, STORE_MAX_KEY_LEN, "%d", (int)key_val->data.num);
    } else {
        return make_num(0);
    }
    dict_set(record, "_id", make_str(key_buf));

    /* Put new record */
    Value *put_args = make_list(3);
    list_append(put_args, handle);
    list_append(put_args, col_val);
    list_append(put_args, record);
    builtin_store_put(put_args);
    return make_num(1);
}

/* store_collections(handle) -> list of collection names */
static Value* builtin_store_collections(Value *arg) {
    Store *store = get_store(arg);
    if (!store) {
        runtime_error(0, "store_collections requires a store handle\n");
        return make_list(0);
    }
    Value *list = make_list(store->catalog->data.dict.count);
    for (int i = 0; i < store->catalog->data.dict.count; i++) {
        list_append(list, make_str(store->catalog->data.dict.keys[i]));
    }
    return list;
}

/* store_drop([handle, collection]) -> 1 or 0 */
static Value* builtin_store_drop(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        runtime_error(0, "store_drop requires [handle, collection]\n");
        return make_num(0);
    }
    Store *store = get_store(arg->data.list.items[0]);
    Value *col_val = arg->data.list.items[1];
    if (!store || !col_val || col_val->type != VAL_STR) return make_num(0);

    const char *collection = col_val->data.str;
    Value *col_info = dict_get(store->catalog, collection);
    if (!col_info || col_info->type != VAL_DICT) return make_num(0);

    /* Mark all pages in chain as free */
    Value *rv = dict_get(col_info, "root");
    if (rv) {
        uint32_t pg = (uint32_t)rv->data.num;
        for (int _hops = 0; pg != 0 && _hops < STORE_MAX_PAGE_HOPS; _hops++) {
            Page page;
            if (store_read_page(store, pg, &page) != 0) break;
            uint32_t next = page.next_page;
            /* Mark as free */
            memset(&page, 0, sizeof(Page));
            page.type = PAGE_FREE;
            page.next_page = store->free_page;
            store_write_page(store, pg, &page);
            store->free_page = pg;
            pg = next;
            if (pg >= store->page_count) break;
        }
    }

    /* Remove from catalog by rebuilding it */
    Value *new_catalog = make_dict(store->catalog->data.dict.count);
    for (int i = 0; i < store->catalog->data.dict.count; i++) {
        if (strcmp(store->catalog->data.dict.keys[i], collection) != 0) {
            dict_set(new_catalog, store->catalog->data.dict.keys[i],
                     store->catalog->data.dict.vals[i]);
        }
    }
    store->catalog = new_catalog;
    store->dirty = 1;
    store_flush_catalog(store);
    return make_num(1);
}

/* ================================================================
 * Registration
 * ================================================================ */

void register_store_builtins(Env *env) {
    env_set_local(env, "store_open",        make_builtin(builtin_store_open));
    env_set_local(env, "store_close",       make_builtin(builtin_store_close));
    env_set_local(env, "store_put",         make_builtin(builtin_store_put));
    env_set_local(env, "store_get",         make_builtin(builtin_store_get));
    env_set_local(env, "store_delete",      make_builtin(builtin_store_delete));
    env_set_local(env, "store_query",       make_builtin(builtin_store_query));
    env_set_local(env, "store_count",       make_builtin(builtin_store_count));
    env_set_local(env, "store_update",      make_builtin(builtin_store_update));
    env_set_local(env, "store_collections", make_builtin(builtin_store_collections));
    env_set_local(env, "store_drop",        make_builtin(builtin_store_drop));
}
