#!/bin/sh
set -eu

test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
binary="${TMPDIR:-/tmp}/test_tx_session_gate.$$"
trap 'rm -f "$binary"' EXIT HUP INT TERM

${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -pthread \
    -I"$test_dir" "$test_dir/test_tx_session_gate.c" -o "$binary"
"$binary"
