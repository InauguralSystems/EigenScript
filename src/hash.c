/*
 * EigenScript hash builtins — SHA-256, MD5, HMAC-SHA256.
 * Zero-dependency implementations of FIPS 180-4 and RFC 1321.
 */

#include "eigenscript.h"
#include <string.h>
#include <stdio.h>

/* ================================================================
 *  SHA-256 (FIPS 180-4)
 * ================================================================ */

static const uint32_t sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

typedef struct {
    uint32_t state[8];
    uint8_t  buffer[64];
    uint64_t total_len;
    int      buf_len;
} SHA256_CTX;

#define ROTR32(x,n) (((x)>>(n)) | ((x)<<(32-(n))))

static void sha256_transform(SHA256_CTX *ctx, const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)block[i*4]<<24) | ((uint32_t)block[i*4+1]<<16) |
                ((uint32_t)block[i*4+2]<<8) | (uint32_t)block[i*4+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROTR32(w[i-15],7) ^ ROTR32(w[i-15],18) ^ (w[i-15]>>3);
        uint32_t s1 = ROTR32(w[i-2],17) ^ ROTR32(w[i-2],19)  ^ (w[i-2]>>10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=ctx->state[0], b=ctx->state[1], c=ctx->state[2], d=ctx->state[3];
    uint32_t e=ctx->state[4], f=ctx->state[5], g=ctx->state[6], h=ctx->state[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1  = ROTR32(e,6) ^ ROTR32(e,11) ^ ROTR32(e,25);
        uint32_t ch  = (e & f) ^ (~e & g);
        uint32_t t1  = h + S1 + ch + sha256_k[i] + w[i];
        uint32_t S0  = ROTR32(a,2) ^ ROTR32(a,13) ^ ROTR32(a,22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2  = S0 + maj;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
    ctx->state[4]+=e; ctx->state[5]+=f; ctx->state[6]+=g; ctx->state[7]+=h;
}

static void sha256_init(SHA256_CTX *ctx) {
    ctx->state[0]=0x6a09e667; ctx->state[1]=0xbb67ae85;
    ctx->state[2]=0x3c6ef372; ctx->state[3]=0xa54ff53a;
    ctx->state[4]=0x510e527f; ctx->state[5]=0x9b05688c;
    ctx->state[6]=0x1f83d9ab; ctx->state[7]=0x5be0cd19;
    ctx->total_len = 0;
    ctx->buf_len = 0;
}

static void sha256_update(SHA256_CTX *ctx, const uint8_t *data, size_t len) {
    ctx->total_len += len;
    while (len > 0) {
        int space = 64 - ctx->buf_len;
        int take = (int)len < space ? (int)len : space;
        memcpy(ctx->buffer + ctx->buf_len, data, take);
        ctx->buf_len += take;
        data += take;
        len -= take;
        if (ctx->buf_len == 64) {
            sha256_transform(ctx, ctx->buffer);
            ctx->buf_len = 0;
        }
    }
}

static void sha256_final(SHA256_CTX *ctx, uint8_t hash[32]) {
    uint64_t bits = ctx->total_len * 8;
    uint8_t pad = 0x80;
    sha256_update(ctx, &pad, 1);
    pad = 0;
    while (ctx->buf_len != 56)
        sha256_update(ctx, &pad, 1);
    uint8_t len_be[8];
    for (int i = 7; i >= 0; i--) { len_be[i] = (uint8_t)(bits & 0xff); bits >>= 8; }
    sha256_update(ctx, len_be, 8);
    for (int i = 0; i < 8; i++) {
        hash[i*4]   = (ctx->state[i]>>24) & 0xff;
        hash[i*4+1] = (ctx->state[i]>>16) & 0xff;
        hash[i*4+2] = (ctx->state[i]>>8)  & 0xff;
        hash[i*4+3] =  ctx->state[i]      & 0xff;
    }
}

/* ================================================================
 *  MD5 (RFC 1321)
 * ================================================================ */

static const uint32_t md5_k[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
};

static const uint32_t md5_s[64] = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
};

typedef struct {
    uint32_t state[4];
    uint8_t  buffer[64];
    uint64_t total_len;
    int      buf_len;
} MD5_CTX;

#define ROTL32(x,n) (((x)<<(n)) | ((x)>>(32-(n))))

static void md5_transform(MD5_CTX *ctx, const uint8_t block[64]) {
    uint32_t m[16];
    for (int i = 0; i < 16; i++)
        m[i] = (uint32_t)block[i*4] | ((uint32_t)block[i*4+1]<<8) |
                ((uint32_t)block[i*4+2]<<16) | ((uint32_t)block[i*4+3]<<24);
    uint32_t a=ctx->state[0], b=ctx->state[1], c=ctx->state[2], d=ctx->state[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f, g;
        if (i < 16) {
            f = (b & c) | (~b & d);
            g = i;
        } else if (i < 32) {
            f = (d & b) | (~d & c);
            g = (5*i + 1) % 16;
        } else if (i < 48) {
            f = b ^ c ^ d;
            g = (3*i + 5) % 16;
        } else {
            f = c ^ (b | ~d);
            g = (7*i) % 16;
        }
        uint32_t temp = d;
        d = c;
        c = b;
        b = b + ROTL32(a + f + md5_k[i] + m[g], md5_s[i]);
        a = temp;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
}

static void md5_init(MD5_CTX *ctx) {
    ctx->state[0] = 0x67452301;
    ctx->state[1] = 0xefcdab89;
    ctx->state[2] = 0x98badcfe;
    ctx->state[3] = 0x10325476;
    ctx->total_len = 0;
    ctx->buf_len = 0;
}

static void md5_update(MD5_CTX *ctx, const uint8_t *data, size_t len) {
    ctx->total_len += len;
    while (len > 0) {
        int space = 64 - ctx->buf_len;
        int take = (int)len < space ? (int)len : space;
        memcpy(ctx->buffer + ctx->buf_len, data, take);
        ctx->buf_len += take;
        data += take;
        len -= take;
        if (ctx->buf_len == 64) {
            md5_transform(ctx, ctx->buffer);
            ctx->buf_len = 0;
        }
    }
}

static void md5_final(MD5_CTX *ctx, uint8_t hash[16]) {
    uint64_t bits = ctx->total_len * 8;
    uint8_t pad = 0x80;
    md5_update(ctx, &pad, 1);
    pad = 0;
    while (ctx->buf_len != 56)
        md5_update(ctx, &pad, 1);
    /* Length in little-endian */
    uint8_t len_le[8];
    for (int i = 0; i < 8; i++) { len_le[i] = (uint8_t)(bits & 0xff); bits >>= 8; }
    md5_update(ctx, len_le, 8);
    for (int i = 0; i < 4; i++) {
        hash[i*4]   =  ctx->state[i]      & 0xff;
        hash[i*4+1] = (ctx->state[i]>>8)  & 0xff;
        hash[i*4+2] = (ctx->state[i]>>16) & 0xff;
        hash[i*4+3] = (ctx->state[i]>>24) & 0xff;
    }
}

/* ================================================================
 *  Hex helper
 * ================================================================ */

static void bytes_to_hex(const uint8_t *bytes, int len, char *hex, int hex_size) {
    for (int i = 0; i < len && i * 2 + 2 < hex_size; i++)
        snprintf(hex + i * 2, 3, "%02x", bytes[i]);
    hex[len * 2 < hex_size ? len * 2 : hex_size - 1] = '\0';
}

/* ================================================================
 *  Builtin functions
 * ================================================================ */

Value* builtin_sha256(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, (uint8_t*)arg->data.str, strlen(arg->data.str));
    uint8_t hash[32];
    sha256_final(&ctx, hash);
    char hex[65];
    bytes_to_hex(hash, 32, hex, sizeof(hex));
    return make_str(hex);
}

Value* builtin_md5(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    MD5_CTX ctx;
    md5_init(&ctx);
    md5_update(&ctx, (uint8_t*)arg->data.str, strlen(arg->data.str));
    uint8_t hash[16];
    md5_final(&ctx, hash);
    char hex[33];
    bytes_to_hex(hash, 16, hex, sizeof(hex));
    return make_str(hex);
}

Value* builtin_sha256_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    FILE *f = fopen(arg->data.str, "rb");
    if (!f) return make_str("");
    SHA256_CTX ctx;
    sha256_init(&ctx);
    uint8_t buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        sha256_update(&ctx, buf, n);
    fclose(f);
    uint8_t hash[32];
    sha256_final(&ctx, hash);
    char hex[65];
    bytes_to_hex(hash, 32, hex, sizeof(hex));
    return make_str(hex);
}

Value* builtin_md5_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    FILE *f = fopen(arg->data.str, "rb");
    if (!f) return make_str("");
    MD5_CTX ctx;
    md5_init(&ctx);
    uint8_t buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        md5_update(&ctx, buf, n);
    fclose(f);
    uint8_t hash[16];
    md5_final(&ctx, hash);
    char hex[33];
    bytes_to_hex(hash, 16, hex, sizeof(hex));
    return make_str(hex);
}

Value* builtin_hmac_sha256(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_str("");
    Value *key_val = arg->data.list.items[0];
    Value *msg_val = arg->data.list.items[1];
    if (!key_val || key_val->type != VAL_STR || !msg_val || msg_val->type != VAL_STR)
        return make_str("");

    const uint8_t *key = (const uint8_t*)key_val->data.str;
    size_t key_len = strlen(key_val->data.str);
    const uint8_t *msg = (const uint8_t*)msg_val->data.str;
    size_t msg_len = strlen(msg_val->data.str);

    uint8_t key_block[64];
    memset(key_block, 0, 64);

    if (key_len > 64) {
        /* Hash the key first */
        SHA256_CTX kctx;
        sha256_init(&kctx);
        sha256_update(&kctx, key, key_len);
        uint8_t kh[32];
        sha256_final(&kctx, kh);
        memcpy(key_block, kh, 32);
    } else {
        memcpy(key_block, key, key_len);
    }

    /* ipad = key XOR 0x36, opad = key XOR 0x5c */
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = key_block[i] ^ 0x36;
        opad[i] = key_block[i] ^ 0x5c;
    }

    /* inner = H(ipad || message) */
    SHA256_CTX inner;
    sha256_init(&inner);
    sha256_update(&inner, ipad, 64);
    sha256_update(&inner, msg, msg_len);
    uint8_t inner_hash[32];
    sha256_final(&inner, inner_hash);

    /* outer = H(opad || inner) */
    SHA256_CTX outer;
    sha256_init(&outer);
    sha256_update(&outer, opad, 64);
    sha256_update(&outer, inner_hash, 32);
    uint8_t final_hash[32];
    sha256_final(&outer, final_hash);

    char hex[65];
    bytes_to_hex(final_hash, 32, hex, sizeof(hex));
    return make_str(hex);
}

/* ================================================================
 *  Registration
 * ================================================================ */

void register_hash_builtins(Env *env) {
    env_set_local(env, "sha256",      make_builtin(builtin_sha256));
    env_set_local(env, "md5",         make_builtin(builtin_md5));
    env_set_local(env, "sha256_file", make_builtin(builtin_sha256_file));
    env_set_local(env, "md5_file",    make_builtin(builtin_md5_file));
    env_set_local(env, "hmac_sha256", make_builtin(builtin_hmac_sha256));
}
