#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
runtime="$root/runtime"
server="${LLAMA_SERVER:-$runtime/llama.cpp/build/bin/llama-server}"
model="${VLM_MODEL_FILE:-$root/models/Cosmos-Reason2-2B-Q4_K_M.gguf}"
mmproj="${VLM_MMPROJ_FILE:-$root/models/mmproj-Cosmos-Reason2-2B-F16.gguf}"
port="${VLM_MODEL_PORT:-4190}"
pidfile="$runtime/model-server.pid"
logfile="$runtime/model-server.log"

mkdir -p "$runtime"
test -x "$server" || { echo "llama-server not found: $server" >&2; exit 1; }
test -s "$model" || { echo "model not found: $model" >&2; exit 1; }
test -s "$mmproj" || { echo "vision projector not found: $mmproj" >&2; exit 1; }

if [ -f "$pidfile" ]; then
    old_pid="$(cat "$pidfile")"
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "model server already running pid=$old_pid"
        exit 0
    fi
fi

nohup "$server" \
    --model "$model" \
    --mmproj "$mmproj" \
    --host 127.0.0.1 \
    --port "$port" \
    --n-gpu-layers 99 \
    --ctx-size 4096 \
    --parallel 1 \
    --batch-size 256 \
    --ubatch-size 128 \
    --threads 6 \
    --no-webui \
    --reasoning-format none \
    >"$logfile" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$pidfile"

for _ in $(seq 1 240); do
    if ! kill -0 "$pid" 2>/dev/null; then
        tail -80 "$logfile" >&2
        exit 1
    fi
    if curl -fsS "http://127.0.0.1:$port/health" | grep -q '"status":"ok"'; then
        echo "model server ready pid=$pid port=$port"
        exit 0
    fi
    sleep 1
done

echo "model server did not become ready" >&2
tail -80 "$logfile" >&2
exit 1
