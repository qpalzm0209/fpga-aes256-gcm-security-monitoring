#!/usr/bin/env bash
set -euo pipefail

PROJECT=/home/jetson/projects/zybo-security-demo
URL=http://127.0.0.1:4173/
FIREFOX_PATTERN='[f]irefox.*:4173'

cd "$PROJECT"
export DISPLAY=:1
export XAUTHORITY=/run/user/1000/gdm/Xauthority
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

if pgrep -f "$FIREFOX_PATTERN" >/dev/null; then
    pkill -TERM -f "$FIREFOX_PATTERN" || true
    for _ in $(seq 1 20); do
        pgrep -f "$FIREFOX_PATTERN" >/dev/null || break
        sleep 0.25
    done
fi

nohup /usr/bin/firefox --new-window "${URL}?build=$(date +%s)" > runtime/firefox-dashboard.log 2>&1 &
PID=$!
printf '%s\n' "$PID" > runtime/firefox-dashboard.pid
sleep 4
pgrep -af firefox
echo "DASHBOARD_LAUNCHED URL=$URL START_PID=$PID"
