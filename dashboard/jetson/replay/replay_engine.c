// SPDX-License-Identifier: MIT
/*
 * Replay one complete, previously valid encrypted Zybo frame without changing
 * the normal kernel bridge forwarding path.
 *
 * The program captures one 1280-packet frame from eno1, preserves every byte,
 * then adds byte-identical past frames through enx00e04c3338b0 at a rate
 * expressed as a percentage of 30 frames/s.  The engine observes completed
 * normal frames on the output interface and inserts a replay only in the
 * natural inter-frame gap, leaving the kernel bridge path unchanged.
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/bpf.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <net/if.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include "tamper_shared.h"

#define VERSION "2.4.0"
#define PACKETS_PER_FRAME 1280U
#define MAX_PACKET_SIZE 2048U
#define PCAM_MAGIC 0x5043414dU
#define UDP_PORT 5602U
#define UDP_LEN 1480U
#define BASE_FRAME_RATE 30.0
#define SEND_RETRY_LIMIT 200U
#define SEND_BATCH_PACKETS 1024U

enum pacing_mode {
    PACING_BURST,
    PACING_ORIGINAL,
};

struct run_options {
    enum pacing_mode pacing;
    unsigned shot_limit;
    int socket_priority;
    bool qdisc_bypass;
};

struct saved_packet {
    uint16_t length;
    uint64_t relative_ns;
    unsigned char bytes[MAX_PACKET_SIZE];
};

struct replay_state {
    const char *status_path;
    unsigned rate_percent;
    uint32_t run_id;
    uint32_t session_id;
    uint32_t frame_id;
    uint64_t source_bytes;
    uint64_t source_capture_ns;
    uint64_t injected_frames;
    uint64_t injected_packets;
    uint64_t injected_bytes;
    uint64_t attempted_packets;
    uint64_t eligible_frames;
    uint64_t selected_frames;
    uint64_t send_errors;
    uint64_t late_schedules;
    uint64_t gate_dropped_packets;
    uint64_t started_ns;
    bool active;
    const char *phase;
    const struct run_options *options;
};

static volatile sig_atomic_t stop_requested;

static void on_signal(int signum)
{
    (void)signum;
    stop_requested = 1;
}

static uint64_t monotonic_ns(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static int write_status(const struct replay_state *state)
{
    char temporary[4096];
    FILE *stream;
    double elapsed = state->started_ns
        ? (monotonic_ns() - state->started_ns) / 1000000000.0 : 0.0;
    double injected_fps = elapsed > 0.0 ? state->injected_frames / elapsed : 0.0;

    if (snprintf(temporary, sizeof(temporary), "%s.tmp.%ld",
                 state->status_path, (long)getpid()) >= (int)sizeof(temporary)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    stream = fopen(temporary, "w");
    if (!stream)
        return -1;
    fprintf(stream,
            "{\"implementation\":\"frame-boundary-configurable-replay\"," 
            "\"version\":\"%s\",\"active\":%s,\"mode\":\"replay\","
            "\"phase\":\"%s\",\"target_rate\":%.6f,"
            "\"rate_percent\":%u,\"target_injected_fps\":%.6f,"
            "\"run_id\":%u,\"source_session_id\":\"0x%08x\","
            "\"source_frame_id\":%u,\"source_packets\":%u,"
            "\"source_bytes\":%llu,\"source_capture_ms\":%.3f,"
            "\"injected_frames_total\":%llu,"
            "\"injected_packets_total\":%llu,"
            "\"injected_bytes_total\":%llu,"
            "\"attempted_packets_total\":%llu,"
            "\"eligible_frames_total\":%llu,"
            "\"selected_frames_total\":%llu,"
            "\"actual_injected_fps\":%.6f,\"send_errors_total\":%llu,"
            "\"late_schedules_total\":%llu,"
            "\"gate_dropped_packets_total\":%llu,"
            "\"pacing\":\"%s\",\"qdisc_bypass\":%s,"
            "\"socket_priority\":%d,\"shot_limit\":%u,\"pid\":%ld}\n",
            VERSION, state->active ? "true" : "false", state->phase,
            state->rate_percent / 100.0, state->rate_percent,
            BASE_FRAME_RATE * state->rate_percent / 100.0,
            state->run_id, state->session_id, state->frame_id,
            PACKETS_PER_FRAME, (unsigned long long)state->source_bytes,
            state->source_capture_ns / 1000000.0,
            (unsigned long long)state->injected_frames,
            (unsigned long long)state->injected_packets,
            (unsigned long long)state->injected_bytes,
            (unsigned long long)state->attempted_packets,
            (unsigned long long)state->eligible_frames,
            (unsigned long long)state->selected_frames,
            injected_fps, (unsigned long long)state->send_errors,
            (unsigned long long)state->late_schedules,
            (unsigned long long)state->gate_dropped_packets,
            state->options->pacing == PACING_ORIGINAL ? "original" : "burst",
            state->options->qdisc_bypass ? "true" : "false",
            state->options->socket_priority, state->options->shot_limit,
            (long)getpid());
    if (fclose(stream) != 0 || rename(temporary, state->status_path) != 0) {
        unlink(temporary);
        return -1;
    }
    return 0;
}

static int bpf_call(enum bpf_cmd command, union bpf_attr *attr)
{
    return (int)syscall(__NR_bpf, command, attr, sizeof(*attr));
}

static int bpf_object_get(const char *path)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.pathname = (uint64_t)(uintptr_t)path;
    return bpf_call(BPF_OBJ_GET, &attr);
}

static int bpf_map_lookup(int fd, const void *key, void *value)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.map_fd = (uint32_t)fd;
    attr.key = (uint64_t)(uintptr_t)key;
    attr.value = (uint64_t)(uintptr_t)value;
    return bpf_call(BPF_MAP_LOOKUP_ELEM, &attr);
}

static int bpf_map_update(int fd, const void *key, const void *value)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.map_fd = (uint32_t)fd;
    attr.key = (uint64_t)(uintptr_t)key;
    attr.value = (uint64_t)(uintptr_t)value;
    attr.flags = BPF_ANY;
    return bpf_call(BPF_MAP_UPDATE_ELEM, &attr);
}

static int replay_gate_set(int config_fd, bool enabled)
{
    const uint32_t key = 0;
    struct tamper_config config;
    if (bpf_map_lookup(config_fd, &key, &config) < 0)
        return -1;
    if (enabled && config.enabled) {
        errno = EBUSY;
        return -1;
    }
    config.reserved[0] = enabled ? 1U : 0U;
    return bpf_map_update(config_fd, &key, &config);
}

static bool mac_equal(const unsigned char *actual, const unsigned char expected[6])
{
    return memcmp(actual, expected, 6) == 0;
}

static bool parse_video_packet(const unsigned char *data, size_t length,
                               uint32_t *session_id, uint32_t *frame_id,
                               uint16_t *packet_index)
{
    static const unsigned char tx_mac[6] = {0x02, 0, 0, 0, 0, 0x02};
    static const unsigned char rx_mac[6] = {0x02, 0, 0, 0, 0, 0x03};
    const struct ethhdr *eth;
    const struct iphdr *ip;
    const struct udphdr *udp;
    const unsigned char *payload;
    uint32_t value32;
    uint16_t value16;
    size_t ip_offset = ETH_HLEN;
    size_t udp_offset;

    if (length < ETH_HLEN + sizeof(struct iphdr) + sizeof(struct udphdr) + 16)
        return false;
    eth = (const struct ethhdr *)data;
    if (!mac_equal(eth->h_source, tx_mac) || !mac_equal(eth->h_dest, rx_mac) ||
        ntohs(eth->h_proto) != ETH_P_IP)
        return false;
    ip = (const struct iphdr *)(data + ip_offset);
    if (ip->version != 4 || ip->ihl < 5 || ip->protocol != IPPROTO_UDP ||
        ntohl(ip->saddr) != 0x0a0a0f02U || ntohl(ip->daddr) != 0x0a0a0f03U)
        return false;
    udp_offset = ip_offset + (size_t)ip->ihl * 4U;
    if (length < udp_offset + sizeof(*udp) + 16U)
        return false;
    udp = (const struct udphdr *)(data + udp_offset);
    if (ntohs(udp->source) != UDP_PORT || ntohs(udp->dest) != UDP_PORT ||
        ntohs(udp->len) != UDP_LEN)
        return false;
    payload = data + udp_offset + sizeof(*udp);
    memcpy(&value32, payload, sizeof(value32));
    if (ntohl(value32) != PCAM_MAGIC)
        return false;
    memcpy(&value16, payload + 14, sizeof(value16));
    if (!(ntohs(value16) & 1U))
        return false;
    memcpy(&value32, payload + 4, sizeof(value32));
    *session_id = ntohl(value32);
    memcpy(&value32, payload + 8, sizeof(value32));
    *frame_id = ntohl(value32);
    memcpy(&value16, payload + 12, sizeof(value16));
    *packet_index = ntohs(value16);
    return *packet_index < PACKETS_PER_FRAME;
}

static int open_bound_packet_socket(const char *interface, bool receive,
                                    const struct run_options *options)
{
    struct sockaddr_ll address;
    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    int ifindex;
    int one = 1;
    int receive_buffer = 32 * 1024 * 1024;
    if (fd < 0)
        return -1;
    ifindex = (int)if_nametoindex(interface);
    if (!ifindex) {
        close(fd);
        errno = ENODEV;
        return -1;
    }
#ifdef PACKET_IGNORE_OUTGOING
    if (receive)
        (void)setsockopt(fd, SOL_PACKET, PACKET_IGNORE_OUTGOING, &one, sizeof(one));
#else
    (void)one;
#endif
    if (receive && setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer,
                             sizeof(receive_buffer)) < 0) {
        close(fd);
        return -1;
    }
    if (!receive && setsockopt(fd, SOL_SOCKET, SO_PRIORITY,
                              &options->socket_priority,
                              sizeof(options->socket_priority)) < 0) {
        close(fd);
        return -1;
    }
    if (!receive && options->qdisc_bypass) {
        int bypass = 1;
        if (setsockopt(fd, SOL_PACKET, PACKET_QDISC_BYPASS, &bypass,
                       sizeof(bypass)) < 0) {
            close(fd);
            return -1;
        }
    }
    memset(&address, 0, sizeof(address));
    address.sll_family = AF_PACKET;
    address.sll_protocol = htons(ETH_P_ALL);
    address.sll_ifindex = ifindex;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int open_frame_boundary_socket(const char *interface)
{
    static const struct sock_filter filter_code[] = {
        BPF_STMT(BPF_LD | BPF_H | BPF_ABS, 12),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, ETH_P_IP, 0, 11),
        BPF_STMT(BPF_LD | BPF_B | BPF_ABS, 23),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, IPPROTO_UDP, 0, 9),
        BPF_STMT(BPF_LD | BPF_H | BPF_ABS, 34),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, UDP_PORT, 0, 7),
        BPF_STMT(BPF_LD | BPF_H | BPF_ABS, 36),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, UDP_PORT, 0, 5),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 42),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PCAM_MAGIC, 0, 3),
        BPF_STMT(BPF_LD | BPF_H | BPF_ABS, 54),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PACKETS_PER_FRAME - 1U, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, 96),
        BPF_STMT(BPF_RET | BPF_K, 0),
    };
    struct sock_fprog filter = {
        .len = (unsigned short)(sizeof(filter_code) / sizeof(filter_code[0])),
        .filter = (struct sock_filter *)filter_code,
    };
    struct sockaddr_ll address;
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 200000};
    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    int ifindex;

    if (fd < 0)
        return -1;
    ifindex = (int)if_nametoindex(interface);
    if (!ifindex) {
        close(fd);
        errno = ENODEV;
        return -1;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_ATTACH_FILTER, &filter, sizeof(filter)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        close(fd);
        return -1;
    }
    memset(&address, 0, sizeof(address));
    address.sll_family = AF_PACKET;
    address.sll_protocol = htons(ETH_P_ALL);
    address.sll_ifindex = ifindex;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int capture_source_frame(const char *interface, struct saved_packet *packets,
                                struct replay_state *state)
{
    bool present[PACKETS_PER_FRAME] = {false};
    unsigned char buffer[MAX_PACKET_SIZE];
    uint32_t candidate_session = 0;
    uint32_t candidate_frame = 0;
    bool have_candidate = false;
    unsigned collected = 0;
    uint64_t first_ns = 0;
    uint64_t deadline = monotonic_ns() + 10000000000ULL;
    int fd = open_bound_packet_socket(interface, true, state->options);
    if (fd < 0)
        return -1;

    while (!stop_requested && monotonic_ns() < deadline) {
        uint32_t session_id;
        uint32_t frame_id;
        uint16_t packet_index;
        ssize_t size = recv(fd, buffer, sizeof(buffer), MSG_DONTWAIT);
        uint64_t now;
        if (size < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct timespec pause = {.tv_sec = 0, .tv_nsec = 1000000};
                nanosleep(&pause, NULL);
                continue;
            }
            close(fd);
            return -1;
        }
        now = monotonic_ns();
        if (!parse_video_packet(buffer, (size_t)size, &session_id, &frame_id,
                                &packet_index))
            continue;
        if (packet_index == 0 &&
            (collected == 0 || session_id != candidate_session ||
             frame_id != candidate_frame)) {
            memset(present, 0, sizeof(present));
            collected = 0;
            candidate_session = session_id;
            candidate_frame = frame_id;
            first_ns = now;
            have_candidate = true;
        }
        if (!have_candidate || session_id != candidate_session ||
            frame_id != candidate_frame || present[packet_index])
            continue;
        if ((size_t)size > MAX_PACKET_SIZE) {
            errno = EMSGSIZE;
            close(fd);
            return -1;
        }
        packets[packet_index].length = (uint16_t)size;
        packets[packet_index].relative_ns = now - first_ns;
        memcpy(packets[packet_index].bytes, buffer, (size_t)size);
        present[packet_index] = true;
        collected++;
        if (collected == PACKETS_PER_FRAME) {
            state->session_id = candidate_session;
            state->frame_id = candidate_frame;
            state->source_capture_ns = now - first_ns;
            state->source_bytes = 0;
            for (unsigned i = 0; i < PACKETS_PER_FRAME; ++i)
                state->source_bytes += packets[i].length;
            close(fd);
            return 0;
        }
    }
    close(fd);
    errno = ETIMEDOUT;
    return -1;
}

static uint32_t decode_u32(const unsigned char bytes[4], bool little_endian)
{
    if (little_endian)
        return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
               (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
    return (uint32_t)bytes[3] | (uint32_t)bytes[2] << 8 |
           (uint32_t)bytes[1] << 16 | (uint32_t)bytes[0] << 24;
}

static int load_source_frame(const char *path, struct saved_packet *packets,
                             struct replay_state *state)
{
    unsigned char global_header[24];
    unsigned char record_header[16];
    unsigned char buffer[MAX_PACKET_SIZE];
    bool present[PACKETS_PER_FRAME] = {false};
    bool little_endian;
    bool nanoseconds;
    uint32_t candidate_session = 0;
    uint32_t candidate_frame = 0;
    bool have_candidate = false;
    uint64_t first_ns = 0;
    unsigned collected = 0;
    FILE *stream = fopen(path, "rb");

    if (!stream)
        return -1;
    if (fread(global_header, 1, sizeof(global_header), stream) !=
        sizeof(global_header)) {
        errno = EINVAL;
        fclose(stream);
        return -1;
    }
    if (!memcmp(global_header, "\xd4\xc3\xb2\xa1", 4)) {
        little_endian = true;
        nanoseconds = false;
    } else if (!memcmp(global_header, "\xa1\xb2\xc3\xd4", 4)) {
        little_endian = false;
        nanoseconds = false;
    } else if (!memcmp(global_header, "\x4d\x3c\xb2\xa1", 4)) {
        little_endian = true;
        nanoseconds = true;
    } else if (!memcmp(global_header, "\xa1\xb2\x3c\x4d", 4)) {
        little_endian = false;
        nanoseconds = true;
    } else {
        errno = EPROTONOSUPPORT;
        fclose(stream);
        return -1;
    }
    if (decode_u32(global_header + 20, little_endian) != 1U) {
        errno = EPROTONOSUPPORT;
        fclose(stream);
        return -1;
    }

    while (fread(record_header, 1, sizeof(record_header), stream) ==
           sizeof(record_header)) {
        uint32_t seconds = decode_u32(record_header, little_endian);
        uint32_t fraction = decode_u32(record_header + 4, little_endian);
        uint32_t included = decode_u32(record_header + 8, little_endian);
        uint32_t session_id;
        uint32_t frame_id;
        uint16_t packet_index;
        uint64_t now;

        if (included > sizeof(buffer)) {
            if (fseek(stream, (long)included, SEEK_CUR) != 0)
                break;
            continue;
        }
        if (fread(buffer, 1, included, stream) != included)
            break;
        if (!parse_video_packet(buffer, included, &session_id, &frame_id,
                                &packet_index))
            continue;
        now = (uint64_t)seconds * 1000000000ULL +
              (uint64_t)fraction * (nanoseconds ? 1ULL : 1000ULL);
        if (packet_index == 0 &&
            (collected == 0 || session_id != candidate_session ||
             frame_id != candidate_frame)) {
            memset(present, 0, sizeof(present));
            collected = 0;
            candidate_session = session_id;
            candidate_frame = frame_id;
            first_ns = now;
            have_candidate = true;
        }
        if (!have_candidate || session_id != candidate_session ||
            frame_id != candidate_frame || present[packet_index])
            continue;
        packets[packet_index].length = (uint16_t)included;
        packets[packet_index].relative_ns = now - first_ns;
        memcpy(packets[packet_index].bytes, buffer, included);
        present[packet_index] = true;
        collected++;
        if (collected == PACKETS_PER_FRAME) {
            state->session_id = candidate_session;
            state->frame_id = candidate_frame;
            state->source_capture_ns = now - first_ns;
            state->source_bytes = 0;
            for (unsigned i = 0; i < PACKETS_PER_FRAME; ++i)
                state->source_bytes += packets[i].length;
            fclose(stream);
            return 0;
        }
    }
    fclose(stream);
    errno = ENODATA;
    return -1;
}

static int inject_one_frame(int fd, const struct sockaddr_ll *address,
                            struct saved_packet *packets,
                            struct replay_state *state)
{
    state->attempted_packets += PACKETS_PER_FRAME;
    if (state->options->pacing == PACING_ORIGINAL) {
        uint64_t base = monotonic_ns() + 1000000ULL;

        for (unsigned i = 0; i < PACKETS_PER_FRAME; ++i) {
            uint64_t target = base + packets[i].relative_ns;
            struct timespec deadline = {
                .tv_sec = (time_t)(target / 1000000000ULL),
                .tv_nsec = (long)(target % 1000000000ULL),
            };
            int result;
            ssize_t sent;
            unsigned retries = 0;

            do {
                result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME,
                                         &deadline, NULL);
            } while (result == EINTR);
            if (result != 0) {
                errno = result;
                state->send_errors += PACKETS_PER_FRAME - i;
                return -1;
            }
            for (;;) {
                sent = sendto(fd, packets[i].bytes, packets[i].length, 0,
                              (const struct sockaddr *)address,
                              sizeof(*address));
                if (sent >= 0)
                    break;
                if (errno == EINTR)
                    continue;
                if ((errno != ENOBUFS && errno != EAGAIN &&
                     errno != EWOULDBLOCK) || retries++ >= SEND_RETRY_LIMIT)
                    break;
                {
                    struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000};
                    nanosleep(&pause, NULL);
                }
            }
            if (sent != packets[i].length) {
                state->send_errors += PACKETS_PER_FRAME - i;
                return -1;
            }
            state->injected_packets++;
            state->injected_bytes += packets[i].length;
        }
        state->injected_frames++;
        return 0;
    }

    for (unsigned start = 0; start < PACKETS_PER_FRAME;
         start += SEND_BATCH_PACKETS) {
        struct mmsghdr messages[SEND_BATCH_PACKETS];
        struct iovec vectors[SEND_BATCH_PACKETS];
        unsigned count = PACKETS_PER_FRAME - start;
        unsigned completed = 0;
        unsigned retries = 0;

        if (count > SEND_BATCH_PACKETS)
            count = SEND_BATCH_PACKETS;
        memset(messages, 0, sizeof(messages));
        for (unsigned i = 0; i < count; ++i) {
            vectors[i].iov_base = packets[start + i].bytes;
            vectors[i].iov_len = packets[start + i].length;
            messages[i].msg_hdr.msg_name = (void *)address;
            messages[i].msg_hdr.msg_namelen = sizeof(*address);
            messages[i].msg_hdr.msg_iov = &vectors[i];
            messages[i].msg_hdr.msg_iovlen = 1;
        }
        while (completed < count) {
            int sent = sendmmsg(fd, &messages[completed], count - completed, 0);
            if (sent > 0) {
                for (int i = 0; i < sent; ++i) {
                    state->injected_packets++;
                    state->injected_bytes +=
                        packets[start + completed + (unsigned)i].length;
                }
                completed += (unsigned)sent;
                retries = 0;
                continue;
            }
            if (sent < 0 && errno == EINTR)
                continue;
            if (sent < 0 &&
                (errno == ENOBUFS || errno == EAGAIN || errno == EWOULDBLOCK) &&
                retries++ < SEND_RETRY_LIMIT) {
                struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000};
                nanosleep(&pause, NULL);
                continue;
            }
            state->send_errors += count - completed;
            return -1;
        }
    }
    state->injected_frames++;
    return 0;
}

static int inject_loop(const char *interface, struct saved_packet *packets,
                       struct replay_state *state)
{
    unsigned char boundary_packet[96];
    struct sockaddr_ll address;
    struct sockaddr_ll observed;
    unsigned accumulator = 0;
    int output_fd = open_bound_packet_socket(interface, false, state->options);
    int boundary_fd;

    if (output_fd < 0)
        return -1;
    boundary_fd = open_frame_boundary_socket(interface);
    if (boundary_fd < 0) {
        close(output_fd);
        return -1;
    }
    memset(&address, 0, sizeof(address));
    address.sll_family = AF_PACKET;
    address.sll_protocol = htons(ETH_P_ALL);
    address.sll_ifindex = (int)if_nametoindex(interface);
    address.sll_halen = ETH_ALEN;
    memcpy(address.sll_addr, packets[0].bytes, ETH_ALEN);

    state->active = true;
    state->phase = "injecting";
    state->started_ns = monotonic_ns();
    if (write_status(state) < 0) {
        close(boundary_fd);
        close(output_fd);
        return -1;
    }

    while (!stop_requested) {
        socklen_t observed_length = sizeof(observed);
        uint32_t session_id, frame_id;
        uint16_t packet_index;
        ssize_t received = recvfrom(boundary_fd, boundary_packet,
                                    sizeof(boundary_packet), 0,
                                    (struct sockaddr *)&observed,
                                    &observed_length);
        if (received < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                continue;
            close(boundary_fd);
            close(output_fd);
            return -1;
        }
        if (observed.sll_pkttype != PACKET_OUTGOING ||
            !parse_video_packet(boundary_packet, (size_t)received,
                                &session_id, &frame_id, &packet_index) ||
            packet_index != PACKETS_PER_FRAME - 1U ||
            session_id != state->session_id || frame_id == state->frame_id)
            continue;

        state->eligible_frames++;
        accumulator += state->rate_percent;
        if (accumulator < 100U)
            continue;
        accumulator -= 100U;
        state->selected_frames++;
        {
            uint64_t started = monotonic_ns();
            if (inject_one_frame(output_fd, &address, packets, state) < 0) {
                close(boundary_fd);
                close(output_fd);
                return -1;
            }
            if (monotonic_ns() - started > 18000000ULL)
                state->late_schedules++;
        }
        if (write_status(state) < 0) {
            close(boundary_fd);
            close(output_fd);
            return -1;
        }
        if (state->options->shot_limit &&
            state->injected_frames >= state->options->shot_limit) {
            stop_requested = 1;
            break;
        }
    }
    close(boundary_fd);
    close(output_fd);
    return 0;
}

static bool valid_rate(unsigned long rate)
{
    return rate == 5 || rate == 10 || rate == 20 || rate == 40 || rate == 60;
}

int main(int argc, char **argv)
{
    const char *input = "eno1";
    const char *output = "enx00e04c3338b0";
    const char *source_path;
    struct saved_packet *packets;
    struct replay_state state = {0};
    struct run_options options = {
        .pacing = PACING_BURST,
        .shot_limit = 0,
        .socket_priority = 6,
        .qdisc_bypass = false,
    };
    char *end = NULL;
    unsigned long rate;
    int result;
    int gate_config_fd = -1;

    if ((argc != 8 && argc != 16) || strcmp(argv[1], "--rate") ||
        strcmp(argv[3], "--status") || strcmp(argv[5], "--source")) {
        fprintf(stderr, "usage: %s --rate {5|10|20|40|60} --status FILE --source PCAP INPUT:OUTPUT [--shots N --pacing burst|original --qdisc-bypass 0|1 --priority 0..7]\n",
                argv[0]);
        return 2;
    }
    errno = 0;
    rate = strtoul(argv[2], &end, 10);
    if (errno || !end || *end || !valid_rate(rate)) {
        fprintf(stderr, "unsupported rate: %s\n", argv[2]);
        return 2;
    }
    if (argc == 16) {
        unsigned long value;

        if (strcmp(argv[8], "--shots") || strcmp(argv[10], "--pacing") ||
            strcmp(argv[12], "--qdisc-bypass") ||
            strcmp(argv[14], "--priority")) {
            fprintf(stderr, "invalid optional arguments\n");
            return 2;
        }
        errno = 0;
        value = strtoul(argv[9], &end, 10);
        if (errno || !end || *end || value > 100000U) {
            fprintf(stderr, "invalid shot limit\n");
            return 2;
        }
        options.shot_limit = (unsigned)value;
        if (!strcmp(argv[11], "burst"))
            options.pacing = PACING_BURST;
        else if (!strcmp(argv[11], "original"))
            options.pacing = PACING_ORIGINAL;
        else {
            fprintf(stderr, "invalid pacing\n");
            return 2;
        }
        if (!strcmp(argv[13], "0"))
            options.qdisc_bypass = false;
        else if (!strcmp(argv[13], "1"))
            options.qdisc_bypass = true;
        else {
            fprintf(stderr, "invalid qdisc bypass\n");
            return 2;
        }
        errno = 0;
        value = strtoul(argv[15], &end, 10);
        if (errno || !end || *end || value > 7U) {
            fprintf(stderr, "invalid priority\n");
            return 2;
        }
        options.socket_priority = (int)value;
    }
    {
        char *separator = strchr(argv[7], ':');
        if (!separator || separator == argv[7] || !separator[1]) {
            fprintf(stderr, "interfaces must be INPUT:OUTPUT\n");
            return 2;
        }
        *separator = '\0';
        input = argv[7];
        output = separator + 1;
    }
    source_path = argv[6];
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    gate_config_fd = bpf_object_get(ZYBO_TAMPER_CONFIG_PIN);
    if (gate_config_fd >= 0 && replay_gate_set(gate_config_fd, false) < 0) {
        perror("ensure replay gate off");
        return 1;
    }
    state.status_path = argv[4];
    state.options = &options;
    state.rate_percent = (unsigned)rate;
    state.run_id = (uint32_t)time(NULL) ^ (uint32_t)getpid();
    state.phase = "capturing";
    if (write_status(&state) < 0) {
        perror("write initial status");
        return 1;
    }
    packets = calloc(PACKETS_PER_FRAME, sizeof(*packets));
    if (!packets) {
        perror("calloc");
        return 1;
    }
    if ((strcmp(source_path, "-") == 0
         ? capture_source_frame(input, packets, &state)
         : load_source_frame(source_path, packets, &state)) < 0) {
        perror("capture source frame");
        state.phase = "failed";
        (void)write_status(&state);
        free(packets);
        return 1;
    }
    state.phase = "ready";
    if (write_status(&state) < 0) {
        perror("write ready status");
        free(packets);
        return 1;
    }
    result = inject_loop(output, packets, &state);
    if (result < 0)
        perror("inject loop");
    state.active = false;
    state.phase = result < 0 ? "failed" : "stopped";
    (void)write_status(&state);
    if (gate_config_fd >= 0) {
        (void)replay_gate_set(gate_config_fd, false);
        close(gate_config_fd);
    }
    free(packets);
    return result < 0 ? 1 : 0;
}
