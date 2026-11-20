/*
 * Candidate TLS secrets in a stretch of a guest's memory, each checked against the encrypted records of the connections
 * it may belong to. A secret is reported only when it opens a record of that connection: the AEAD tag passes, or for
 * CBC the padding and the MAC. Called from Python through ctypes, with memory and records that came from the guest, so
 * every length is checked before it is used.
 *
 * A candidate is a window of 32 or 48 bytes. Few windows of real memory look random, and the checks are ordered by cost:
 * the look of the bytes, then the key derivation and one block of keystream against what the record has to hold, then
 * the whole record.
 */
#include <openssl/evp.h>
#include <openssl/md5.h>
#include <openssl/sha.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* H_LEGACY is the PRF of TLS 1.0 and 1.1, MD5 and SHA1 together. */
enum { H_SHA1 = 1, H_SHA256 = 2, H_SHA384 = 3, H_MD5 = 4, H_LEGACY = 5 };
enum { GCM = 1, CHACHA = 2, CBC = 3, CCM = 4, CCM8 = 5, CBC3 = 6, RC4 = 7 };
enum { MAXRECORDS = 32, LARGEST = (1 << 14) + 2048 };

/* A record of TLS, or for QUIC a whole protected packet: then type is 2 for a Handshake packet and 3 for one with a
 * short header, and version is where its packet number starts. */
typedef struct {
    uint32_t direction; /* 0 the client sent it, 1 the server */
    uint32_t type;      /* the outer content type */
    uint32_t version;   /* the record header's version */
    uint32_t length;
    const uint8_t *body;
} tls_record;

typedef struct {
    uint32_t version; /* 0x0301 to 0x0304 */
    uint32_t suite;
    uint32_t etm;
    uint32_t nrecords;
    const tls_record *records;
    uint8_t client_random[32];
    uint8_t server_random[32];
    uint32_t quic; /* 0 for TLS, else the QUIC version as 1 or 2 */
} tls_target;

typedef struct {
    uint32_t target;
    uint32_t record; /* the index among the target's records */
    uint32_t inner;  /* TLS 1.3: the inner content type of the record it opened */
    uint32_t first;  /* the record's first byte of plaintext */
    uint32_t length;
    uint32_t pad;
    uint64_t address;
    uint8_t secret[48];
} tls_hit;

typedef struct {
    uint16_t suite;
    uint8_t version, mode, keylen, ivlen, mac, prf;
} suite_info;

static const suite_info SUITES[] = {
    {0x1301, 13, GCM, 16, 12, 0, H_SHA256},
    {0x1302, 13, GCM, 32, 12, 0, H_SHA384},
    {0x1303, 13, CHACHA, 32, 12, 0, H_SHA256},
    {0x1304, 13, CCM, 16, 12, 0, H_SHA256},
    {0x1305, 13, CCM8, 16, 12, 0, H_SHA256},
    /* AES-CCM of TLS 1.2 (RFC 6655, 7251), whose PRF is SHA-256 throughout. */
    {0xc09c, 12, CCM, 16, 4, 0, H_SHA256},
    {0xc09d, 12, CCM, 32, 4, 0, H_SHA256},
    {0xc09e, 12, CCM, 16, 4, 0, H_SHA256},
    {0xc09f, 12, CCM, 32, 4, 0, H_SHA256},
    {0xc0a0, 12, CCM8, 16, 4, 0, H_SHA256},
    {0xc0a1, 12, CCM8, 32, 4, 0, H_SHA256},
    {0xc0a2, 12, CCM8, 16, 4, 0, H_SHA256},
    {0xc0a3, 12, CCM8, 32, 4, 0, H_SHA256},
    {0xc0ac, 12, CCM, 16, 4, 0, H_SHA256},
    {0xc0ad, 12, CCM, 32, 4, 0, H_SHA256},
    {0xc0ae, 12, CCM8, 16, 4, 0, H_SHA256},
    {0xc0af, 12, CCM8, 32, 4, 0, H_SHA256},
    /* 3DES and RC4, which old programs and devices still speak. */
    {0x000a, 12, CBC3, 24, 0, H_SHA1, H_SHA256},
    {0x0016, 12, CBC3, 24, 0, H_SHA1, H_SHA256},
    {0xc008, 12, CBC3, 24, 0, H_SHA1, H_SHA256},
    {0xc012, 12, CBC3, 24, 0, H_SHA1, H_SHA256},
    {0x0004, 12, RC4, 16, 0, H_MD5, H_SHA256},
    {0x0005, 12, RC4, 16, 0, H_SHA1, H_SHA256},
    {0xc007, 12, RC4, 16, 0, H_SHA1, H_SHA256},
    {0xc011, 12, RC4, 16, 0, H_SHA1, H_SHA256},
    {0x009c, 12, GCM, 16, 4, 0, H_SHA256},
    {0x009d, 12, GCM, 32, 4, 0, H_SHA384},
    {0x009e, 12, GCM, 16, 4, 0, H_SHA256},
    {0x009f, 12, GCM, 32, 4, 0, H_SHA384},
    {0xc02b, 12, GCM, 16, 4, 0, H_SHA256},
    {0xc02c, 12, GCM, 32, 4, 0, H_SHA384},
    {0xc02f, 12, GCM, 16, 4, 0, H_SHA256},
    {0xc030, 12, GCM, 32, 4, 0, H_SHA384},
    {0xcca8, 12, CHACHA, 32, 12, 0, H_SHA256},
    {0xcca9, 12, CHACHA, 32, 12, 0, H_SHA256},
    {0xccaa, 12, CHACHA, 32, 12, 0, H_SHA256},
    {0x002f, 12, CBC, 16, 0, H_SHA1, H_SHA256},
    {0x0033, 12, CBC, 16, 0, H_SHA1, H_SHA256},
    {0x0035, 12, CBC, 32, 0, H_SHA1, H_SHA256},
    {0x0039, 12, CBC, 32, 0, H_SHA1, H_SHA256},
    {0x003c, 12, CBC, 16, 0, H_SHA256, H_SHA256},
    {0x003d, 12, CBC, 32, 0, H_SHA256, H_SHA256},
    {0x0067, 12, CBC, 16, 0, H_SHA256, H_SHA256},
    {0x006b, 12, CBC, 32, 0, H_SHA256, H_SHA256},
    {0xc009, 12, CBC, 16, 0, H_SHA1, H_SHA256},
    {0xc00a, 12, CBC, 32, 0, H_SHA1, H_SHA256},
    {0xc013, 12, CBC, 16, 0, H_SHA1, H_SHA256},
    {0xc014, 12, CBC, 32, 0, H_SHA1, H_SHA256},
    {0xc023, 12, CBC, 16, 0, H_SHA256, H_SHA256},
    {0xc024, 12, CBC, 32, 0, H_SHA384, H_SHA384},
    {0xc027, 12, CBC, 16, 0, H_SHA256, H_SHA256},
    {0xc028, 12, CBC, 32, 0, H_SHA384, H_SHA384},
    /* TLS 1.0 and 1.1, whose key block has the IVs that TLS 1.0 uses for its first records. */
    {0x002f, 10, CBC, 16, 16, H_SHA1, H_LEGACY},
    {0x0033, 10, CBC, 16, 16, H_SHA1, H_LEGACY},
    {0x0035, 10, CBC, 32, 16, H_SHA1, H_LEGACY},
    {0x0039, 10, CBC, 32, 16, H_SHA1, H_LEGACY},
    {0xc009, 10, CBC, 16, 16, H_SHA1, H_LEGACY},
    {0xc00a, 10, CBC, 32, 16, H_SHA1, H_LEGACY},
    {0xc013, 10, CBC, 16, 16, H_SHA1, H_LEGACY},
    {0xc014, 10, CBC, 32, 16, H_SHA1, H_LEGACY},
    {0x000a, 10, CBC3, 24, 8, H_SHA1, H_LEGACY},
    {0x0016, 10, CBC3, 24, 8, H_SHA1, H_LEGACY},
    {0xc008, 10, CBC3, 24, 8, H_SHA1, H_LEGACY},
    {0xc012, 10, CBC3, 24, 8, H_SHA1, H_LEGACY},
    {0x0004, 10, RC4, 16, 0, H_MD5, H_LEGACY},
    {0x0005, 10, RC4, 16, 0, H_SHA1, H_LEGACY},
    {0xc007, 10, RC4, 16, 0, H_SHA1, H_LEGACY},
    {0xc011, 10, RC4, 16, 0, H_SHA1, H_LEGACY},
};

static const suite_info *suite_of(uint32_t version, uint32_t suite) {
    for (size_t i = 0; i < sizeof SUITES / sizeof *SUITES; i++)
        if (SUITES[i].suite == suite && SUITES[i].version == (version == 0x0304 ? 13 : version == 0x0303 ? 12 : 10))
            return &SUITES[i];
    return NULL;
}

int tlsscan_supported(uint32_t version, uint32_t suite) {
    return version >= 0x0301 && version <= 0x0304 && suite_of(version, suite) != NULL;
}

/* HMAC on the low level hash functions, whose keyed states are copied instead of rebuilt, since the scan computes
 * millions of them with a handful of keys each. */
typedef union {
    MD5_CTX md5;
    SHA_CTX s1;
    SHA256_CTX s256;
    SHA512_CTX s512;
} sha_ctx;

typedef struct {
    int hash;
    sha_ctx inner, outer;
} hmac_key;

static size_t hash_size(int hash) { return hash == H_MD5 ? 16 : hash == H_SHA1 ? 20 : hash == H_SHA256 ? 32 : 48; }
static size_t hash_block(int hash) { return hash == H_SHA384 ? 128 : 64; }

static void sha_init(int hash, sha_ctx *c) {
    if (hash == H_MD5)
        MD5_Init(&c->md5);
    else if (hash == H_SHA1)
        SHA1_Init(&c->s1);
    else if (hash == H_SHA256)
        SHA256_Init(&c->s256);
    else
        SHA384_Init(&c->s512);
}

static void sha_update(int hash, sha_ctx *c, const void *data, size_t length) {
    if (hash == H_MD5)
        MD5_Update(&c->md5, data, length);
    else if (hash == H_SHA1)
        SHA1_Update(&c->s1, data, length);
    else if (hash == H_SHA256)
        SHA256_Update(&c->s256, data, length);
    else
        SHA384_Update(&c->s512, data, length);
}

static void sha_final(int hash, sha_ctx *c, uint8_t *out) {
    if (hash == H_MD5)
        MD5_Final(out, &c->md5);
    else if (hash == H_SHA1)
        SHA1_Final(out, &c->s1);
    else if (hash == H_SHA256)
        SHA256_Final(out, &c->s256);
    else
        SHA384_Final(out, &c->s512);
}

/* Keys here are secrets and MAC keys of at most 48 bytes, never longer than a block. */
static void hmac_setup(hmac_key *k, int hash, const uint8_t *key, size_t length) {
    uint8_t pad[128];
    size_t block = hash_block(hash);
    k->hash = hash;
    memset(pad, 0x36, block);
    for (size_t i = 0; i < length; i++)
        pad[i] ^= key[i];
    sha_init(hash, &k->inner);
    sha_update(hash, &k->inner, pad, block);
    memset(pad, 0x5c, block);
    for (size_t i = 0; i < length; i++)
        pad[i] ^= key[i];
    sha_init(hash, &k->outer);
    sha_update(hash, &k->outer, pad, block);
}

static void hmac(const hmac_key *k, const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, uint8_t *out) {
    uint8_t inner[64];
    sha_ctx c = k->inner;
    sha_update(k->hash, &c, a, alen);
    if (blen)
        sha_update(k->hash, &c, b, blen);
    sha_final(k->hash, &c, inner);
    c = k->outer;
    sha_update(k->hash, &c, inner, hash_size(k->hash));
    sha_final(k->hash, &c, out);
}

/* HKDF-Expand-Label of RFC 8446 7.1 with an empty context, for an output no longer than the hash. */
static void expand_label(const hmac_key *k, const char *label, size_t length, uint8_t *out) {
    uint8_t info[32], full[64];
    size_t n = 0, l = strlen(label);
    info[n++] = (uint8_t)(length >> 8);
    info[n++] = (uint8_t)length;
    info[n++] = (uint8_t)(6 + l);
    memcpy(info + n, "tls13 ", 6);
    n += 6;
    memcpy(info + n, label, l);
    n += l;
    info[n++] = 0;
    info[n++] = 1;
    hmac(k, info, n, NULL, 0, full);
    memcpy(out, full, length);
}

/* P_hash of RFC 5246 5. */
static void p_hash(int hash, const uint8_t *secret, size_t secretlen, const uint8_t *seed, size_t seedlen, uint8_t *out, size_t length) {
    hmac_key k;
    uint8_t a[64], block[64];
    size_t size = hash_size(hash);
    hmac_setup(&k, hash, secret, secretlen);
    hmac(&k, seed, seedlen, NULL, 0, a);
    while (length) {
        size_t take = length < size ? length : size;
        hmac(&k, a, size, seed, seedlen, block);
        memcpy(out, block, take);
        out += take;
        length -= take;
        if (length)
            hmac(&k, a, size, NULL, 0, a);
    }
}

/* The key block of TLS 1.0 to 1.2 from the master secret: the PRF over "key expansion", which TLS 1.0 and 1.1 make of
 * P_MD5 over the master secret's first half and P_SHA1 over its second, XORed (RFC 2246 5). */
static void key_block(int hash, const uint8_t master[48], const uint8_t *seed, size_t seedlen, uint8_t *out, size_t length) {
    if (hash != H_LEGACY) {
        p_hash(hash, master, 48, seed, seedlen, out, length);
        return;
    }
    uint8_t other[256];
    p_hash(H_MD5, master, 24, seed, seedlen, out, length);
    p_hash(H_SHA1, master + 24, 24, seed, seedlen, other, length);
    for (size_t i = 0; i < length; i++)
        out[i] ^= other[i];
}

typedef struct {
    EVP_CIPHER_CTX *ecb[2][2]; /* [encrypt][256 bit key] */
    EVP_CIPHER_CTX *gcm[2], *cbc[2], *ccm[2], *chacha, *chachapoly, *des3ecb, *des3cbc;
    uint8_t plain[LARGEST + 64];
} crypto;

static EVP_CIPHER_CTX *ready(EVP_CIPHER_CTX **slot, const EVP_CIPHER *cipher, int encrypt) {
    if (!*slot) {
        EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
        if (!c || !EVP_CipherInit_ex(c, cipher, NULL, NULL, NULL, encrypt)) {
            EVP_CIPHER_CTX_free(c);
            return NULL;
        }
        EVP_CIPHER_CTX_set_padding(c, 0);
        *slot = c;
    }
    return *slot;
}

static void crypto_free(crypto *c) {
    for (int i = 0; i < 2; i++) {
        EVP_CIPHER_CTX_free(c->ecb[i][0]);
        EVP_CIPHER_CTX_free(c->ecb[i][1]);
        EVP_CIPHER_CTX_free(c->gcm[i]);
        EVP_CIPHER_CTX_free(c->cbc[i]);
        EVP_CIPHER_CTX_free(c->ccm[i]);
    }
    EVP_CIPHER_CTX_free(c->chacha);
    EVP_CIPHER_CTX_free(c->chachapoly);
    EVP_CIPHER_CTX_free(c->des3ecb);
    EVP_CIPHER_CTX_free(c->des3cbc);
}

/* One 3DES block, decrypted. */
static int des3_block(crypto *c, const uint8_t key[24], const uint8_t in[8], uint8_t out[8]) {
    int n;
    EVP_CIPHER_CTX *x = ready(&c->des3ecb, EVP_des_ede3_ecb(), 0);
    return x && EVP_CipherInit_ex(x, NULL, NULL, key, NULL, 0) && EVP_CipherUpdate(x, out, &n, in, 8) && n == 8;
}

/* RC4 from the start of its keystream, written out since OpenSSL 3 keeps it only in its legacy provider. */
static void rc4(const uint8_t *key, size_t keylen, const uint8_t *in, uint8_t *out, size_t length) {
    uint8_t s[256], t;
    size_t i, j = 0;
    for (i = 0; i < 256; i++)
        s[i] = (uint8_t)i;
    for (i = 0; i < 256; i++) {
        j = (j + s[i] + key[i % keylen]) & 0xff;
        t = s[i], s[i] = s[j], s[j] = t;
    }
    i = j = 0;
    for (size_t n = 0; n < length; n++) {
        i = (i + 1) & 0xff;
        j = (j + s[i]) & 0xff;
        t = s[i], s[i] = s[j], s[j] = t;
        out[n] = in[n] ^ s[(s[i] + s[j]) & 0xff];
    }
}

static size_t tag_size(int mode) { return mode == CCM8 ? 8 : 16; }

/* One AES block with the key, encrypting or decrypting. Re-keying a prepared context avoids OpenSSL fetching the
 * cipher again for each candidate. */
static int aes_block(crypto *c, int encrypt, size_t keylen, const uint8_t *key, const uint8_t in[16], uint8_t out[16]) {
    int big = keylen == 32, n;
    EVP_CIPHER_CTX *x = ready(&c->ecb[encrypt][big], big ? EVP_aes_256_ecb() : EVP_aes_128_ecb(), encrypt);
    return x && EVP_CipherInit_ex(x, NULL, NULL, key, NULL, encrypt) && EVP_CipherUpdate(x, out, &n, in, 16) && n == 16;
}

/* The ChaCha20 keystream block that covers this offset of the AEAD's plaintext, which starts at block counter 1. */
static int chacha_block(crypto *c, const uint8_t key[32], const uint8_t nonce[12], size_t offset, uint8_t out[64]) {
    static const uint8_t zero[64];
    uint8_t iv[16];
    uint32_t counter = (uint32_t)(1 + offset / 64);
    int n;
    EVP_CIPHER_CTX *x = ready(&c->chacha, EVP_chacha20(), 1);
    iv[0] = (uint8_t)counter, iv[1] = (uint8_t)(counter >> 8), iv[2] = (uint8_t)(counter >> 16), iv[3] = (uint8_t)(counter >> 24);
    memcpy(iv + 4, nonce, 12);
    return x && EVP_EncryptInit_ex(x, NULL, NULL, key, iv) && EVP_EncryptUpdate(x, out, &n, zero, 64) && n == 64;
}

/* A ChaCha20 keystream block at a counter and nonce given whole, as QUIC's header protection takes them. */
static int chacha_raw(crypto *c, const uint8_t key[32], const uint8_t sample[16], uint8_t out[64]) {
    static const uint8_t zero[64];
    int n;
    EVP_CIPHER_CTX *x = ready(&c->chacha, EVP_chacha20(), 1);
    return x && EVP_EncryptInit_ex(x, NULL, NULL, key, sample) && EVP_EncryptUpdate(x, out, &n, zero, 64) && n == 64;
}

/* The keystream block of AES-CCM at this counter, with a 12 byte nonce: a flags byte that says the counter has three bytes,
 * the nonce, and the counter, whose first block of plaintext is 1. */
static int ccm_block(crypto *c, size_t keylen, const uint8_t *key, const uint8_t nonce[12], uint32_t counter, uint8_t out[16]) {
    uint8_t block[16];
    block[0] = 2;
    memcpy(block + 1, nonce, 12);
    block[13] = (uint8_t)(counter >> 16), block[14] = (uint8_t)(counter >> 8), block[15] = (uint8_t)counter;
    return aes_block(c, 1, keylen, key, block, out);
}

/* The whole AEAD record, tag included. The plaintext is left in c->plain. */
static int aead_open(crypto *c, int mode, size_t keylen, const uint8_t *key, const uint8_t nonce[12], const uint8_t *aad,
                     size_t aadlen, const uint8_t *body, size_t length) {
    uint8_t tag[16];
    int n, m;
    EVP_CIPHER_CTX *x;
    size_t taglen = tag_size(mode);
    if (length < taglen || length - taglen > sizeof c->plain - 32)
        return 0;
    if (mode == CCM || mode == CCM8) {
        /* CCM takes the tag and the length before the key, and checks the tag as it decrypts. */
        x = ready(&c->ccm[keylen == 32], keylen == 32 ? EVP_aes_256_ccm() : EVP_aes_128_ccm(), 0);
        memcpy(tag, body + length - taglen, taglen);
        return x && EVP_CIPHER_CTX_ctrl(x, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL) && EVP_CIPHER_CTX_ctrl(x, EVP_CTRL_AEAD_SET_TAG, (int)taglen, tag) &&
               EVP_DecryptInit_ex(x, NULL, NULL, key, nonce) && EVP_DecryptUpdate(x, NULL, &n, NULL, (int)(length - taglen)) &&
               EVP_DecryptUpdate(x, NULL, &n, aad, (int)aadlen) && EVP_DecryptUpdate(x, c->plain, &n, body, (int)(length - taglen)) > 0;
    }
    if (mode == GCM)
        x = ready(&c->gcm[keylen == 32], keylen == 32 ? EVP_aes_256_gcm() : EVP_aes_128_gcm(), 0);
    else
        x = ready(&c->chachapoly, EVP_chacha20_poly1305(), 0);
    memcpy(tag, body + length - 16, 16);
    return x && EVP_DecryptInit_ex(x, NULL, NULL, key, nonce) && EVP_DecryptUpdate(x, NULL, &n, aad, (int)aadlen) &&
           EVP_DecryptUpdate(x, c->plain, &n, body, (int)(length - 16)) &&
           EVP_CIPHER_CTX_ctrl(x, EVP_CTRL_AEAD_SET_TAG, 16, tag) && EVP_DecryptFinal_ex(x, c->plain + n, &m) > 0;
}

typedef struct {
    const tls_target *target;
    const suite_info *suite;
    uint8_t seed[77];
    uint32_t nrecords;
    uint32_t index[MAXRECORDS];
    _Atomic uint32_t solved;
    _Atomic int client, server, done;
} prepared;

typedef struct {
    const uint8_t *memory;
    size_t length, step, from, to;
    uint64_t base;
    prepared *targets;
    size_t ntargets;
    tls_hit *hits;
    size_t maxhits;
    _Atomic size_t *nhits;
    _Atomic int *stop;
    _Atomic uint64_t *tested;
} job;

/* Whether a window could be a secret. A random window of 32 or 48 bytes has no 8 byte word that starts with two zero or
 * two 0xff bytes, as pointers, small numbers and negative ones do, has most of its bytes distinct, and is not mostly
 * text. Each test throws away a random secret with odds near 1 in 5000. */
static int plausible(const uint8_t *p, size_t n) {
    uint64_t seen[4] = {0, 0, 0, 0}, q;
    size_t distinct = 0, printable = 0;
    for (size_t i = 0; i < n; i += 8) {
        memcpy(&q, p + i, 8);
        uint16_t top = (uint16_t)(q >> 48);
        if (top == 0 || top == 0xffff)
            return 0;
    }
    for (size_t i = 0; i < n; i++) {
        uint8_t b = p[i];
        if (!(seen[b >> 6] >> (b & 63) & 1)) {
            seen[b >> 6] |= 1ull << (b & 63);
            distinct++;
        }
        printable += b >= 0x20 && b < 0x7f;
    }
    return distinct * 3 >= n * 2 && printable * 4 <= n * 3;
}

static void report(job *j, prepared *t, uint32_t record, uint32_t inner, uint32_t first, const uint8_t *secret, size_t length,
                   size_t offset) {
    uint32_t bit = 1u << record, before = atomic_fetch_or(&t->solved, bit);
    if (before & bit)
        return;
    size_t at = atomic_fetch_add(j->nhits, 1);
    if (at < j->maxhits) {
        tls_hit *h = &j->hits[at];
        memset(h, 0, sizeof *h);
        h->target = (uint32_t)(t - j->targets);
        h->record = record;
        h->inner = inner;
        h->first = first;
        h->length = (uint32_t)length;
        h->address = j->base + offset;
        memcpy(h->secret, secret, length);
    }
}

/* Done when the secrets that decrypt the traffic are found: TLS 1.2's master secret, or both traffic secrets of TLS 1.3.
 * The last target done stops the scan. */
static void settle(job *j, prepared *t) {
    int finished = t->target->version != 0x0304 ? atomic_load(&t->solved) != 0 : atomic_load(&t->client) && atomic_load(&t->server);
    if (!finished || atomic_exchange(&t->done, 1))
        return;
    for (size_t i = 0; i < j->ntargets; i++)
        if (!atomic_load(&j->targets[i].done))
            return;
    atomic_store(j->stop, 1);
}

/* TLS 1.3: the secret's key and IV open the record at sequence number 0, so the record starts the secret's epoch. */
static void try13(job *j, crypto *c, prepared *t, const uint8_t *key, const uint8_t *iv, const uint8_t *secret, size_t offset) {
    const suite_info *s = t->suite;
    for (uint32_t r = 0; r < t->nrecords; r++) {
        uint32_t solved = atomic_load(&t->solved);
        const tls_record *x = &t->target->records[r];
        if (solved >> r & 1 || x->length < tag_size(s->mode) + 1 || x->length > LARGEST)
            continue;
        size_t clen = x->length - tag_size(s->mode), last = clen - 1;
        uint8_t byte;
        if (s->mode == CCM || s->mode == CCM8) {
            uint8_t stream[16];
            if (!ccm_block(c, s->keylen, key, iv, (uint32_t)(1 + last / 16), stream))
                continue;
            byte = x->body[last] ^ stream[last % 16];
        } else if (s->mode == GCM) {
            uint8_t counter[16], stream[16];
            uint32_t block = (uint32_t)(2 + last / 16);
            memcpy(counter, iv, 12);
            counter[12] = (uint8_t)(block >> 24), counter[13] = (uint8_t)(block >> 16), counter[14] = (uint8_t)(block >> 8),
            counter[15] = (uint8_t)block;
            if (!aes_block(c, 1, s->keylen, key, counter, stream))
                continue;
            byte = x->body[last] ^ stream[last % 16];
        } else {
            uint8_t stream[64];
            if (!chacha_block(c, key, iv, last, stream))
                continue;
            byte = x->body[last] ^ stream[last % 64];
        }
        /* The last byte of an inner plaintext is its content type, or 0 when the sender padded it. */
        if (byte != 0 && byte != 21 && byte != 22 && byte != 23)
            continue;
        uint8_t aad[5] = {23, (uint8_t)(x->version >> 8), (uint8_t)x->version, (uint8_t)(x->length >> 8), (uint8_t)x->length};
        if (!aead_open(c, s->mode, s->keylen, key, iv, aad, 5, x->body, x->length))
            continue;
        size_t end = clen;
        while (end > 0 && c->plain[end - 1] == 0)
            end--;
        if (end == 0)
            continue;
        uint8_t inner = c->plain[end - 1], first = end > 1 ? c->plain[0] : 0;
        report(j, t, r, inner, first, secret, hash_size(s->prf), offset);
        /* A client's first record under its handshake secret is its Finished, everything after is traffic. */
        if (x->direction == 1 && t->index[r] > 0)
            atomic_store(&t->server, 1);
        if (x->direction == 0 && !(inner == 22 && first == 20))
            atomic_store(&t->client, 1);
        settle(j, t);
    }
}

/* QUIC (RFC 9001 5): the secret's key, IV and header protection key open a protected packet at its own packet number,
 * which the start of a connection keeps small enough to be whole in the packet. */
static void tryquic(job *j, crypto *c, prepared *t, const uint8_t *key, const uint8_t *iv, const uint8_t *hp, const uint8_t *secret,
                    size_t offset) {
    const suite_info *s = t->suite;
    for (uint32_t r = 0; r < t->nrecords; r++) {
        const tls_record *x = &t->target->records[r];
        size_t at = x->version;
        /* RFC 9001 5.4.2: the sample is the 16 bytes from 4 after the packet number's start, the tag among them in a short packet. */
        if (atomic_load(&t->solved) >> r & 1 || at > 64 || at + 4 + 16 > x->length || x->length > LARGEST)
            continue;
        uint8_t mask[64];
        if (s->mode != CHACHA ? !aes_block(c, 1, s->keylen, hp, x->body + at + 4, mask) : !chacha_raw(c, hp, x->body + at + 4, mask))
            continue;
        int long_header = x->body[0] & 0x80;
        uint8_t first = x->body[0] ^ (mask[0] & (long_header ? 0x0f : 0x1f));
        /* The reserved bits are zero in a packet whose protection came off, which throws away most candidates for one AES block. */
        if (first & (long_header ? 0x0c : 0x18))
            continue;
        size_t length = (size_t)(first & 3) + 1;
        uint8_t header[128], nonce[12];
        uint64_t number = 0;
        memcpy(header, x->body, at + length);
        header[0] = first;
        for (size_t i = 0; i < length; i++) {
            header[at + i] = x->body[at + i] ^ mask[1 + i];
            number = number << 8 | header[at + i];
        }
        memcpy(nonce, iv, 12);
        for (int i = 0; i < 8; i++)
            nonce[11 - i] ^= (uint8_t)(number >> (8 * i));
        if (!aead_open(c, s->mode, s->keylen, key, nonce, header, at + length, x->body + at + length, x->length - at - length))
            continue;
        report(j, t, r, x->type, 0, secret, hash_size(s->prf), offset);
        if (x->type == 3)
            atomic_store(x->direction ? &t->server : &t->client, 1);
        settle(j, t);
    }
}

/* TLS 1.0 to 1.2: the master secret's keys open the first encrypted record of a direction, its Finished, at sequence
 * number 0. */
static void try12(job *j, crypto *c, prepared *t, const uint8_t *master, size_t offset) {
    static const uint8_t header[4] = {20, 0, 0, 12};
    const suite_info *s = t->suite;
    size_t maclen = s->mode == CBC || s->mode == CBC3 || s->mode == RC4 ? hash_size(s->mac) : 0,
           need = 2 * maclen + 2 * s->keylen + 2 * s->ivlen;
    uint8_t block[2 * 48 + 2 * 32 + 2 * 12];
    int derived = 0;
    for (uint32_t r = 0; r < t->nrecords; r++) {
        const tls_record *x = &t->target->records[r];
        if (atomic_load(&t->solved) >> r & 1 || x->length > LARGEST)
            continue;
        if (!derived) {
            key_block(s->prf, master, t->seed, sizeof t->seed, block, need);
            derived = 1;
        }
        int server = x->direction == 1;
        const uint8_t *mackey = block + (server ? maclen : 0), *key = block + 2 * maclen + (server ? s->keylen : 0),
                      *fixed = block + 2 * maclen + 2 * s->keylen + (server ? s->ivlen : 0);
        uint8_t nonce[12], stream[16], first[16], aad[13] = {0, 0, 0, 0, 0, 0, 0, 0, 22, 3, (uint8_t)t->target->version, 0, 0};
        if (s->mode == GCM) {
            if (x->length < 8 + 16 + 4)
                continue;
            size_t clen = x->length - 24;
            uint8_t counter[16];
            memcpy(nonce, fixed, 4);
            memcpy(nonce + 4, x->body, 8);
            memcpy(counter, nonce, 12);
            counter[12] = 0, counter[13] = 0, counter[14] = 0, counter[15] = 2;
            if (!aes_block(c, 1, s->keylen, key, counter, stream))
                continue;
            for (int i = 0; i < 4; i++)
                first[i] = x->body[8 + i] ^ stream[i];
            if (memcmp(first, header, 4))
                continue;
            aad[11] = (uint8_t)(clen >> 8), aad[12] = (uint8_t)clen;
            if (!aead_open(c, GCM, s->keylen, key, nonce, aad, 13, x->body + 8, x->length - 8))
                continue;
        } else if (s->mode == CCM || s->mode == CCM8) {
            size_t taglen = tag_size(s->mode);
            if (x->length < 8 + taglen + 4)
                continue;
            size_t clen = x->length - 8 - taglen;
            memcpy(nonce, fixed, 4);
            memcpy(nonce + 4, x->body, 8);
            if (!ccm_block(c, s->keylen, key, nonce, 1, stream))
                continue;
            for (int i = 0; i < 4; i++)
                first[i] = x->body[8 + i] ^ stream[i];
            if (memcmp(first, header, 4))
                continue;
            aad[11] = (uint8_t)(clen >> 8), aad[12] = (uint8_t)clen;
            if (!aead_open(c, s->mode, s->keylen, key, nonce, aad, 13, x->body + 8, x->length - 8))
                continue;
        } else if (s->mode == RC4) {
            /* A stream cipher's first record of a direction is its Finished from the start of the keystream, then its MAC. */
            if (x->length != 16 + maclen)
                continue;
            rc4(key, s->keylen, x->body, c->plain, x->length);
            if (memcmp(c->plain, header, 4))
                continue;
            hmac_key mk;
            uint8_t mac[48];
            hmac_setup(&mk, s->mac, mackey, maclen);
            aad[11] = 0, aad[12] = 16;
            hmac(&mk, aad, 13, c->plain, 16, mac);
            if (memcmp(mac, c->plain + 16, maclen))
                continue;
        } else if (s->mode == CHACHA) {
            if (x->length < 16 + 4)
                continue;
            size_t clen = x->length - 16;
            uint8_t stream64[64];
            memcpy(nonce, fixed, 12);
            if (!chacha_block(c, key, nonce, 0, stream64))
                continue;
            for (int i = 0; i < 4; i++)
                first[i] = x->body[i] ^ stream64[i];
            if (memcmp(first, header, 4))
                continue;
            aad[11] = (uint8_t)(clen >> 8), aad[12] = (uint8_t)clen;
            if (!aead_open(c, CHACHA, s->keylen, key, nonce, aad, 13, x->body, x->length))
                continue;
        } else {
            /* TLS 1.0 has no IV in its records, and its first record's IV is the key block's. 3DES has blocks of 8 bytes. */
            size_t bs = s->mode == CBC3 ? 8 : 16;
            size_t tail = t->target->etm ? maclen : 0, explicit = t->target->version >= 0x0302 ? bs : 0;
            if (x->length < explicit + 16 + tail || (x->length - explicit - tail) % bs)
                continue;
            const uint8_t *iv = explicit ? x->body : fixed, *enc = x->body + explicit;
            size_t enclen = x->length - explicit - tail;
            if (s->mode == CBC3 ? !des3_block(c, key, enc, first) : !aes_block(c, 0, s->keylen, key, enc, first))
                continue;
            for (size_t i = 0; i < bs; i++)
                first[i] ^= iv[i];
            if (memcmp(first, header, 4) || enclen > sizeof c->plain - 32)
                continue;
            hmac_key mk;
            uint8_t mac[48];
            hmac_setup(&mk, s->mac, mackey, maclen);
            if (t->target->etm) {
                aad[11] = (uint8_t)((x->length - tail) >> 8), aad[12] = (uint8_t)(x->length - tail);
                hmac(&mk, aad, 13, x->body, x->length - tail, mac);
                if (memcmp(mac, x->body + x->length - tail, maclen))
                    continue;
            }
            int big = s->keylen == 32, n;
            EVP_CIPHER_CTX *d = s->mode == CBC3 ? ready(&c->des3cbc, EVP_des_ede3_cbc(), 0)
                                                : ready(&c->cbc[big], big ? EVP_aes_256_cbc() : EVP_aes_128_cbc(), 0);
            if (!d || !EVP_DecryptInit_ex(d, NULL, NULL, key, iv) || !EVP_DecryptUpdate(d, c->plain, &n, enc, (int)enclen) ||
                (size_t)n != enclen)
                continue;
            size_t pad = c->plain[enclen - 1];
            if (pad + 1 + (t->target->etm ? 0 : maclen) + 16 != enclen)
                continue;
            int padded = 1;
            for (size_t i = enclen - 1 - pad; i < enclen - 1; i++)
                padded &= c->plain[i] == pad;
            if (!padded)
                continue;
            if (!t->target->etm) {
                aad[11] = 0, aad[12] = 16;
                hmac(&mk, aad, 13, c->plain, 16, mac);
                if (memcmp(mac, c->plain + 16, maclen))
                    continue;
            }
        }
        report(j, t, r, 22, 20, master, 48, offset);
        settle(j, t);
    }
}

/* The candidates of one length at one offset, against every target they could belong to. */
static void candidate(job *j, crypto *c, const uint8_t *p, size_t n, size_t offset) {
    hmac_key k;
    int keyed = 0;
    uint8_t key[2][32], iv[2][12], qkey[3][2][32], qiv[3][2][12], qhp[3][2][32];
    int have[2] = {0, 0}, qhave[3][2] = {{0, 0}, {0, 0}, {0, 0}};
    for (size_t i = 0; i < j->ntargets; i++) {
        prepared *t = &j->targets[i];
        if (atomic_load(&t->done))
            continue;
        if (t->target->version != 0x0304) {
            if (n == 48)
                try12(j, c, t, p, offset);
            continue;
        }
        if (hash_size(t->suite->prf) != n)
            continue;
        if (!keyed) {
            hmac_setup(&k, t->suite->prf, p, n);
            keyed = 1;
        }
        int big = t->suite->keylen == 32;
        uint32_t quic = t->target->quic;
        if (quic == 1 || quic == 2) {
            if (!qhave[quic][big]) {
                /* QUIC version 2 names its keys apart (RFC 9369 3.3.2), and ChaCha20's header key is as long as its key. */
                expand_label(&k, quic == 1 ? "quic key" : "quicv2 key", t->suite->keylen, qkey[quic][big]);
                expand_label(&k, quic == 1 ? "quic iv" : "quicv2 iv", 12, qiv[quic][big]);
                expand_label(&k, quic == 1 ? "quic hp" : "quicv2 hp", t->suite->keylen, qhp[quic][big]);
                qhave[quic][big] = 1;
            }
            tryquic(j, c, t, qkey[quic][big], qiv[quic][big], qhp[quic][big], p, offset);
            continue;
        }
        if (!have[big]) {
            expand_label(&k, "key", t->suite->keylen, key[big]);
            expand_label(&k, "iv", 12, iv[big]);
            have[big] = 1;
        }
        try13(j, c, t, key[big], iv[big], p, offset);
    }
}

static void *work(void *argument) {
    job *j = argument;
    crypto *c = calloc(1, sizeof *c);
    int want32 = 0, want48 = 0;
    uint64_t tested = 0;
    if (!c)
        return NULL;
    for (size_t i = 0; i < j->ntargets; i++) {
        if (atomic_load(&j->targets[i].done))
            continue;
        size_t n = j->targets[i].target->version != 0x0304 ? 48 : hash_size(j->targets[i].suite->prf);
        want32 |= n == 32;
        want48 |= n == 48;
    }
    size_t round = 0;
    for (size_t at = j->from; at < j->to && at + 32 <= j->length; at += j->step) {
        if ((++round & 0x3fff) == 0 && atomic_load(j->stop))
            break;
        const uint8_t *p = j->memory + at;
        if (!plausible(p, 32))
            continue;
        if (want32) {
            tested++;
            candidate(j, c, p, 32, at);
        }
        if (want48 && at + 48 <= j->length && plausible(p, 48)) {
            tested++;
            candidate(j, c, p, 48, at);
        }
    }
    atomic_fetch_add(j->tested, tested);
    crypto_free(c);
    free(c);
    return NULL;
}

/*
 * Tries every window of memory that starts at a multiple of step against the targets, with up to threads threads.
 * Addresses in the hits are base plus the offset. Returns the number of hits, which may exceed maxhits, in which case
 * only maxhits were written. tested receives how many candidates passed the first look.
 */
size_t tlsscan_scan(const uint8_t *memory, size_t length, uint64_t base, size_t step, unsigned threads, const tls_target *targets,
                    size_t ntargets, tls_hit *hits, size_t maxhits, uint64_t *tested) {
    _Atomic size_t nhits = 0;
    _Atomic int stop = 0;
    _Atomic uint64_t count = 0;
    /* A hit names its target by its place in the list given, so a target this cannot check keeps its place, as done. */
    prepared *all = calloc(ntargets ? ntargets : 1, sizeof *all);
    size_t usable = 0;
    if (!all)
        return 0;
    if (step == 0)
        step = 1;
    if (threads == 0)
        threads = 1;
    if (threads > 64)
        threads = 64;
    for (size_t i = 0; i < ntargets; i++) {
        const tls_target *t = &targets[i];
        prepared *p = &all[i];
        p->target = t;
        p->suite = suite_of(t->version, t->suite);
        p->nrecords = t->nrecords < MAXRECORDS ? t->nrecords : MAXRECORDS;
        if (!p->suite || !p->nrecords || !t->records) {
            p->suite = SUITES;
            atomic_store(&p->done, 1);
            continue;
        }
        uint32_t seen[2] = {0, 0};
        for (uint32_t r = 0; r < p->nrecords; r++)
            p->index[r] = seen[t->records[r].direction ? 1 : 0]++;
        memcpy(p->seed, "key expansion", 13);
        memcpy(p->seed + 13, t->server_random, 32);
        memcpy(p->seed + 45, t->client_random, 32);
        usable++;
    }
    if (usable && length >= 32) {
        pthread_t ids[64];
        job jobs[64];
        size_t positions = (length - 32) / step + 1, share = (positions + threads - 1) / threads;
        unsigned started = 0;
        for (unsigned i = 0; i < threads && i * share < positions; i++) {
            jobs[i] = (job){memory, length, step, i * share * step, (i + 1) * share * step, base, all, ntargets, hits, maxhits, &nhits, &stop, &count};
            if (pthread_create(&ids[started], NULL, work, &jobs[i]))
                work(&jobs[i]);
            else
                started++;
        }
        for (unsigned i = 0; i < started; i++)
            pthread_join(ids[i], NULL);
    }
    free(all);
    if (tested)
        *tested = atomic_load(&count);
    return atomic_load(&nhits);
}

/*
 * Opens a QUIC Initial packet (RFC 9001 5.2), whose keys come from the client's first destination connection ID, which
 * anyone on the path knows, to read the hellos in it. at is where its packet number starts. Returns the length of the
 * plaintext written to out, or -1.
 */
/* One record of TLS 1.3, its header and the rest, opened with a traffic secret at a sequence number: the records after a key
 * update, which tshark opens only from the first secret on. The plaintext, inner type and padding still on it, goes to out. */
long tlsscan_open13(uint32_t suite, const uint8_t *secret, uint64_t seq, const uint8_t *record, size_t length, uint8_t *out, size_t room) {
    const suite_info *s = suite_of(0x0304, suite);
    hmac_key k;
    uint8_t key[32], iv[12], nonce[12];
    long result = -1;
    if (!s || length < 5 + tag_size(s->mode) + 1 || length > 5 + LARGEST)
        return -1;
    hmac_setup(&k, s->prf, secret, hash_size(s->prf));
    expand_label(&k, "key", s->keylen, key);
    expand_label(&k, "iv", 12, iv);
    memcpy(nonce, iv, 12);
    for (int i = 0; i < 8; i++)
        nonce[11 - i] ^= (uint8_t)(seq >> (8 * i));
    crypto *c = calloc(1, sizeof *c);
    if (!c)
        return -1;
    size_t plain = length - 5 - tag_size(s->mode);
    if (plain <= room && aead_open(c, s->mode, s->keylen, key, nonce, record, 5, record + 5, length - 5)) {
        memcpy(out, c->plain, plain);
        result = (long)plain;
    }
    crypto_free(c);
    free(c);
    return result;
}

/* The secret a key update of TLS 1.3 turns one into (RFC 8446 7.2), and its length. */
int tlsscan_next13(uint32_t suite, const uint8_t *secret, uint8_t *out) {
    const suite_info *s = suite_of(0x0304, suite);
    hmac_key k;
    if (!s)
        return 0;
    hmac_setup(&k, s->prf, secret, hash_size(s->prf));
    expand_label(&k, "traffic upd", hash_size(s->prf), out);
    return (int)hash_size(s->prf);
}

long tlsscan_quic_initial(const uint8_t *packet, size_t length, size_t at, uint32_t version, const uint8_t *dcid, size_t dcidlen,
                          int from_server, uint8_t *out, size_t room) {
    static const uint8_t salt1[20] = {0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
                                      0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a};
    static const uint8_t salt2[20] = {0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93,
                                      0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9};
    hmac_key k;
    // A client that comes back sends the token the server gave it in its Initial packets, which makes their headers long.
    uint8_t initial[32], secret[32], key[16], iv[12], hp[16], mask[16], header[2048], nonce[12];
    long result = -1;
    if ((version != 1 && version != 2) || at + 4 > sizeof header || at + 4 + 16 > length || length > LARGEST || dcidlen > 20)
        return -1;
    hmac_setup(&k, H_SHA256, version == 1 ? salt1 : salt2, 20);
    hmac(&k, dcid, dcidlen, NULL, 0, initial);
    hmac_setup(&k, H_SHA256, initial, 32);
    expand_label(&k, from_server ? "server in" : "client in", 32, secret);
    hmac_setup(&k, H_SHA256, secret, 32);
    expand_label(&k, version == 1 ? "quic key" : "quicv2 key", 16, key);
    expand_label(&k, version == 1 ? "quic iv" : "quicv2 iv", 12, iv);
    expand_label(&k, version == 1 ? "quic hp" : "quicv2 hp", 16, hp);
    crypto *c = calloc(1, sizeof *c);
    if (!c)
        return -1;
    if (aes_block(c, 1, 16, hp, packet + at + 4, mask)) {
        uint8_t first = packet[0] ^ (mask[0] & 0x0f);
        size_t pnlen = (size_t)(first & 3) + 1;
        uint64_t number = 0;
        memcpy(header, packet, at + pnlen);
        header[0] = first;
        for (size_t i = 0; i < pnlen; i++) {
            header[at + i] = packet[at + i] ^ mask[1 + i];
            number = number << 8 | header[at + i];
        }
        memcpy(nonce, iv, 12);
        for (int i = 0; i < 8; i++)
            nonce[11 - i] ^= (uint8_t)(number >> (8 * i));
        size_t clen = length - at - pnlen - 16;
        if (clen <= room && aead_open(c, GCM, 16, key, nonce, header, at + pnlen, packet + at + pnlen, length - at - pnlen)) {
            memcpy(out, c->plain, clen);
            result = (long)clen;
        }
    }
    crypto_free(c);
    free(c);
    return result;
}

typedef struct {
    const uint8_t *memory, *needles;
    size_t length, from, to, n, bits;
    const uint64_t *table;
    const uint32_t *slot;
    uint64_t base;
    uint64_t *addresses;
    uint32_t *which;
    size_t max;
    _Atomic size_t *found;
} search;

static size_t place(uint64_t prefix, size_t bits) { return (size_t)((prefix * 0x9E3779B97F4A7C15ull) >> (64 - bits)); }

static void *seek(void *argument) {
    search *s = argument;
    size_t mask = ((size_t)1 << s->bits) - 1;
    for (size_t at = s->from; at < s->to && at + 32 <= s->length; at++) {
        uint64_t prefix;
        memcpy(&prefix, s->memory + at, 8);
        for (size_t h = place(prefix, s->bits); s->slot[h]; h = (h + 1) & mask) {
            if (s->table[h] != prefix)
                continue;
            uint32_t which = s->slot[h] - 1;
            if (memcmp(s->memory + at, s->needles + 32 * (size_t)which, 32))
                continue;
            size_t i = atomic_fetch_add(s->found, 1);
            if (i < s->max) {
                s->addresses[i] = s->base + at;
                s->which[i] = which;
            }
        }
    }
    return NULL;
}

/*
 * Every place in memory where one of the 32 byte needles is, at any offset: the anchors, which are the client randoms
 * the libraries keep beside their secrets. Returns the number found, which may exceed max.
 */
size_t tlsscan_find(const uint8_t *memory, size_t length, uint64_t base, const uint8_t *needles, size_t n, unsigned threads,
                    uint64_t *addresses, uint32_t *which, size_t max) {
    _Atomic size_t found = 0;
    size_t bits = 4;
    if (!n || length < 32)
        return 0;
    while (((size_t)1 << bits) < 4 * n)
        bits++;
    size_t size = (size_t)1 << bits;
    uint64_t *table = calloc(size, sizeof *table);
    uint32_t *slot = calloc(size, sizeof *slot);
    if (!table || !slot) {
        free(table);
        free(slot);
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        uint64_t prefix;
        memcpy(&prefix, needles + 32 * i, 8);
        size_t h = place(prefix, bits);
        while (slot[h])
            h = (h + 1) & (size - 1);
        table[h] = prefix;
        slot[h] = (uint32_t)i + 1;
    }
    if (threads == 0)
        threads = 1;
    if (threads > 64)
        threads = 64;
    pthread_t ids[64];
    search parts[64];
    size_t share = (length + threads - 1) / threads;
    unsigned started = 0;
    for (unsigned i = 0; i < threads && i * share < length; i++) {
        parts[i] = (search){memory, needles, length, i * share, (i + 1) * share, n, bits, table, slot, base, addresses, which, max, &found};
        if (pthread_create(&ids[started], NULL, seek, &parts[i]))
            seek(&parts[i]);
        else
            started++;
    }
    for (unsigned i = 0; i < started; i++)
        pthread_join(ids[i], NULL);
    free(table);
    free(slot);
    return atomic_load(&found);
}
