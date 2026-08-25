#!/usr/bin/env bash
set -euo pipefail

PROJECT=/home/jetson/projects/zybo-security-demo
ATTACK_DIR="$PROJECT/tamper"
IFACE=eno1
CFG_PIN=/sys/fs/bpf/tc/globals/zt_cfg
STATS_PIN=/sys/fs/bpf/tc/globals/zt_stats
BPF_MODE_STATE="$ATTACK_DIR/runtime-bpf-dir-modes"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this installer with sudo on the Jetson console." >&2
  exit 1
fi

[[ -f "$ATTACK_DIR/tamper_kern.o" ]] || { echo "missing tamper_kern.o" >&2; exit 1; }
[[ -x "$ATTACK_DIR/tamperctl" ]] || { echo "missing tamperctl" >&2; exit 1; }
[[ "$(cat /sys/class/net/$IFACE/master/ifindex 2>/dev/null || true)" == \
   "$(cat /sys/class/net/br-video/ifindex 2>/dev/null || true)" ]] || {
  echo "$IFACE is not a br-video port; refusing to attach" >&2
  exit 1
}

if ip -details link show dev "$IFACE" | grep -q 'prog/xdp'; then
  if [[ ! -e "$CFG_PIN" || ! -e "$STATS_PIN" ]] ||
     ! "$ATTACK_DIR/tamperctl" status >/dev/null 2>&1; then
    echo "$IFACE has an unknown XDP program; refusing to overwrite it" >&2
    ip -details link show dev "$IFACE" >&2
    exit 1
  fi
  echo "Replacing the known Zybo Tamper XDP program in ATTACK OFF state."
  "$ATTACK_DIR/tamperctl" stop >/dev/null
  ip link set dev "$IFACE" xdpgeneric off
fi

cleanup_failed_install() {
  ip link set dev "$IFACE" xdpgeneric off 2>/dev/null || true
  rm -f "$CFG_PIN" "$STATS_PIN"
  if [[ -f "$BPF_MODE_STATE" ]]; then
    while read -r mode path; do chmod "$mode" "$path" 2>/dev/null || true; done < "$BPF_MODE_STATE"
    rm -f "$BPF_MODE_STATE"
  fi
}
trap cleanup_failed_install ERR

mkdir -p /sys/fs/bpf/tc/globals
: > "$BPF_MODE_STATE"
for path in /sys/fs/bpf /sys/fs/bpf/tc /sys/fs/bpf/tc/globals; do
  printf '%s %s\n' "$(stat -c %a "$path")" "$path" >> "$BPF_MODE_STATE"
  chmod o+x "$path"
done
rm -f "$CFG_PIN" "$STATS_PIN"
ip link set dev "$IFACE" xdpgeneric obj "$ATTACK_DIR/tamper_kern.o" sec xdp

chown jetson:jetson "$CFG_PIN" "$STATS_PIN"
chmod 0600 "$CFG_PIN" "$STATS_PIN"
chown root:jetson "$ATTACK_DIR/tamperctl"
chmod 0750 "$ATTACK_DIR/tamperctl"
setcap cap_bpf=ep "$ATTACK_DIR/tamperctl"
sudo -u jetson "$ATTACK_DIR/tamperctl" stop >/dev/null

trap - ERR
echo "Tamper engine installed in ATTACK OFF state."
ip -details link show dev "$IFACE" | sed -n '/prog\/xdp/,+2p'
sudo -u jetson "$ATTACK_DIR/tamperctl" status
