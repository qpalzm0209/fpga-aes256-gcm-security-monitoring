#!/usr/bin/env bash
set -euo pipefail

root="${VLM_ROOT:-/home/jetson/local-vlm-test}"
python="${VLM_PYTHON:-/usr/bin/python3}"
app_port="${VLM_TEST_PORT:-4188}"
model_port="${VLM_MODEL_PORT:-4190}"

export VLM_MODEL_API="${VLM_MODEL_API:-http://127.0.0.1:$model_port}"

"$root/start_model.sh"
exec "$python" -u "$root/app.py" --host 0.0.0.0 --port "$app_port"
