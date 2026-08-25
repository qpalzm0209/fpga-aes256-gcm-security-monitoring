#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
grep -Fqx '    ssid="KCCI_STC_S"' "$ROOT_DIR/wpa.conf"
grep -Fqx '    psk=ad0f7abffa912d27479c591006d190b60bb385c4b31fa086f264559dbb7e824d' "$ROOT_DIR/wpa.conf"
for role in tx rx; do
    grep -Fqx "WIFI_PIDFILE=\$RUN_DIR/aes-session-wifi-$role.child.pid" \
        "$ROOT_DIR/aes-session-$role.init"
    grep -Fqx 'CONTROL_INTERFACE=${AES_SESSION_CONTROL_INTERFACE:-}' \
        "$ROOT_DIR/aes-session-$role.init"
    grep -Fq 'Never' "$ROOT_DIR/aes-session-$role.init"
    ! grep -Fq 'Wired control' "$ROOT_DIR/aes-session-$role.init"
done
TMP_ROOT="$(mktemp -d)"
cleanup() {
    for role in tx rx; do
        script="$ROOT_DIR/aes-session-$role.init"
        AES_SESSION_RUN_DIR="$TMP_ROOT/supervisor-$role/run" \
        AES_SESSION_INIT_SELF="$script" \
            sh "$script" stop >/dev/null 2>&1 || true
    done
    if [[ -r "$TMP_ROOT/wifi/wpa.pid" ]]; then
        kill "$(cat "$TMP_ROOT/wifi/wpa.pid")" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

wait_for_lines() {
    local file=$1 expected=$2 attempts=0
    while (( attempts < 150 )); do
        if [[ -r "$file" ]] && (( $(wc -l <"$file") >= expected )); then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    return 1
}

wait_for_value() {
    local file=$1 expected=$2 attempts=0
    while (( attempts < 150 )); do
        [[ -r "$file" ]] && [[ "$(cat "$file")" == "$expected" ]] && return 0
        attempts=$((attempts + 1))
        sleep 0.1
    done
    return 1
}

test_wifi_ensure() {
    local test_dir="$TMP_ROOT/wifi"
    mkdir -p "$test_dir/bin" "$test_dir/sys/wlan0" "$test_dir/ctrl"
    printf '%s\n' 10 >"$test_dir/sys/wlan0/ifindex"
    printf '%s\n' 0x1003 >"$test_dir/sys/wlan0/flags"
    printf '%s\n' COMPLETED >"$test_dir/wpa.state"
    : >"$test_dir/wpa.conf"

    cat >"$test_dir/bin/wpa_supplicant" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --worker ]; then
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
fi
pidfile=
while [ "$#" -gt 0 ]; do
    [ "$1" != -P ] || { shift; pidfile="$1"; }
    shift
done
"$0" --worker >/dev/null 2>&1 &
printf '%s\n' "$!" >"$pidfile"
printf '%s\n' start >>"$FAKE_WPA_STARTS"
printf '%s\n' COMPLETED >"$FAKE_WPA_STATE"
EOF

    cat >"$test_dir/bin/wpa_cli" <<'EOF'
#!/bin/sh
command=
for argument in "$@"; do command="$argument"; done
case "$command" in
ping)
    [ -r "$AES_SESSION_WIFI_PIDFILE" ] || exit 1
    kill -0 "$(cat "$AES_SESSION_WIFI_PIDFILE")" 2>/dev/null || exit 1
    echo PONG
    ;;
status)
    printf 'wpa_state=%s\n' "$(cat "$FAKE_WPA_STATE")"
    ;;
reconnect)
    [ "$(cat "$FAKE_WPA_STATE")" = INTERFACE_DISABLED ] ||
        printf '%s\n' COMPLETED >"$FAKE_WPA_STATE"
    ;;
terminate)
    [ ! -r "$AES_SESSION_WIFI_PIDFILE" ] ||
        kill "$(cat "$AES_SESSION_WIFI_PIDFILE")" 2>/dev/null || true
    ;;
esac
EOF

    cat >"$test_dir/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_IP_LOG"
case "$1 $2" in
'link set')
    printf '%s\n' 0x1003 >"$AES_SESSION_SYS_CLASS_NET/$3/flags"
    ;;
'addr replace')
    printf '%s\n' "$3" >"$FAKE_IP_STATE/addr-$5"
    ;;
'-4 addr')
    [ -r "$FAKE_IP_STATE/addr-$5" ] &&
        printf '    inet %s scope global %s\n' "$(cat "$FAKE_IP_STATE/addr-$5")" "$5"
    ;;
esac
EOF

    cat >"$test_dir/bin/udhcpc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_UDHCPC_LOG"
exit 0
EOF
    chmod +x "$test_dir/bin/"*

    export AES_SESSION_WIFI_CONF="$test_dir/wpa.conf"
    export AES_SESSION_WIFI_PIDFILE="$test_dir/wpa.pid"
    export AES_SESSION_WIFI_INTERFACE_FILE="$test_dir/interface"
    export AES_SESSION_WIFI_IDENTITY_FILE="$test_dir/identity"
    export AES_SESSION_SYS_CLASS_NET="$test_dir/sys"
    export AES_SESSION_WPA_CTRL_DIR="$test_dir/ctrl"
    export AES_SESSION_WPA_SUPPLICANT="$test_dir/bin/wpa_supplicant"
    export AES_SESSION_WPA_CLI="$test_dir/bin/wpa_cli"
    export AES_SESSION_IP="$test_dir/bin/ip"
    export AES_SESSION_UDHCPC="$test_dir/bin/udhcpc"
    export AES_SESSION_WIFI_FIND_ATTEMPTS=2
    export AES_SESSION_WIFI_ASSOC_ATTEMPTS=2
    export FAKE_WPA_STATE="$test_dir/wpa.state"
    export FAKE_WPA_STARTS="$test_dir/wpa.starts"
    export FAKE_IP_LOG="$test_dir/ip.log"
    export FAKE_IP_STATE="$test_dir"
    export FAKE_UDHCPC_LOG="$test_dir/udhcpc.log"

    sh "$ROOT_DIR/aes-session-wifi" start tx
    [[ "$(cat "$test_dir/identity")" == 'wlan0 10' ]]
    [[ "$(wc -l <"$FAKE_WPA_STARTS")" == 1 ]]
    sh "$ROOT_DIR/aes-session-wifi" health tx

    # A live PID with INTERFACE_DISABLED must be replaced, not trusted.
    printf '%s\n' INTERFACE_DISABLED >"$FAKE_WPA_STATE"
    sh "$ROOT_DIR/aes-session-wifi" start tx
    [[ "$(wc -l <"$FAKE_WPA_STARTS")" == 2 ]]
    [[ "$(cat "$test_dir/identity")" == 'wlan0 10' ]]

    # restart must retain the role and therefore restore TX link-local state.
    sh "$ROOT_DIR/aes-session-wifi" restart tx
    [[ "$(wc -l <"$FAKE_WPA_STARTS")" == 3 ]]
    grep -q 'addr replace 169.254.77.2/24 dev wlan0' "$FAKE_IP_LOG"
    ! grep -q '^neigh ' "$FAKE_IP_LOG"

    # USB re-enumeration can change both interface name and ifindex.
    rm -rf "$test_dir/sys/wlan0"
    mkdir -p "$test_dir/sys/wlan1"
    printf '%s\n' 11 >"$test_dir/sys/wlan1/ifindex"
    printf '%s\n' 0x1003 >"$test_dir/sys/wlan1/flags"
    sh "$ROOT_DIR/aes-session-wifi" start tx
    [[ "$(cat "$test_dir/identity")" == 'wlan1 11' ]]
    [[ "$(wc -l <"$FAKE_WPA_STARTS")" == 4 ]]

    printf '%s\n' SCANNING >"$FAKE_WPA_STATE"
    set +e
    sh "$ROOT_DIR/aes-session-wifi" health tx
    local scanning_status=$?
    set -e
    [[ "$scanning_status" == 1 ]]
    printf '%s\n' INTERFACE_DISABLED >"$FAKE_WPA_STATE"
    set +e
    sh "$ROOT_DIR/aes-session-wifi" health tx
    local disabled_status=$?
    set -e
    [[ "$disabled_status" == 2 ]]

    sh "$ROOT_DIR/aes-session-wifi" stop

    # Some MT7601U dongles fail their first cold-boot probe before a wl*
    # interface exists.  The service must reset USB once and then continue
    # normal role discovery without relying on a physical replug.
    cat >"$test_dir/bin/usb-recover" <<'EOF'
#!/bin/sh
mkdir -p "$AES_SESSION_SYS_CLASS_NET/wlan2"
printf '%s\n' 12 >"$AES_SESSION_SYS_CLASS_NET/wlan2/ifindex"
printf '%s\n' 0x1003 >"$AES_SESSION_SYS_CLASS_NET/wlan2/flags"
printf '%s\n' recovered >>"$FAKE_USB_RECOVERY_LOG"
EOF
    chmod +x "$test_dir/bin/usb-recover"
    rm -rf "$test_dir/sys/wlan1"
    printf '%s\n' COMPLETED >"$FAKE_WPA_STATE"
    export AES_SESSION_USB_RECOVERY_AFTER=1
    export AES_SESSION_USB_RECOVERY_HOOK="$test_dir/bin/usb-recover"
    export FAKE_USB_RECOVERY_LOG="$test_dir/usb-recovery.log"
    sh "$ROOT_DIR/aes-session-wifi" start rx
    [[ "$(cat "$test_dir/identity")" == 'wlan2 12' ]]
    [[ "$(cat "$FAKE_USB_RECOVERY_LOG")" == recovered ]]
    grep -q 'addr replace 169.254.77.3/24 dev wlan2' "$FAKE_IP_LOG"
    sh "$ROOT_DIR/aes-session-wifi" stop
    unset AES_SESSION_USB_RECOVERY_AFTER AES_SESSION_USB_RECOVERY_HOOK
    echo 'PASS: Wi-Fi ensure replaces stale/disabled wpa and preserves restart role'
}

test_supervisor_isolation() {
    local role=$1
    local script="$ROOT_DIR/aes-session-$role.init"
    local test_dir="$TMP_ROOT/supervisor-$role"
    mkdir -p "$test_dir/run" "$test_dir/data" "$test_dir/log"

    cat >"$test_dir/fake-wifi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_WIFI_CALLS"
case "$1" in
start)
    printf '%s\n' wlan-test >"$AES_SESSION_WIFI_INTERFACE_FILE"
    exit 0
    ;;
health) exit 0 ;;
stop) exit 0 ;;
esac
exit 1
EOF

    cat >"$test_dir/fake-agent" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_AGENT_STARTS"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
    chmod +x "$test_dir/fake-wifi" "$test_dir/fake-agent"

    export AES_SESSION_DAEMON="$test_dir/fake-agent"
    export AES_SESSION_WIFI_INIT="$test_dir/fake-wifi"
    export AES_SESSION_RUN_DIR="$test_dir/run"
    export AES_SESSION_DATA_DIR="$test_dir/data"
    export AES_SESSION_LOGFILE="$test_dir/log/service.log"
    export AES_SESSION_WIFI_INTERFACE_FILE="$test_dir/run/interface"
    export AES_SESSION_WIFI_IDENTITY_FILE="$test_dir/run/interface.identity"
    export AES_SESSION_SYS_CLASS_NET="$test_dir/sys"
    mkdir -p "$AES_SESSION_SYS_CLASS_NET/aaa-tun0"
    mkdir -p "$AES_SESSION_SYS_CLASS_NET/lan-runtime/device"
    mkdir -p "$AES_SESSION_SYS_CLASS_NET/wlan-test/device"
    mkdir -p "$AES_SESSION_SYS_CLASS_NET/wlan-test/wireless"
    export AES_SESSION_KEY_FILE="$test_dir/dummy-key"
    unset AES_SESSION_CONTROL_INTERFACE
    export AES_SESSION_RESTART_DELAY=0.1
    export AES_SESSION_INIT_SELF="$script"
    export TEST_WIFI_CALLS="$test_dir/wifi.calls"
    export TEST_AGENT_STARTS="$test_dir/agent.starts"
    : >"$AES_SESSION_KEY_FILE"

    sh "$script" start
    wait_for_lines "$TEST_WIFI_CALLS" 1
    wait_for_lines "$TEST_AGENT_STARTS" 1
    [[ "$(sed -n '1p' "$TEST_AGENT_STARTS")" == *'--interface wlan-test'* ]]
    [[ "$(sed -n '1p' "$TEST_AGENT_STARTS")" != *'--interface lan-runtime'* ]]
    sleep 0.3
    [[ "$(wc -l <"$TEST_AGENT_STARTS")" == 1 ]]
    grep -q "^start $role$" "$TEST_WIFI_CALLS"
    grep -q "^health $role$" "$TEST_WIFI_CALLS"

    sh "$script" stop
    [[ ! -e "$test_dir/run/aes-session-wifi-$role.child.pid" ]]

    unset AES_SESSION_SYS_CLASS_NET
    echo "PASS: $role key exchange binds USB Wi-Fi and rejects wired/virtual NICs"
}

test_wifi_ensure
test_supervisor_isolation tx
test_supervisor_isolation rx
echo 'PASS: all Wi-Fi recovery host mocks'
