#include "ecdh_session_crypto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/rand.h>

static int fail(const char *message)
{
    fprintf(stderr, "FAIL: %s\n", message);
    return 1;
}

static EVP_PKEY *public_only(EVP_PKEY *key)
{
    uint8_t raw[SESSION_X25519_KEY_BYTES];
    size_t raw_len = sizeof(raw);

    if (EVP_PKEY_get_raw_public_key(key, raw, &raw_len) <= 0 ||
        raw_len != sizeof(raw))
        return NULL;
    return EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, raw, raw_len);
}

static int secret_equal(const struct session_secret *a,
                        const struct session_secret *b)
{
    return a->session_id == b->session_id && a->counter == b->counter &&
           CRYPTO_memcmp(a->challenge, b->challenge,
                         sizeof(a->challenge)) == 0 &&
           CRYPTO_memcmp(a->aes_key, b->aes_key, sizeof(a->aes_key)) == 0;
}

int main(void)
{
    EVP_PKEY *alice = NULL, *bob = NULL, *mallory = NULL;
    EVP_PKEY *alice_public = NULL, *bob_public = NULL, *mallory_public = NULL;
    struct session_secret source = {0}, recovered = {0};
    uint8_t encoded[SESSION_PLAIN_BYTES] = {0};
    uint8_t proof[SESSION_CONFIRM_BYTES] = {0};
    uint8_t tampered[SESSION_CAPSULE_BYTES];
    uint8_t *ab1 = NULL, *ab2 = NULL, *ba = NULL, *plain = NULL;
    size_t ab1_len = 0, ab2_len = 0, ba_len = 0, plain_len = 0;
    int result = 1;

    alice = ecdh_session_generate_key();
    bob = ecdh_session_generate_key();
    mallory = ecdh_session_generate_key();
    if (alice == NULL || bob == NULL || mallory == NULL ||
        (alice_public = public_only(alice)) == NULL ||
        (bob_public = public_only(bob)) == NULL ||
        (mallory_public = public_only(mallory)) == NULL)
        goto out;

    source.session_id = 0x26080901u;
    source.counter = UINT64_C(0x0102030405060708);
    if (RAND_bytes(source.challenge, sizeof(source.challenge)) != 1 ||
        RAND_bytes(source.aes_key, sizeof(source.aes_key)) != 1 ||
        !session_secret_encode(&source, encoded))
        goto out;

    if (!ecdh_session_encrypt(alice, bob_public, encoded, sizeof(encoded),
                              &ab1, &ab1_len) ||
        !ecdh_session_decrypt(bob, alice_public, ab1, ab1_len,
                              &plain, &plain_len) ||
        plain_len != sizeof(encoded) ||
        !session_secret_decode(plain, &recovered) ||
        !secret_equal(&source, &recovered))
        goto out;
    session_secure_clear(plain, plain_len);
    free(plain);
    plain = NULL;
    plain_len = 0;

    if (!ecdh_session_encrypt(bob, alice_public, encoded, sizeof(encoded),
                              &ba, &ba_len) ||
        !ecdh_session_decrypt(alice, bob_public, ba, ba_len,
                              &plain, &plain_len) ||
        plain_len != sizeof(encoded) ||
        CRYPTO_memcmp(plain, encoded, sizeof(encoded)) != 0)
        goto out;
    session_secure_clear(plain, plain_len);
    free(plain);
    plain = NULL;
    plain_len = 0;

    if (!ecdh_session_encrypt(alice, bob_public, encoded, sizeof(encoded),
                              &ab2, &ab2_len) ||
        ab1_len != SESSION_CAPSULE_BYTES || ab2_len != ab1_len ||
        CRYPTO_memcmp(ab1, ab2, ab1_len) == 0)
        goto out;

    memcpy(tampered, ab1, sizeof(tampered));
    tampered[SESSION_CAPSULE_SALT_OFFSET] ^= 0x80;
    if (ecdh_session_decrypt(bob, alice_public, tampered, sizeof(tampered),
                             &plain, &plain_len) ||
        ecdh_session_decrypt(bob, mallory_public, ab1, ab1_len,
                             &plain, &plain_len))
        goto out;

    if (!session_make_proof(&source, SESSION_PROOF_READY, proof) ||
        !session_verify_proof(&source, SESSION_PROOF_READY, proof) ||
        session_verify_proof(&source, SESSION_PROOF_COMMIT, proof) ||
        !session_make_proof(&source, SESSION_PROOF_TERMINATE, proof) ||
        !session_verify_proof(&source, SESSION_PROOF_TERMINATE, proof) ||
        session_verify_proof(&source, SESSION_PROOF_TERMINATED, proof))
        goto out;
    proof[0] ^= 1;
    if (session_verify_proof(&source, SESSION_PROOF_TERMINATE, proof))
        goto out;

    printf("PASS: bidirectional X25519 + HKDF-SHA256 + AES-256-GCM "
           "capsules, pinned-peer/tamper rejection, fresh wrapping, and "
           "phase-bound proofs\n");
    result = 0;
out:
    session_secure_clear(&source, sizeof(source));
    session_secure_clear(&recovered, sizeof(recovered));
    session_secure_clear(encoded, sizeof(encoded));
    session_secure_clear(proof, sizeof(proof));
    session_secure_clear(tampered, sizeof(tampered));
    if (plain != NULL) {
        session_secure_clear(plain, plain_len);
        free(plain);
    }
    if (ab1 != NULL) {
        session_secure_clear(ab1, ab1_len);
        free(ab1);
    }
    if (ab2 != NULL) {
        session_secure_clear(ab2, ab2_len);
        free(ab2);
    }
    if (ba != NULL) {
        session_secure_clear(ba, ba_len);
        free(ba);
    }
    EVP_PKEY_free(alice_public);
    EVP_PKEY_free(bob_public);
    EVP_PKEY_free(mallory_public);
    EVP_PKEY_free(alice);
    EVP_PKEY_free(bob);
    EVP_PKEY_free(mallory);
    if (result != 0)
        return fail("ECDH session crypto self-test");
    return 0;
}
