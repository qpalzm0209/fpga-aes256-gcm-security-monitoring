#!/usr/bin/env bash
set -euo pipefail

PROJECT=${PROJECT:-/home/jetson/projects/zybo-security-demo}
SYS_CLASS_NET=${SYS_CLASS_NET:-/sys/class/net}
BRIDGE_PORT=${BRIDGE_PORT:-eno1}
BRIDGE_NAME=${BRIDGE_NAME:-br-video}
WAIT_INTERVAL=${WAIT_INTERVAL:-1}

while :; do
    port_master=$(cat "$SYS_CLASS_NET/$BRIDGE_PORT/master/ifindex" 2>/dev/null || true)
    bridge_index=$(cat "$SYS_CLASS_NET/$BRIDGE_NAME/ifindex" 2>/dev/null || true)
    if [ -n "$bridge_index" ] && [ "$port_master" = "$bridge_index" ]; then
        exec "$PROJECT/tamper/install_tamper.sh"
    fi
    sleep "$WAIT_INTERVAL"
done
