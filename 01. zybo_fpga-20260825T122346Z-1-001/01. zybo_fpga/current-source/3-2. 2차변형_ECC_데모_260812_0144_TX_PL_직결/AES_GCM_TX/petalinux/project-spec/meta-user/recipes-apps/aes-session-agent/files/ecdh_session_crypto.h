#ifndef ECDH_SESSION_CRYPTO_H
#define ECDH_SESSION_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#include <openssl/evp.h>

#define SESSION_AES_KEY_BYTES 32u
#define SESSION_CHALLENGE_BYTES 16u
#define SESSION_CONFIRM_BYTES 32u
#define SESSION_PLAIN_BYTES 68u

#define SESSION_X25519_KEY_BYTES 32u
#define SESSION_HKDF_SALT_BYTES 32u
#define SESSION_GCM_NONCE_BYTES 12u
#define SESSION_GCM_TAG_BYTES 16u
#define SESSION_CAPSULE_SALT_OFFSET 8u
#define SESSION_CAPSULE_NONCE_OFFSET \
    (SESSION_CAPSULE_SALT_OFFSET + SESSION_HKDF_SALT_BYTES)
#define SESSION_CAPSULE_HEADER_BYTES 52u
#define SESSION_CAPSULE_CIPHER_OFFSET SESSION_CAPSULE_HEADER_BYTES
#define SESSION_CAPSULE_TAG_OFFSET \
    (SESSION_CAPSULE_CIPHER_OFFSET + SESSION_PLAIN_BYTES)
#define SESSION_CAPSULE_BYTES \
    (SESSION_CAPSULE_TAG_OFFSET + SESSION_GCM_TAG_BYTES)
#define SESSION_WRAP_HKDF_INFO "ZYBO-AES-SESSION-WRAP-v1"

/* "ZEC1" | version | suite | reserved | salt | nonce is authenticated AAD. */

enum session_proof_phase {
    SESSION_PROOF_READY = 2,
    SESSION_PROOF_COMMIT = 3,
    SESSION_PROOF_DONE = 4,
    SESSION_PROOF_TERMINATE = 5,
    SESSION_PROOF_TERMINATED = 6
};

struct session_secret {
    uint32_t session_id;
    uint64_t counter;
    uint8_t challenge[SESSION_CHALLENGE_BYTES];
    uint8_t aes_key[SESSION_AES_KEY_BYTES];
};

EVP_PKEY *ecdh_session_generate_key(void);

int ecdh_session_encrypt(EVP_PKEY *local_private_key,
                         EVP_PKEY *pinned_peer_public_key,
                         const uint8_t *plain, size_t plain_len,
                         uint8_t **capsule, size_t *capsule_len);

int ecdh_session_decrypt(EVP_PKEY *local_private_key,
                         EVP_PKEY *pinned_peer_public_key,
                         const uint8_t *capsule, size_t capsule_len,
                         uint8_t **plain, size_t *plain_len);

int session_secret_encode(const struct session_secret *secret,
                          uint8_t out[SESSION_PLAIN_BYTES]);

int session_secret_decode(const uint8_t in[SESSION_PLAIN_BYTES],
                          struct session_secret *secret);

int session_make_proof(const struct session_secret *secret,
                       enum session_proof_phase phase,
                       uint8_t out[SESSION_CONFIRM_BYTES]);

int session_verify_proof(const struct session_secret *secret,
                         enum session_proof_phase phase,
                         const uint8_t in[SESSION_CONFIRM_BYTES]);

void session_secure_clear(void *ptr, size_t len);

#endif
