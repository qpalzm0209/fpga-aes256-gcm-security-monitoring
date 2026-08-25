#!/usr/bin/env bash
set -Eeuo pipefail

bridge="${BRIDGE_NAME:-br-video}"
address="${BRIDGE_ADDRESS:-10.10.15.1/24}"

if (( EUID != 0 )); then
  echo "Run with sudo: sudo $0 [tx-side-interface rx-side-interface]" >&2
  exit 1
fi

discover_ports() {
  local path name
  for path in /sys/class/net/*; do
    name="${path##*/}"
    [[ -e "$path/device" ]] || continue
    [[ ! -d "$path/wireless" ]] || continue
    [[ "$(<"$path/type")" == 1 ]] || continue
    [[ "$name" != "$bridge" ]] || continue
    printf '%s\n' "$name"
  done
}

if (( $# == 2 )); then
  ports=("$1" "$2")
elif (( $# == 0 )); then
  mapfile -t ports < <(discover_ports)
  if (( ${#ports[@]} != 2 )); then
    echo "Expected exactly two physical Ethernet interfaces; found ${#ports[@]}." >&2
    printf 'Detected: %s\n' "${ports[*]:-(none)}" >&2
    echo "Specify both interfaces: sudo $0 <tx-side> <rx-side>" >&2
    exit 2
  fi
else
  echo "Usage: sudo $0 [tx-side-interface rx-side-interface]" >&2
  exit 2
fi

for port in "${ports[@]}"; do
  ip link show dev "$port" >/dev/null
done

if ! nmcli -t -f NAME connection show | grep -Fxq "$bridge"; then
  nmcli connection add type bridge con-name "$bridge" ifname "$bridge"
fi

nmcli connection modify "$bridge" \
  connection.autoconnect yes \
  ipv4.method manual \
  ipv4.addresses "$address" \
  ipv4.gateway '' \
  ipv4.dns '' \
  ipv4.never-default yes \
  ipv4.ignore-auto-routes yes \
  ipv4.ignore-auto-dns yes \
  ipv6.method disabled \
  bridge.stp no \
  bridge.forward-delay 0

for port in "${ports[@]}"; do
  profile="${bridge}-${port}"
  if ! nmcli -t -f NAME connection show | grep -Fxq "$profile"; then
    nmcli connection add type ethernet slave-type bridge con-name "$profile" ifname "$port" master "$bridge"
  fi
  nmcli connection modify "$profile" connection.autoconnect yes connection.interface-name "$port" connection.master "$bridge"
done

nmcli connection up "$bridge"
for port in "${ports[@]}"; do
  nmcli connection up "${bridge}-${port}"
done

ip -4 -o address show dev "$bridge" | grep -Fq "${address%/*}/"
for port in "${ports[@]}"; do
  bridge link show dev "$port" | grep -Fq "master $bridge"
done

echo "$bridge ready: ${ports[0]} <-> ${ports[1]} ($address)"
