#!/usr/bin/env bash
set -uo pipefail

PROJECT=${ZYBO_DEMO_PROJECT:-/home/jetson/projects/zybo-security-demo}
BACKEND_PATTERN='^python3 -u backend/server.py( |$)'
FIREFOX_PATTERN='[f]irefox.*:4173'

# SIGINT lets server.py clean up active Page 2/3 operations before exit.
mapfile -t backend_pids < <(pgrep -f "$BACKEND_PATTERN" || true)
for pid in "${backend_pids[@]}"; do
    kill -INT "$pid" 2>/dev/null || true
done
for _ in $(seq 1 20); do
    pgrep -f "$BACKEND_PATTERN" >/dev/null || break
    sleep 0.5
done
for pid in "${backend_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
done

mapfile -t firefox_pids < <(pgrep -f "$FIREFOX_PATTERN" || true)
for pid in "${firefox_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
done

rm -f "$PROJECT/runtime/backend.pid" "$PROJECT/runtime/firefox-dashboard.pid"
notify-send "Secure Video Dashboard" \
    "Stopped safely — br-video was not changed" 2>/dev/null || true
