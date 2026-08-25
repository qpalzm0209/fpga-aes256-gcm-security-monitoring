#ifndef ZYBO_TAMPER_SHARED_H
#define ZYBO_TAMPER_SHARED_H

#include <linux/types.h>

#define ZYBO_TAMPER_VERSION "1.1.0"
#define ZYBO_TAMPER_CONFIG_PIN "/sys/fs/bpf/tc/globals/zt_cfg"
#define ZYBO_TAMPER_STATS_PIN  "/sys/fs/bpf/tc/globals/zt_stats"

struct tamper_config {
    __u32 enabled;
    __u32 rate_percent;
    __u32 packet_index;
    __u32 bit_mask;
    __u32 run_id;
    __u32 reserved[3];
};

struct tamper_stats {
    __u64 eligible_frames;
    __u64 selected_frames;
    __u64 modified_frames;
    __u64 modified_packets;
    __u64 checksum_errors;
    __u64 store_errors;
    __u64 parse_errors;
    __u32 run_id;
    __u32 last_session_id;
    __u32 last_frame_id;
    __u32 last_packet_index;
};

#endif
