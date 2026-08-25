#!/usr/bin/env bash
set -uo pipefail

API=http://127.0.0.1:4173/api/telemetry/latest
BACKEND_PATTERN='^python3 -u backend/server.py( |$)'
FIREFOX_PATTERN='[f]irefox.*:4173'
backend=STOPPED
screen=STOPPED
bridge=NOT_READY
telemetry=WAITING
details=""

pgrep -f "$BACKEND_PATTERN" >/dev/null && backend=RUNNING
pgrep -f "$FIREFOX_PATTERN" >/dev/null && screen=RUNNING
ip -4 addr show br-video 2>/dev/null | grep -q '10\.10\.15\.1/24' && bridge=READY

if snapshot=$(curl -fsS --max-time 2 "$API" 2>/dev/null); then
    telemetry=$(jq -r 'if .live then "LIVE" else "WAITING" end' <<<"$snapshot")
    details=$(jq -r 'if .telemetry then "RX FPS: \(.telemetry.valid_frame_rate)\nSession: \(.telemetry.session_id)\nAge: \(.age_ms) ms" else "No RX telemetry received yet" end' <<<"$snapshot")
fi

zenity --info --title="Secure Video Dashboard Status" --width=440 \
    --text="Backend: $backend\nDashboard screen: $screen\nbr-video: $bridge\nRX telemetry: $telemetry\n\n$details" 2>/dev/null || \
    printf 'Backend: %s\nScreen: %s\nbr-video: %s\nTelemetry: %s\n%s\n' \
        "$backend" "$screen" "$bridge" "$telemetry" "$details"
