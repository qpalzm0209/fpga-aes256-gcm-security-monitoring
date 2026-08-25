#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_ROOT="$(mktemp -d)"
cleanup() {
    status=$?
    if (( status != 0 )); then
        echo "FAIL: supervision mock artifacts from $TMP_ROOT" >&2
        find "$TMP_ROOT" -type f -maxdepth 3 -print -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; >&2 || true
    fi
    rm -rf "$TMP_ROOT"
    exit "$status"
}
trap cleanup EXIT

wait_for_lines() {
    local file=$1 expected=$2 attempts=0
    while (( attempts < 100 )); do
        if [[ -r "$file" ]] && (( $(wc -l <"$file") >= expected )); then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    return 1
}

wait_for_file() {
    local file=$1 attempts=0
    while (( attempts < 100 )); do
        [[ -s "$file" ]] && return 0
        attempts=$((attempts + 1))
        sleep 0.1
    done
    return 1
}

run_role_test() {
    local role=$1 script=$2
    local role_dir="$TMP_ROOT/$role"
    mkdir -p "$role_dir/run" "$role_dir/data" "$role_dir/log"

    cat >"$role_dir/fake-wifi" <<'EOF'
#!/bin/sh
calls_file="$AES_SESSION_TEST_WIFI_CALLS"
printf '%s\n' "$1 $2" >>"$calls_file"
case "$1" in
start)
    printf '%s\n' wlan-test >"$AES_SESSION_WIFI_INTERFACE_FILE"
    exit 0
    ;;
health) [ ! -e "$AES_SESSION_TEST_WIFI_DOWN" ]; exit $? ;;
restart)
    rm -f "$AES_SESSION_TEST_WIFI_DOWN"
    printf '%s\n' wlan-test >"$AES_SESSION_WIFI_INTERFACE_FILE"
    exit 0
    ;;
stop) exit 0 ;;
esac
exit 1
EOF

    cat >"$role_dir/fake-agent" <<'EOF'
#!/bin/sh
starts_file="$AES_SESSION_TEST_AGENT_STARTS"
count=0
[ ! -r "$starts_file" ] || count="$(wc -l <"$starts_file")"
printf '%s\n' "$$ $*" >>"$starts_file"
if [ "$count" -lt 1 ]; then
    exit 42
fi
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
    chmod +x "$role_dir/fake-wifi" "$role_dir/fake-agent"

    export AES_SESSION_DAEMON="$role_dir/fake-agent"
    export AES_SESSION_WIFI_INIT="$role_dir/fake-wifi"
    export AES_SESSION_RUN_DIR="$role_dir/run"
    export AES_SESSION_DATA_DIR="$role_dir/data"
    export AES_SESSION_LOGFILE="$role_dir/log/agent.log"
    export AES_SESSION_WIFI_INTERFACE_FILE="$role_dir/run/interface"
    export AES_SESSION_SYS_CLASS_NET="$role_dir/sys"
    mkdir -p "$AES_SESSION_SYS_CLASS_NET/wlan-test/device"
    mkdir -p "$AES_SESSION_SYS_CLASS_NET/wlan-test/wireless"
    export AES_SESSION_PRIVATE_KEY_FILE="$role_dir/private-key"
    export AES_SESSION_PEER_PUBLIC_KEY_FILE="$role_dir/peer-public-key"
    export AES_SESSION_TX_ACTIVE_STATE="$role_dir/run/tx-active"
    export AES_SESSION_CONTROL_BIND=127.0.0.1
    export AES_SESSION_CONTROL_PEER=127.0.0.2
    export AES_SESSION_CONTROL_PORT=46123
    unset AES_SESSION_CONTROL_INTERFACE
    export AES_SESSION_RESTART_DELAY=1
    export AES_SESSION_INIT_SELF="$script"
    export AES_SESSION_TEST_WIFI_CALLS="$role_dir/wifi.calls"
    export AES_SESSION_TEST_AGENT_STARTS="$role_dir/agent.starts"
    export AES_SESSION_TEST_WIFI_DOWN="$role_dir/wifi.down"
    unset AES_SESSION_PEER

    : >"$AES_SESSION_PRIVATE_KEY_FILE"
    : >"$AES_SESSION_PEER_PUBLIC_KEY_FILE"
    sh "$script" start
    wait_for_lines "$AES_SESSION_TEST_WIFI_CALLS" 1
    wait_for_lines "$AES_SESSION_TEST_AGENT_STARTS" 2
    grep -F -- "--counter $role_dir/data/$role-counter" \
        "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null
    grep -F -- "--$role $role_dir/private-key $role_dir/peer-public-key" \
        "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null
    grep -F -- "--interface wlan-test" \
        "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null
    if grep -F -- '--interface eth-test' \
        "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null; then
        echo "FAIL: $role agent bound key exchange to wired Ethernet" >&2
        return 1
    fi
    if [[ "$role" == tx ]]; then
        if grep -F -- ' --peer ' "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null; then
            echo "FAIL: TX init embedded a fixed RX peer" >&2
            return 1
        fi
        grep -F -- "--active-state $role_dir/run/tx-active" \
            "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null
        grep -F -- "--control-bind 127.0.0.1 --control-port 46123" \
            "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null
        grep -F -- "--control-peer 127.0.0.2" \
            "$AES_SESSION_TEST_AGENT_STARTS" >/dev/null
    fi
    sh "$script" status

    # A removed/reinserted USB dongle gives the replacement interface a new
    # ifindex.  The live agent must be terminated, Wi-Fi restarted, and the
    # agent relaunched against a freshly discovered interface without reboot.
    : >"$AES_SESSION_TEST_WIFI_DOWN"
    wait_for_lines "$AES_SESSION_TEST_AGENT_STARTS" 3
    grep -F -- "restart $role" "$AES_SESSION_TEST_WIFI_CALLS" >/dev/null
    [[ ! -e "$AES_SESSION_TEST_WIFI_DOWN" ]]

    local starts_before_stop
    starts_before_stop="$(wc -l <"$AES_SESSION_TEST_AGENT_STARTS")"
    sh "$script" stop
    [[ ! -e "$role_dir/run/aes-session-agent-$role.pid" ]]
    [[ ! -e "$role_dir/run/aes-session-agent-$role.child.pid" ]]
    [[ ! -e "$role_dir/run/aes-session-wifi-$role.child.pid" ]]
    sleep 2
    [[ "$(wc -l <"$AES_SESSION_TEST_AGENT_STARTS")" == "$starts_before_stop" ]]

    # restart must remain usable after a clean stop and must leave exactly one
    # live supervisor/agent pair rather than reviving the stopped generation.
    sh "$script" restart
    wait_for_file "$role_dir/run/aes-session-agent-$role.child.pid"
    sh "$script" status
    sh "$script" stop
}

run_role_test tx "$ROOT_DIR/aes-session-tx.init"
run_role_test rx "$ROOT_DIR/aes-session-rx.init"
echo "PASS: TX/RX init supervisors restart crashes and honor stop/restart"
