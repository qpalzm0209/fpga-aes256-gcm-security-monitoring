#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
for name in app model-server; do
    pidfile="$root/runtime/$name.pid"
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile")"
    command_line="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$command_line" in
        *"$root"*|*llama-server*) kill "$pid" 2>/dev/null || true ;;
        *) echo "refusing to stop unrelated pid=$pid command=$command_line" >&2 ;;
    esac
done
echo "local VLM test stopped"
