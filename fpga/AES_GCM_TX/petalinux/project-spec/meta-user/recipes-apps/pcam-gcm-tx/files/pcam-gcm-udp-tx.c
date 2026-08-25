#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <linux/dma-buf.h>
#include <linux/if_packet.h>
#include <linux/udp.h>
#include <linux/virtio_net.h>
#include <linux/videodev2.h>
#include <netinet/in.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <net/ethernet.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef PACKET_QDISC_BYPASS
#define PACKET_QDISC_BYPASS 20
#endif
#ifndef SO_NO_CHECK
#define SO_NO_CHECK 11
#endif

#define WIDTH 1280U
#define HEIGHT 720U
#define FRAME_BYTES (WIDTH * HEIGHT * 2U)
#define PACKET_COUNT 1280U
#define PAYLOAD_BYTES 1440U
#define AAD_BYTES 16U
#define TAG_BYTES 16U
#define RECORD_BYTES (AAD_BYTES + TAG_BYTES)
#define METADATA_BYTES (PACKET_COUNT * RECORD_BYTES)
#define UDP_DATA_BYTES (AAD_BYTES + PAYLOAD_BYTES + TAG_BYTES)
#define SEND_BATCH 32U
#define SEND_BATCH_MAX 128U
#define SEND_SPAN_US_DEFAULT 0ULL
#define TX_RING_FRAME_SIZE 2048U
#define TX_RING_BLOCK_SIZE (1024U * 1024U)
#define TX_RING_BLOCK_COUNT 16U
#define VIDEO_BUFFERS 4U
#define DEFAULT_PORT 5602
#define VIDEO_FRAME_TIMEOUT_MS 2000
#define PACKET_MAGIC 0x5043414dU
#define META_GPIO_BASE 0x41220000UL
#define META_GPIO_SIZE 0x10000UL
#define SESSION_REG_BASE 0x43d00000UL
#define SESSION_REG_SIZE 0x1000UL
#define SESSION_REG_ID 0x00U
#define SESSION_REG_CONTROL 0x04U
#define SESSION_REG_STATUS 0x08U
#define SESSION_REG_ACTIVE_ID 0x30U
#define SESSION_REG_REQUEST_COUNT 0x34U
#define SESSION_REG_EPOCH 0x38U
#define SESSION_REG_TERMINATION_COUNT 0x3cU
#define SESSION_REG_MAGIC 0x4b455931U
#define SESSION_STATUS_KEY_VALID (1U << 0)
#define SESSION_STATUS_KEY_READY (1U << 1)
#define SESSION_STATUS_COMMAND_ERROR (1U << 3)
#define SESSION_STATUS_COMMIT_PENDING (1U << 6)
#define SESSION_STATUS_CLEAR_PENDING (1U << 7)
#define SESSION_STATUS_TERMINATION_ACTIVE (1U << 8)
#define SESSION_STATUS_FRAME_LOCK (1U << 9)
#define SESSION_CONTROL_FRAME_ACQUIRE (1U << 4)
#define SESSION_CONTROL_FRAME_RELEASE (1U << 5)
#define SESSION_STATUS_READY_MASK \
    (SESSION_STATUS_KEY_VALID | SESSION_STATUS_KEY_READY)
#define SESSION_STATUS_TRANSITION_MASK \
    (SESSION_STATUS_COMMIT_PENDING | SESSION_STATUS_CLEAR_PENDING | \
     SESSION_STATUS_TERMINATION_ACTIVE)
#define META_BRAM_BASE 0x42000000UL
#define META_BRAM_SIZE 0x20000UL
#define META_BANK_COUNT 4U
#define META_BANK_SIZE 0x8000UL
#define META_TAG_BASE 0x10UL
#define GPIO_DATA 0x0U
#define GPIO_TRI 0x4U
#define GPIO2_DATA 0x8U
#define GPIO2_TRI 0xcU
#define PIPELINE_HEALTH_ERROR_MASK 0xf0000000U

#define STATUS_TOGGLE(v) (((v) >> 31) & 1U)
#define STATUS_BANK(v) (((v) >> 29) & 3U)
#define STATUS_MODE(v) (((v) >> 28) & 1U)

static volatile sig_atomic_t stop_requested;
static int use_udp_gso;
static int use_udp_staging;
static unsigned int udp_gso_batch = SEND_BATCH;
static unsigned int udp_send_batch = SEND_BATCH;
static unsigned int udp_records_per_datagram = 1U;
static uint64_t send_span_us = SEND_SPAN_US_DEFAULT;
static uint8_t *udp_staging;
static int dump_packet0_requested;

struct session_hw_state {
    uint32_t status;
    uint32_t active_session;
    uint32_t request_count;
    uint32_t epoch;
    uint32_t termination_count;
};

static void read_session_hw(volatile uint32_t *regs,
                            struct session_hw_state *state)
{
    state->status = regs[SESSION_REG_STATUS / 4U];
    state->active_session = regs[SESSION_REG_ACTIVE_ID / 4U];
    state->request_count = regs[SESSION_REG_REQUEST_COUNT / 4U];
    state->epoch = regs[SESSION_REG_EPOCH / 4U] & 0xffffU;
    state->termination_count =
        regs[SESSION_REG_TERMINATION_COUNT / 4U];
}

static int session_hw_ready(const struct session_hw_state *state)
{
    return (state->status & SESSION_STATUS_READY_MASK) ==
               SESSION_STATUS_READY_MASK &&
           (state->status & SESSION_STATUS_TRANSITION_MASK) == 0U &&
           state->active_session != 0U;
}

static int direct_frame_session_matches(const struct session_hw_state *state,
                                        uint32_t metadata_session)
{
    return session_hw_ready(state) && metadata_session != 0U &&
           state->active_session == metadata_session;
}

/* Acquire an atomic PL-side reservation before programming AXI DMA.  Unlike a
 * userspace status check, this closes the interval between the last read and
 * the first MM2S TVALID beat: BTN3 may queue a clear, but the key cannot be
 * removed until this frame reservation is released. */
static int acquire_session_frame(volatile uint32_t *regs)
{
    for (unsigned int retry = 0; retry < 1000U; ++retry) {
        struct session_hw_state state;

        if (retry == 0U) {
            regs[SESSION_REG_CONTROL / 4U] =
                SESSION_CONTROL_FRAME_ACQUIRE;
            __sync_synchronize();
        }
        read_session_hw(regs, &state);
        if ((state.status & SESSION_STATUS_COMMAND_ERROR) != 0U) {
            if (state.status & SESSION_STATUS_FRAME_LOCK) {
                regs[SESSION_REG_CONTROL / 4U] =
                    SESSION_CONTROL_FRAME_RELEASE;
                __sync_synchronize();
            }
            errno = EBUSY;
            return -1;
        }
        if ((state.status & SESSION_STATUS_TRANSITION_MASK) != 0U ||
            (state.status & SESSION_STATUS_READY_MASK) !=
                SESSION_STATUS_READY_MASK) {
            if (state.status & SESSION_STATUS_FRAME_LOCK) {
                regs[SESSION_REG_CONTROL / 4U] =
                    SESSION_CONTROL_FRAME_RELEASE;
                __sync_synchronize();
            }
            errno = EAGAIN;
            return -1;
        }
        if (state.status & SESSION_STATUS_FRAME_LOCK)
            return 0;
    }
    errno = ETIMEDOUT;
    return -1;
}

static int release_session_frame(volatile uint32_t *regs)
{
    regs[SESSION_REG_CONTROL / 4U] = SESSION_CONTROL_FRAME_RELEASE;
    __sync_synchronize();
    for (unsigned int retry = 0; retry < 1000U; ++retry) {
        if ((regs[SESSION_REG_STATUS / 4U] &
             SESSION_STATUS_FRAME_LOCK) == 0U)
            return 0;
    }
    errno = ETIMEDOUT;
    return -1;
}

/* The acquire command is atomic with key commit/clear in PL, but userspace
 * must still verify that it reserved the same session it observed before
 * dequeuing the camera frame.  Once FRAME_LOCK is visible, PL cannot change
 * the active key/session until release. */
static int session_frame_lock_matches(volatile uint32_t *regs,
                                      uint32_t session_id,
                                      uint32_t session_epoch)
{
    struct session_hw_state state;

    read_session_hw(regs, &state);
    return (state.status & SESSION_STATUS_FRAME_LOCK) != 0U &&
           session_hw_ready(&state) &&
           state.active_session == session_id &&
           state.epoch == session_epoch;
}

struct raw_header {
    uint8_t destination[6];
    uint8_t source[6];
    uint16_t ether_type;
    uint8_t version_ihl;
    uint8_t tos;
    uint16_t total_length;
    uint16_t identification;
    uint16_t fragment_offset;
    uint8_t ttl;
    uint8_t protocol;
    uint16_t ip_checksum;
    uint32_t source_ip;
    uint32_t destination_ip;
    uint16_t source_port;
    uint16_t destination_port;
    uint16_t udp_length;
    uint16_t udp_checksum;
} __attribute__((packed));

struct raw_sender {
    int fd;
    struct sockaddr_ll destination;
    uint8_t source_mac[6];
    uint8_t destination_mac[6];
    uint32_t source_ip;
    uint32_t destination_ip;
    uint16_t source_port;
    uint16_t destination_port;
    void *ring;
    size_t ring_length;
    unsigned int ring_frame_count;
    unsigned int ring_next;
    int vnet_header;
};

struct raw_vnet_header {
    struct virtio_net_hdr vnet;
    struct raw_header wire;
};

static uint64_t monotonic_us(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000ULL +
           (uint64_t)now.tv_nsec / 1000ULL;
}

static uint16_t ipv4_checksum(const uint8_t *data, size_t length)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < length; i += 2U)
        sum += ((uint32_t)data[i] << 8) | data[i + 1U];
    while (sum >> 16)
        sum = (sum & 0xffffU) + (sum >> 16);
    return (uint16_t)~sum;
}

/* CHECKSUM_PARTIAL requires the UDP pseudo-header's non-complemented,
 * folded sum in the checksum field.  GEM then adds the UDP header/payload
 * and writes the final one's-complement checksum in hardware. */
static uint16_t udp_pseudo_seed(uint32_t source, uint32_t destination,
                                uint16_t udp_bytes)
{
    const uint8_t *src = (const uint8_t *)&source;
    const uint8_t *dst = (const uint8_t *)&destination;
    uint32_t sum = ((uint32_t)src[0] << 8) | src[1];

    sum += ((uint32_t)src[2] << 8) | src[3];
    sum += ((uint32_t)dst[0] << 8) | dst[1];
    sum += ((uint32_t)dst[2] << 8) | dst[3];
    sum += IPPROTO_UDP;
    sum += udp_bytes;
    while (sum >> 16)
        sum = (sum & 0xffffU) + (sum >> 16);
    return htons((uint16_t)sum);
}

static void on_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int xioctl(int fd, unsigned long request, void *argument)
{
    int result;
    do {
        result = ioctl(fd, request, argument);
    } while (result < 0 && errno == EINTR && !stop_requested);
    return result;
}

static uint32_t load_be32(const uint8_t *data)
{
    uint32_t value;
    memcpy(&value, data, sizeof(value));
    return ntohl(value);
}

static uint16_t load_be16(const uint8_t *data)
{
    uint16_t value;
    memcpy(&value, data, sizeof(value));
    return ntohs(value);
}

static int sync_dmabuf(int dmabuf_fd, uint64_t flags)
{
    struct dma_buf_sync sync = {.flags = flags};
    int result;

    do {
        result = ioctl(dmabuf_fd, DMA_BUF_IOCTL_SYNC, &sync);
    } while (result < 0 && errno == EINTR);
    return result;
}

static void store_be32(uint8_t *data, uint32_t value)
{
    value = htonl(value);
    memcpy(data, &value, sizeof(value));
}

static void store_be16(uint8_t *data, uint16_t value)
{
    value = htons(value);
    memcpy(data, &value, sizeof(value));
}

static int read_bank_header(volatile uint8_t *bram, unsigned int bank,
                            uint8_t header[AAD_BYTES])
{
    size_t base = (size_t)bank * META_BANK_SIZE;
    for (size_t byte = 0; byte < AAD_BYTES; ++byte)
        header[byte] = bram[base + byte];
    __sync_synchronize();
    return load_be32(header) == PACKET_MAGIC ? 0 : -1;
}

static int header_matches(const uint8_t header[AAD_BYTES],
                          uint32_t session_id, uint32_t frame_id)
{
    uint16_t flags = load_be16(header + 14U);
    return load_be32(header) == PACKET_MAGIC &&
           load_be32(header + 4U) == session_id &&
           load_be32(header + 8U) == frame_id &&
           load_be16(header + 12U) == 0U &&
           (flags >> 12) == 1U && (flags & 2U) != 0U;
}

static int copy_metadata_bank(volatile uint8_t *bram, unsigned int bank,
                              uint32_t session_id, uint32_t frame_id,
                              uint8_t *metadata)
{
    uint8_t header[AAD_BYTES], confirm[AAD_BYTES];
    size_t base = (size_t)bank * META_BANK_SIZE;
    unsigned int mode;

    if (read_bank_header(bram, bank, header) < 0 ||
        !header_matches(header, session_id, frame_id))
        return -1;
    mode = load_be16(header + 14U) & 1U;

    for (unsigned int packet = 0; packet < PACKET_COUNT; ++packet) {
        uint8_t *record = metadata + (size_t)packet * RECORD_BYTES;
        uint16_t flags = 0x1000U | (uint16_t)mode;
        size_t tag = base + META_TAG_BASE + (size_t)packet * TAG_BYTES;

        if (packet == 0U)
            flags |= 2U;
        if (packet + 1U == PACKET_COUNT)
            flags |= 4U;
        store_be32(record, PACKET_MAGIC);
        store_be32(record + 4U, session_id);
        store_be32(record + 8U, frame_id);
        store_be16(record + 12U, (uint16_t)packet);
        store_be16(record + 14U, flags);
        {
            const volatile uint32_t *source =
                (const volatile uint32_t *)(bram + tag);
            uint32_t *destination = (uint32_t *)(record + AAD_BYTES);

            destination[0] = source[0];
            destination[1] = source[1];
            destination[2] = source[2];
            destination[3] = source[3];
        }
    }
    __sync_synchronize();
    if (read_bank_header(bram, bank, confirm) < 0 ||
        memcmp(header, confirm, sizeof(header)) != 0)
        return -1;
    return 0;
}

static int wait_and_copy_metadata(volatile uint32_t *gpio,
                                  volatile uint8_t *bram,
                                  uint32_t previous_status,
                                  uint8_t *metadata,
                                  uint32_t *session_id,
                                  uint32_t *frame_id,
                                  uint32_t *new_status)
{
    struct timespec pause_time = {0, 100000};

    for (unsigned int loops = 0; loops <= 20000U && !stop_requested;
         ++loops) {
        uint32_t first = gpio[GPIO2_DATA / 4U];
        __sync_synchronize();
        uint32_t second = gpio[GPIO2_DATA / 4U];
        unsigned int bank;
        uint8_t header[AAD_BYTES];
        uint32_t completed_session;
        uint32_t completed_frame;

        if (first != second || first == previous_status) {
            nanosleep(&pause_time, NULL);
            continue;
        }
        bank = STATUS_BANK(first);
        if (read_bank_header(bram, bank, header) == 0) {
            completed_session = load_be32(header + 4U);
            completed_frame = load_be32(header + 8U);
            if (completed_session != 0U &&
                header_matches(header, completed_session, completed_frame) &&
                copy_metadata_bank(bram, bank, completed_session,
                                   completed_frame, metadata) == 0) {
                *session_id = completed_session;
                *frame_id = completed_frame;
                *new_status = first;
                return 0;
            }
        }
        nanosleep(&pause_time, NULL);
    }
    fprintf(stderr,
            "metadata completion timeout (previous 0x%08x pipeline_health 0x%08x)\n",
            previous_status, gpio[GPIO_DATA / 4U]);
    return -1;
}

struct metadata_worker {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t wake;
    volatile uint32_t *gpio;
    volatile uint8_t *bram;
    uint32_t session_id;
    uint32_t previous_status;
    uint8_t *metadata;
    uint32_t frame_id;
    uint32_t new_status;
    int result;
    int job_pending;
    int job_done;
    int shutting_down;
};

static void *metadata_worker_main(void *opaque)
{
    struct metadata_worker *worker = opaque;
    cpu_set_t affinity;

    CPU_ZERO(&affinity);
    CPU_SET(0, &affinity);
    if (pthread_setaffinity_np(pthread_self(), sizeof(affinity),
                               &affinity) != 0)
        fprintf(stderr, "metadata worker CPU0 affinity failed\n");

    pthread_mutex_lock(&worker->lock);
    while (!worker->shutting_down) {
        uint32_t previous_status;
        uint8_t *metadata;
        uint32_t session_id = 0U;
        uint32_t frame_id = 0U, new_status = 0U;
        int result;

        while (!worker->job_pending && !worker->shutting_down)
            pthread_cond_wait(&worker->wake, &worker->lock);
        if (worker->shutting_down)
            break;
        previous_status = worker->previous_status;
        metadata = worker->metadata;
        pthread_mutex_unlock(&worker->lock);

        result = wait_and_copy_metadata(worker->gpio, worker->bram,
                                        previous_status, metadata,
                                        &session_id,
                                        &frame_id, &new_status);

        pthread_mutex_lock(&worker->lock);
        worker->result = result;
        worker->session_id = session_id;
        worker->frame_id = frame_id;
        worker->new_status = new_status;
        worker->job_pending = 0;
        worker->job_done = 1;
        pthread_cond_broadcast(&worker->wake);
    }
    pthread_mutex_unlock(&worker->lock);
    return NULL;
}

static int metadata_worker_start(struct metadata_worker *worker,
                                 volatile uint32_t *gpio,
                                 volatile uint8_t *bram)
{
    memset(worker, 0, sizeof(*worker));
    worker->gpio = gpio;
    worker->bram = bram;
    if (pthread_mutex_init(&worker->lock, NULL) != 0)
        return -1;
    if (pthread_cond_init(&worker->wake, NULL) != 0) {
        pthread_mutex_destroy(&worker->lock);
        return -1;
    }
    if (pthread_create(&worker->thread, NULL,
                       metadata_worker_main, worker) != 0) {
        pthread_cond_destroy(&worker->wake);
        pthread_mutex_destroy(&worker->lock);
        return -1;
    }
    return 0;
}

static int metadata_worker_submit(struct metadata_worker *worker,
                                  uint32_t previous_status,
                                  uint8_t *metadata)
{
    int result = 0;

    pthread_mutex_lock(&worker->lock);
    if (worker->job_pending || worker->shutting_down) {
        result = -1;
    } else {
        worker->previous_status = previous_status;
        worker->metadata = metadata;
        worker->job_done = 0;
        worker->job_pending = 1;
        pthread_cond_signal(&worker->wake);
    }
    pthread_mutex_unlock(&worker->lock);
    return result;
}

static int metadata_worker_wait(struct metadata_worker *worker,
                                uint32_t *session_id, uint32_t *frame_id,
                                uint32_t *new_status)
{
    int result;

    pthread_mutex_lock(&worker->lock);
    while (!worker->job_done && !worker->shutting_down)
        pthread_cond_wait(&worker->wake, &worker->lock);
    result = worker->shutting_down ? -1 : worker->result;
    if (result == 0) {
        *session_id = worker->session_id;
        *frame_id = worker->frame_id;
        *new_status = worker->new_status;
    }
    pthread_mutex_unlock(&worker->lock);
    return result;
}

static void metadata_worker_stop(struct metadata_worker *worker)
{
    pthread_mutex_lock(&worker->lock);
    worker->shutting_down = 1;
    pthread_cond_broadcast(&worker->wake);
    pthread_mutex_unlock(&worker->lock);
    pthread_join(worker->thread, NULL);
    pthread_cond_destroy(&worker->wake);
    pthread_mutex_destroy(&worker->lock);
}

static void sleep_until_us(uint64_t deadline)
{
    struct timespec value;

    value.tv_sec = (time_t)(deadline / 1000000ULL);
    value.tv_nsec = (long)((deadline % 1000000ULL) * 1000ULL);
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME,
                           &value, NULL) < 0 && errno == EINTR) {
    }
}

static int send_frame(int socket_fd, const uint8_t *frame,
                      const uint8_t *metadata)
{
    struct iovec vectors[SEND_BATCH_MAX * 3U];
    struct mmsghdr messages[SEND_BATCH_MAX];
    uint64_t send_started = monotonic_us();

    if (dump_packet0_requested) {
        int dump_fd = open("/tmp/tx_encrypted_packet0.bin",
                           O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);

        if (dump_fd >= 0) {
            ssize_t written = write(dump_fd, metadata, AAD_BYTES);
            if (written == (ssize_t)AAD_BYTES)
                written = write(dump_fd, frame, PAYLOAD_BYTES);
            if (written == (ssize_t)PAYLOAD_BYTES)
                written = write(dump_fd, metadata + AAD_BYTES, TAG_BYTES);
            if (written != (ssize_t)TAG_BYTES)
                perror("write TX packet-0 dump");
            close(dump_fd);
        } else {
            perror("open TX packet-0 dump");
        }
        dump_packet0_requested = 0;
    }

    if (use_udp_staging) {
        for (unsigned int packet = 0U; packet < PACKET_COUNT; ++packet) {
            const uint8_t *record =
                metadata + (size_t)packet * RECORD_BYTES;
            uint8_t *segment =
                udp_staging + (size_t)packet * UDP_DATA_BYTES;

            memcpy(segment, record, AAD_BYTES);
            memcpy(segment + AAD_BYTES,
                   frame + (size_t)packet * PAYLOAD_BYTES,
                   PAYLOAD_BYTES);
            memcpy(segment + AAD_BYTES + PAYLOAD_BYTES,
                   record + AAD_BYTES, TAG_BYTES);
        }
    }

    if (udp_records_per_datagram > 1U) {
        const unsigned int datagram_count =
            (PACKET_COUNT + udp_records_per_datagram - 1U) /
            udp_records_per_datagram;

        for (unsigned int first = 0U; first < datagram_count;
             first += udp_send_batch) {
            unsigned int count = datagram_count - first;
            unsigned int sent_count = 0U;

            if (count > udp_send_batch)
                count = udp_send_batch;
            memset(messages, 0, sizeof(messages));
            for (unsigned int item = 0U; item < count; ++item) {
                const unsigned int datagram = first + item;
                const unsigned int first_record =
                    datagram * udp_records_per_datagram;
                unsigned int record_count = PACKET_COUNT - first_record;
                struct iovec *iov = &vectors[item * 3U];

                if (record_count > udp_records_per_datagram)
                    record_count = udp_records_per_datagram;
                iov[0].iov_base = udp_staging +
                                  (size_t)first_record * UDP_DATA_BYTES;
                iov[0].iov_len = (size_t)record_count * UDP_DATA_BYTES;
                messages[item].msg_hdr.msg_iov = iov;
                messages[item].msg_hdr.msg_iovlen = 1U;
            }
            while (sent_count < count && !stop_requested) {
                int sent = sendmmsg(socket_fd, &messages[sent_count],
                                    count - sent_count, 0);
                if (sent < 0 && errno == EINTR)
                    continue;
                if (sent <= 0) {
                    perror("aggregated sendmmsg");
                    return -1;
                }
                sent_count += (unsigned int)sent;
            }
            if (send_span_us != 0U)
                sleep_until_us(send_started +
                               send_span_us * (first + count) /
                               datagram_count);
        }
        return stop_requested ? -1 : 0;
    }

    for (unsigned int first = 0U; first < PACKET_COUNT;
         first += use_udp_gso ? udp_gso_batch : udp_send_batch) {
        uint8_t gso_buffer[SEND_BATCH * UDP_DATA_BYTES];
        unsigned int count = PACKET_COUNT - first;
        unsigned int sent_count = 0;
        if (count > (use_udp_gso ? udp_gso_batch : udp_send_batch))
            count = use_udp_gso ? udp_gso_batch : udp_send_batch;
        memset(messages, 0, sizeof(messages));

        for (unsigned int item = 0; item < count; ++item) {
            unsigned int packet = first + item;
            const uint8_t *record =
                metadata + (size_t)packet * RECORD_BYTES;
            struct iovec *iov = &vectors[item * 3U];

            if (use_udp_staging) {
                iov[0].iov_base = udp_staging +
                                  (size_t)packet * UDP_DATA_BYTES;
                iov[0].iov_len = UDP_DATA_BYTES;
                messages[item].msg_hdr.msg_iov = iov;
                messages[item].msg_hdr.msg_iovlen = 1U;
                continue;
            }

            iov[0].iov_base = (void *)record;
            iov[0].iov_len = AAD_BYTES;
            iov[1].iov_base = (void *)(frame +
                              (size_t)packet * PAYLOAD_BYTES);
            iov[1].iov_len = PAYLOAD_BYTES;
            iov[2].iov_base = (void *)(record + AAD_BYTES);
            iov[2].iov_len = TAG_BYTES;
            messages[item].msg_hdr.msg_iov = iov;
            messages[item].msg_hdr.msg_iovlen = 3;

            if (use_udp_gso) {
                uint8_t *segment = gso_buffer +
                                   (size_t)item * UDP_DATA_BYTES;
                memcpy(segment, record, AAD_BYTES);
                memcpy(segment + AAD_BYTES,
                       frame + (size_t)packet * PAYLOAD_BYTES,
                       PAYLOAD_BYTES);
                memcpy(segment + AAD_BYTES + PAYLOAD_BYTES,
                       record + AAD_BYTES, TAG_BYTES);
            }
        }

        if (use_udp_gso) {
            ssize_t sent;
            size_t bytes = (size_t)count * UDP_DATA_BYTES;

            do {
                sent = send(socket_fd, gso_buffer, bytes, 0);
            } while (sent < 0 && errno == EINTR);
            if (sent != (ssize_t)bytes) {
                perror("UDP GSO send");
                return -1;
            }
        } else {
            while (sent_count < count && !stop_requested) {
                int sent = sendmmsg(socket_fd, &messages[sent_count],
                                    count - sent_count, 0);
                if (sent < 0 && errno == EINTR)
                    continue;
                if (sent <= 0) {
                    perror("sendmmsg");
                    return -1;
                }
                sent_count += (unsigned int)sent;
            }
        }

        if (send_span_us != 0U)
            sleep_until_us(send_started +
                           send_span_us * (first + count) / PACKET_COUNT);

    }

    return stop_requested ? -1 : 0;
}

static int send_frame_raw(struct raw_sender *sender, const uint8_t *frame,
                          const uint8_t *metadata);

static int setup_raw_sender(struct raw_sender *sender, int udp_fd,
                            const struct sockaddr_in *peer)
{
    struct sockaddr_in local = {0};
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *item;
    struct ifreq request;
    struct arpreq arp;
    socklen_t local_length = sizeof(local);
    char interface_name[IFNAMSIZ] = {0};
    int control_fd = -1;
    int one = 1;

    sender->fd = -1;
    sender->ring = MAP_FAILED;
    sender->ring_length = 0U;
    sender->ring_frame_count = 0U;
    sender->ring_next = 0U;
    sender->vnet_header = 0;
    if (getsockname(udp_fd, (struct sockaddr *)&local, &local_length) < 0) {
        perror("RAW_UDP getsockname");
        return -1;
    }
    if (getifaddrs(&interfaces) < 0) {
        perror("RAW_UDP getifaddrs");
        return -1;
    }
    for (item = interfaces; item; item = item->ifa_next) {
        struct sockaddr_in *address;
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
            (item->ifa_flags & IFF_LOOPBACK))
            continue;
        address = (struct sockaddr_in *)item->ifa_addr;
        if (address->sin_addr.s_addr == local.sin_addr.s_addr) {
            snprintf(interface_name, sizeof(interface_name), "%s",
                     item->ifa_name);
            break;
        }
    }
    freeifaddrs(interfaces);
    if (!interface_name[0]) {
        fprintf(stderr, "RAW_UDP could not match local IPv4 interface\n");
        return -1;
    }

    control_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (control_fd < 0) {
        perror("RAW_UDP control socket");
        return -1;
    }
    memset(&request, 0, sizeof(request));
    snprintf(request.ifr_name, sizeof(request.ifr_name), "%s",
             interface_name);
    if (ioctl(control_fd, SIOCGIFINDEX, &request) < 0) {
        perror("RAW_UDP SIOCGIFINDEX");
        goto failure;
    }
    sender->destination.sll_ifindex = request.ifr_ifindex;
    if (ioctl(control_fd, SIOCGIFHWADDR, &request) < 0) {
        perror("RAW_UDP SIOCGIFHWADDR");
        goto failure;
    }
    memcpy(sender->source_mac, request.ifr_hwaddr.sa_data, 6U);

    memset(&arp, 0, sizeof(arp));
    memcpy(&arp.arp_pa, peer, sizeof(*peer));
    snprintf(arp.arp_dev, sizeof(arp.arp_dev), "%s", interface_name);
    for (unsigned int retry = 0; retry < 20U; ++retry) {
        if (ioctl(control_fd, SIOCGARP, &arp) == 0 &&
            (arp.arp_flags & ATF_COM))
            break;
        usleep(10000U);
    }
    if (!(arp.arp_flags & ATF_COM)) {
        fprintf(stderr, "RAW_UDP unresolved ARP for %s\n",
                inet_ntoa(peer->sin_addr));
        goto failure;
    }
    memcpy(sender->destination_mac, arp.arp_ha.sa_data, 6U);
    close(control_fd);
    control_fd = -1;

    sender->fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC, htons(0x0800));
    if (sender->fd < 0) {
        perror("RAW_UDP AF_PACKET socket");
        return -1;
    }
    memset(&sender->destination, 0, sizeof(sender->destination));
    sender->destination.sll_family = AF_PACKET;
    sender->destination.sll_protocol = htons(0x0800);
    sender->destination.sll_ifindex = if_nametoindex(interface_name);
    sender->destination.sll_halen = 6U;
    memcpy(sender->destination.sll_addr, sender->destination_mac, 6U);
    setsockopt(sender->fd, SOL_PACKET, PACKET_QDISC_BYPASS,
               &one, sizeof(one));
    if (getenv("PCAM_RAW_HW_CSUM") &&
        strcmp(getenv("PCAM_RAW_HW_CSUM"), "1") == 0 &&
        !(getenv("PCAM_TX_RING") &&
          strcmp(getenv("PCAM_TX_RING"), "1") == 0)) {
        if (setsockopt(sender->fd, SOL_PACKET, PACKET_VNET_HDR,
                       &one, sizeof(one)) < 0) {
            fprintf(stderr, "PACKET_VNET_HDR setup: %s\n",
                    strerror(errno));
        } else {
            sender->vnet_header = 1;
            fprintf(stderr,
                    "RAW_UDP GEM checksum/FCS offload enabled\n");
        }
    }
    sender->source_ip = local.sin_addr.s_addr;
    sender->destination_ip = peer->sin_addr.s_addr;
    sender->source_port = local.sin_port;
    sender->destination_port = peer->sin_port;
    if (getenv("PCAM_TX_RING") &&
        strcmp(getenv("PCAM_TX_RING"), "1") == 0) {
        int version = TPACKET_V2;
        struct tpacket_req request_ring = {
            .tp_block_size = TX_RING_BLOCK_SIZE,
            .tp_block_nr = TX_RING_BLOCK_COUNT,
            .tp_frame_size = TX_RING_FRAME_SIZE,
            .tp_frame_nr = TX_RING_BLOCK_SIZE * TX_RING_BLOCK_COUNT /
                           TX_RING_FRAME_SIZE,
        };

        if (setsockopt(sender->fd, SOL_PACKET, PACKET_VERSION,
                       &version, sizeof(version)) < 0 ||
            setsockopt(sender->fd, SOL_PACKET, PACKET_TX_RING,
                       &request_ring, sizeof(request_ring)) < 0 ||
            bind(sender->fd, (struct sockaddr *)&sender->destination,
                 sizeof(sender->destination)) < 0) {
            fprintf(stderr, "PACKET_TX_RING setup: %s\n", strerror(errno));
            close(sender->fd);
            sender->fd = -1;
            return -1;
        }
        sender->ring_length = (size_t)request_ring.tp_block_size *
                              request_ring.tp_block_nr;
        sender->ring = mmap(NULL, sender->ring_length,
                            PROT_READ | PROT_WRITE, MAP_SHARED,
                            sender->fd, 0);
        if (sender->ring == MAP_FAILED) {
            fprintf(stderr, "PACKET_TX_RING mmap: %s\n", strerror(errno));
            close(sender->fd);
            sender->fd = -1;
            return -1;
        }
        sender->ring_frame_count = request_ring.tp_frame_nr;
        fprintf(stderr,
                "PACKET_TX_RING %u frames x %u bytes, paced %llu us\n",
                sender->ring_frame_count, TX_RING_FRAME_SIZE,
                (unsigned long long)send_span_us);
    }
    fprintf(stderr,
            "RAW_UDP interface=%s src=%02x:%02x:%02x:%02x:%02x:%02x dst=%02x:%02x:%02x:%02x:%02x:%02x\n",
            interface_name,
            sender->source_mac[0], sender->source_mac[1],
            sender->source_mac[2], sender->source_mac[3],
            sender->source_mac[4], sender->source_mac[5],
            sender->destination_mac[0], sender->destination_mac[1],
            sender->destination_mac[2], sender->destination_mac[3],
            sender->destination_mac[4], sender->destination_mac[5]);
    return 0;

failure:
    if (control_fd >= 0)
        close(control_fd);
    return -1;
}

static int send_frame_ring(struct raw_sender *sender, const uint8_t *frame,
                           const uint8_t *metadata)
{
    const unsigned int data_offset =
        TPACKET2_HDRLEN - sizeof(struct sockaddr_ll);
    const unsigned int wire_bytes = sizeof(struct raw_header) +
                                    UDP_DATA_BYTES;
    uint32_t frame_id = load_be32(metadata + 8U);
    uint64_t send_started = monotonic_us();

    for (unsigned int first = 0U; first < PACKET_COUNT;
         first += SEND_BATCH) {
        unsigned int count = PACKET_COUNT - first;
        if (count > SEND_BATCH)
            count = SEND_BATCH;

        for (unsigned int item = 0U; item < count; ++item) {
            unsigned int packet = first + item;
            unsigned int ring_index = sender->ring_next %
                                      sender->ring_frame_count;
            struct tpacket2_hdr *packet_header =
                (struct tpacket2_hdr *)((uint8_t *)sender->ring +
                    (size_t)ring_index * TX_RING_FRAME_SIZE);
            uint8_t *wire = (uint8_t *)packet_header + data_offset;
            struct raw_header *header = (struct raw_header *)wire;
            const uint8_t *record = metadata +
                                    (size_t)packet * RECORD_BYTES;

            while (__atomic_load_n(&packet_header->tp_status,
                                   __ATOMIC_ACQUIRE) !=
                   TP_STATUS_AVAILABLE) {
                if (stop_requested)
                    return -1;
                sched_yield();
            }

            memset(header, 0, sizeof(*header));
            memcpy(header->destination, sender->destination_mac, 6U);
            memcpy(header->source, sender->source_mac, 6U);
            header->ether_type = htons(0x0800);
            header->version_ihl = 0x45U;
            header->total_length = htons(20U + 8U + UDP_DATA_BYTES);
            header->identification = htons((uint16_t)(
                frame_id * PACKET_COUNT + packet));
            header->fragment_offset = htons(0x4000U);
            header->ttl = 64U;
            header->protocol = IPPROTO_UDP;
            header->source_ip = sender->source_ip;
            header->destination_ip = sender->destination_ip;
            header->source_port = sender->source_port;
            header->destination_port = sender->destination_port;
            header->udp_length = htons(8U + UDP_DATA_BYTES);
            header->ip_checksum = htons(ipv4_checksum(
                ((const uint8_t *)header) + 14U, 20U));
            memcpy(wire + sizeof(*header), record, AAD_BYTES);
            memcpy(wire + sizeof(*header) + AAD_BYTES,
                   frame + (size_t)packet * PAYLOAD_BYTES,
                   PAYLOAD_BYTES);
            memcpy(wire + sizeof(*header) + AAD_BYTES + PAYLOAD_BYTES,
                   record + AAD_BYTES, TAG_BYTES);

            packet_header->tp_len = wire_bytes;
            packet_header->tp_snaplen = wire_bytes;
            packet_header->tp_mac = data_offset;
            packet_header->tp_net = data_offset + 14U;
            __atomic_store_n(&packet_header->tp_status,
                             TP_STATUS_SEND_REQUEST, __ATOMIC_RELEASE);
            ++sender->ring_next;
        }

        if (send(sender->fd, NULL, 0, MSG_DONTWAIT) < 0 &&
            errno != EAGAIN && errno != ENOBUFS) {
            perror("PACKET_TX_RING kick");
            return -1;
        }
        if (send_span_us != 0U)
            sleep_until_us(send_started +
                           send_span_us * (first + count) / PACKET_COUNT);
    }
    (void)send_started;
    return stop_requested ? -1 : 0;
}

static int send_frame_raw(struct raw_sender *sender, const uint8_t *frame,
                          const uint8_t *metadata)
{
    struct raw_vnet_header vnet_headers[SEND_BATCH];
    struct raw_header headers[SEND_BATCH];
    struct iovec vectors[SEND_BATCH * 4U];
    struct mmsghdr messages[SEND_BATCH];
    uint32_t frame_id = load_be32(metadata + 8U);

    if (sender->ring != MAP_FAILED)
        return send_frame_ring(sender, frame, metadata);

    for (unsigned int first = 0; first < PACKET_COUNT;
         first += SEND_BATCH) {
        unsigned int count = PACKET_COUNT - first;
        unsigned int sent_count = 0;
        if (count > SEND_BATCH)
            count = SEND_BATCH;
        memset(messages, 0, sizeof(messages));

        for (unsigned int item = 0; item < count; ++item) {
            unsigned int packet = first + item;
            const uint8_t *record = metadata +
                                    (size_t)packet * RECORD_BYTES;
            struct raw_header *header = sender->vnet_header ?
                &vnet_headers[item].wire : &headers[item];
            struct iovec *iov = &vectors[item * 4U];

            memset(header, 0, sizeof(*header));
            memcpy(header->destination, sender->destination_mac, 6U);
            memcpy(header->source, sender->source_mac, 6U);
            header->ether_type = htons(0x0800);
            header->version_ihl = 0x45U;
            header->total_length = htons(20U + 8U + UDP_DATA_BYTES);
            header->identification = htons((uint16_t)(
                frame_id * PACKET_COUNT + packet));
            header->fragment_offset = htons(0x4000U);
            header->ttl = 64U;
            header->protocol = IPPROTO_UDP;
            header->source_ip = sender->source_ip;
            header->destination_ip = sender->destination_ip;
            header->source_port = sender->source_port;
            header->destination_port = sender->destination_port;
            header->udp_length = htons(8U + UDP_DATA_BYTES);
            if (sender->vnet_header) {
                struct virtio_net_hdr *vnet = &vnet_headers[item].vnet;

                memset(vnet, 0, sizeof(*vnet));
                vnet->flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
                vnet->gso_type = VIRTIO_NET_HDR_GSO_NONE;
                vnet->hdr_len = sizeof(*header);
                vnet->csum_start = 14U + 20U;
                vnet->csum_offset = 6U;
                header->udp_checksum = udp_pseudo_seed(
                    header->source_ip, header->destination_ip,
                    8U + UDP_DATA_BYTES);
            }
            header->ip_checksum = htons(ipv4_checksum(
                ((const uint8_t *)header) + 14U, 20U));

            iov[0].iov_base = sender->vnet_header ?
                (void *)&vnet_headers[item] : (void *)header;
            iov[0].iov_len = sizeof(*header) +
                (sender->vnet_header ? sizeof(struct virtio_net_hdr) : 0U);
            iov[1].iov_base = (void *)record;
            iov[1].iov_len = AAD_BYTES;
            iov[2].iov_base = (void *)(frame +
                              (size_t)packet * PAYLOAD_BYTES);
            iov[2].iov_len = PAYLOAD_BYTES;
            iov[3].iov_base = (void *)(record + AAD_BYTES);
            iov[3].iov_len = TAG_BYTES;
            messages[item].msg_hdr.msg_name = &sender->destination;
            messages[item].msg_hdr.msg_namelen =
                sizeof(sender->destination);
            messages[item].msg_hdr.msg_iov = iov;
            messages[item].msg_hdr.msg_iovlen = 4U;
        }
        while (sent_count < count && !stop_requested) {
            int sent = sendmmsg(sender->fd, &messages[sent_count],
                                count - sent_count, 0);
            if (sent < 0 && errno == EINTR)
                continue;
            if (sent < 0 && (errno == ENOBUFS || errno == EAGAIN)) {
                /*
                 * PACKET_QDISC_BYPASS can report transient TX-ring
                 * backpressure even on a healthy full-duplex link.  Dropping
                 * out here stops the whole camera service; yield until GEM
                 * releases descriptors and retry the same unsent batch.
                 */
                sched_yield();
                continue;
            }
            if (sent < 0 && (errno == ENETDOWN ||
                             errno == ENETUNREACH ||
                             errno == EHOSTUNREACH)) {
                /* Keep the stream alive across a short PHY/autoneg flap. */
                usleep(1000U);
                continue;
            }
            if (sent <= 0) {
                perror("raw sendmmsg");
                return -1;
            }
            sent_count += (unsigned int)sent;
        }
    }
    return stop_requested ? -1 : 0;
}

static int persist_runtime_rx_peer(const struct sockaddr_in *peer)
{
    const char *path = getenv("PCAM_RX_PEER_FILE");
    char text[INET_ADDRSTRLEN + 2U];
    int fd;
    int length;

    if (path == NULL || *path == '\0')
        path = "/run/aes-gcm-rx-peer";
    if (inet_ntop(AF_INET, &peer->sin_addr, text, sizeof(text)) == NULL)
        return -1;
    length = snprintf(text + strlen(text), sizeof(text) - strlen(text), "\n");
    if (length <= 0)
        return -1;
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
              0600);
    if (fd < 0)
        return -1;
    if (write(fd, text, strlen(text)) != (ssize_t)strlen(text)) {
        close(fd);
        return -1;
    }
    return close(fd);
}

static int discover_runtime_rx_peer(unsigned int port)
{
    static const char expected[] = "PCAM-GCM-RX";
    struct sockaddr_in local = {0}, peer = {0};
    socklen_t peer_length = sizeof(peer);
    char hello[32];
    int fd;
    ssize_t received;

    if (port == 0U || port > 65535U)
        return -1;
    fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
        close(fd);
        return -1;
    }
    do {
        received = recvfrom(fd, hello, sizeof(hello), 0,
                            (struct sockaddr *)&peer, &peer_length);
    } while (received < 0 && errno == EINTR);
    close(fd);
    if (received != (ssize_t)(sizeof(expected) - 1U) ||
        memcmp(hello, expected, sizeof(expected) - 1U) != 0)
        return -1;
    if (persist_runtime_rx_peer(&peer) < 0)
        return -1;
    fprintf(stderr, "PCAM_GCM_DISCOVERED_RX %s:%u\n",
            inet_ntoa(peer.sin_addr), ntohs(peer.sin_port));
    return 0;
}

int main(int argc, char **argv)
{
    const char *video_path = argc > 2 ? argv[2] : "/dev/video0";
    int port = argc > 1 ? atoi(argv[1]) : DEFAULT_PORT;
    uint32_t session_id = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 0U;
    int video_fd = -1, socket_fd = -1;
    int mem_fd = -1;
    struct sockaddr_in peer = {0};
    struct raw_sender raw = {.fd = -1, .ring = MAP_FAILED};
    int streaming = 0, result = EXIT_FAILURE;
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    int video_dmabuf[VIDEO_BUFFERS] = {-1, -1, -1, -1};
    uint8_t *video_input[VIDEO_BUFFERS] = {
        MAP_FAILED, MAP_FAILED, MAP_FAILED, MAP_FAILED
    };
    size_t video_input_length[VIDEO_BUFFERS] = {0U, 0U, 0U, 0U};
    unsigned int mapped_count = 0;
    uint8_t *metadata[2] = {NULL, NULL};
    volatile uint32_t *gpio = MAP_FAILED;
    volatile uint8_t *bram = MAP_FAILED;
    volatile uint32_t *session_regs = MAP_FAILED;
    uint32_t last_status;
    uint64_t timing_dq = 0, timing_copy = 0;
    uint64_t timing_meta = 0, timing_send = 0, timing_qbuf = 0;
    uint64_t timing_total = 0;
    unsigned int timing_frames = 0;
    unsigned int next_slot = 0;
    uint32_t session_epoch = 0U;
    uint32_t sequence_to_frame = 0U;
    int sequence_offset_valid = 0;
    struct metadata_worker metadata_thread;
    int metadata_thread_started = 0;
    int dump_pipeline_requested = getenv("PCAM_DUMP_PIPELINE") &&
                                  strcmp(getenv("PCAM_DUMP_PIPELINE"),
                                         "1") == 0;
    long dump_pipeline_frame = -1;
    long dump_pipeline_after = -1;
    unsigned long dump_pipeline_seen = 0U;

    if (argc > 1 && strcmp(argv[1], "--discover-peer") == 0) {
        unsigned long discovery_port = argc > 2 ?
            strtoul(argv[2], NULL, 0) : DEFAULT_PORT;
        return discover_runtime_rx_peer((unsigned int)discovery_port) == 0 ?
            EXIT_SUCCESS : EXIT_FAILURE;
    }

    if (getenv("PCAM_DUMP_FRAME_ID")) {
        dump_pipeline_frame = strtol(getenv("PCAM_DUMP_FRAME_ID"),
                                     NULL, 0);
        dump_pipeline_requested = dump_pipeline_frame >= 0;
    }
    if (getenv("PCAM_DUMP_AFTER")) {
        dump_pipeline_after = strtol(getenv("PCAM_DUMP_AFTER"), NULL, 0);
        dump_pipeline_requested = dump_pipeline_after >= 0;
    }

    if (port <= 0 || port > 65535) {
        fprintf(stderr, "invalid UDP port\n");
        return EXIT_FAILURE;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    {
        cpu_set_t affinity;
        CPU_ZERO(&affinity);
        CPU_SET(1, &affinity);
        if (sched_setaffinity(0, sizeof(affinity), &affinity) < 0)
            perror("sched_setaffinity CPU1");
        else
            fprintf(stderr, "TX process pinned to CPU1\n");
    }

    mem_fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (mem_fd < 0) {
        perror("open /dev/mem");
        goto cleanup;
    }
    {
        uint32_t active_session;
        uint32_t session_status;

        session_regs = mmap(NULL, SESSION_REG_SIZE, PROT_READ | PROT_WRITE,
                            MAP_SHARED,
                            mem_fd, SESSION_REG_BASE);
        if (session_regs == MAP_FAILED) {
            perror("mmap AES session registers");
            goto cleanup;
        }
        if (session_regs[SESSION_REG_ID / 4U] != SESSION_REG_MAGIC) {
            fprintf(stderr, "AES session register ID is invalid\n");
            goto cleanup;
        }
        /* Recover a reservation left by a previously killed userspace
         * process before validating the active session. */
        if (release_session_frame(session_regs) < 0) {
            perror("release stale AES frame reservation");
            goto cleanup;
        }
        active_session = session_regs[SESSION_REG_ACTIVE_ID / 4U];
        session_status = session_regs[SESSION_REG_STATUS / 4U];
        if (
            (session_status & 3U) != 3U || active_session == 0U) {
            fprintf(stderr, "AES session registers are not ready\n");
            goto cleanup;
        }
        if (session_id != 0U && session_id != active_session) {
            fprintf(stderr,
                    "requested session 0x%08x differs from active PL session 0x%08x\n",
                    session_id, active_session);
            goto cleanup;
        }
        session_id = active_session;
        session_epoch =
            session_regs[SESSION_REG_EPOCH / 4U] & 0xffffU;
    }
    gpio = mmap(NULL, META_GPIO_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                mem_fd, META_GPIO_BASE);
    bram = mmap(NULL, META_BRAM_SIZE, PROT_READ, MAP_SHARED,
                mem_fd, META_BRAM_BASE);
    if (gpio == MAP_FAILED || bram == MAP_FAILED) {
        perror("mmap TX hardware");
        goto cleanup;
    }
    fprintf(stderr,
            "TX_PL_DIRECT=1 path=MIPI->PL_AES_GCM->V4L2_DDR->PS_UDP\n");
    fprintf(stderr,
            "PLAINTEXT_DDR_PRE_GCM=0 (SW3 bypass remains an explicit demo mode)\n");
    gpio[GPIO_TRI / 4U] = 0xffffffffU;
    gpio[GPIO2_TRI / 4U] = 0xffffffffU;
    __sync_synchronize();
    last_status = gpio[GPIO2_DATA / 4U];
    fprintf(stderr, "PCAM_GCM_SESSION 0x%08x\n", session_id);

    metadata[0] = malloc(METADATA_BYTES);
    metadata[1] = malloc(METADATA_BYTES);
    video_fd = open(video_path, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (!metadata[0] || !metadata[1] || video_fd < 0) {
        perror("allocate/open video");
        goto cleanup;
    }
    {
        struct v4l2_format format = {0};
        format.type = type;
        format.fmt.pix_mp.width = WIDTH;
        format.fmt.pix_mp.height = HEIGHT;
        format.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_YUYV;
        format.fmt.pix_mp.field = V4L2_FIELD_NONE;
        format.fmt.pix_mp.num_planes = 1;
        format.fmt.pix_mp.plane_fmt[0].bytesperline = WIDTH * 2U;
        format.fmt.pix_mp.plane_fmt[0].sizeimage = FRAME_BYTES;
        if (xioctl(video_fd, VIDIOC_S_FMT, &format) < 0) {
            perror("VIDIOC_S_FMT");
            goto cleanup;
        }
    }
    {
        struct v4l2_requestbuffers request = {0};
        request.count = VIDEO_BUFFERS;
        request.type = type;
        request.memory = V4L2_MEMORY_MMAP;
        if (xioctl(video_fd, VIDIOC_REQBUFS, &request) < 0 ||
            request.count < 2 || request.count > VIDEO_BUFFERS) {
            perror("VIDIOC_REQBUFS");
            goto cleanup;
        }
        mapped_count = request.count;
    }
    for (unsigned int i = 0; i < mapped_count; ++i) {
        struct v4l2_exportbuffer export_buffer = {0};
        struct v4l2_plane plane = {0};
        struct v4l2_buffer buffer = {0};
        buffer.type = type;
        buffer.memory = V4L2_MEMORY_MMAP;
        buffer.index = i;
        buffer.length = 1;
        buffer.m.planes = &plane;
        if (xioctl(video_fd, VIDIOC_QUERYBUF, &buffer) < 0)
            goto cleanup;
        video_input_length[i] = plane.length;
        video_input[i] = mmap(NULL, video_input_length[i],
                              PROT_READ, MAP_SHARED, video_fd,
                              plane.m.mem_offset);
        if (video_input[i] == MAP_FAILED) {
            perror("mmap PL-direct V4L2 buffer");
            goto cleanup;
        }
        export_buffer.type = type;
        export_buffer.index = i;
        export_buffer.plane = 0;
        export_buffer.flags = O_RDWR | O_CLOEXEC;
        if (xioctl(video_fd, VIDIOC_EXPBUF, &export_buffer) < 0) {
            perror("VIDIOC_EXPBUF");
            goto cleanup;
        }
        video_dmabuf[i] = export_buffer.fd;
        fprintf(stderr,
                "V4L2 buffer %u mapped as PL-produced frame DMA-BUF\n", i);
        if (xioctl(video_fd, VIDIOC_QBUF, &buffer) < 0)
            goto cleanup;
    }

    socket_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (socket_fd < 0)
        goto cleanup;
    {
        int size = 8 * 1024 * 1024;
        struct sockaddr_in local = {0};
        socklen_t peer_length = sizeof(peer);
        char hello[32];
        setsockopt(socket_fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
        if (getenv("PCAM_UDP_NOCHECK") &&
            strcmp(getenv("PCAM_UDP_NOCHECK"), "1") == 0) {
            int one = 1;

            if (setsockopt(socket_fd, SOL_SOCKET, SO_NO_CHECK,
                           &one, sizeof(one)) < 0) {
                fprintf(stderr, "SO_NO_CHECK unavailable: %s\n",
                        strerror(errno));
            } else {
                fprintf(stderr, "IPv4 UDP checksum disabled\n");
            }
        }
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_ANY);
        local.sin_port = htons((uint16_t)port);
        if (bind(socket_fd, (struct sockaddr *)&local, sizeof(local)) < 0)
            goto cleanup;
        fprintf(stderr, "PCAM_GCM_LISTEN %d\n", port);
        if (recvfrom(socket_fd, hello, sizeof(hello), 0,
                     (struct sockaddr *)&peer, &peer_length) < 0 ||
            connect(socket_fd, (struct sockaddr *)&peer, peer_length) < 0)
            goto cleanup;
        fprintf(stderr, "PCAM_GCM_CLIENT %s:%u\n", inet_ntoa(peer.sin_addr),
                ntohs(peer.sin_port));
        if (persist_runtime_rx_peer(&peer) < 0)
            fprintf(stderr, "warning: could not persist runtime RX peer: %s\n",
                    strerror(errno));
        if (getenv("PCAM_DUMP_PACKET0") &&
            strcmp(getenv("PCAM_DUMP_PACKET0"), "1") == 0)
            dump_packet0_requested = 1;
        {
            const char *batch_text = getenv("PCAM_SEND_BATCH");
            unsigned long requested = batch_text ?
                strtoul(batch_text, NULL, 0) : SEND_BATCH;

            if (requested < 1U)
                requested = 1U;
            if (requested > SEND_BATCH_MAX)
                requested = SEND_BATCH_MAX;
            udp_send_batch = (unsigned int)requested;
        }
        {
            const char *span_text = getenv("PCAM_SEND_SPAN_US");

            if (span_text)
                send_span_us = strtoull(span_text, NULL, 0);
        }
        {
            const char *aggregate_text = getenv("PCAM_UDP_AGGREGATE");
            unsigned long requested = aggregate_text ?
                strtoul(aggregate_text, NULL, 0) : 1U;

            if (requested < 1U)
                requested = 1U;
            if (requested > 3U)
                requested = 3U;
            udp_records_per_datagram = (unsigned int)requested;
        }
        if (udp_records_per_datagram > 1U) {
            int discovery = IP_PMTUDISC_DONT;

            if (setsockopt(socket_fd, IPPROTO_IP, IP_MTU_DISCOVER,
                           &discovery, sizeof(discovery)) < 0) {
                perror("disable IPv4 path-MTU discovery");
                goto cleanup;
            }
            fprintf(stderr,
                    "IPv4 fragmentation enabled for aggregated UDP\n");
        }
        if ((getenv("PCAM_UDP_STAGING") &&
             strcmp(getenv("PCAM_UDP_STAGING"), "1") == 0) ||
            udp_records_per_datagram > 1U) {
            udp_staging = malloc((size_t)PACKET_COUNT * UDP_DATA_BYTES);
            if (!udp_staging) {
                perror("allocate UDP staging frame");
                goto cleanup;
            }
            use_udp_staging = 1;
            fprintf(stderr, "UDP contiguous staging enabled\n");
        }
        if (getenv("PCAM_UDP_GSO") &&
            strcmp(getenv("PCAM_UDP_GSO"), "1") == 0) {
            int segment_bytes = UDP_DATA_BYTES;
            const char *batch_text = getenv("PCAM_GSO_BATCH");
            unsigned long requested = batch_text ?
                strtoul(batch_text, NULL, 0) : SEND_BATCH;

            if (requested < 1U)
                requested = 1U;
            if (requested > SEND_BATCH)
                requested = SEND_BATCH;
            udp_gso_batch = (unsigned int)requested;
            if (setsockopt(socket_fd, IPPROTO_UDP, UDP_SEGMENT,
                           &segment_bytes, sizeof(segment_bytes)) == 0) {
                use_udp_gso = 1;
                fprintf(stderr, "UDP GSO %u x %u-byte segments\n",
                        udp_gso_batch, UDP_DATA_BYTES);
            } else {
                fprintf(stderr, "UDP GSO unavailable: %s\n",
                        strerror(errno));
            }
        }
        fprintf(stderr,
                "UDP %s batch=%u paced %llu us\n",
                use_udp_gso ? "GSO" : "sendmmsg",
                use_udp_gso ? udp_gso_batch : udp_send_batch,
                (unsigned long long)send_span_us);
        if (udp_records_per_datagram > 1U)
            fprintf(stderr,
                    "UDP jumbo aggregation %u AES records/datagram (%u bytes)\n",
                    udp_records_per_datagram,
                    udp_records_per_datagram * UDP_DATA_BYTES);
        if (getenv("PCAM_RAW_UDP") &&
            strcmp(getenv("PCAM_RAW_UDP"), "1") == 0 &&
            setup_raw_sender(&raw, socket_fd, &peer) < 0)
            fprintf(stderr, "warning: raw UDP setup failed; using UDP socket\n");
    }

    if (metadata_worker_start(&metadata_thread, gpio, bram) < 0) {
        fprintf(stderr, "start metadata worker failed\n");
        goto cleanup;
    }
    metadata_thread_started = 1;
    fprintf(stderr, "AES metadata worker pinned to CPU0\n");
    if (xioctl(video_fd, VIDIOC_STREAMON, &type) < 0)
        goto cleanup;
    streaming = 1;
    /* STREAMON may pulse the shared frame-buffer/crypto runtime reset.  Use
     * the post-reset completion token, not the value sampled during process
     * setup, so stale BRAM from a previous service instance is never paired
     * with the first new V4L2 frame. */
    for (unsigned int retry = 0; retry < 1000U; ++retry) {
        uint32_t first = gpio[GPIO2_DATA / 4U];
        __sync_synchronize();
        uint32_t second = gpio[GPIO2_DATA / 4U];

        if (first == second) {
            last_status = first;
            break;
        }
    }
    fprintf(stderr, "TX_PL_DIRECT_BASELINE status=0x%08x\n", last_status);
    if (metadata_worker_submit(&metadata_thread, last_status,
                               metadata[next_slot]) < 0) {
        fprintf(stderr, "initial metadata worker submit failed\n");
        goto cleanup;
    }

    while (!stop_requested) {
        struct v4l2_plane plane = {0};
        struct v4l2_buffer buffer = {0};
        uint32_t status = 0U, meta_session = 0U, meta_frame = 0U;
        unsigned int slot = next_slot;
        uint64_t loop_start = monotonic_us();
        uint64_t stamp = loop_start;
        int frame_lock_held = 0;

        buffer.type = type;
        buffer.memory = V4L2_MEMORY_MMAP;
        buffer.length = 1;
        buffer.m.planes = &plane;
        {
            struct pollfd camera_event = {
                .fd = video_fd,
                .events = POLLIN | POLLPRI,
            };
            int poll_result;

            do {
                poll_result = poll(&camera_event, 1, VIDEO_FRAME_TIMEOUT_MS);
            } while (poll_result < 0 && errno == EINTR && !stop_requested);
            if (poll_result == 0) {
                fprintf(stderr,
                        "V4L2 frame timeout; restarting camera pipeline\n");
                errno = ETIMEDOUT;
                break;
            }
            if (poll_result < 0) {
                if (!stop_requested)
                    perror("poll V4L2 frame");
                break;
            }
            if (camera_event.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                fprintf(stderr, "V4L2 poll error 0x%x\n",
                        camera_event.revents);
                errno = EIO;
                break;
            }
            if (xioctl(video_fd, VIDIOC_DQBUF, &buffer) < 0) {
                if (errno == EAGAIN)
                    continue;
                if (!stop_requested)
                    perror("VIDIOC_DQBUF");
                break;
            }
        }
        timing_dq += monotonic_us() - stamp;
        if ((plane.bytesused ? plane.bytesused : FRAME_BYTES) != FRAME_BYTES) {
            fprintf(stderr, "unexpected PL-direct V4L2 frame size\n");
            break;
        }
        {
            uint32_t pipeline_health = gpio[GPIO_DATA / 4U];

            /* A protocol mismatch means this frame can contain a stale
             * row/frame boundary even when V4L2 still reports the expected
             * byte count.  Exit instead of transmitting a visually stitched
             * but correctly authenticated frame.  The init supervisor
             * restarts STREAMON, which resets the runtime PL pipeline and
             * waits for the camera's next real SOF. */
            if ((pipeline_health & PIPELINE_HEALTH_ERROR_MASK) != 0U) {
                fprintf(stderr,
                        "TX_PL_DIRECT_PIPELINE_FAULT health=0x%08x; restarting camera pipeline\n",
                        pipeline_health);
                errno = EIO;
                break;
            }
        }

        stamp = monotonic_us();
        if (metadata_worker_wait(&metadata_thread, &meta_session,
                                 &meta_frame, &status) < 0) {
            fprintf(stderr, "PL-direct metadata wait failed\n");
            break;
        }
        timing_meta += monotonic_us() - stamp;
        last_status = status;
        next_slot = slot ^ 1U;
        if (metadata_worker_submit(&metadata_thread, last_status,
                                   metadata[next_slot]) < 0) {
            fprintf(stderr, "next PL-direct metadata submit failed\n");
            break;
        }

        /* V4L2 sequence and GCM frame ID may start at different absolute
         * values, but their offset must remain constant.  A changed offset
         * means one side skipped a frame; discard that frame and re-lock. */
        if (!sequence_offset_valid) {
            sequence_to_frame = meta_frame - buffer.sequence;
            sequence_offset_valid = 1;
            fprintf(stderr,
                    "TX_PL_DIRECT_ALIGN v4l2=%u gcm=%u offset=%u\n",
                    buffer.sequence, meta_frame, sequence_to_frame);
        } else if (meta_frame - buffer.sequence != sequence_to_frame) {
            fprintf(stderr,
                    "TX_PL_DIRECT_REALIGN v4l2=%u gcm=%u old_offset=%u new_offset=%u\n",
                    buffer.sequence, meta_frame, sequence_to_frame,
                    meta_frame - buffer.sequence);
            sequence_to_frame = meta_frame - buffer.sequence;
            goto requeue;
        }

        {
            struct session_hw_state state;

            read_session_hw(session_regs, &state);
            if (!direct_frame_session_matches(&state, meta_session)) {
                fprintf(stderr,
                        "TX_PL_DIRECT_DROP session metadata=0x%08x active=0x%08x status=0x%08x\n",
                        meta_session, state.active_session, state.status);
                goto requeue;
            }
            if (session_id != state.active_session ||
                session_epoch != state.epoch) {
                fprintf(stderr,
                        "SESSION_SWITCH session=0x%08x epoch=%u request=%u\n",
                        state.active_session, state.epoch,
                        state.request_count);
                session_id = state.active_session;
                session_epoch = state.epoch;
            }
        }

        if (acquire_session_frame(session_regs) < 0) {
            if (errno != EAGAIN)
                perror("acquire PL-direct send reservation");
            goto requeue;
        }
        frame_lock_held = 1;
        if (!session_frame_lock_matches(session_regs, meta_session,
                                        session_epoch)) {
            fprintf(stderr,
                    "TX_PL_DIRECT_DROP session changed before send\n");
            goto requeue;
        }

        stamp = monotonic_us();
        if (sync_dmabuf(video_dmabuf[buffer.index],
                        DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ) < 0) {
            perror("DMA_BUF_SYNC_START PL-direct frame");
            goto requeue;
        }
        timing_copy += monotonic_us() - stamp;

        if (dump_pipeline_requested &&
            (dump_pipeline_frame < 0 ||
             meta_frame == (uint32_t)dump_pipeline_frame) &&
            (dump_pipeline_after < 0 ||
             dump_pipeline_seen == (unsigned long)dump_pipeline_after)) {
            int frame_fd = -1, meta_fd = -1;

            frame_fd = open("/tmp/tx_pl_direct_frame.bin",
                            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                            0600);
            meta_fd = open("/tmp/tx_pl_direct_meta.bin",
                           O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                           0600);
            if (frame_fd >= 0 && meta_fd >= 0 &&
                write(frame_fd, video_input[buffer.index], FRAME_BYTES) ==
                    (ssize_t)FRAME_BYTES &&
                write(meta_fd, metadata[slot], METADATA_BYTES) ==
                    (ssize_t)METADATA_BYTES) {
                fprintf(stderr,
                        "TX_PL_DIRECT_DUMP frame=%u v4l2=%u buffer=%u\n",
                        meta_frame, buffer.sequence, buffer.index);
                dump_pipeline_requested = 0;
            } else {
                perror("write TX PL-direct dump");
            }
            if (frame_fd >= 0)
                close(frame_fd);
            if (meta_fd >= 0)
                close(meta_fd);
        }
        ++dump_pipeline_seen;

        stamp = monotonic_us();
        {
            int send_result = raw.fd >= 0 ?
                send_frame_raw(&raw, video_input[buffer.index],
                               metadata[slot]) :
                send_frame(socket_fd, video_input[buffer.index],
                           metadata[slot]);
            int sync_result = sync_dmabuf(video_dmabuf[buffer.index],
                                          DMA_BUF_SYNC_END |
                                          DMA_BUF_SYNC_READ);

            timing_send += monotonic_us() - stamp;
            if (sync_result < 0)
                perror("DMA_BUF_SYNC_END PL-direct frame");
            if (send_result < 0 || sync_result < 0) {
                if (release_session_frame(session_regs) < 0)
                    perror("release PL-direct send reservation");
                frame_lock_held = 0;
                break;
            }
        }
        if (release_session_frame(session_regs) < 0) {
            perror("release PL-direct send reservation");
            frame_lock_held = 0;
            break;
        }
        frame_lock_held = 0;

        if ((meta_frame % 30U) == 0U)
            fprintf(stderr,
                    "frame=%u v4l2=%u mode=%s status=0x%08x path=PL_DIRECT\n",
                    meta_frame, buffer.sequence,
                    (load_be16(metadata[slot] + 14U) & 1U) ?
                        "AES-GCM" : "BYPASS",
                    status);

requeue:
        if (frame_lock_held) {
            if (release_session_frame(session_regs) < 0)
                perror("release AES frame reservation");
            frame_lock_held = 0;
        }
        stamp = monotonic_us();
        if (xioctl(video_fd, VIDIOC_QBUF, &buffer) < 0)
            break;
        timing_qbuf += monotonic_us() - stamp;
        timing_total += monotonic_us() - loop_start;
        if (++timing_frames == 30U) {
            fprintf(stderr,
                    "TIMING avg_ms total=%.2f dq=%.2f sync=%.2f meta=%.2f send=%.2f qbuf=%.2f path=PL_DIRECT gso=%d\n",
                    timing_total / 30000.0,
                    timing_dq / 30000.0, timing_copy / 30000.0,
                    timing_meta / 30000.0, timing_send / 30000.0,
                    timing_qbuf / 30000.0,
                    raw.fd >= 0 ? 2 : use_udp_gso);
            timing_dq = timing_copy = 0;
            timing_meta = timing_send = timing_qbuf = 0;
            timing_total = 0;
            timing_frames = 0;
        }
    }
    if (stop_requested)
        result = EXIT_SUCCESS;

cleanup:
    stop_requested = 1;
    if (metadata_thread_started)
        metadata_worker_stop(&metadata_thread);
    if (streaming)
        xioctl(video_fd, VIDIOC_STREAMOFF, &type);
    if (socket_fd >= 0)
        close(socket_fd);
    if (raw.ring != MAP_FAILED)
        munmap(raw.ring, raw.ring_length);
    if (raw.fd >= 0)
        close(raw.fd);
    if (video_fd >= 0)
        close(video_fd);
    for (unsigned int i = 0; i < mapped_count; ++i) {
        if (video_input[i] != MAP_FAILED)
            munmap(video_input[i], video_input_length[i]);
        if (video_dmabuf[i] >= 0)
            close(video_dmabuf[i]);
    }
    if (gpio != MAP_FAILED)
        munmap((void *)gpio, META_GPIO_SIZE);
    if (bram != MAP_FAILED)
        munmap((void *)bram, META_BRAM_SIZE);
    if (session_regs != MAP_FAILED)
        munmap((void *)session_regs, SESSION_REG_SIZE);
    if (mem_fd >= 0)
        close(mem_fd);
    free(metadata[0]);
    free(metadata[1]);
    free(udp_staging);
    return result;
}
