#define _GNU_SOURCE

#include "aes_session_regs.h"
#include "ecdh_session_crypto.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <openssl/crypto.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DISCOVERY_PORT 46099u
#define SESSION_PORT 46100u
#define MANAGEMENT_PORT 46101u
#define MANAGEMENT_MESSAGE_MAX 192u
#define MANAGEMENT_CACHE_SIZE 8u
#define CAPSULE_MAX 512u
#define CAPSULE_DIGEST_BYTES 32u
#define COUNTER_FLOOR_MAGIC_BYTES 8u
#define COUNTER_FLOOR_SESSION_OFFSET COUNTER_FLOOR_MAGIC_BYTES
#define COUNTER_FLOOR_REJECTED_OFFSET \
    (COUNTER_FLOOR_SESSION_OFFSET + 4u)
#define COUNTER_FLOOR_COMMITTED_OFFSET \
    (COUNTER_FLOOR_REJECTED_OFFSET + 8u)
#define COUNTER_FLOOR_DIGEST_OFFSET \
    (COUNTER_FLOOR_COMMITTED_OFFSET + 8u)
#define COUNTER_FLOOR_RESERVED_OFFSET \
    (COUNTER_FLOOR_DIGEST_OFFSET + CAPSULE_DIGEST_BYTES)
#define RX_STATE_MAGIC_V2 "AGS-RX-STATE-2"
#define RX_STATE_MAGIC "AGS-RX-STATE-3"
#define TX_ACTIVE_MAGIC_BYTES 8u
#define TX_ACTIVE_TERMINATION_BYTES 4u
#define TX_ACTIVE_DIGEST_BYTES 32u
#define TX_ACTIVE_SECRET_OFFSET TX_ACTIVE_MAGIC_BYTES
#define TX_ACTIVE_TERMINATION_OFFSET \
    (TX_ACTIVE_SECRET_OFFSET + SESSION_PLAIN_BYTES)
#define TX_ACTIVE_DIGEST_OFFSET \
    (TX_ACTIVE_TERMINATION_OFFSET + TX_ACTIVE_TERMINATION_BYTES)
#define TX_ACTIVE_RECORD_BYTES \
    (TX_ACTIVE_DIGEST_OFFSET + TX_ACTIVE_DIGEST_BYTES)
#define IO_TIMEOUT_SECONDS 5
#define STATUS_KEY_VALID (1u << 0)
#define STATUS_KEY_READY (1u << 1)
#define STATUS_REQUEST_PENDING (1u << 4)
#define STATUS_COMMIT_PENDING (1u << 6)
#define STATUS_CLEAR_PENDING (1u << 7)
#define STATUS_TERMINATION_ACTIVE (1u << 8)

enum wire_message_type {
    MESSAGE_SESSION_CAPSULE = 1,
    MESSAGE_READY = 2,
    MESSAGE_COMMIT = 3,
    MESSAGE_DONE = 4,
    MESSAGE_TERMINATE = 5,
    MESSAGE_TERMINATED = 6,
    MESSAGE_COUNTER_FLOOR = 7,
};

enum tx_exchange_result {
    TX_EXCHANGE_ERROR = -1,
    TX_EXCHANGE_COMMITTED = 0,
    TX_EXCHANGE_REMOTE_COMMITTED_CANCELED = 1,
    TX_EXCHANGE_COUNTER_RESYNC_REQUIRED = 2,
};

enum session_profile {
    SESSION_PROFILE_SECURE = 0,
    SESSION_PROFILE_WEAK = 1,
};

enum rx_state_phase {
    RX_STATE_NONE = 0,
    RX_STATE_PENDING,
    RX_STATE_ACTIVE,
    RX_STATE_TERMINATED,
};

static const uint8_t discovery_magic[8] = {'A','G','D','1',0,0,0,1};
static const uint8_t message_magic[4] = {'A','G','S','1'};
static const uint8_t tx_active_magic[TX_ACTIVE_MAGIC_BYTES] =
    {'A','G','S','T','X','A','2',0};
static const uint8_t counter_floor_magic[COUNTER_FLOOR_MAGIC_BYTES] =
    {'A','G','S','F','L','R','1',0};
static volatile sig_atomic_t stop_requested;

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

struct __attribute__((packed)) wire_header {
    uint8_t magic[4];
    uint8_t version;
    uint8_t type;
    uint16_t length_be;
};

static void put_be32(uint8_t *out, uint32_t value)
{
    out[0] = (uint8_t)(value >> 24);
    out[1] = (uint8_t)(value >> 16);
    out[2] = (uint8_t)(value >> 8);
    out[3] = (uint8_t)value;
}

static uint32_t get_be32(const uint8_t *in)
{
    return ((uint32_t)in[0] << 24) | ((uint32_t)in[1] << 16) |
           ((uint32_t)in[2] << 8) | (uint32_t)in[3];
}

static void put_be64(uint8_t *out, uint64_t value)
{
    unsigned int i;

    for (i = 0; i < 8u; ++i)
        out[i] = (uint8_t)(value >> (56u - i * 8u));
}

static uint64_t get_be64(const uint8_t *in)
{
    uint64_t value = 0u;
    unsigned int i;

    for (i = 0; i < 8u; ++i)
        value = (value << 8) | in[i];
    return value;
}

struct options {
    bool tx;
    bool no_hardware;
    bool once;
    const char *private_key_path;
    const char *peer_public_key_path;
    const char *interface;
    const char *peer;
    const char *counter_path;
    const char *active_state_path;
    const char *control_bind;
    const char *control_peer;
    unsigned int control_port;
};

struct management_command {
    enum session_profile profile;
    uint64_t request_id;
    unsigned int seed_bits;
    struct sockaddr_in source;
    socklen_t source_length;
};

struct management_reply {
    bool valid;
    enum session_profile profile;
    uint64_t request_id;
    unsigned int seed_bits;
    char text[MANAGEMENT_MESSAGE_MAX];
};

struct rx_commit_state {
    uint64_t counter;
    uint32_t session_id;
    uint8_t capsule_digest[CAPSULE_DIGEST_BYTES];
    uint8_t capsule[CAPSULE_MAX];
    size_t capsule_length;
    bool has_identity;
    bool has_capsule;
    bool terminated;
    enum rx_state_phase phase;
};

static void on_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static void sleep_ms(unsigned int milliseconds)
{
    struct timespec delay;

    delay.tv_sec = milliseconds / 1000u;
    delay.tv_nsec = (long)(milliseconds % 1000u) * 1000000L;
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR && !stop_requested)
        ;
}

static int set_socket_timeout(int fd)
{
    const struct timeval timeout = {IO_TIMEOUT_SECONDS, 0};
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                      sizeof(timeout)) == 0 &&
           setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                      sizeof(timeout)) == 0 ? 0 : -1;
}

static int bind_to_interface(int fd, const char *interface)
{
    if (interface == NULL || *interface == '\0')
        return 0;
    return setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, interface,
                      strlen(interface) + 1u);
}

static int write_all(int fd, const void *data, size_t length)
{
    const uint8_t *cursor = data;

    while (length != 0) {
        const ssize_t written = send(fd, cursor, length, MSG_NOSIGNAL);
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            return -1;
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return 0;
}

static int read_all(int fd, void *data, size_t length)
{
    uint8_t *cursor = data;

    while (length != 0) {
        const ssize_t received = recv(fd, cursor, length, 0);
        if (received < 0 && errno == EINTR)
            continue;
        if (received <= 0)
            return -1;
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return 0;
}

static int send_message(int fd, uint8_t type, const void *payload,
                        size_t payload_length)
{
    struct wire_header header;

    if (payload_length > UINT16_MAX)
        return -1;
    memcpy(header.magic, message_magic, sizeof(header.magic));
    header.version = 1;
    header.type = type;
    header.length_be = htons((uint16_t)payload_length);
    if (write_all(fd, &header, sizeof(header)) != 0)
        return -1;
    return write_all(fd, payload, payload_length);
}

static int receive_wire_header(int fd, struct wire_header *header)
{
    if (header == NULL || read_all(fd, header, sizeof(*header)) != 0 ||
        memcmp(header->magic, message_magic, sizeof(header->magic)) != 0 ||
        header->version != 1) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int receive_header(int fd, uint8_t expected_type, size_t expected_length)
{
    struct wire_header header;

    if (receive_wire_header(fd, &header) != 0 ||
        header.type != expected_type ||
        ntohs(header.length_be) != expected_length) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static EVP_PKEY *load_key(const char *path, bool private_key)
{
    BIO *bio = BIO_new_file(path, "r");
    EVP_PKEY *key = NULL;

    if (bio != NULL)
        key = private_key ? PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL) :
                            PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    BIO_free(bio);
    return key;
}

static int load_counter(const char *path, uint64_t *counter)
{
    FILE *file;
    unsigned long long value;

    *counter = 0;
    file = fopen(path, "r");
    if (file == NULL)
        return errno == ENOENT ? 0 : -1;
    if (fscanf(file, "%llu", &value) != 1) {
        fclose(file);
        errno = EINVAL;
        return -1;
    }
    fclose(file);
    *counter = (uint64_t)value;
    return 0;
}

static int store_counter(const char *path, uint64_t counter)
{
    char temporary[512];
    FILE *file;

    if (snprintf(temporary, sizeof(temporary), "%s.tmp", path) >=
        (int)sizeof(temporary)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    file = fopen(temporary, "w");
    if (file == NULL)
        return -1;
    if (fprintf(file, "%llu\n", (unsigned long long)counter) < 0 ||
        fflush(file) != 0 || fsync(fileno(file)) != 0 || fclose(file) != 0) {
        unlink(temporary);
        return -1;
    }
    return rename(temporary, path);
}

static int hex_nibble(int value)
{
    if (value >= '0' && value <= '9')
        return value - '0';
    if (value >= 'a' && value <= 'f')
        return value - 'a' + 10;
    if (value >= 'A' && value <= 'F')
        return value - 'A' + 10;
    return -1;
}

static const char *rx_state_phase_name(enum rx_state_phase phase)
{
    switch (phase) {
    case RX_STATE_PENDING:
        return "PENDING";
    case RX_STATE_ACTIVE:
        return "ACTIVE";
    case RX_STATE_TERMINATED:
        return "TERMINATED";
    default:
        return NULL;
    }
}

static enum rx_state_phase parse_rx_state_phase(const char *text)
{
    if (strcmp(text, "PENDING") == 0)
        return RX_STATE_PENDING;
    if (strcmp(text, "ACTIVE") == 0)
        return RX_STATE_ACTIVE;
    if (strcmp(text, "TERMINATED") == 0)
        return RX_STATE_TERMINATED;
    return RX_STATE_NONE;
}

static int load_rx_commit_state(const char *path,
                                struct rx_commit_state *state)
{
    char digest_hex[CAPSULE_DIGEST_BYTES * 2u + 1u] = {0};
    char capsule_hex[CAPSULE_MAX * 2u + 1u] = {0};
    unsigned long long counter;
    unsigned int session_id;
    unsigned int terminated;
    size_t capsule_length;
    char state_magic[32] = {0};
    char phase_text[16] = {0};
    char trailing;
    FILE *file;
    int fields;
    int extended_fields;
    size_t i;

    memset(state, 0, sizeof(*state));
    file = fopen(path, "r");
    if (file == NULL)
        return errno == ENOENT ? 0 : -1;
    fields = fscanf(file, "%llu %x %64s", &counter, &session_id, digest_hex);
    if (fields < 1) {
        fclose(file);
        errno = EINVAL;
        return -1;
    }
    state->counter = (uint64_t)counter;
    if (fields == 1) {
        fclose(file);
        return 0; /* Backward-compatible with the old counter-only file. */
    }
    if (fields != 3 || strlen(digest_hex) != CAPSULE_DIGEST_BYTES * 2u) {
        fclose(file);
        errno = EINVAL;
        return -1;
    }
    state->session_id = (uint32_t)session_id;
    for (i = 0; i < CAPSULE_DIGEST_BYTES; ++i) {
        const int high = hex_nibble((unsigned char)digest_hex[i * 2u]);
        const int low = hex_nibble((unsigned char)digest_hex[i * 2u + 1u]);
        if (high < 0 || low < 0) {
            fclose(file);
            errno = EINVAL;
            return -1;
        }
        state->capsule_digest[i] = (uint8_t)((high << 4) | low);
    }
    state->has_identity = true;
    state->phase = RX_STATE_ACTIVE;
    extended_fields = fscanf(file, "%31s %zu %1024s %u", state_magic,
                             &capsule_length, capsule_hex, &terminated);
    if (extended_fields == EOF)
        goto legacy_identity;
    if (extended_fields != 4 ||
        (strcmp(state_magic, RX_STATE_MAGIC) != 0 &&
         strcmp(state_magic, RX_STATE_MAGIC_V2) != 0) ||
        terminated > 1u || capsule_length == 0 ||
        capsule_length > CAPSULE_MAX ||
        strlen(capsule_hex) != capsule_length * 2u) {
        fclose(file);
        errno = EINVAL;
        return -1;
    }
    for (i = 0; i < capsule_length; ++i) {
        const int high = hex_nibble((unsigned char)capsule_hex[i * 2u]);
        const int low = hex_nibble((unsigned char)capsule_hex[i * 2u + 1u]);
        if (high < 0 || low < 0) {
            fclose(file);
            errno = EINVAL;
            return -1;
        }
        state->capsule[i] = (uint8_t)((high << 4) | low);
    }
    if (strcmp(state_magic, RX_STATE_MAGIC) == 0) {
        if (fscanf(file, "%15s", phase_text) != 1) {
            fclose(file);
            errno = EINVAL;
            return -1;
        }
        state->phase = parse_rx_state_phase(phase_text);
        if (state->phase == RX_STATE_NONE ||
            (terminated != 0) != (state->phase == RX_STATE_TERMINATED)) {
            fclose(file);
            errno = EINVAL;
            return -1;
        }
    } else {
        state->phase = terminated != 0 ? RX_STATE_TERMINATED : RX_STATE_ACTIVE;
    }
    if (fscanf(file, " %c", &trailing) == 1) {
        fclose(file);
        errno = EINVAL;
        return -1;
    }
    fclose(file);
    state->capsule_length = capsule_length;
    state->has_capsule = true;
    state->terminated = terminated != 0;
    return 0;

legacy_identity:
    fclose(file);
    return 0; /* Version 1 identity-only state. */
}

static int fsync_parent_directory(const char *path)
{
    char directory[512];
    char *separator;
    int fd;
    int result;
    int saved_errno;

    if (snprintf(directory, sizeof(directory), "%s", path) >=
        (int)sizeof(directory)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    separator = strrchr(directory, '/');
    if (separator == NULL) {
        memcpy(directory, ".", 2u);
    } else if (separator == directory) {
        separator[1] = '\0';
    } else {
        *separator = '\0';
    }
    fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    result = fsync(fd);
    saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return result;
}

static int file_write_all(int fd, const void *data, size_t length)
{
    const uint8_t *cursor = data;

    while (length != 0) {
        const ssize_t written = write(fd, cursor, length);

        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            return -1;
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return 0;
}

static int file_read_all(int fd, void *data, size_t length)
{
    uint8_t *cursor = data;

    while (length != 0) {
        const ssize_t received = read(fd, cursor, length);

        if (received < 0 && errno == EINTR)
            continue;
        if (received <= 0)
            return -1;
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return 0;
}

static int clear_tx_active_state(const char *path)
{
    uint8_t zeros[TX_ACTIVE_RECORD_BYTES] = {0};
    struct stat state;
    int fd = -1;
    int result = 0;
    int saved_errno = 0;

    if (path == NULL || *path == '\0')
        return 0;
    fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd >= 0) {
        if (fstat(fd, &state) == 0 && S_ISREG(state.st_mode) &&
            state.st_uid == geteuid() && (state.st_mode & 0077) == 0) {
            if (lseek(fd, 0, SEEK_SET) < 0 ||
                file_write_all(fd, zeros, sizeof(zeros)) != 0 ||
                fsync(fd) != 0) {
                result = -1;
                saved_errno = errno;
            }
        }
        close(fd);
    } else if (errno != ENOENT) {
        result = -1;
        saved_errno = errno;
    }
    if (unlink(path) != 0 && errno != ENOENT && result == 0) {
        result = -1;
        saved_errno = errno;
    }
    if (result == 0 && fsync_parent_directory(path) != 0 && errno != EINVAL &&
        errno != EROFS) {
        result = -1;
        saved_errno = errno;
    }
    session_secure_clear(zeros, sizeof(zeros));
    if (result != 0)
        errno = saved_errno;
    return result;
}

static int store_tx_active_state(const char *path,
                                 const struct session_secret *secret,
                                 uint32_t termination_count)
{
    uint8_t record[TX_ACTIVE_RECORD_BYTES] = {0};
    const uint32_t termination_be = htonl(termination_count);
    char temporary[512];
    unsigned int digest_length = 0;
    int fd = -1;
    int result = -1;
    int saved_errno = 0;

    if (path == NULL || *path == '\0')
        return 0;
    if (secret == NULL || secret->session_id == 0 ||
        snprintf(temporary, sizeof(temporary), "%s.tmp.XXXXXX", path) >=
            (int)sizeof(temporary)) {
        errno = secret == NULL || secret->session_id == 0 ? EINVAL :
                                                           ENAMETOOLONG;
        return -1;
    }
    memcpy(record, tx_active_magic, sizeof(tx_active_magic));
    memcpy(record + TX_ACTIVE_TERMINATION_OFFSET, &termination_be,
           sizeof(termination_be));
    if (!session_secret_encode(secret, record + TX_ACTIVE_SECRET_OFFSET) ||
        EVP_Digest(record, TX_ACTIVE_DIGEST_OFFSET,
                   record + TX_ACTIVE_DIGEST_OFFSET,
                   &digest_length, EVP_sha256(), NULL) != 1 ||
        digest_length != TX_ACTIVE_DIGEST_BYTES) {
        errno = EPROTO;
        goto out;
    }
    fd = mkstemp(temporary);
    if (fd < 0)
        goto out;
    if (fchmod(fd, 0600) != 0 ||
        file_write_all(fd, record, sizeof(record)) != 0 || fsync(fd) != 0)
        goto out;
    if (close(fd) != 0) {
        fd = -1;
        goto out;
    }
    fd = -1;
    if (rename(temporary, path) != 0 || fsync_parent_directory(path) != 0)
        goto out;
    result = 0;
out:
    saved_errno = errno;
    if (fd >= 0)
        close(fd);
    if (result != 0)
        unlink(temporary);
    session_secure_clear(record, sizeof(record));
    errno = saved_errno;
    return result;
}

static int tx_recovery_hardware_status(const struct options *options,
                                       struct aes_session_regs *regs,
                                       struct aes_session_status *status)
{
    if (!options->no_hardware)
        return aes_session_regs_read_status(regs, status);
#ifdef AES_SESSION_FAULT_TEST
    {
        const char *active_text = getenv("AES_SESSION_TEST_PL_ACTIVE_SESSION");
        const char *raw_text = getenv("AES_SESSION_TEST_PL_STATUS");
        const char *termination_text =
            getenv("AES_SESSION_TEST_PL_TERMINATION_COUNT");
        char *end = NULL;
        unsigned long active_value;
        unsigned long raw_value;
        unsigned long termination_value;

        if (active_text == NULL || *active_text == '\0') {
            errno = ENODEV;
            return -1;
        }
        errno = 0;
        active_value = strtoul(active_text, &end, 16);
        if (errno != 0 || end == active_text || *end != '\0' ||
            active_value > UINT32_MAX) {
            errno = EINVAL;
            return -1;
        }
        raw_text = raw_text != NULL ? raw_text : "3";
        end = NULL;
        errno = 0;
        raw_value = strtoul(raw_text, &end, 16);
        if (errno != 0 || end == raw_text || *end != '\0' ||
            raw_value > UINT32_MAX) {
            errno = EINVAL;
            return -1;
        }
        termination_text = termination_text != NULL ? termination_text : "0";
        end = NULL;
        errno = 0;
        termination_value = strtoul(termination_text, &end, 0);
        if (errno != 0 || end == termination_text || *end != '\0' ||
            termination_value > UINT32_MAX) {
            errno = EINVAL;
            return -1;
        }
        memset(status, 0, sizeof(*status));
        status->raw = (uint32_t)raw_value;
        status->active_session_id = (uint32_t)active_value;
        status->termination_count = (uint32_t)termination_value;
        status->termination_active =
            (uint8_t)((status->raw & STATUS_TERMINATION_ACTIVE) != 0);
        return 0;
    }
#else
    (void)regs;
    (void)status;
    errno = ENOTSUP;
    return -1;
#endif
}

static int load_tx_active_state(const struct options *options,
                                struct aes_session_regs *regs,
                                struct session_secret *secret,
                                bool *valid,
                                bool *termination_credential)
{
    uint8_t record[TX_ACTIVE_RECORD_BYTES] = {0};
    uint8_t digest[TX_ACTIVE_DIGEST_BYTES] = {0};
    struct session_secret recovered;
    struct aes_session_status hardware_status;
    struct stat state;
    uint32_t stored_termination_be = 0;
    uint32_t stored_termination_count;
    unsigned int digest_length = 0;
    bool accepted = false;
    int fd = -1;
    int result = 0;

    memset(&recovered, 0, sizeof(recovered));
    *valid = false;
    *termination_credential = false;
    if (options->active_state_path == NULL ||
        *options->active_state_path == '\0')
        goto out;
    fd = open(options->active_state_path,
              O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (errno == ENOENT)
            goto out;
        result = -1;
        goto out;
    }
    if (fstat(fd, &state) != 0) {
        result = -1;
        goto out;
    }
    if (!S_ISREG(state.st_mode) || state.st_uid != geteuid() ||
        (state.st_mode & 0077) != 0 ||
        state.st_size != (off_t)sizeof(record))
        goto discard;
    if (file_read_all(fd, record, sizeof(record)) != 0) {
        result = -1;
        goto out;
    }
    if (memcmp(record, tx_active_magic, sizeof(tx_active_magic)) != 0 ||
        EVP_Digest(record, TX_ACTIVE_DIGEST_OFFSET,
                   digest, &digest_length, EVP_sha256(), NULL) != 1 ||
        digest_length != sizeof(digest) ||
        CRYPTO_memcmp(digest, record + TX_ACTIVE_DIGEST_OFFSET,
                      sizeof(digest)) != 0 ||
        !session_secret_decode(record + TX_ACTIVE_SECRET_OFFSET, &recovered) ||
        recovered.session_id == 0)
        goto discard;
    memcpy(&stored_termination_be, record + TX_ACTIVE_TERMINATION_OFFSET,
           sizeof(stored_termination_be));
    stored_termination_count = ntohl(stored_termination_be);
    if (tx_recovery_hardware_status(options, regs, &hardware_status) != 0) {
        result = -1;
        goto out;
    }
    if ((hardware_status.raw & (STATUS_KEY_VALID | STATUS_KEY_READY)) ==
            (STATUS_KEY_VALID | STATUS_KEY_READY) &&
        hardware_status.active_session_id == recovered.session_id) {
        *termination_credential = false;
    } else if ((hardware_status.raw &
                (STATUS_KEY_VALID | STATUS_KEY_READY)) == 0 &&
               hardware_status.termination_count ==
                   stored_termination_count + 1u &&
               (hardware_status.termination_active ||
                (hardware_status.raw & STATUS_CLEAR_PENDING) != 0)) {
        /* Local PL has already erased this exact session after one BTN3
         * generation.  Retain the secret solely to authenticate TERMINATE to
         * RX; it must never be recommitted as an active key. */
        *termination_credential = true;
    } else {
        goto discard;
    }
    memcpy(secret, &recovered, sizeof(*secret));
    *valid = true;
    accepted = true;
    goto out;

discard:
    if (fd >= 0) {
        close(fd);
        fd = -1;
    }
    if (clear_tx_active_state(options->active_state_path) != 0)
        result = -1;
out:
    if (fd >= 0)
        close(fd);
    if (!accepted)
        session_secure_clear(secret, sizeof(*secret));
    session_secure_clear(&recovered, sizeof(recovered));
    session_secure_clear(record, sizeof(record));
    session_secure_clear(digest, sizeof(digest));
    return result;
}

static int store_rx_commit_state(const char *path,
                                 const struct rx_commit_state *state)
{
    static const char hex[] = "0123456789abcdef";
    char digest_hex[CAPSULE_DIGEST_BYTES * 2u + 1u];
    char capsule_hex[CAPSULE_MAX * 2u + 1u];
    char temporary[512];
    FILE *file;
    int fd;
    size_t i;
    const char *phase_name;

    phase_name = state != NULL ? rx_state_phase_name(state->phase) : NULL;
    if (state == NULL || !state->has_identity || !state->has_capsule ||
        state->capsule_length == 0 || state->capsule_length > CAPSULE_MAX ||
        phase_name == NULL ||
        state->terminated != (state->phase == RX_STATE_TERMINATED)) {
        errno = EINVAL;
        return -1;
    }
    if (snprintf(temporary, sizeof(temporary), "%s.tmp.XXXXXX", path) >=
        (int)sizeof(temporary)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    for (i = 0; i < CAPSULE_DIGEST_BYTES; ++i) {
        digest_hex[i * 2u] = hex[state->capsule_digest[i] >> 4];
        digest_hex[i * 2u + 1u] = hex[state->capsule_digest[i] & 0x0fu];
    }
    digest_hex[sizeof(digest_hex) - 1u] = '\0';
    for (i = 0; i < state->capsule_length; ++i) {
        capsule_hex[i * 2u] = hex[state->capsule[i] >> 4];
        capsule_hex[i * 2u + 1u] = hex[state->capsule[i] & 0x0fu];
    }
    capsule_hex[state->capsule_length * 2u] = '\0';
    fd = mkstemp(temporary);
    if (fd < 0)
        return -1;
    if (fchmod(fd, 0600) != 0) {
        close(fd);
        unlink(temporary);
        return -1;
    }
    file = fdopen(fd, "w");
    if (file == NULL) {
        close(fd);
        unlink(temporary);
        return -1;
    }
    if (fprintf(file, "%llu\n%08x\n%s\n%s\n%zu\n%s\n%u\n%s\n",
                (unsigned long long)state->counter, state->session_id,
                digest_hex, RX_STATE_MAGIC, state->capsule_length, capsule_hex,
                state->terminated ? 1u : 0u, phase_name) < 0 ||
        fflush(file) != 0 || fsync(fileno(file)) != 0) {
        const int saved_errno = errno;

        fclose(file);
        unlink(temporary);
        errno = saved_errno;
        return -1;
    }
    if (fclose(file) != 0) {
        unlink(temporary);
        return -1;
    }
    if (rename(temporary, path) != 0) {
        unlink(temporary);
        return -1;
    }
    return fsync_parent_directory(path);
}

static int open_discovery_receiver(const struct options *options)
{
    struct sockaddr_in address = {0};
    const struct timeval timeout = {1, 0};
    int one = 1;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);

    if (fd < 0 || bind_to_interface(fd, options->interface) != 0)
        goto fail;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout)) != 0)
        goto fail;
    address.sin_family = AF_INET;
    address.sin_port = htons(DISCOVERY_PORT);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0)
        goto fail;
    return fd;
fail:
    if (fd >= 0)
        close(fd);
    return -1;
}

static int probe_session_listener(const struct options *options,
                                  in_addr_t address)
{
    struct sockaddr_in target = {0};
    struct timeval timeout = {0, 20000};
    fd_set writable;
    socklen_t error_length;
    int socket_error = 0;
    int flags;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int result = -1;

    if (fd < 0 || bind_to_interface(fd, options->interface) != 0)
        goto out;
    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0)
        goto out;
    target.sin_family = AF_INET;
    target.sin_port = htons(SESSION_PORT);
    target.sin_addr.s_addr = address;
    if (connect(fd, (struct sockaddr *)&target, sizeof(target)) == 0) {
        result = 0;
        goto out;
    }
    if (errno != EINPROGRESS)
        goto out;
    FD_ZERO(&writable);
    FD_SET(fd, &writable);
    if (select(fd + 1, NULL, &writable, NULL, &timeout) <= 0 ||
        !FD_ISSET(fd, &writable))
        goto out;
    error_length = sizeof(socket_error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error,
                   &error_length) == 0 && socket_error == 0)
        result = 0;
out:
    if (fd >= 0)
        close(fd);
    return result;
}

static int discover_receiver_by_subnet(const struct options *options,
                                       struct sockaddr_in *peer)
{
    struct ifreq address_request = {0};
    struct ifreq mask_request = {0};
    struct in_addr candidate;
    struct in_addr local_address;
    struct in_addr netmask;
    uint32_t host;
    uint32_t local;
    uint32_t mask;
    uint32_t network;
    uint32_t broadcast;
    int fd = -1;

    if (options->interface == NULL || *options->interface == '\0' ||
        snprintf(address_request.ifr_name, sizeof(address_request.ifr_name),
                 "%s", options->interface) >=
            (int)sizeof(address_request.ifr_name) ||
        snprintf(mask_request.ifr_name, sizeof(mask_request.ifr_name), "%s",
                 options->interface) >= (int)sizeof(mask_request.ifr_name))
        return -1;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0 || bind_to_interface(fd, options->interface) != 0 ||
        ioctl(fd, SIOCGIFADDR, &address_request) != 0 ||
        ioctl(fd, SIOCGIFNETMASK, &mask_request) != 0)
        goto fail;
    local_address =
        ((const struct sockaddr_in *)&address_request.ifr_addr)->sin_addr;
    netmask = ((const struct sockaddr_in *)&mask_request.ifr_netmask)->sin_addr;
    close(fd);
    fd = -1;
    local = ntohl(local_address.s_addr);
    mask = ntohl(netmask.s_addr);
    network = local & mask;
    broadcast = network | ~mask;

    /* A Wi-Fi demo LAN is normally /24.  Avoid an unbounded scan if a site
     * supplies a much broader DHCP prefix: retain the current /24 while still
     * deriving it from the live interface rather than a fixed address. */
    if (broadcast - network > 1023u) {
        network = local & UINT32_C(0xffffff00);
        broadcast = network | UINT32_C(0x000000ff);
    }
    for (host = network + 1u; host < broadcast && !stop_requested; ++host) {
        char text[INET_ADDRSTRLEN];

        if (host == local)
            continue;
        candidate.s_addr = htonl(host);
        if (probe_session_listener(options, candidate.s_addr) != 0)
            continue;
        memset(peer, 0, sizeof(*peer));
        peer->sin_family = AF_INET;
        peer->sin_port = htons(SESSION_PORT);
        peer->sin_addr = candidate;
        fprintf(stderr, "RX discovery unicast fallback found %s on %s\n",
                inet_ntop(AF_INET, &candidate, text, sizeof(text)) != NULL ?
                    text : "unknown",
                options->interface);
        return 0;
    }
    return -1;
fail:
    if (fd >= 0)
        close(fd);
    return -1;
}

static int discover_receiver(const struct options *options,
                             struct sockaddr_in *peer)
{
    uint8_t packet[sizeof(discovery_magic)];
    socklen_t peer_length = sizeof(*peer);
    int fd;

    if (options->peer != NULL) {
        memset(peer, 0, sizeof(*peer));
        peer->sin_family = AF_INET;
        peer->sin_port = htons(SESSION_PORT);
        return inet_pton(AF_INET, options->peer, &peer->sin_addr) == 1 ? 0 : -1;
    }
    fd = open_discovery_receiver(options);
    if (fd < 0)
        return -1;
    fprintf(stderr, "waiting for RX discovery on %s\n",
            options->interface != NULL ? options->interface : "all interfaces");
    for (;;) {
        const ssize_t length = recvfrom(fd, packet, sizeof(packet), 0,
                                        (struct sockaddr *)peer, &peer_length);
        if (length == (ssize_t)sizeof(packet) &&
            memcmp(packet, discovery_magic, sizeof(packet)) == 0) {
            peer->sin_port = htons(SESSION_PORT);
            close(fd);
            return 0;
        }
        if (length < 0 && errno != EINTR && errno != EAGAIN &&
            errno != EWOULDBLOCK) {
            close(fd);
            return -1;
        }
        if (length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) &&
            discover_receiver_by_subnet(options, peer) == 0) {
            close(fd);
            return 0;
        }
        if (stop_requested) {
            close(fd);
            errno = EINTR;
            return -1;
        }
    }
}

static int open_tcp_listener(const struct options *options)
{
    struct sockaddr_in address = {0};
    int one = 1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0 || bind_to_interface(fd, options->interface) != 0)
        goto fail;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    address.sin_family = AF_INET;
    address.sin_port = htons(SESSION_PORT);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, 2) != 0 || fcntl(fd, F_SETFL, O_NONBLOCK) != 0)
        goto fail;
    return fd;
fail:
    if (fd >= 0)
        close(fd);
    return -1;
}

static int open_announcer(const struct options *options)
{
    int one = 1;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);

    if (fd < 0 || bind_to_interface(fd, options->interface) != 0 ||
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one)) != 0) {
        if (fd >= 0)
            close(fd);
        return -1;
    }
    return fd;
}

static in_addr_t interface_broadcast(int fd, const char *interface)
{
    struct ifreq request = {0};

    if (interface == NULL || *interface == '\0')
        return htonl(INADDR_BROADCAST);
    if (snprintf(request.ifr_name, sizeof(request.ifr_name), "%s", interface) >=
        (int)sizeof(request.ifr_name) ||
        ioctl(fd, SIOCGIFBRDADDR, &request) != 0)
        return htonl(INADDR_BROADCAST);
    return ((const struct sockaddr_in *)&request.ifr_broadaddr)->sin_addr.s_addr;
}

static void announce_receiver(int fd, const struct options *options)
{
    struct sockaddr_in target = {0};

    target.sin_family = AF_INET;
    target.sin_port = htons(DISCOVERY_PORT);
    /* Some access points do not forward the limited broadcast address.
     * Announce to the DHCP interface's directed broadcast instead. */
    target.sin_addr.s_addr = interface_broadcast(fd, options->interface);
    (void)sendto(fd, discovery_magic, sizeof(discovery_magic), 0,
                 (struct sockaddr *)&target, sizeof(target));
}

static int request_secure_session_recovery(int fd,
                                           const struct options *options,
                                           uint64_t request_id)
{
    struct sockaddr_in target = {0};
    struct ifreq address_request = {0};
    struct ifreq netmask_request = {0};
    struct in_addr local_address;
    struct in_addr netmask;
    uint32_t local;
    uint32_t mask;
    uint32_t network;
    uint32_t broadcast;
    uint32_t host;
    char message[80];
    int length;
    int sent = 0;

    if (request_id == 0u)
        return -1;
    length = snprintf(message, sizeof(message),
                      "CREATE_SECURE_SESSION %llu",
                      (unsigned long long)request_id);
    if (length <= 0 || (size_t)length >= sizeof(message))
        return -1;
    target.sin_family = AF_INET;
    target.sin_port = htons((uint16_t)options->control_port);
    /* Session recovery is part of key exchange and therefore stays on the USB
     * Wi-Fi interface.  Never reuse a peer learned from the wired video path. */
    target.sin_addr.s_addr = interface_broadcast(fd, options->interface);
    if (sendto(fd, message, (size_t)length, MSG_NOSIGNAL,
               (struct sockaddr *)&target, sizeof(target)) ==
        (ssize_t)length)
        sent = 1;

    /* Enterprise and guest Wi-Fi commonly suppress client-to-client
     * broadcasts even though unicast remains available.  Initial TX->RX
     * discovery already has a subnet-derived unicast fallback; give RX-only
     * reboot recovery the same property without baking in either board's
     * DHCP address.  The scan is bounded to at most the live /24 when a site
     * supplies a broader prefix, and it stops as soon as RX accepts a fresh
     * authenticated session. */
    if (options->interface == NULL || *options->interface == '\0' ||
        snprintf(address_request.ifr_name,
                 sizeof(address_request.ifr_name), "%s",
                 options->interface) >=
            (int)sizeof(address_request.ifr_name) ||
        snprintf(netmask_request.ifr_name,
                 sizeof(netmask_request.ifr_name), "%s",
                 options->interface) >=
            (int)sizeof(netmask_request.ifr_name) ||
        ioctl(fd, SIOCGIFADDR, &address_request) != 0 ||
        ioctl(fd, SIOCGIFNETMASK, &netmask_request) != 0)
        return sent ? 0 : -1;

    local_address =
        ((const struct sockaddr_in *)&address_request.ifr_addr)->sin_addr;
    netmask =
        ((const struct sockaddr_in *)&netmask_request.ifr_netmask)->sin_addr;
    local = ntohl(local_address.s_addr);
    mask = ntohl(netmask.s_addr);
    network = local & mask;
    broadcast = network | ~mask;
    if (broadcast - network > 1023u) {
        network = local & UINT32_C(0xffffff00);
        broadcast = network | UINT32_C(0x000000ff);
    }

    for (host = network + 1u; host < broadcast; ++host) {
        if (host == local)
            continue;
        target.sin_addr.s_addr = htonl(host);
        if (sendto(fd, message, (size_t)length, MSG_NOSIGNAL,
                   (struct sockaddr *)&target, sizeof(target)) ==
            (ssize_t)length)
            sent = 1;
    }
    return sent ? 0 : -1;
}

static int connect_receiver(const struct options *options, int *socket_out)
{
    struct sockaddr_in peer;
    int fd;

    if (discover_receiver(options, &peer) != 0)
        return -1;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0 || bind_to_interface(fd, options->interface) != 0 ||
        set_socket_timeout(fd) != 0 ||
        connect(fd, (struct sockaddr *)&peer, sizeof(peer)) != 0) {
        if (fd >= 0)
            close(fd);
        return -1;
    }
    *socket_out = fd;
    return 0;
}

static int derive_weak_key(uint32_t seed,
                           uint8_t key[SESSION_AES_KEY_BYTES])
{
    static const uint8_t weak_label[] = "ZYBO-SEED-v1";
    uint8_t material[sizeof(weak_label) - 1u + sizeof(uint32_t)];
    uint32_t seed_be = htonl(seed);
    unsigned int digest_length = 0;
    int result;

    memcpy(material, weak_label, sizeof(weak_label) - 1u);
    memcpy(material + sizeof(weak_label) - 1u, &seed_be, sizeof(seed_be));
    result = EVP_Digest(material, sizeof(material), key, &digest_length,
                        EVP_sha256(), NULL) == 1 &&
             digest_length == SESSION_AES_KEY_BYTES ? 0 : -1;
    session_secure_clear(material, sizeof(material));
    seed_be = 0;
    return result;
}

#ifdef AES_SESSION_FAULT_TEST
static int weak_key_selftest(void)
{
    static const uint8_t expected[SESSION_AES_KEY_BYTES] = {
        0xf7, 0x1f, 0x48, 0x68, 0x43, 0xa2, 0x59, 0x52,
        0x81, 0xee, 0xf2, 0x02, 0xc9, 0x9d, 0x38, 0x19,
        0xa6, 0xab, 0xa1, 0x99, 0x4e, 0x13, 0x6f, 0x50,
        0x41, 0x21, 0x65, 0x29, 0xf4, 0x28, 0xd9, 0xc4
    };
    uint8_t key[SESSION_AES_KEY_BYTES] = {0};
    int result = derive_weak_key(UINT32_C(0x12345678), key) == 0 &&
                 CRYPTO_memcmp(key, expected, sizeof(key)) == 0 ? 0 : -1;

    session_secure_clear(key, sizeof(key));
    if (result == 0)
        fprintf(stderr, "PASS: exact ZYBO-SEED-v1 weak-key derivation\n");
    return result;
}
#endif

static int create_secret(struct session_secret *secret, uint64_t counter,
                         enum session_profile profile,
                         unsigned int seed_bits)
{
    uint32_t session_id;

    memset(secret, 0, sizeof(*secret));
    /* OpenSSL seeds its DRBG from the Linux kernel entropy source.  Refuse to
     * create a session until that source is ready, and use the private DRBG
     * for every value whose secrecy matters.  The explicit strength request
     * makes a successful AES-key call require 256-bit security strength. */
    if (RAND_status() != 1 ||
        RAND_bytes((uint8_t *)&session_id, sizeof(session_id)) != 1 ||
        RAND_priv_bytes_ex(NULL, secret->challenge,
                           sizeof(secret->challenge), 128) != 1)
        return -1;
    if (profile == SESSION_PROFILE_SECURE) {
        if (RAND_priv_bytes_ex(NULL, secret->aes_key,
                               sizeof(secret->aes_key), 256) != 1)
            return -1;
    } else {
        uint32_t seed;

        if (seed_bits == 0u || seed_bits > 32u ||
            RAND_priv_bytes((uint8_t *)&seed, sizeof(seed)) != 1)
            return -1;
        if (seed_bits < 32u)
            seed &= (UINT32_C(1) << seed_bits) - 1u;
        if (derive_weak_key(seed, secret->aes_key) != 0) {
            seed = 0;
            return -1;
        }
        seed = 0;
    }
    secret->session_id = session_id != 0 ? session_id : 1;
    secret->counter = counter;
    return 0;
}

static int capsule_sha256(const uint8_t *capsule, size_t capsule_length,
                          uint8_t digest[CAPSULE_DIGEST_BYTES])
{
    unsigned int digest_length = 0;

    return capsule != NULL && capsule_length != 0 &&
           EVP_Digest(capsule, capsule_length, digest, &digest_length,
                      EVP_sha256(), NULL) == 1 &&
           digest_length == CAPSULE_DIGEST_BYTES;
}

static void encode_counter_floor_plain(
    uint8_t plain[SESSION_PLAIN_BYTES], const struct session_secret *rejected,
    uint64_t committed_counter,
    const uint8_t capsule_digest[CAPSULE_DIGEST_BYTES])
{
    memset(plain, 0, SESSION_PLAIN_BYTES);
    memcpy(plain, counter_floor_magic, sizeof(counter_floor_magic));
    put_be32(plain + COUNTER_FLOOR_SESSION_OFFSET, rejected->session_id);
    put_be64(plain + COUNTER_FLOOR_REJECTED_OFFSET, rejected->counter);
    put_be64(plain + COUNTER_FLOOR_COMMITTED_OFFSET, committed_counter);
    memcpy(plain + COUNTER_FLOOR_DIGEST_OFFSET, capsule_digest,
           CAPSULE_DIGEST_BYTES);
}

static int send_counter_floor(
    int fd, EVP_PKEY *local_private_key, EVP_PKEY *pinned_peer_public_key,
    const struct session_secret *rejected, uint64_t committed_counter,
    const uint8_t capsule_digest[CAPSULE_DIGEST_BYTES])
{
    uint8_t plain[SESSION_PLAIN_BYTES] = {0};
    uint8_t *capsule = NULL;
    size_t capsule_length = 0;
    int result = -1;

    if (rejected == NULL || capsule_digest == NULL ||
        committed_counter < rejected->counter) {
        errno = EINVAL;
        return -1;
    }
    encode_counter_floor_plain(plain, rejected, committed_counter,
                               capsule_digest);
    if (ecdh_session_encrypt(local_private_key, pinned_peer_public_key,
                             plain, sizeof(plain), &capsule,
                             &capsule_length) &&
        capsule_length <= CAPSULE_MAX &&
        send_message(fd, MESSAGE_COUNTER_FLOOR, capsule, capsule_length) == 0)
        result = 0;
    if (capsule != NULL) {
        session_secure_clear(capsule, capsule_length);
        free(capsule);
    }
    session_secure_clear(plain, sizeof(plain));
    return result;
}

static int receive_counter_floor(
    int fd, size_t capsule_length, EVP_PKEY *local_private_key,
    EVP_PKEY *pinned_peer_public_key, const struct session_secret *rejected,
    const uint8_t capsule_digest[CAPSULE_DIGEST_BYTES], uint64_t *floor_out)
{
    uint8_t capsule[CAPSULE_MAX] = {0};
    uint8_t *plain = NULL;
    size_t plain_length = 0;
    uint64_t rejected_counter;
    uint64_t committed_counter;
    uint32_t rejected_session;
    size_t i;
    int result = -1;

    if (capsule_length == 0 || capsule_length > sizeof(capsule) ||
        rejected == NULL || capsule_digest == NULL || floor_out == NULL ||
        read_all(fd, capsule, capsule_length) != 0 ||
        !ecdh_session_decrypt(local_private_key, pinned_peer_public_key,
                              capsule, capsule_length,
                              &plain, &plain_length) ||
        plain_length != SESSION_PLAIN_BYTES ||
        CRYPTO_memcmp(plain, counter_floor_magic,
                      sizeof(counter_floor_magic)) != 0)
        goto out;
    rejected_session = get_be32(plain + COUNTER_FLOOR_SESSION_OFFSET);
    rejected_counter = get_be64(plain + COUNTER_FLOOR_REJECTED_OFFSET);
    committed_counter = get_be64(plain + COUNTER_FLOOR_COMMITTED_OFFSET);
    if (rejected_session != rejected->session_id ||
        rejected_counter != rejected->counter ||
        committed_counter < rejected_counter ||
        committed_counter == UINT64_MAX ||
        CRYPTO_memcmp(plain + COUNTER_FLOOR_DIGEST_OFFSET,
                      capsule_digest, CAPSULE_DIGEST_BYTES) != 0)
        goto out;
    for (i = COUNTER_FLOOR_RESERVED_OFFSET; i < SESSION_PLAIN_BYTES; ++i) {
        if (plain[i] != 0)
            goto out;
    }
    *floor_out = committed_counter;
    result = 0;
out:
    if (result != 0)
        errno = EPROTO;
    if (plain != NULL) {
        session_secure_clear(plain, plain_length);
        free(plain);
    }
    session_secure_clear(capsule, sizeof(capsule));
    return result;
}

static int activate_rx_pending_state(const struct options *options,
                                     struct aes_session_regs *regs,
                                     struct rx_commit_state *committed,
                                     const struct session_secret *secret)
{
    struct aes_session_status hardware_status;

    if (committed == NULL || secret == NULL ||
        committed->phase != RX_STATE_PENDING || committed->terminated ||
        committed->counter != secret->counter ||
        committed->session_id != secret->session_id) {
        errno = EINVAL;
        return -1;
    }
    if (!options->no_hardware) {
        const uint32_t ready_mask = STATUS_KEY_VALID | STATUS_KEY_READY;

        if (aes_session_regs_read_status(regs, &hardware_status) != 0)
            return -1;
        if ((hardware_status.raw & ready_mask) != ready_mask ||
            hardware_status.active_session_id != secret->session_id) {
            /* PENDING is a write-ahead record created only after a valid
             * COMMIT proof.  Reapplying it is therefore safe and closes the
             * crash window between PL commit and durable ACTIVE state. */
            if (aes_session_regs_commit(regs, secret->session_id,
                                        secret->aes_key, 2000) != 0)
                return -1;
        }
    }
#ifdef AES_SESSION_FAULT_TEST
    {
        const char *marker = getenv("AES_SESSION_EXIT_AFTER_PL_COMMIT_ONCE");

        if (marker != NULL && *marker != '\0') {
            const int marker_fd =
                open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);

            if (marker_fd >= 0) {
                close(marker_fd);
                stop_requested = 1;
                errno = ECONNRESET;
                return -1;
            }
            if (errno != EEXIST)
                return -1;
        }
    }
#endif
    committed->phase = RX_STATE_ACTIVE;
    committed->terminated = false;
    return store_rx_commit_state(options->counter_path, committed);
}

static int recover_rx_active_secret(const struct options *options,
                                    EVP_PKEY *local_private_key,
                                    EVP_PKEY *pinned_peer_public_key,
                                    struct aes_session_regs *regs,
                                    struct session_secret *active_secret,
                                    bool *active_secret_valid,
                                    bool *terminated)
{
    struct rx_commit_state committed;
    struct session_secret recovered;
    struct aes_session_status hardware_status;
    uint8_t digest[CAPSULE_DIGEST_BYTES] = {0};
    uint8_t *plain = NULL;
    size_t plain_length = 0;
    int result = -1;

    memset(&recovered, 0, sizeof(recovered));
    *active_secret_valid = false;
    *terminated = false;
    if (load_rx_commit_state(options->counter_path, &committed) != 0)
        goto out;
    if (!committed.has_identity || !committed.has_capsule) {
        result = 0; /* Legacy state cannot reconstruct a volatile secret. */
        goto out;
    }
    if (!capsule_sha256(committed.capsule, committed.capsule_length, digest) ||
        CRYPTO_memcmp(digest, committed.capsule_digest, sizeof(digest)) != 0 ||
        !ecdh_session_decrypt(local_private_key, pinned_peer_public_key,
                              committed.capsule, committed.capsule_length,
                              &plain, &plain_length) ||
        plain_length != SESSION_PLAIN_BYTES ||
        !session_secret_decode(plain, &recovered) ||
        recovered.counter != committed.counter ||
        recovered.session_id != committed.session_id) {
        errno = EPROTO;
        goto out;
    }

    if (committed.phase == RX_STATE_PENDING &&
        activate_rx_pending_state(options, regs, &committed, &recovered) != 0)
        goto out;
    if (committed.phase != RX_STATE_ACTIVE &&
        committed.phase != RX_STATE_TERMINATED) {
        errno = EPROTO;
        goto out;
    }

    if (!options->no_hardware) {
        const uint32_t ready_mask = STATUS_KEY_VALID | STATUS_KEY_READY;

        if (aes_session_regs_read_status(regs, &hardware_status) != 0)
            goto out;
        if (committed.phase == RX_STATE_TERMINATED) {
            if ((hardware_status.raw & STATUS_KEY_VALID) != 0) {
                if (hardware_status.active_session_id != recovered.session_id ||
                    aes_session_regs_clear(regs, 2000) != 0)
                    goto out;
            }
        } else if ((hardware_status.raw & ready_mask) != ready_mask ||
                   hardware_status.active_session_id != recovered.session_id) {
            /* A board reset clears the volatile PL key while the authenticated
             * ACTIVE capsule remains on the SD card.  Re-decrypt that exact
             * capsule and restore the same key so an RX-only reboot does not
             * require a TX reboot or a physical session-control action.  A
             * different valid PL session is never overwritten silently. */
            if ((hardware_status.raw & STATUS_KEY_VALID) != 0) {
                errno = EPROTO;
                goto out;
            }
            if (aes_session_regs_commit(regs, recovered.session_id,
                                        recovered.aes_key, 2000) != 0)
                goto out;
            fprintf(stderr,
                    "RX restored active session %08x into PL after reset\n",
                    recovered.session_id);
        }
    }

    memcpy(active_secret, &recovered, sizeof(*active_secret));
    *active_secret_valid = true;
    *terminated = committed.phase == RX_STATE_TERMINATED;
    fprintf(stderr, "RX recovered session %08x counter %llu (%s)\n",
            recovered.session_id, (unsigned long long)recovered.counter,
            committed.phase == RX_STATE_TERMINATED ? "terminated" : "active");
    result = 0;
out:
    if (plain != NULL) {
        session_secure_clear(plain, plain_length);
        free(plain);
    }
    session_secure_clear(digest, sizeof(digest));
    session_secure_clear(&recovered, sizeof(recovered));
    return result;
}

static int tx_exchange(const struct options *options,
                       EVP_PKEY *local_private_key,
                       EVP_PKEY *pinned_peer_public_key,
                       enum session_profile profile,
                       unsigned int seed_bits,
                       struct aes_session_regs *regs,
                       uint32_t termination_baseline,
                       uint32_t *termination_observed_out,
                       struct session_secret *active_secret_out)
{
    struct session_secret secret;
    uint8_t plain[SESSION_PLAIN_BYTES] = {0};
    uint8_t confirmation[SESSION_CONFIRM_BYTES] = {0};
    uint8_t done_confirmation[SESSION_CONFIRM_BYTES] = {0};
    uint8_t capsule_digest[CAPSULE_DIGEST_BYTES] = {0};
    uint8_t *capsule = NULL;
    size_t capsule_length = 0;
    uint64_t counter;
    uint32_t termination_observed = termination_baseline;
    bool commit_may_have_reached_rx = false;
    int result = TX_EXCHANGE_ERROR;

    memset(&secret, 0, sizeof(secret));
    if (load_counter(options->counter_path, &counter) != 0 ||
        counter == UINT64_MAX ||
        create_secret(&secret, counter + 1u, profile, seed_bits) != 0 ||
        /* Reserve once per management request.  The same secret and exact
         * ECDH capsule are reused until DONE arrives, allowing RX to answer
         * an already-committed duplicate idempotently after link recovery. */
        store_counter(options->counter_path, secret.counter) != 0 ||
        !session_secret_encode(&secret, plain) ||
        !ecdh_session_encrypt(local_private_key, pinned_peer_public_key,
                              plain, sizeof(plain),
                              &capsule, &capsule_length) ||
        capsule_length > CAPSULE_MAX ||
        !capsule_sha256(capsule, capsule_length, capsule_digest))
        goto out;

    while (!stop_requested) {
        int fd = -1;
        struct aes_session_status hardware_status;
        struct wire_header response_header;
        bool canceled_after_done = false;

        memset(confirmation, 0, sizeof(confirmation));
        memset(done_confirmation, 0, sizeof(done_confirmation));
        if (!options->no_hardware) {
            if (aes_session_regs_read_status(regs, &hardware_status) != 0)
                goto retry;
            termination_observed = hardware_status.termination_count;
            if ((hardware_status.termination_active ||
                 termination_observed != termination_baseline) &&
                !commit_may_have_reached_rx) {
                errno = ECANCELED;
                break;
            }
        }
        if (connect_receiver(options, &fd) != 0)
            goto retry;

        /* A connect or READY wait can take seconds.  Recheck BTN3 immediately
         * before publishing the candidate capsule while it is still certain
         * that RX has not been asked to commit this secret.  Once COMMIT has
         * been attempted, finish the same-capsule handshake even if BTN3 is
         * held so both sides first converge on a known secret to terminate. */
        if (!options->no_hardware && !commit_may_have_reached_rx) {
            if (aes_session_regs_read_status(regs, &hardware_status) != 0)
                goto retry;
            termination_observed = hardware_status.termination_count;
            if (hardware_status.termination_active ||
                termination_observed != termination_baseline) {
                errno = ECANCELED;
                close(fd);
                break;
            }
        }
        if (send_message(fd, MESSAGE_SESSION_CAPSULE,
                         capsule, capsule_length) != 0 ||
            receive_wire_header(fd, &response_header) != 0)
            goto retry;
        if (response_header.type == MESSAGE_COUNTER_FLOOR) {
            uint64_t counter_floor = 0u;

            if (receive_counter_floor(
                    fd, ntohs(response_header.length_be), local_private_key,
                    pinned_peer_public_key, &secret, capsule_digest,
                    &counter_floor) != 0 ||
                store_counter(options->counter_path, counter_floor) != 0)
                goto retry;
            fprintf(stderr,
                    "TX accepted authenticated RX counter floor %llu; "
                    "creating a fresh session\n",
                    (unsigned long long)counter_floor);
            result = TX_EXCHANGE_COUNTER_RESYNC_REQUIRED;
            close(fd);
            break;
        }
        if (response_header.type != MESSAGE_READY ||
            ntohs(response_header.length_be) != sizeof(confirmation) ||
            read_all(fd, confirmation, sizeof(confirmation)) != 0 ||
            !session_verify_proof(&secret, SESSION_PROOF_READY, confirmation)) {
            errno = EPROTO;
            goto retry;
        }

        /* This is the last cancellation point at which RX is guaranteed to
         * still have the previous active key. */
        if (!options->no_hardware && !commit_may_have_reached_rx) {
            if (aes_session_regs_read_status(regs, &hardware_status) != 0)
                goto retry;
            termination_observed = hardware_status.termination_count;
            if (hardware_status.termination_active ||
                termination_observed != termination_baseline) {
                errno = ECANCELED;
                close(fd);
                break;
            }
        }
        if (!session_make_proof(&secret, SESSION_PROOF_COMMIT, confirmation)) {
            errno = EPROTO;
            goto retry;
        }

        /* Treat even a failed COMMIT write as potentially delivered.  From
         * this point a BTN3 cancellation must authenticate TERMINATE with B,
         * not with the previous local active secret A.  Retrying the exact
         * capsule makes RX's duplicate path converge on B before termination. */
        commit_may_have_reached_rx = true;
        if (send_message(fd, MESSAGE_COMMIT,
                         confirmation, sizeof(confirmation)) != 0 ||
            receive_header(fd, MESSAGE_DONE,
                           sizeof(done_confirmation)) != 0 ||
            read_all(fd, done_confirmation, sizeof(done_confirmation)) != 0 ||
            !session_verify_proof(&secret, SESSION_PROOF_DONE,
                                  done_confirmation))
            goto retry;

#ifdef AES_SESSION_FAULT_TEST
        if (options->no_hardware &&
            getenv("AES_SESSION_CANCEL_AFTER_DONE_ONCE") != NULL)
            canceled_after_done = true;
        if (options->no_hardware &&
            getenv("AES_SESSION_PRESS_RELEASE_AFTER_COMMIT_ONCE") != NULL) {
            termination_observed = termination_baseline + 1u;
            canceled_after_done = true;
        }
#endif
        if (!options->no_hardware) {
            if (aes_session_regs_read_status(regs, &hardware_status) != 0)
                goto retry;
            termination_observed = hardware_status.termination_count;
            canceled_after_done = hardware_status.termination_active ||
                                  termination_observed != termination_baseline;
        }
        if (canceled_after_done) {
            if (active_secret_out != NULL) {
                session_secure_clear(active_secret_out,
                                     sizeof(*active_secret_out));
                memcpy(active_secret_out, &secret, sizeof(*active_secret_out));
            }
            fprintf(stderr,
                    "TX session %08x remote DONE received; local commit "
                    "canceled, terminating candidate\n",
                    secret.session_id);
            result = TX_EXCHANGE_REMOTE_COMMITTED_CANCELED;
            close(fd);
            break;
        }

        if (!options->no_hardware &&
            aes_session_regs_commit(regs, secret.session_id, secret.aes_key,
                                    2000) != 0)
            goto retry;
        if (active_secret_out != NULL) {
            session_secure_clear(active_secret_out,
                                 sizeof(*active_secret_out));
            memcpy(active_secret_out, &secret, sizeof(*active_secret_out));
        }
        fprintf(stderr,
                "TX session %08x counter %llu committed and confirmed\n",
                secret.session_id, (unsigned long long)secret.counter);
        result = TX_EXCHANGE_COMMITTED;
        close(fd);
        break;

retry:
        perror("TX session exchange; retaining pending key and retrying");
        if (fd >= 0)
            close(fd);
        sleep_ms(500);
    }
out:
    if (termination_observed_out != NULL)
        *termination_observed_out = termination_observed;
    if (result == TX_EXCHANGE_ERROR && !stop_requested)
        perror("TX session exchange");
    if (capsule != NULL) {
        session_secure_clear(capsule, capsule_length);
        free(capsule);
    }
    session_secure_clear(plain, sizeof(plain));
    session_secure_clear(confirmation, sizeof(confirmation));
    session_secure_clear(done_confirmation, sizeof(done_confirmation));
    session_secure_clear(capsule_digest, sizeof(capsule_digest));
    session_secure_clear(&secret, sizeof(secret));
    return result;
}

static int tx_exchange_and_persist(
    const struct options *options, EVP_PKEY *local_private_key,
    EVP_PKEY *pinned_peer_public_key, enum session_profile profile,
    unsigned int seed_bits, struct aes_session_regs *regs,
    uint32_t termination_baseline,
    uint32_t *termination_observed_out,
    struct session_secret *active_secret_out)
{
    int result;

    do {
        result = tx_exchange(options, local_private_key,
                             pinned_peer_public_key, profile, seed_bits,
                             regs, termination_baseline,
                             termination_observed_out, active_secret_out);
    } while (result == TX_EXCHANGE_COUNTER_RESYNC_REQUIRED &&
             !stop_requested);
    const uint32_t committed_termination_count =
        termination_observed_out != NULL ? *termination_observed_out :
                                           termination_baseline;

    if (result == TX_EXCHANGE_COMMITTED && active_secret_out != NULL &&
        store_tx_active_state(options->active_state_path,
                              active_secret_out,
                              committed_termination_count) != 0) {
        const int saved_errno = errno;

        /* Never leave the previous session record behind after PL/RX have
         * advanced, even when persisting the replacement fails. */
        (void)clear_tx_active_state(options->active_state_path);
        errno = saved_errno;
        perror("persist TX active session");
    }
    return result;
}

static int tx_terminate(const struct options *options,
                        const struct session_secret *active_secret)
{
    uint8_t proof[SESSION_CONFIRM_BYTES] = {0};
    uint8_t response[SESSION_CONFIRM_BYTES] = {0};
    int fd = -1;
    int result = -1;

    if (active_secret == NULL ||
        !session_make_proof(active_secret, SESSION_PROOF_TERMINATE, proof) ||
        connect_receiver(options, &fd) != 0 ||
        send_message(fd, MESSAGE_TERMINATE, proof, sizeof(proof)) != 0 ||
        receive_header(fd, MESSAGE_TERMINATED, sizeof(response)) != 0 ||
        read_all(fd, response, sizeof(response)) != 0 ||
        !session_verify_proof(active_secret, SESSION_PROOF_TERMINATED,
                              response))
        goto out;
    fprintf(stderr, "TX session %08x terminated on both boards\n",
            active_secret->session_id);
    result = 0;
out:
    if (result != 0)
        perror("TX session termination; retrying receiver lookup/connect");
    if (fd >= 0)
        close(fd);
    session_secure_clear(proof, sizeof(proof));
    session_secure_clear(response, sizeof(response));
    return result;
}

static bool tx_pl_update_pending(const struct aes_session_status *status)
{
    return status != NULL &&
           (status->raw & (STATUS_COMMIT_PENDING | STATUS_CLEAR_PENDING)) != 0;
}

#ifdef AES_SESSION_FAULT_TEST
static void tx_observe_termination(uint32_t observed,
                                   uint32_t *last_observed,
                                   bool active_secret_valid,
                                   bool *termination_pending)
{
    if (last_observed == NULL || termination_pending == NULL ||
        observed == *last_observed)
        return;
    *last_observed = observed;
    *termination_pending = active_secret_valid;
}

static int tx_control_state_selftest(void)
{
    struct aes_session_status status;
    uint32_t last_observed = 7u;
    bool termination_pending = false;

    memset(&status, 0, sizeof(status));
    tx_observe_termination(7u, &last_observed, true,
                           &termination_pending);
    if (last_observed != 7u || termination_pending)
        return -1;
    tx_observe_termination(8u, &last_observed, true,
                           &termination_pending);
    if (last_observed != 8u || !termination_pending)
        return -1;
    tx_observe_termination(9u, &last_observed, false,
                           &termination_pending);
    if (last_observed != 9u || termination_pending)
        return -1;

    status.raw = STATUS_CLEAR_PENDING;
    if (!tx_pl_update_pending(&status))
        return -1;
    status.raw = STATUS_COMMIT_PENDING;
    if (!tx_pl_update_pending(&status))
        return -1;
    status.raw = STATUS_REQUEST_PENDING;
    if (tx_pl_update_pending(&status))
        return -1;

    fprintf(stderr,
            "PASS: TX termination event retention and PL-update gating\n");
    return 0;
}
#endif

static int send_management_text(int fd, const struct sockaddr_in *destination,
                                socklen_t destination_length,
                                const char *text)
{
    const size_t length = strlen(text);

    return sendto(fd, text, length, MSG_NOSIGNAL,
                  (const struct sockaddr *)destination,
                  destination_length) == (ssize_t)length ? 0 : -1;
}

static int open_management_socket(const struct options *options)
{
    struct sockaddr_in local = {0};
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    int reuse = 1;

    if (fd < 0)
        return -1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    local.sin_family = AF_INET;
    local.sin_port = htons((uint16_t)options->control_port);
    if (options->control_bind == NULL ||
        strcmp(options->control_bind, "0.0.0.0") == 0) {
        local.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, options->control_bind,
                         &local.sin_addr) != 1) {
        close(fd);
        errno = EINVAL;
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool management_source_allowed(const struct options *options,
                                      const struct sockaddr_in *source)
{
    struct in_addr configured;

    return options->control_peer == NULL ||
           *options->control_peer == '\0' ||
           (inet_pton(AF_INET, options->control_peer, &configured) == 1 &&
             configured.s_addr == source->sin_addr.s_addr);
}

static int parse_management_u64(const char *text, uint64_t *value_out)
{
    char *end = NULL;
    unsigned long long value;

    if (text == NULL || text[0] < '0' || text[0] > '9')
        return -1;
    errno = 0;
    value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0u)
        return -1;
    *value_out = (uint64_t)value;
    return 0;
}

static int parse_management_seed_bits(const char *text,
                                      unsigned int *value_out)
{
    char *end = NULL;
    unsigned long value;

    if (text == NULL || text[0] < '0' || text[0] > '9')
        return -1;
    errno = 0;
    value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        value < 1u || value > 32u)
        return -1;
    *value_out = (unsigned int)value;
    return 0;
}

/* The V1 wire representation is an intentionally small line protocol:
 *   CREATE_SECURE_SESSION request_id
 *   CREATE_WEAK_SESSION request_id seed_bits
 * Command and ACK semantics are frozen; bind address and port remain config. */
static int parse_management_text(const char *packet,
                                 enum session_profile *profile_out,
                                 uint64_t *request_id_out,
                                 unsigned int *seed_bits_out)
{
    char name[40] = {0};
    char request_text[32] = {0};
    char argument[16] = {0};
    char extra[2] = {0};
    uint64_t request_id = 0;
    unsigned int seed_bits = 0;
    int fields;

    fields = sscanf(packet, "%39s %31s %15s %1s", name, request_text,
                    argument, extra);
    if (fields < 2 || parse_management_u64(request_text, &request_id) != 0) {
        *request_id_out = 0u;
        return -2;
    }
    *request_id_out = request_id;
    if (strcmp(name, "CREATE_SECURE_SESSION") == 0 && fields == 2) {
        *profile_out = SESSION_PROFILE_SECURE;
        *seed_bits_out = 0u;
        return 1;
    }
    if (strcmp(name, "CREATE_WEAK_SESSION") == 0 && fields == 3 &&
        parse_management_seed_bits(argument, &seed_bits) == 0) {
        *profile_out = SESSION_PROFILE_WEAK;
        *seed_bits_out = seed_bits;
        return 1;
    }
    return -1;
}

static int receive_management_command(const struct options *options, int fd,
                                      struct management_command *command)
{
    char packet[MANAGEMENT_MESSAGE_MAX] = {0};
    uint64_t request_id = 0;
    ssize_t length;
    int parsed;

    memset(command, 0, sizeof(*command));
    command->source_length = sizeof(command->source);
    length = recvfrom(fd, packet, sizeof(packet) - 1u, 0,
                      (struct sockaddr *)&command->source,
                      &command->source_length);
    if (length < 0)
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? 0 :
                                                                           -1;
    if (!management_source_allowed(options, &command->source))
        return 0;
    packet[length] = '\0';
    if (memchr(packet, '\0', (size_t)length) != NULL)
        parsed = -1;
    else
        parsed = parse_management_text(packet, &command->profile,
                                       &request_id, &command->seed_bits);
    if (parsed != 1) {
        char response[MANAGEMENT_MESSAGE_MAX];

        snprintf(response, sizeof(response), "ERROR %llu %s\n",
                 (unsigned long long)request_id,
                 parsed == -2 ? "INVALID_REQUEST_ID" : "BAD_REQUEST");
        (void)send_management_text(fd, &command->source,
                                   command->source_length, response);
        return 0;
    }
    command->request_id = request_id;
    return 1;
}

static struct management_reply *find_management_reply(
    struct management_reply cache[MANAGEMENT_CACHE_SIZE], uint64_t request_id)
{
    for (unsigned int i = 0; i < MANAGEMENT_CACHE_SIZE; ++i) {
        if (cache[i].valid && cache[i].request_id == request_id)
            return &cache[i];
    }
    return NULL;
}

static void store_management_reply(
    struct management_reply cache[MANAGEMENT_CACHE_SIZE],
    unsigned int *next, const struct management_command *command,
    const char *text)
{
    struct management_reply *reply = &cache[*next];

    memset(reply, 0, sizeof(*reply));
    reply->valid = true;
    reply->profile = command->profile;
    reply->request_id = command->request_id;
    reply->seed_bits = command->seed_bits;
    snprintf(reply->text, sizeof(reply->text), "%s", text);
    *next = (*next + 1u) % MANAGEMENT_CACHE_SIZE;
}

#ifdef AES_SESSION_FAULT_TEST
static int management_control_selftest(void)
{
    struct management_command command = {0};
    struct management_reply cache[MANAGEMENT_CACHE_SIZE] = {{0}};
    struct management_reply *reply;
    unsigned int next = 0u;
    uint64_t request_id = 0;
    unsigned int seed_bits = 0;
    enum session_profile profile = SESSION_PROFILE_SECURE;

    if (parse_management_text("CREATE_SECURE_SESSION 42", &profile,
                              &request_id, &seed_bits) != 1 ||
        profile != SESSION_PROFILE_SECURE || request_id != 42u ||
        seed_bits != 0u ||
        parse_management_text("CREATE_WEAK_SESSION 43 32", &profile,
                              &request_id, &seed_bits) != 1 ||
        profile != SESSION_PROFILE_WEAK || request_id != 43u ||
        seed_bits != 32u ||
        parse_management_text("CREATE_SECURE_SESSION 42 extra", &profile,
                              &request_id, &seed_bits) != -1 ||
        parse_management_text("CREATE_WEAK_SESSION 43 0", &profile,
                              &request_id, &seed_bits) != -1 ||
        parse_management_text("CREATE_WEAK_SESSION 43 33", &profile,
                              &request_id, &seed_bits) != -1 ||
        parse_management_text("CREATE_SECURE_SESSION -1", &profile,
                              &request_id, &seed_bits) != -2 ||
        parse_management_text("CREATE_SECURE_SESSION 0", &profile,
                              &request_id, &seed_bits) != -2)
        return -1;

    command.profile = SESSION_PROFILE_WEAK;
    command.request_id = 43u;
    command.seed_bits = 32u;
    store_management_reply(cache, &next, &command,
                           "WEAK_SESSION_ACTIVE 43 7 32\n");
    reply = find_management_reply(cache, 43u);
    if (reply == NULL || reply->profile != SESSION_PROFILE_WEAK ||
        reply->seed_bits != 32u ||
        strcmp(reply->text, "WEAK_SESSION_ACTIVE 43 7 32\n") != 0)
        return -1;
    fprintf(stderr,
            "PASS: strict management parsing and request-id reply cache\n");
    return 0;
}
#endif

static int rx_connection(const struct options *options,
                         EVP_PKEY *local_private_key,
                         EVP_PKEY *pinned_peer_public_key,
                         struct aes_session_regs *regs, int fd,
                         struct session_secret *active_secret,
                         bool *active_secret_valid, bool *terminated)
{
    struct wire_header header;
    struct session_secret secret;
    uint8_t capsule[CAPSULE_MAX] = {0};
    uint8_t confirmation[SESSION_CONFIRM_BYTES] = {0};
    uint8_t commit_proof[SESSION_CONFIRM_BYTES] = {0};
    uint8_t *plain = NULL;
    size_t plain_length = 0;
    struct rx_commit_state committed;
    struct aes_session_status hardware_status;
    uint8_t capsule_digest[CAPSULE_DIGEST_BYTES] = {0};
    size_t capsule_length;
    bool duplicate = false;
    int result = -1;

    memset(&secret, 0, sizeof(secret));
    if (set_socket_timeout(fd) != 0 || read_all(fd, &header, sizeof(header)) != 0 ||
        memcmp(header.magic, message_magic, sizeof(header.magic)) != 0 ||
        header.version != 1)
        goto out;

    if (header.type == MESSAGE_TERMINATE) {
        if (ntohs(header.length_be) != sizeof(confirmation) ||
            read_all(fd, confirmation, sizeof(confirmation)) != 0 ||
            !*active_secret_valid ||
            !session_verify_proof(active_secret, SESSION_PROOF_TERMINATE,
                                  confirmation)) {
            errno = EPROTO;
            goto out;
        }
        if (load_rx_commit_state(options->counter_path, &committed) != 0 ||
            !committed.has_identity || !committed.has_capsule ||
            committed.counter != active_secret->counter ||
            committed.session_id != active_secret->session_id ||
            (committed.phase != RX_STATE_ACTIVE &&
             committed.phase != RX_STATE_TERMINATED)) {
            errno = EPROTO;
            goto out;
        }
        if (!*terminated && !options->no_hardware) {
            if (aes_session_regs_read_status(regs, &hardware_status) != 0 ||
                hardware_status.active_session_id !=
                    active_secret->session_id ||
                (hardware_status.raw &
                 (STATUS_KEY_VALID | STATUS_KEY_READY)) !=
                    (STATUS_KEY_VALID | STATUS_KEY_READY) ||
                aes_session_regs_clear(regs, 2000) != 0)
                goto out;
        }
        /* The PL clear is complete before the durable tombstone is written.
         * A daemon restart can decrypt the retained capsule and authenticate
         * an identical TERMINATE retry even when the first reply was lost. */
        if (!committed.terminated) {
            committed.terminated = true;
            committed.phase = RX_STATE_TERMINATED;
            if (store_rx_commit_state(options->counter_path, &committed) != 0)
                goto out;
        }
        *terminated = true;
#ifdef AES_SESSION_FAULT_TEST
        {
            const char *marker = getenv("AES_SESSION_DROP_TERMINATED_ONCE");

            if (marker != NULL && *marker != '\0') {
                const int marker_fd =
                    open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);

                if (marker_fd >= 0) {
                    close(marker_fd);
                    if (getenv("AES_SESSION_EXIT_AFTER_DROP_TERMINATED") != NULL)
                        stop_requested = 1;
                    errno = ECONNRESET;
                    goto out;
                }
                if (errno != EEXIST)
                    goto out;
            }
        }
#endif
        if (!session_make_proof(active_secret, SESSION_PROOF_TERMINATED,
                                confirmation) ||
            send_message(fd, MESSAGE_TERMINATED,
                         confirmation, sizeof(confirmation)) != 0)
            goto out;
        fprintf(stderr, "RX session %08x terminated and key cleared\n",
                active_secret->session_id);
        result = 0;
        goto out;
    }
    if (header.type != MESSAGE_SESSION_CAPSULE) {
        errno = EPROTO;
        goto out;
    }
    capsule_length = ntohs(header.length_be);
    if (capsule_length == 0 || capsule_length > sizeof(capsule) ||
        read_all(fd, capsule, capsule_length) != 0 ||
        !ecdh_session_decrypt(local_private_key, pinned_peer_public_key,
                              capsule, capsule_length,
                              &plain, &plain_length) ||
        plain_length != SESSION_PLAIN_BYTES ||
        !session_secret_decode(plain, &secret) ||
        !capsule_sha256(capsule, capsule_length, capsule_digest) ||
        load_rx_commit_state(options->counter_path, &committed) != 0) {
        errno = EPROTO;
        goto out;
    }
    if (secret.counter <= committed.counter) {
        bool same_capsule = false;

        if (secret.counter == committed.counter) {
            same_capsule = committed.has_identity &&
                           secret.session_id == committed.session_id &&
                           CRYPTO_memcmp(capsule_digest,
                                         committed.capsule_digest,
                                         sizeof(capsule_digest)) == 0;
        }

        if (same_capsule && committed.has_capsule)
            same_capsule = capsule_length == committed.capsule_length &&
                           CRYPTO_memcmp(capsule, committed.capsule,
                                         capsule_length) == 0;
        if (same_capsule && committed.phase == RX_STATE_PENDING &&
            activate_rx_pending_state(options, regs, &committed, &secret) != 0)
            goto out;
        duplicate = same_capsule && committed.phase == RX_STATE_ACTIVE;
        if (!options->no_hardware) {
            duplicate = duplicate &&
                        aes_session_regs_read_status(regs, &hardware_status) == 0 &&
                        hardware_status.active_session_id == secret.session_id &&
                        (hardware_status.raw &
                         (STATUS_KEY_VALID | STATUS_KEY_READY)) ==
                        (STATUS_KEY_VALID | STATUS_KEY_READY);
        }
        if (!duplicate) {
            if (send_counter_floor(fd, local_private_key,
                                   pinned_peer_public_key, &secret,
                                   committed.counter,
                                   capsule_digest) != 0)
                goto out;
            fprintf(stderr,
                    "RX rejected stale session counter %llu and returned "
                    "authenticated floor %llu\n",
                    (unsigned long long)secret.counter,
                    (unsigned long long)committed.counter);
            errno = ESTALE;
            goto out;
        }
    }
    /* Phase 1 proves possession of the private key without changing PL. */
    if (!session_make_proof(&secret, SESSION_PROOF_READY, confirmation) ||
        send_message(fd, MESSAGE_READY,
                     confirmation, sizeof(confirmation)) != 0 ||
        receive_header(fd, MESSAGE_COMMIT, sizeof(commit_proof)) != 0 ||
        read_all(fd, commit_proof, sizeof(commit_proof)) != 0 ||
        !session_verify_proof(&secret, SESSION_PROOF_COMMIT, commit_proof))
        goto out;
    /* Phase 2 writes the exact authorized capsule as PENDING before touching
     * PL.  If the daemon dies after PL commit but before ACTIVE is durable,
     * startup replays this same secret idempotently and then returns DONE. */
    if (!duplicate) {
        committed.counter = secret.counter;
        committed.session_id = secret.session_id;
        memcpy(committed.capsule_digest, capsule_digest,
               sizeof(committed.capsule_digest));
        memcpy(committed.capsule, capsule, capsule_length);
        committed.capsule_length = capsule_length;
        committed.has_identity = true;
        committed.has_capsule = true;
        committed.terminated = false;
        committed.phase = RX_STATE_PENDING;
        if (store_rx_commit_state(options->counter_path, &committed) != 0 ||
            activate_rx_pending_state(options, regs, &committed, &secret) != 0)
            goto out;
    }
#ifdef AES_SESSION_FAULT_TEST
    /* Host-only integration test hook: emulate a lost first DONE after RX
     * has already committed and persisted the new key identity. */
    if (!duplicate) {
        const char *marker = getenv("AES_SESSION_DROP_DONE_ONCE");
        if (marker != NULL && *marker != '\0') {
            const int marker_fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (marker_fd >= 0) {
                close(marker_fd);
                errno = ECONNRESET;
                goto out;
            }
            if (errno != EEXIST)
                goto out;
        }
    }
#endif
    if (!session_make_proof(&secret, SESSION_PROOF_DONE, confirmation) ||
        send_message(fd, MESSAGE_DONE,
                     confirmation, sizeof(confirmation)) != 0)
        goto out;
    memcpy(active_secret, &secret, sizeof(*active_secret));
    *active_secret_valid = true;
    *terminated = false;
    fprintf(stderr, "RX session %08x counter %llu %s\n",
            secret.session_id, (unsigned long long)secret.counter,
            duplicate ? "reconfirmed after duplicate" :
                        "committed and confirmed");
    result = 0;
out:
    if (result != 0)
        perror("RX session exchange");
    if (plain != NULL) {
        session_secure_clear(plain, plain_length);
        free(plain);
    }
    session_secure_clear(capsule, sizeof(capsule));
    session_secure_clear(confirmation, sizeof(confirmation));
    session_secure_clear(commit_proof, sizeof(commit_proof));
    session_secure_clear(capsule_digest, sizeof(capsule_digest));
    session_secure_clear(&secret, sizeof(secret));
    return result;
}

static int run_tx(const struct options *options,
                  EVP_PKEY *local_private_key,
                  EVP_PKEY *pinned_peer_public_key,
                  struct aes_session_regs *regs)
{
    struct aes_session_status status;
    struct session_secret active_secret;
    bool active_secret_valid = false;
    bool recovered_termination_credential = false;

    memset(&active_secret, 0, sizeof(active_secret));
    if (load_tx_active_state(options, regs, &active_secret,
                             &active_secret_valid,
                             &recovered_termination_credential) != 0) {
        perror("recover TX active session");
        session_secure_clear(&active_secret, sizeof(active_secret));
        return -1;
    }
    if (active_secret_valid)
        fprintf(stderr, "TX recovered %s session %08x counter %llu\n",
                recovered_termination_credential ? "termination credential for" :
                                                   "active",
                active_secret.session_id,
                (unsigned long long)active_secret.counter);
    if (options->no_hardware) {
#ifdef AES_SESSION_FAULT_TEST
        if (getenv("AES_SESSION_TEST_WEAK_KEY") != NULL)
            return weak_key_selftest();
        if (getenv("AES_SESSION_TEST_MANAGEMENT") != NULL)
            return management_control_selftest();
        if (getenv("AES_SESSION_TEST_CONTROL_STATE") != NULL)
            return tx_control_state_selftest();
        if (getenv("AES_SESSION_TEST_RESTART_TERMINATE") != NULL) {
            int restart_result;

            if (!active_secret_valid) {
                errno = ENOKEY;
                perror("TX restart termination state");
                session_secure_clear(&active_secret, sizeof(active_secret));
                return -1;
            }
            restart_result = tx_terminate(options, &active_secret);
            if (restart_result == 0 &&
                clear_tx_active_state(options->active_state_path) != 0)
                perror("clear TX active session");
            session_secure_clear(&active_secret, sizeof(active_secret));
            return restart_result;
        }
#endif
        uint32_t host_termination_count = 0;
        uint32_t observed_termination_count = 0;
        int host_result =
            tx_exchange_and_persist(options, local_private_key,
                                    pinned_peer_public_key,
                                    SESSION_PROFILE_SECURE, 0u, regs,
                                    host_termination_count,
                                    &observed_termination_count,
                                    &active_secret);

        host_termination_count = observed_termination_count;
#ifdef AES_SESSION_FAULT_TEST
        if (host_result == TX_EXCHANGE_COMMITTED &&
            getenv("AES_SESSION_TEST_REKEY_CANCEL_AFTER_DONE") != NULL) {
            if (setenv("AES_SESSION_CANCEL_AFTER_DONE_ONCE", "1", 1) != 0)
                host_result = TX_EXCHANGE_ERROR;
            else
                host_result = tx_exchange_and_persist(
                    options, local_private_key, pinned_peer_public_key,
                    SESSION_PROFILE_SECURE, 0u, regs, host_termination_count,
                    &observed_termination_count, &active_secret);
            (void)unsetenv("AES_SESSION_CANCEL_AFTER_DONE_ONCE");
        }
        if (host_result == TX_EXCHANGE_COMMITTED &&
            getenv("AES_SESSION_TEST_REKEY_PRESS_RELEASE") != NULL) {
            if (setenv("AES_SESSION_PRESS_RELEASE_AFTER_COMMIT_ONCE", "1", 1) !=
                0)
                host_result = TX_EXCHANGE_ERROR;
            else
                host_result = tx_exchange_and_persist(
                    options, local_private_key, pinned_peer_public_key,
                    SESSION_PROFILE_SECURE, 0u, regs, host_termination_count,
                    &observed_termination_count, &active_secret);
            (void)unsetenv("AES_SESSION_PRESS_RELEASE_AFTER_COMMIT_ONCE");
        }
        host_termination_count = observed_termination_count;
        if (host_result == TX_EXCHANGE_COMMITTED &&
            getenv("AES_SESSION_TEST_RELEASE_REKEY_AFTER_LOST_TERMINATE") !=
                NULL) {
            if (tx_terminate(options, &active_secret) == 0) {
                if (clear_tx_active_state(options->active_state_path) != 0)
                    perror("clear TX active session");
                errno = EPROTO;
                host_result = TX_EXCHANGE_ERROR;
            } else {
                host_result = tx_exchange_and_persist(
                    options, local_private_key, pinned_peer_public_key,
                    SESSION_PROFILE_SECURE, 0u, regs, host_termination_count,
                    &observed_termination_count, &active_secret);
                if (host_result == TX_EXCHANGE_COMMITTED)
                    fprintf(stderr,
                            "TX release request superseded unacknowledged "
                            "termination with session %08x\n",
                            active_secret.session_id);
            }
        } else if (host_result == TX_EXCHANGE_REMOTE_COMMITTED_CANCELED) {
            host_result = tx_terminate(options, &active_secret);
            if (host_result == 0 &&
                clear_tx_active_state(options->active_state_path) != 0)
                perror("clear TX active session");
        } else if (host_result == TX_EXCHANGE_COMMITTED &&
                   getenv("AES_SESSION_TEST_TERMINATE_AFTER_COMMIT") != NULL) {
            do {
                host_result = tx_terminate(options, &active_secret);
                if (host_result != 0 &&
                    getenv("AES_SESSION_TEST_RETRY_TERMINATE") != NULL)
                    sleep_ms(100);
            } while (host_result != 0 && !stop_requested &&
                     getenv("AES_SESSION_TEST_RETRY_TERMINATE") != NULL);
            if (host_result == 0 &&
                clear_tx_active_state(options->active_state_path) != 0)
                perror("clear TX active session");
        }
#endif
        session_secure_clear(&active_secret, sizeof(active_secret));
        return host_result;
    }
    {
        struct management_reply cache[MANAGEMENT_CACHE_SIZE] = {{0}};
        unsigned int cache_next = 0u;
        int control_fd = open_management_socket(options);

        if (control_fd < 0) {
            perror("open TX management socket");
            session_secure_clear(&active_secret, sizeof(active_secret));
            return -1;
        }
        fprintf(stderr,
                "TX management UDP %s:%u; boot default is automatic Secure Session\n",
                options->control_bind, options->control_port);
        while (!stop_requested) {
            const uint32_t ready_mask = STATUS_KEY_VALID | STATUS_KEY_READY;
            bool hardware_ready;

            if (aes_session_regs_read_status(regs, &status) != 0) {
                close(control_fd);
                session_secure_clear(&active_secret, sizeof(active_secret));
                return -1;
            }
            /* SW2 is intentionally not a session-control path in V1.  Clear
             * any legacy PL request without creating or replacing a key. */
            if ((status.raw & STATUS_REQUEST_PENDING) != 0)
                (void)aes_session_regs_ack_request(regs);
            if (status.termination_active || tx_pl_update_pending(&status)) {
                sleep_ms(20);
                continue;
            }
            hardware_ready = active_secret_valid &&
                             (status.raw & ready_mask) == ready_mask &&
                             status.active_session_id == active_secret.session_id;

            if (!hardware_ready) {
                uint32_t termination_observed = status.termination_count;
                int exchange_result;

                fprintf(stderr,
                        "TX creating default Secure Session without Jetson control\n");
                exchange_result = tx_exchange_and_persist(
                    options, local_private_key, pinned_peer_public_key,
                    SESSION_PROFILE_SECURE, 0u, regs,
                    status.termination_count, &termination_observed,
                    &active_secret);
                if (exchange_result == TX_EXCHANGE_COMMITTED) {
                    active_secret_valid = true;
                    fprintf(stderr,
                            "TX default Secure Session active session=%08x\n",
                            active_secret.session_id);
                    if (options->once)
                        break;
                } else if (exchange_result ==
                           TX_EXCHANGE_REMOTE_COMMITTED_CANCELED) {
                    active_secret_valid = true;
                    if (tx_terminate(options, &active_secret) == 0)
                        (void)clear_tx_active_state(options->active_state_path);
                    active_secret_valid = false;
                } else if (!stop_requested) {
                    sleep_ms(500);
                }
                continue;
            }

            {
                struct management_command command;
                struct management_reply *cached;
                int received = receive_management_command(
                    options, control_fd, &command);

                if (received < 0) {
                    perror("receive TX management command");
                    sleep_ms(100);
                    continue;
                }
                if (received == 0) {
                    if (options->once)
                        break;
                    sleep_ms(20);
                    continue;
                }
                cached = find_management_reply(cache, command.request_id);
                if (cached != NULL) {
                    if (cached->profile == command.profile &&
                        cached->seed_bits == command.seed_bits) {
                        (void)send_management_text(
                            control_fd, &command.source,
                            command.source_length, cached->text);
                    } else {
                        char response[MANAGEMENT_MESSAGE_MAX];

                        snprintf(response, sizeof(response),
                                 "ERROR %llu REQUEST_ID_CONFLICT\n",
                                 (unsigned long long)command.request_id);
                        (void)send_management_text(
                            control_fd, &command.source,
                            command.source_length, response);
                    }
                    continue;
                }

                {
                    uint32_t termination_observed = status.termination_count;
                    const int exchange_result = tx_exchange_and_persist(
                        options, local_private_key, pinned_peer_public_key,
                        command.profile, command.seed_bits, regs,
                        status.termination_count, &termination_observed,
                        &active_secret);
                    char response[MANAGEMENT_MESSAGE_MAX];

                    if (exchange_result == TX_EXCHANGE_COMMITTED) {
                        active_secret_valid = true;
                        if (command.profile == SESSION_PROFILE_SECURE) {
                            snprintf(
                                response, sizeof(response),
                                "SECURE_SESSION_ACTIVE %llu %u\n",
                                (unsigned long long)command.request_id,
                                active_secret.session_id);
                        } else {
                            snprintf(
                                response, sizeof(response),
                                "WEAK_SESSION_ACTIVE %llu %u %u\n",
                                (unsigned long long)command.request_id,
                                active_secret.session_id, command.seed_bits);
                        }
                    } else {
                        snprintf(response, sizeof(response),
                                 "ERROR %llu SESSION_SETUP_FAILED\n",
                                 (unsigned long long)command.request_id);
                        if (exchange_result ==
                            TX_EXCHANGE_REMOTE_COMMITTED_CANCELED) {
                            active_secret_valid = true;
                            if (tx_terminate(options, &active_secret) == 0)
                                (void)clear_tx_active_state(
                                    options->active_state_path);
                            active_secret_valid = false;
                        }
                    }
                    store_management_reply(cache, &cache_next, &command,
                                           response);
                    (void)send_management_text(
                        control_fd, &command.source,
                        command.source_length, response);
                }
            }
        }
        close(control_fd);
    }
    session_secure_clear(&active_secret, sizeof(active_secret));
    return 0;
}

static int run_rx(const struct options *options,
                  EVP_PKEY *local_private_key,
                  EVP_PKEY *pinned_peer_public_key,
                  struct aes_session_regs *regs)
{
    int listener;
    int announcer;
    int successful = 0;
    struct session_secret active_secret;
    bool active_secret_valid = false;
    bool terminated = false;
    uint64_t recovery_request_id = 0u;
    unsigned int recovery_ticks = 0u;

    memset(&active_secret, 0, sizeof(active_secret));
    if (recover_rx_active_secret(options, local_private_key,
                                 pinned_peer_public_key, regs, &active_secret,
                                 &active_secret_valid, &terminated) != 0) {
        perror("RX durable session recovery");
        session_secure_clear(&active_secret, sizeof(active_secret));
        return -1;
    }
    listener = open_tcp_listener(options);
    announcer = open_announcer(options);

    if (listener < 0 || announcer < 0) {
        if (listener >= 0)
            close(listener);
        if (announcer >= 0)
            close(announcer);
        return -1;
    }
    fprintf(stderr, "RX session service listening on TCP %u\n", SESSION_PORT);
    if (!active_secret_valid && !terminated) {
        do {
            if (RAND_bytes((uint8_t *)&recovery_request_id,
                           sizeof(recovery_request_id)) != 1) {
                recovery_request_id = 0u;
                break;
            }
        } while (recovery_request_id == 0u);
    }
    while (!stop_requested) {
        struct sockaddr_in peer;
        socklen_t peer_length = sizeof(peer);
        int fd;

        announce_receiver(announcer, options);
        /* Joint boot normally completes through TX's automatic default
         * exchange before this three-second grace period expires.  If RX was
         * rebooted alone from JTAG/initramfs, its volatile PL/session state is
         * empty while TX still considers the old key active.  Reissue one
         * idempotent request every two seconds until the authenticated normal
         * exchange commits; duplicate UDP datagrams hit TX's request cache. */
        if (!active_secret_valid && !terminated && recovery_request_id != 0u) {
            ++recovery_ticks;
            if (recovery_ticks >= 12u &&
                ((recovery_ticks - 12u) % 8u) == 0u) {
                if (request_secure_session_recovery(
                        announcer, options, recovery_request_id) == 0)
                    fprintf(stderr,
                            "RX requested automatic Secure Session recovery "
                            "request=%llu\n",
                            (unsigned long long)recovery_request_id);
            }
        }
        fd = accept(listener, (struct sockaddr *)&peer, &peer_length);
        if (fd < 0) {
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
                perror("accept");
            sleep_ms(250);
            continue;
        }
        if (rx_connection(options, local_private_key,
                          pinned_peer_public_key, regs, fd, &active_secret,
                          &active_secret_valid, &terminated) == 0)
            ++successful;
        close(fd);
        if (options->once && successful != 0) {
#ifdef AES_SESSION_FAULT_TEST
            if (getenv("AES_SESSION_TEST_TERMINATE_AFTER_COMMIT") == NULL ||
                terminated)
                break;
#else
            break;
#endif
        }
    }
    close(announcer);
    close(listener);
    session_secure_clear(&active_secret, sizeof(active_secret));
    return successful != 0 || !options->once ? 0 : -1;
}

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s --tx TX_PRIVATE.pem RX_PUBLIC.pem|"
            "--rx RX_PRIVATE.pem TX_PUBLIC.pem [options]\n"
            "  --interface IFACE   bind key exchange to Wi-Fi interface\n"
            "  --peer RX_IP        skip broadcast discovery (TX only)\n"
            "  --counter PATH      replay counter file\n"
            "  --active-state PATH root-only ephemeral TX recovery file\n"
            "  --control-bind IP   TX Jetson-control bind address\n"
            "  --control-peer IP   optional accepted Jetson source IP\n"
            "  --control-port PORT TX Jetson-control UDP port (default 46101)\n"
            "  --once              exit after one successful exchange\n"
            "  --no-hardware       host test without 0x43d00000 registers\n",
            program);
}

static int parse_options(int argc, char **argv, struct options *options)
{
    int i;
    bool mode_selected = false;

    memset(options, 0, sizeof(*options));
    for (i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--tx") == 0 && i + 2 < argc && !mode_selected) {
            options->tx = true;
            options->private_key_path = argv[++i];
            options->peer_public_key_path = argv[++i];
            mode_selected = true;
        } else if (strcmp(argv[i], "--rx") == 0 && i + 2 < argc && !mode_selected) {
            options->tx = false;
            options->private_key_path = argv[++i];
            options->peer_public_key_path = argv[++i];
            mode_selected = true;
        } else if (strcmp(argv[i], "--interface") == 0 && i + 1 < argc) {
            options->interface = argv[++i];
        } else if (strcmp(argv[i], "--peer") == 0 && i + 1 < argc) {
            options->peer = argv[++i];
        } else if (strcmp(argv[i], "--counter") == 0 && i + 1 < argc) {
            options->counter_path = argv[++i];
        } else if (strcmp(argv[i], "--active-state") == 0 && i + 1 < argc) {
            options->active_state_path = argv[++i];
        } else if (strcmp(argv[i], "--control-bind") == 0 && i + 1 < argc) {
            options->control_bind = argv[++i];
        } else if (strcmp(argv[i], "--control-peer") == 0 && i + 1 < argc) {
            options->control_peer = argv[++i];
        } else if (strcmp(argv[i], "--control-port") == 0 && i + 1 < argc) {
            char *end = NULL;
            unsigned long value;

            errno = 0;
            value = strtoul(argv[++i], &end, 10);
            if (errno != 0 || end == argv[i] || *end != '\0' ||
                value == 0u || value > 65535u)
                return -1;
            options->control_port = (unsigned int)value;
        } else if (strcmp(argv[i], "--once") == 0) {
            options->once = true;
        } else if (strcmp(argv[i], "--no-hardware") == 0) {
            options->no_hardware = true;
        } else {
            return -1;
        }
    }
    if (!mode_selected)
        return -1;
    if (options->control_bind == NULL) {
        const char *configured = getenv("AES_SESSION_CONTROL_BIND");
        options->control_bind = configured != NULL && *configured != '\0' ?
                                configured : "0.0.0.0";
    }
    if (options->control_peer == NULL) {
        const char *configured = getenv("AES_SESSION_CONTROL_PEER");
        if (configured != NULL && *configured != '\0')
            options->control_peer = configured;
    }
    if (options->control_port == 0u) {
        const char *configured = getenv("AES_SESSION_CONTROL_PORT");
        char *end = NULL;
        unsigned long value = MANAGEMENT_PORT;

        if (configured != NULL && *configured != '\0') {
            errno = 0;
            value = strtoul(configured, &end, 10);
            if (errno != 0 || end == configured || *end != '\0' ||
                value == 0u || value > 65535u)
                return -1;
        }
        options->control_port = (unsigned int)value;
    }
    if (options->counter_path == NULL)
        options->counter_path = options->tx ? "/var/lib/aes-session/tx-counter" :
                                              "/var/lib/aes-session/rx-counter";
    if (options->tx && options->active_state_path == NULL) {
        const char *configured = getenv("AES_SESSION_TX_ACTIVE_STATE");

        if (configured != NULL && *configured != '\0')
            options->active_state_path = configured;
        else if (!options->no_hardware)
            options->active_state_path = "/run/aes-session-tx-active";
    }
    return 0;
}

int main(int argc, char **argv)
{
    struct options options;
    struct aes_session_regs regs;
    EVP_PKEY *local_private_key;
    EVP_PKEY *pinned_peer_public_key;
    int result;

    if (parse_options(argc, argv, &options) != 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    local_private_key = load_key(options.private_key_path, true);
    pinned_peer_public_key = load_key(options.peer_public_key_path, false);
    if (local_private_key == NULL || pinned_peer_public_key == NULL ||
        EVP_PKEY_base_id(local_private_key) != EVP_PKEY_X25519 ||
        EVP_PKEY_base_id(pinned_peer_public_key) != EVP_PKEY_X25519) {
        fprintf(stderr, "cannot load pinned X25519 key pair: %s + %s\n",
                options.private_key_path, options.peer_public_key_path);
        EVP_PKEY_free(local_private_key);
        EVP_PKEY_free(pinned_peer_public_key);
        return EXIT_FAILURE;
    }
    memset(&regs, 0, sizeof(regs));
    regs.fd = -1;
    if (!options.no_hardware &&
        aes_session_regs_open(&regs, AES_SESSION_REG_BASE_DEFAULT) != 0) {
        perror("open AES session registers");
        EVP_PKEY_free(local_private_key);
        EVP_PKEY_free(pinned_peer_public_key);
        return EXIT_FAILURE;
    }
    result = options.tx ? run_tx(&options, local_private_key,
                                 pinned_peer_public_key, &regs) :
                          run_rx(&options, local_private_key,
                                 pinned_peer_public_key, &regs);
    aes_session_regs_close(&regs);
    EVP_PKEY_free(local_private_key);
    EVP_PKEY_free(pinned_peer_public_key);
    return result == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
