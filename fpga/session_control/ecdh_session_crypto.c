#include "ecdh_session_crypto.h"

#include <stdlib.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/rand.h>

enum {
    CAPSULE_MAGIC_OFFSET = 0,
    CAPSULE_VERSION_OFFSET = 4,
    CAPSULE_SUITE_OFFSET = 5,
    CAPSULE_RESERVED_OFFSET = 6,
};

static const uint8_t capsule_magic[4] = {'Z', 'E', 'C', '1'};
static const uint8_t secret_magic[4] = {'A', 'K', 'Y', '1'};
static const uint8_t hkdf_info[] = SESSION_WRAP_HKDF_INFO;
static const uint8_t confirm_label[] = "AES-GCM-KEY-PROOF-V1";

static void put_be32(uint8_t out[4], uint32_t value)
{
    out[0] = (uint8_t)(value >> 24);
    out[1] = (uint8_t)(value >> 16);
    out[2] = (uint8_t)(value >> 8);
    out[3] = (uint8_t)value;
}

static void put_be64(uint8_t out[8], uint64_t value)
{
    size_t i;

    for (i = 0; i < 8; ++i)
        out[i] = (uint8_t)(value >> (56u - 8u * i));
}

static uint32_t get_be32(const uint8_t in[4])
{
    return ((uint32_t)in[0] << 24) | ((uint32_t)in[1] << 16) |
           ((uint32_t)in[2] << 8) | (uint32_t)in[3];
}

static uint64_t get_be64(const uint8_t in[8])
{
    uint64_t value = 0;
    size_t i;

    for (i = 0; i < 8; ++i)
        value = (value << 8) | in[i];
    return value;
}

void session_secure_clear(void *ptr, size_t len)
{
    if (ptr != NULL && len != 0)
        OPENSSL_cleanse(ptr, len);
}

EVP_PKEY *ecdh_session_generate_key(void)
{
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, NULL);
    EVP_PKEY *key = NULL;

    if (ctx == NULL || EVP_PKEY_keygen_init(ctx) <= 0 ||
        EVP_PKEY_keygen(ctx, &key) <= 0) {
        EVP_PKEY_free(key);
        key = NULL;
    }
    EVP_PKEY_CTX_free(ctx);
    return key;
}

static int derive_shared_secret(EVP_PKEY *local_private_key,
                                EVP_PKEY *pinned_peer_public_key,
                                uint8_t shared[SESSION_X25519_KEY_BYTES])
{
    static const uint8_t zero[SESSION_X25519_KEY_BYTES] = {0};
    EVP_PKEY_CTX *ctx = NULL;
    size_t shared_len = SESSION_X25519_KEY_BYTES;
    int ok = 0;

    if (local_private_key == NULL || pinned_peer_public_key == NULL ||
        EVP_PKEY_base_id(local_private_key) != EVP_PKEY_X25519 ||
        EVP_PKEY_base_id(pinned_peer_public_key) != EVP_PKEY_X25519)
        return 0;

    ctx = EVP_PKEY_CTX_new(local_private_key, NULL);
    if (ctx != NULL && EVP_PKEY_derive_init(ctx) > 0 &&
        EVP_PKEY_derive_set_peer(ctx, pinned_peer_public_key) > 0 &&
        EVP_PKEY_derive(ctx, shared, &shared_len) > 0 &&
        shared_len == SESSION_X25519_KEY_BYTES &&
        CRYPTO_memcmp(shared, zero, sizeof(zero)) != 0)
        ok = 1;

    EVP_PKEY_CTX_free(ctx);
    if (!ok)
        session_secure_clear(shared, SESSION_X25519_KEY_BYTES);
    return ok;
}

static int derive_wrap_key(const uint8_t shared[SESSION_X25519_KEY_BYTES],
                           const uint8_t salt[SESSION_HKDF_SALT_BYTES],
                           uint8_t key[SESSION_AES_KEY_BYTES])
{
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
    size_t key_len = SESSION_AES_KEY_BYTES;
    int ok = 0;

    if (ctx != NULL && EVP_PKEY_derive_init(ctx) > 0 &&
        EVP_PKEY_CTX_hkdf_mode(
            ctx, EVP_PKEY_HKDEF_MODE_EXTRACT_AND_EXPAND) > 0 &&
        EVP_PKEY_CTX_set_hkdf_md(ctx, EVP_sha256()) > 0 &&
        EVP_PKEY_CTX_set1_hkdf_salt(
            ctx, salt, SESSION_HKDF_SALT_BYTES) > 0 &&
        EVP_PKEY_CTX_set1_hkdf_key(
            ctx, shared, SESSION_X25519_KEY_BYTES) > 0 &&
        EVP_PKEY_CTX_add1_hkdf_info(
            ctx, hkdf_info, sizeof(hkdf_info) - 1) > 0 &&
        EVP_PKEY_derive(ctx, key, &key_len) > 0 &&
        key_len == SESSION_AES_KEY_BYTES)
        ok = 1;

    EVP_PKEY_CTX_free(ctx);
    if (!ok)
        session_secure_clear(key, SESSION_AES_KEY_BYTES);
    return ok;
}

static int gcm_encrypt(const uint8_t key[SESSION_AES_KEY_BYTES],
                       const uint8_t nonce[SESSION_GCM_NONCE_BYTES],
                       const uint8_t aad[SESSION_CAPSULE_HEADER_BYTES],
                       const uint8_t plain[SESSION_PLAIN_BYTES],
                       uint8_t cipher[SESSION_PLAIN_BYTES],
                       uint8_t tag[SESSION_GCM_TAG_BYTES])
{
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int length = 0;
    int total = 0;
    int ok = 0;

    if (ctx != NULL &&
        EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN,
                            SESSION_GCM_NONCE_BYTES, NULL) == 1 &&
        EVP_EncryptInit_ex(ctx, NULL, NULL, key, nonce) == 1 &&
        EVP_EncryptUpdate(ctx, NULL, &length, aad,
                          SESSION_CAPSULE_HEADER_BYTES) == 1 &&
        EVP_EncryptUpdate(ctx, cipher, &length, plain,
                          SESSION_PLAIN_BYTES) == 1) {
        total = length;
        if (EVP_EncryptFinal_ex(ctx, cipher + total, &length) == 1) {
            total += length;
            if (total == SESSION_PLAIN_BYTES &&
                EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG,
                                    SESSION_GCM_TAG_BYTES, tag) == 1)
                ok = 1;
        }
    }

    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

static int gcm_decrypt(const uint8_t key[SESSION_AES_KEY_BYTES],
                       const uint8_t nonce[SESSION_GCM_NONCE_BYTES],
                       const uint8_t aad[SESSION_CAPSULE_HEADER_BYTES],
                       const uint8_t cipher[SESSION_PLAIN_BYTES],
                       const uint8_t tag[SESSION_GCM_TAG_BYTES],
                       uint8_t plain[SESSION_PLAIN_BYTES])
{
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int length = 0;
    int total = 0;
    int ok = 0;

    if (ctx != NULL &&
        EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN,
                            SESSION_GCM_NONCE_BYTES, NULL) == 1 &&
        EVP_DecryptInit_ex(ctx, NULL, NULL, key, nonce) == 1 &&
        EVP_DecryptUpdate(ctx, NULL, &length, aad,
                          SESSION_CAPSULE_HEADER_BYTES) == 1 &&
        EVP_DecryptUpdate(ctx, plain, &length, cipher,
                          SESSION_PLAIN_BYTES) == 1) {
        total = length;
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG,
                                SESSION_GCM_TAG_BYTES, (void *)tag) == 1 &&
            EVP_DecryptFinal_ex(ctx, plain + total, &length) == 1) {
            total += length;
            ok = total == SESSION_PLAIN_BYTES;
        }
    }

    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        session_secure_clear(plain, SESSION_PLAIN_BYTES);
    return ok;
}

static int capsule_header_valid(const uint8_t *capsule)
{
    return CRYPTO_memcmp(capsule + CAPSULE_MAGIC_OFFSET, capsule_magic,
                         sizeof(capsule_magic)) == 0 &&
           capsule[CAPSULE_VERSION_OFFSET] == 1 &&
           capsule[CAPSULE_SUITE_OFFSET] == 1 &&
           capsule[CAPSULE_RESERVED_OFFSET] == 0 &&
           capsule[CAPSULE_RESERVED_OFFSET + 1] == 0;
}

int ecdh_session_encrypt(EVP_PKEY *local_private_key,
                         EVP_PKEY *pinned_peer_public_key,
                         const uint8_t *plain, size_t plain_len,
                         uint8_t **capsule, size_t *capsule_len)
{
    uint8_t shared[SESSION_X25519_KEY_BYTES] = {0};
    uint8_t key[SESSION_AES_KEY_BYTES] = {0};
    uint8_t *buffer = NULL;
    int ok = 0;

    if (plain == NULL || plain_len != SESSION_PLAIN_BYTES ||
        capsule == NULL || capsule_len == NULL)
        return 0;
    *capsule = NULL;
    *capsule_len = 0;

    buffer = calloc(1, SESSION_CAPSULE_BYTES);
    if (buffer == NULL)
        goto out;
    memcpy(buffer + CAPSULE_MAGIC_OFFSET, capsule_magic,
           sizeof(capsule_magic));
    buffer[CAPSULE_VERSION_OFFSET] = 1;
    buffer[CAPSULE_SUITE_OFFSET] = 1;
    if (RAND_bytes(buffer + SESSION_CAPSULE_SALT_OFFSET,
                   SESSION_HKDF_SALT_BYTES) != 1 ||
        RAND_bytes(buffer + SESSION_CAPSULE_NONCE_OFFSET,
                   SESSION_GCM_NONCE_BYTES) != 1 ||
        !derive_shared_secret(local_private_key, pinned_peer_public_key,
                              shared) ||
        !derive_wrap_key(shared, buffer + SESSION_CAPSULE_SALT_OFFSET, key) ||
        !gcm_encrypt(key, buffer + SESSION_CAPSULE_NONCE_OFFSET, buffer, plain,
                     buffer + SESSION_CAPSULE_CIPHER_OFFSET,
                     buffer + SESSION_CAPSULE_TAG_OFFSET))
        goto out;

    *capsule = buffer;
    *capsule_len = SESSION_CAPSULE_BYTES;
    buffer = NULL;
    ok = 1;
out:
    if (buffer != NULL) {
        session_secure_clear(buffer, SESSION_CAPSULE_BYTES);
        free(buffer);
    }
    session_secure_clear(shared, sizeof(shared));
    session_secure_clear(key, sizeof(key));
    return ok;
}

int ecdh_session_decrypt(EVP_PKEY *local_private_key,
                         EVP_PKEY *pinned_peer_public_key,
                         const uint8_t *capsule, size_t capsule_len,
                         uint8_t **plain, size_t *plain_len)
{
    uint8_t shared[SESSION_X25519_KEY_BYTES] = {0};
    uint8_t key[SESSION_AES_KEY_BYTES] = {0};
    uint8_t *buffer = NULL;
    int ok = 0;

    if (capsule == NULL || capsule_len != SESSION_CAPSULE_BYTES ||
        plain == NULL || plain_len == NULL)
        return 0;
    *plain = NULL;
    *plain_len = 0;

    if (!capsule_header_valid(capsule) ||
        !derive_shared_secret(local_private_key, pinned_peer_public_key,
                              shared) ||
        !derive_wrap_key(shared, capsule + SESSION_CAPSULE_SALT_OFFSET, key))
        goto out;
    buffer = malloc(SESSION_PLAIN_BYTES);
    if (buffer == NULL ||
        !gcm_decrypt(key, capsule + SESSION_CAPSULE_NONCE_OFFSET, capsule,
                     capsule + SESSION_CAPSULE_CIPHER_OFFSET,
                     capsule + SESSION_CAPSULE_TAG_OFFSET, buffer))
        goto out;

    *plain = buffer;
    *plain_len = SESSION_PLAIN_BYTES;
    buffer = NULL;
    ok = 1;
out:
    if (buffer != NULL) {
        session_secure_clear(buffer, SESSION_PLAIN_BYTES);
        free(buffer);
    }
    session_secure_clear(shared, sizeof(shared));
    session_secure_clear(key, sizeof(key));
    return ok;
}

int session_secret_encode(const struct session_secret *secret,
                          uint8_t out[SESSION_PLAIN_BYTES])
{
    if (secret == NULL || out == NULL)
        return 0;

    memcpy(out, secret_magic, sizeof(secret_magic));
    out[4] = 1;
    out[5] = out[6] = out[7] = 0;
    put_be32(out + 8, secret->session_id);
    put_be64(out + 12, secret->counter);
    memcpy(out + 20, secret->challenge, SESSION_CHALLENGE_BYTES);
    memcpy(out + 36, secret->aes_key, SESSION_AES_KEY_BYTES);
    return 1;
}

int session_secret_decode(const uint8_t in[SESSION_PLAIN_BYTES],
                          struct session_secret *secret)
{
    if (in == NULL || secret == NULL ||
        CRYPTO_memcmp(in, secret_magic, sizeof(secret_magic)) != 0 ||
        in[4] != 1 || in[5] != 0 || in[6] != 0 || in[7] != 0)
        return 0;

    secret->session_id = get_be32(in + 8);
    secret->counter = get_be64(in + 12);
    memcpy(secret->challenge, in + 20, SESSION_CHALLENGE_BYTES);
    memcpy(secret->aes_key, in + 36, SESSION_AES_KEY_BYTES);
    return 1;
}

int session_make_proof(const struct session_secret *secret,
                       enum session_proof_phase phase,
                       uint8_t out[SESSION_CONFIRM_BYTES])
{
    uint8_t message[sizeof(confirm_label) - 1 + 1 + 4 + 8 +
                    SESSION_CHALLENGE_BYTES];
    unsigned int output_len = 0;
    size_t offset = 0;

    if (secret == NULL || out == NULL ||
        (phase != SESSION_PROOF_READY && phase != SESSION_PROOF_COMMIT &&
         phase != SESSION_PROOF_DONE && phase != SESSION_PROOF_TERMINATE &&
         phase != SESSION_PROOF_TERMINATED))
        return 0;

    memcpy(message + offset, confirm_label, sizeof(confirm_label) - 1);
    offset += sizeof(confirm_label) - 1;
    message[offset++] = (uint8_t)phase;
    put_be32(message + offset, secret->session_id);
    offset += 4;
    put_be64(message + offset, secret->counter);
    offset += 8;
    memcpy(message + offset, secret->challenge, SESSION_CHALLENGE_BYTES);
    offset += SESSION_CHALLENGE_BYTES;

    return HMAC(EVP_sha256(), secret->aes_key, SESSION_AES_KEY_BYTES,
                message, offset, out, &output_len) != NULL &&
           output_len == SESSION_CONFIRM_BYTES;
}

int session_verify_proof(const struct session_secret *secret,
                         enum session_proof_phase phase,
                         const uint8_t in[SESSION_CONFIRM_BYTES])
{
    uint8_t expected[SESSION_CONFIRM_BYTES];
    int ok;

    if (in == NULL || !session_make_proof(secret, phase, expected))
        return 0;
    ok = CRYPTO_memcmp(expected, in, sizeof(expected)) == 0;
    session_secure_clear(expected, sizeof(expected));
    return ok;
}
