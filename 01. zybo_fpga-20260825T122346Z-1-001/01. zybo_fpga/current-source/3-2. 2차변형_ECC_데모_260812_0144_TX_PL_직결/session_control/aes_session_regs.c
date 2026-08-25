#define _POSIX_C_SOURCE 200809L

#include "aes_session_regs.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

enum {
    REG_ID = 0x00 / 4,
    REG_COMMAND = 0x04 / 4,
    REG_STATUS = 0x08 / 4,
    REG_SHADOW_SESSION = 0x0c / 4,
    REG_SHADOW_KEY0 = 0x10 / 4,
    REG_ACTIVE_SESSION = 0x30 / 4,
    REG_REQUEST_COUNT = 0x34 / 4,
    REG_KEY_EPOCH = 0x38 / 4,
    REG_TERMINATION_COUNT = 0x3c / 4,
};

#define REGISTER_ID 0x4b455931u
#define STATUS_KEY_VALID (1u << 0)
#define STATUS_KEY_READY (1u << 1)
#define STATUS_COMMAND_ERROR (1u << 3)
#define STATUS_TERMINATION_ACTIVE (1u << 8)
#define COMMAND_COMMIT 0x1u
#define COMMAND_CLEAR 0x2u
#define COMMAND_ACK_REQUEST 0x4u
#define COMMAND_CLEAR_ERROR 0x8u

static void sleep_ms(unsigned int milliseconds)
{
    struct timespec delay;

    delay.tv_sec = milliseconds / 1000u;
    delay.tv_nsec = (long)(milliseconds % 1000u) * 1000000L;
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR)
        ;
}

static uint32_t key_word_be(const uint8_t *key)
{
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) |
           ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

int aes_session_regs_open(struct aes_session_regs *regs, uintptr_t phys_addr)
{
    const long page_size = sysconf(_SC_PAGESIZE);
    const uintptr_t page_base = phys_addr & ~((uintptr_t)page_size - 1u);
    const uintptr_t page_offset = phys_addr - page_base;
    void *mapping;

    if (regs == NULL || page_size <= 0)
        return -1;
    memset(regs, 0, sizeof(*regs));
    regs->fd = -1;
    regs->map_size = (size_t)page_size;
    regs->fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (regs->fd < 0)
        return -1;
    mapping = mmap(NULL, regs->map_size, PROT_READ | PROT_WRITE,
                   MAP_SHARED, regs->fd, (off_t)page_base);
    if (mapping == MAP_FAILED) {
        close(regs->fd);
        regs->fd = -1;
        return -1;
    }
    regs->base = (volatile uint32_t *)((uint8_t *)mapping + page_offset);
    if (regs->base[REG_ID] != REGISTER_ID) {
        aes_session_regs_close(regs);
        errno = ENODEV;
        return -1;
    }
    return 0;
}

void aes_session_regs_close(struct aes_session_regs *regs)
{
    uintptr_t address;
    uintptr_t page_base;

    if (regs == NULL)
        return;
    if (regs->base != NULL) {
        address = (uintptr_t)regs->base;
        page_base = address & ~((uintptr_t)regs->map_size - 1u);
        munmap((void *)page_base, regs->map_size);
    }
    if (regs->fd >= 0)
        close(regs->fd);
    memset(regs, 0, sizeof(*regs));
    regs->fd = -1;
}

int aes_session_regs_read_status(struct aes_session_regs *regs,
                                 struct aes_session_status *status)
{
    if (regs == NULL || regs->base == NULL || status == NULL)
        return -1;
    status->raw = regs->base[REG_STATUS];
    status->active_session_id = regs->base[REG_ACTIVE_SESSION];
    status->request_count = regs->base[REG_REQUEST_COUNT];
    status->key_epoch = (uint16_t)regs->base[REG_KEY_EPOCH];
    status->termination_count = regs->base[REG_TERMINATION_COUNT];
    status->termination_active =
        (uint8_t)((status->raw & STATUS_TERMINATION_ACTIVE) != 0);
    status->frame_locked =
        (uint8_t)((status->raw & AES_SESSION_STATUS_FRAME_LOCK) != 0);
    return 0;
}

int aes_session_regs_commit(struct aes_session_regs *regs,
                            uint32_t session_id,
                            const uint8_t key[AES_SESSION_KEY_BYTES],
                            unsigned int timeout_ms)
{
    uint16_t old_epoch;
    unsigned int i;
    uint32_t status;

    if (regs == NULL || regs->base == NULL || key == NULL)
        return -1;
    old_epoch = (uint16_t)regs->base[REG_KEY_EPOCH];
    regs->base[REG_SHADOW_SESSION] = session_id;
    /* shadow[7] is the high 32 bits of active_key. */
    for (i = 0; i < 8; ++i)
        regs->base[REG_SHADOW_KEY0 + (7u - i)] = key_word_be(key + i * 4u);
    __sync_synchronize();
    regs->base[REG_COMMAND] = COMMAND_COMMIT | COMMAND_CLEAR_ERROR;
    __sync_synchronize();
    for (i = 0; i <= timeout_ms; ++i) {
        status = regs->base[REG_STATUS];
        if ((status & STATUS_COMMAND_ERROR) != 0) {
            errno = EBUSY;
            return -1;
        }
        if ((status & STATUS_KEY_VALID) != 0 &&
            (uint16_t)regs->base[REG_KEY_EPOCH] != old_epoch &&
            regs->base[REG_ACTIVE_SESSION] == session_id) {
            while (i++ <= timeout_ms) {
                status = regs->base[REG_STATUS];
                if ((status & STATUS_KEY_READY) != 0)
                    return 0;
                sleep_ms(1);
            }
            break;
        }
        sleep_ms(1);
    }
    errno = ETIMEDOUT;
    return -1;
}

int aes_session_regs_clear(struct aes_session_regs *regs,
                           unsigned int timeout_ms)
{
    unsigned int i;

    if (regs == NULL || regs->base == NULL)
        return -1;
    regs->base[REG_COMMAND] = COMMAND_CLEAR | COMMAND_CLEAR_ERROR;
    __sync_synchronize();
    for (i = 0; i <= timeout_ms; ++i) {
        const uint32_t status = regs->base[REG_STATUS];
        if ((status & STATUS_COMMAND_ERROR) != 0) {
            errno = EBUSY;
            return -1;
        }
        if ((status & STATUS_KEY_VALID) == 0)
            return 0;
        sleep_ms(1);
    }
    errno = ETIMEDOUT;
    return -1;
}

int aes_session_regs_ack_request(struct aes_session_regs *regs)
{
    if (regs == NULL || regs->base == NULL)
        return -1;
    regs->base[REG_COMMAND] = COMMAND_ACK_REQUEST;
    __sync_synchronize();
    return 0;
}
