#!/usr/bin/env bash
set -uo pipefail

PROJECT=${ZYBO_DEMO_PROJECT:-/home/jetson/projects/zybo-security-demo}
URL=http://127.0.0.1:4173/
API=${URL}api/telemetry/latest
LOG="$PROJECT/runtime/dashboard.log"
BACKEND_PATTERN='^python3 -u backend/server.py( |$)'
FIREFOX_PATTERN='[f]irefox.*:4173'

message() {
    if [ -n "${DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
        zenity "$1" --title="Secure Video Dashboard" --text="$2" \
            --width=430 2>/dev/null || true
    else
        printf '%b\n' "$2"
    fi
}

if [ ! -f "$PROJECT/backend/server.py" ] || \
   [ ! -f "$PROJECT/dashboard/index.html" ]; then
    message --error "Dashboard project files are missing:\n$PROJECT"
    exit 1
fi

# The bridge profile is independent of Zybo carrier state.  Keep waiting for
# NetworkManager instead of assuming a fixed Jetson/Wi-Fi boot duration.
until ip -4 addr show br-video 2>/dev/null | grep -q '10\.10\.15\.1/24'; do
    nmcli connection up br-video >/dev/null 2>&1 || true
    sleep 1
done

cd "$PROJECT" || exit 1
mkdir -p runtime

if ! pgrep -f "$BACKEND_PATTERN" >/dev/null; then
    nohup python3 -u backend/server.py --http-bind 0.0.0.0 >"$LOG" 2>&1 &
    printf '%s\n' "$!" >runtime/backend.pid
fi

until curl -fsS --max-time 1 "$API" >/dev/null 2>&1; do
    pgrep -f "$BACKEND_PATTERN" >/dev/null || {
        message --error "Dashboard backend exited.\nLog: $LOG"
        exit 1
    }
    sleep 1
done

if pgrep -f "$FIREFOX_PATTERN" >/dev/null; then
    pkill -TERM -f "$FIREFOX_PATTERN" || true
    for _ in $(seq 1 20); do
        pgrep -f "$FIREFOX_PATTERN" >/dev/null || break
        sleep 0.25
    done
fi

export DISPLAY="${ZYBO_DASHBOARD_DISPLAY:-:1}"
export XAUTHORITY="${XAUTHORITY:-/run/user/1000/gdm/Xauthority}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"
nohup /usr/bin/firefox --new-window "${URL}?build=$(date +%s)" >runtime/firefox-dashboard.log 2>&1 &
printf '%s\n' "$!" >runtime/firefox-dashboard.pid

live=$(curl -fsS --max-time 2 "$API" | jq -r \
    'if .stream_analysis.live then
         "Jetson packet observer live"
     else
         "Waiting for AES-GCM traffic"
     end' \
    2>/dev/null || printf 'Backend ready')
notify-send "Secure Video Dashboard" "Started — $live" 2>/dev/null || true
