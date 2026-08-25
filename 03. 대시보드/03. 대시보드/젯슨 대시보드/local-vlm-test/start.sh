#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
runtime="$root/runtime"
app_port="${VLM_TEST_PORT:-4188}"
model_port="${VLM_MODEL_PORT:-4190}"
pidfile="$runtime/app.pid"
logfile="$runtime/app.log"

"$root/start_model.sh"
export VLM_MODEL_API="${VLM_MODEL_API:-http://127.0.0.1:$model_port}"

if [ -f "$pidfile" ]; then
    old_pid="$(cat "$pidfile")"
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "test app already running pid=$old_pid"
        exit 0
    fi
fi

nohup python3 -u "$root/app.py" --host 0.0.0.0 --port "$app_port" >"$logfile" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$pidfile"
sleep 1
kill -0 "$pid"
curl -fsS "http://127.0.0.1:$app_port/api/status"
printf '\nUI addresses:\n'
for address in $(hostname -I); do
    printf '  http://%s:%s/\n' "$address" "$app_port"
done
