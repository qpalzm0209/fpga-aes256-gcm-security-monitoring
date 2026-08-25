#!/usr/bin/env bash
set -Eeuo pipefail

bridge="${BRIDGE_NAME:-br-video}"

if (( EUID != 0 )); then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

ports=()
if [[ -d "/sys/class/net/$bridge/brif" ]]; then
  while IFS= read -r port; do
    [[ -n "$port" ]] && ports+=("$port")
  done < <(find "/sys/class/net/$bridge/brif" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
fi

while IFS= read -r profile; do
  [[ -n "$profile" ]] || continue
  master="$(nmcli -g connection.master connection show "$profile" 2>/dev/null || true)"
  if [[ "$master" == "$bridge" || "$profile" == "$bridge-"* ]]; then
    nmcli connection down "$profile" 2>/dev/null || true
    nmcli connection delete "$profile"
  fi
done < <(nmcli -t -f NAME connection show)

if nmcli -t -f NAME connection show | grep -Fxq "$bridge"; then
  nmcli connection down "$bridge" 2>/dev/null || true
  nmcli connection delete "$bridge"
fi

for port in "${ports[@]}"; do
  nmcli device connect "$port" 2>/dev/null || true
done

echo "$bridge removed; physical Ethernet interfaces returned to NetworkManager."
