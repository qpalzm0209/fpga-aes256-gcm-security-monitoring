// SPDX-License-Identifier: GPL-2.0
/*
 * Selective Zybo AES-GCM tamper action for generic XDP on eno1.
 *
 * The normal path remains the Linux bridge.  When enabled, this program
 * selects frame_id %% 100 < rate_percent, then flips exactly one ciphertext
 * bit in packet_index 0.  AAD, GCM tag and packet length are untouched.
 */

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include "tamper_shared.h"

#define SEC(NAME) __attribute__((section(NAME), used))
#define PIN_GLOBAL_NS 2

struct bpf_elf_map {
    __u32 type;
    __u32 size_key;
    __u32 size_value;
    __u32 max_elem;
    __u32 flags;
    __u32 id;
    __u32 pinning;
    __u32 inner_id;
    __u32 inner_idx;
};

static void *(*bpf_map_lookup_elem)(void *map, const void *key) =
    (void *)BPF_FUNC_map_lookup_elem;

struct bpf_elf_map SEC("maps") zt_cfg = {
    .type = BPF_MAP_TYPE_ARRAY,
    .size_key = sizeof(__u32),
    .size_value = sizeof(struct tamper_config),
    .max_elem = 1,
    .pinning = PIN_GLOBAL_NS,
};

struct bpf_elf_map SEC("maps") zt_stats = {
    .type = BPF_MAP_TYPE_ARRAY,
    .size_key = sizeof(__u32),
    .size_value = sizeof(struct tamper_stats),
    .max_elem = 1,
    .pinning = PIN_GLOBAL_NS,
};

static __inline __u16 bswap16(__u16 value)
{
    return __builtin_bswap16(value);
}

static __inline __u32 bswap32(__u32 value)
{
    return __builtin_bswap32(value);
}

static __inline __u16 csum16_add(__u16 checksum, __u16 addend)
{
    __u16 result = checksum + addend;
    return result + (result < addend);
}

static __inline __u16 csum16_sub(__u16 checksum, __u16 addend)
{
    return csum16_add(checksum, (__u16)~addend);
}

static __inline __u16 csum_replace2(__u16 checksum, __u16 old_word,
                                    __u16 new_word)
{
    return (__u16)~csum16_add(csum16_sub((__u16)~checksum, old_word),
                              new_word);
}

SEC("xdp")
int zybo_tamper(struct xdp_md *ctx)
{
    const __u32 key = 0;
    struct tamper_config *cfg;
    struct tamper_stats *stats;
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = data;
    struct iphdr *ip = data + ETH_HLEN;
    struct udphdr *udp = data + ETH_HLEN + sizeof(struct iphdr);
    unsigned char *payload = data + ETH_HLEN + sizeof(struct iphdr)
                             + sizeof(struct udphdr);
    __u32 *magic = (__u32 *)(payload + 0);
    __u32 *session_id_be = (__u32 *)(payload + 4);
    __u32 *frame_id_be = (__u32 *)(payload + 8);
    __u16 *packet_index_be = (__u16 *)(payload + 12);
    __u16 *flags_be = (__u16 *)(payload + 14);
    __u16 *body_word = (__u16 *)(payload + 16);
    __u16 old_word;
    __u16 new_word;
    __u32 frame_id;
    __u16 packet_index;

    cfg = bpf_map_lookup_elem(&zt_cfg, &key);
    if (!cfg || !cfg->enabled)
        return XDP_PASS;

    stats = bpf_map_lookup_elem(&zt_stats, &key);
    if (!stats)
        return XDP_PASS;

    if ((void *)(body_word + 1) > data_end) {
        __sync_fetch_and_add(&stats->parse_errors, 1);
        return XDP_PASS;
    }

    if (eth->h_proto != bswap16(ETH_P_IP) ||
        ip->version != 4 || ip->ihl != 5 || ip->protocol != IPPROTO_UDP ||
        ip->saddr != bswap32(0x0a0a0f02) ||
        ip->daddr != bswap32(0x0a0a0f03) ||
        udp->source != bswap16(5602) || udp->dest != bswap16(5602) ||
        udp->len != bswap16(1480) || *magic != bswap32(0x5043414d))
        return XDP_PASS;

    /* Refuse to alter plaintext/bypass traffic. */
    if (!(bswap16(*flags_be) & 1))
        return XDP_PASS;

    packet_index = bswap16(*packet_index_be);
    if (packet_index != cfg->packet_index)
        return XDP_PASS;

    frame_id = bswap32(*frame_id_be);
    __sync_fetch_and_add(&stats->eligible_frames, 1);
    stats->run_id = cfg->run_id;
    stats->last_session_id = bswap32(*session_id_be);
    stats->last_frame_id = frame_id;
    stats->last_packet_index = packet_index;

    if (cfg->rate_percent == 0 || cfg->rate_percent > 100 ||
        frame_id % 100 >= cfg->rate_percent)
        return XDP_PASS;

    __sync_fetch_and_add(&stats->selected_frames, 1);
    old_word = *body_word;
    /* bswap16(1) flips bit 0 of the second ciphertext byte on the wire. */
    new_word = old_word ^ bswap16((__u16)(cfg->bit_mask & 1));
    if (new_word == old_word)
        return XDP_PASS;

    if (udp->check != 0) {
        udp->check = csum_replace2(udp->check, old_word, new_word);
        if (udp->check == 0)
            udp->check = 0xffff;
    }
    *body_word = new_word;

    __sync_fetch_and_add(&stats->modified_frames, 1);
    __sync_fetch_and_add(&stats->modified_packets, 1);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
