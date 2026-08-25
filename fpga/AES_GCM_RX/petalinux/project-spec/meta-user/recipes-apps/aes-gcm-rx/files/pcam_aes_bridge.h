/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef PCAM_AES_BRIDGE_H
#define PCAM_AES_BRIDGE_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define PCAM_AES_IOC_MAGIC 'G'
#define PCAM_AES_ABI_VERSION 1U

#define PCAM_AES_BUFFER_INPUT  0U
#define PCAM_AES_BUFFER_OUTPUT 1U

struct pcam_aes_info {
    __u32 abi_version;
    __u32 alignment;
    __u32 max_transfer_bytes;
    __u32 reserved;
};

struct pcam_aes_import {
    __s32 dmabuf_fd;
    __u32 direction;
    __u32 handle;
    __u32 reserved; /* returned 32-bit Zynq DMA address */
};

struct pcam_aes_start {
    __u32 input_handle;
    __u32 output_handle;
    __u32 transfer_bytes; /* MM2S input bytes */
    __u32 flags;          /* S2MM output bytes; zero means same as input */
};

struct pcam_aes_wait {
    __u32 timeout_ms;
    __s32 status;
    __u32 tx_status;
    __u32 rx_status;
};

#define PCAM_AES_IOC_GET_INFO \
    _IOR(PCAM_AES_IOC_MAGIC, 0x00, struct pcam_aes_info)
#define PCAM_AES_IOC_IMPORT \
    _IOWR(PCAM_AES_IOC_MAGIC, 0x01, struct pcam_aes_import)
#define PCAM_AES_IOC_START \
    _IOW(PCAM_AES_IOC_MAGIC, 0x02, struct pcam_aes_start)
#define PCAM_AES_IOC_WAIT \
    _IOWR(PCAM_AES_IOC_MAGIC, 0x03, struct pcam_aes_wait)

#endif
