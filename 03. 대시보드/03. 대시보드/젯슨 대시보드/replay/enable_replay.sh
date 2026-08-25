#!/usr/bin/env bash
set -euo pipefail

PROJECT=/home/jetson/projects/zybo-security-demo
BINARY="$PROJECT/replay/replay_engine"

test -x "$BINARY"
sudo /usr/sbin/setcap cap_net_raw=ep "$BINARY"
/usr/sbin/getcap "$BINARY"
echo "Replay capability enabled. No service was installed and no attack was started."
