#!/usr/bin/env bash
set -euo pipefail

IFACE=eno1
MODE_STATE=/home/jetson/projects/zybo-security-demo/tamper/runtime-bpf-dir-modes

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this rollback with sudo on the Jetson console." >&2
  exit 1
fi

/home/jetson/projects/zybo-security-demo/tamper/tamperctl stop 2>/dev/null || true
ip link set dev "$IFACE" xdpgeneric off 2>/dev/null || true
rm -f /sys/fs/bpf/tc/globals/zt_cfg /sys/fs/bpf/tc/globals/zt_stats
if [[ -f "$MODE_STATE" ]]; then
  while read -r mode path; do chmod "$mode" "$path" 2>/dev/null || true; done < "$MODE_STATE"
  rm -f "$MODE_STATE"
fi

echo "Tamper engine detached; br-video and NetworkManager were not changed."
ip -details link show dev "$IFACE"
