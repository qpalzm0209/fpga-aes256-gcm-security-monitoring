// SPDX-License-Identifier: MIT
/* Minimal unprivileged controller for the two root-created pinned BPF maps. */

#define _GNU_SOURCE
#include <errno.h>
#include <linux/bpf.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "tamper_shared.h"

static int bpf_call(enum bpf_cmd command, union bpf_attr *attr)
{
    return (int)syscall(__NR_bpf, command, attr, sizeof(*attr));
}

static int object_get(const char *path)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.pathname = (uint64_t)(uintptr_t)path;
    return bpf_call(BPF_OBJ_GET, &attr);
}

static int map_lookup(int fd, const void *key, void *value)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.map_fd = fd;
    attr.key = (uint64_t)(uintptr_t)key;
    attr.value = (uint64_t)(uintptr_t)value;
    return bpf_call(BPF_MAP_LOOKUP_ELEM, &attr);
}

static int map_update(int fd, const void *key, const void *value)
{
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.map_fd = fd;
    attr.key = (uint64_t)(uintptr_t)key;
    attr.value = (uint64_t)(uintptr_t)value;
    attr.flags = BPF_ANY;
    return bpf_call(BPF_MAP_UPDATE_ELEM, &attr);
}

static int valid_rate(unsigned long rate)
{
    return rate == 5 || rate == 10 || rate == 20 || rate == 40 || rate == 60;
}

static void print_status(const struct tamper_config *cfg,
                         const struct tamper_stats *stats)
{
    double actual = stats->eligible_frames
        ? (double)stats->modified_frames / (double)stats->eligible_frames
        : 0.0;
    printf("{\"implementation\":\"xdp-ebpf\"," 
           "\"version\":\"%s\",\"active\":%s,\"mode\":\"tamper\"," 
           "\"replay_gate_active\":%s,"
           "\"target_rate\":%.6f,\"rate_percent\":%u,"
           "\"run_id\":%u,\"packet_index\":%u,\"bit_mask\":%u,"
           "\"eligible_frames_total\":%llu,"
           "\"selected_frames_total\":%llu,"
           "\"modified_frames_total\":%llu,"
           "\"modified_packets_total\":%llu,"
           "\"actual_attack_rate\":%.9f,"
           "\"checksum_errors_total\":%llu,"
           "\"store_errors_total\":%llu,"
           "\"replay_gate_dropped_packets_total\":%llu,"
           "\"parse_errors_total\":%llu,"
           "\"last_session_id\":\"0x%08x\","
           "\"last_frame_id\":%u,\"last_packet_index\":%u}\n",
           ZYBO_TAMPER_VERSION, cfg->enabled ? "true" : "false",
           cfg->reserved[0] ? "true" : "false",
           cfg->rate_percent / 100.0, cfg->rate_percent, cfg->run_id,
           cfg->packet_index, cfg->bit_mask,
           (unsigned long long)stats->eligible_frames,
           (unsigned long long)stats->selected_frames,
           (unsigned long long)stats->modified_frames,
           (unsigned long long)stats->modified_packets,
           actual,
           (unsigned long long)stats->checksum_errors,
           (unsigned long long)stats->store_errors,
           (unsigned long long)stats->store_errors,
           (unsigned long long)stats->parse_errors,
           stats->last_session_id, stats->last_frame_id,
           stats->last_packet_index);
}

int main(int argc, char **argv)
{
    const uint32_t key = 0;
    struct tamper_config cfg;
    struct tamper_stats stats;
    int cfg_fd;
    int stats_fd;

    if (argc < 2 || (strcmp(argv[1], "status") && strcmp(argv[1], "start") &&
                     strcmp(argv[1], "stop") && strcmp(argv[1], "gate-on") &&
                     strcmp(argv[1], "gate-off"))) {
        fprintf(stderr, "usage: %s status | start {5|10|20|40|60} | stop | gate-on | gate-off\n",
                argv[0]);
        return 2;
    }

    cfg_fd = object_get(ZYBO_TAMPER_CONFIG_PIN);
    stats_fd = object_get(ZYBO_TAMPER_STATS_PIN);
    if (cfg_fd < 0 || stats_fd < 0) {
        fprintf(stderr, "tamper maps unavailable: %s\n", strerror(errno));
        return 1;
    }
    if (map_lookup(cfg_fd, &key, &cfg) < 0 ||
        map_lookup(stats_fd, &key, &stats) < 0) {
        fprintf(stderr, "cannot read tamper maps: %s\n", strerror(errno));
        return 1;
    }

    if (!strcmp(argv[1], "start")) {
        char *end = NULL;
        unsigned long rate;
        struct tamper_config disabled = cfg;

        if (argc != 3) {
            fprintf(stderr, "start requires one rate: 5, 10, 20, 40 or 60\n");
            return 2;
        }
        errno = 0;
        rate = strtoul(argv[2], &end, 10);
        if (errno || !end || *end || !valid_rate(rate)) {
            fprintf(stderr, "unsupported rate: %s\n", argv[2]);
            return 2;
        }

        disabled.enabled = 0;
        if (map_update(cfg_fd, &key, &disabled) < 0) {
            fprintf(stderr, "cannot disable before reset: %s\n", strerror(errno));
            return 1;
        }
        memset(&stats, 0, sizeof(stats));
        cfg.enabled = 1;
        cfg.rate_percent = (uint32_t)rate;
        cfg.packet_index = 0;
        cfg.bit_mask = 1;
        cfg.reserved[0] = 0;
        cfg.run_id = cfg.run_id + 1;
        if (cfg.run_id == 0)
            cfg.run_id = 1;
        stats.run_id = cfg.run_id;
        if (map_update(stats_fd, &key, &stats) < 0 ||
            map_update(cfg_fd, &key, &cfg) < 0) {
            fprintf(stderr, "cannot start tamper: %s\n", strerror(errno));
            return 1;
        }
    } else if (!strcmp(argv[1], "stop")) {
        cfg.enabled = 0;
        cfg.reserved[0] = 0;
        if (map_update(cfg_fd, &key, &cfg) < 0) {
            fprintf(stderr, "cannot stop tamper: %s\n", strerror(errno));
            return 1;
        }
    } else if (!strcmp(argv[1], "gate-on")) {
        if (cfg.enabled) {
            fprintf(stderr, "tamper is active; refusing replay gate\n");
            return 1;
        }
        cfg.reserved[0] = 1;
        stats.store_errors = 0;
        if (map_update(stats_fd, &key, &stats) < 0 ||
            map_update(cfg_fd, &key, &cfg) < 0) {
            fprintf(stderr, "cannot enable replay gate: %s\n", strerror(errno));
            return 1;
        }
    } else if (!strcmp(argv[1], "gate-off")) {
        cfg.reserved[0] = 0;
        if (map_update(cfg_fd, &key, &cfg) < 0) {
            fprintf(stderr, "cannot disable replay gate: %s\n", strerror(errno));
            return 1;
        }
    }

    if (map_lookup(cfg_fd, &key, &cfg) < 0 ||
        map_lookup(stats_fd, &key, &stats) < 0) {
        fprintf(stderr, "cannot read final status: %s\n", strerror(errno));
        return 1;
    }
    print_status(&cfg, &stats);
    close(cfg_fd);
    close(stats_fd);
    return 0;
}
