#ifndef AES_SESSION_REGS_H
#define AES_SESSION_REGS_H

#include <stddef.h>
#include <stdint.h>

#define AES_SESSION_REG_BASE_DEFAULT 0x43d00000u
#define AES_SESSION_KEY_BYTES 32u
#define AES_SESSION_REG_COMMAND_OFFSET 0x04u
#define AES_SESSION_REG_STATUS_OFFSET 0x08u
#define AES_SESSION_COMMAND_FRAME_ACQUIRE (1u << 4)
#define AES_SESSION_COMMAND_FRAME_RELEASE (1u << 5)
#define AES_SESSION_STATUS_FRAME_LOCK (1u << 9)

struct aes_session_regs {
    int fd;
    size_t map_size;
    volatile uint32_t *base;
};

struct aes_session_status {
    uint32_t raw;
    uint32_t active_session_id;
    uint32_t request_count;
    uint32_t termination_count;
    uint16_t key_epoch;
    uint8_t termination_active;
    uint8_t frame_locked;
};

int aes_session_regs_open(struct aes_session_regs *regs, uintptr_t phys_addr);
void aes_session_regs_close(struct aes_session_regs *regs);
int aes_session_regs_read_status(struct aes_session_regs *regs,
                                 struct aes_session_status *status);
int aes_session_regs_commit(struct aes_session_regs *regs,
                            uint32_t session_id,
                            const uint8_t key[AES_SESSION_KEY_BYTES],
                            unsigned int timeout_ms);
int aes_session_regs_clear(struct aes_session_regs *regs,
                           unsigned int timeout_ms);
int aes_session_regs_ack_request(struct aes_session_regs *regs);

#endif
