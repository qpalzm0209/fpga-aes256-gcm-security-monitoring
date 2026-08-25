#!/bin/sh
set -eu

# Every fault scenario uses the production localhost port.  Serialize parallel
# `make test` invocations so one test process cannot impersonate another RX.
exec 9>"${TMPDIR:-/tmp}/aes-session-recovery-test.lock"
flock 9

tmp_dir="$(mktemp -d)"
rx_pid=""
tx_pid=""
cleanup() {
    if [ -n "$tx_pid" ]; then
        kill "$tx_pid" 2>/dev/null || true
        wait "$tx_pid" 2>/dev/null || true
    fi
    if [ -n "$rx_pid" ]; then
        kill "$rx_pid" 2>/dev/null || true
        wait "$rx_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

wait_for_file() {
    file="$1"
    loops=0
    while [ ! -f "$file" ] && [ "$loops" -lt 100 ]; do
        sleep 0.1
        loops=$((loops + 1))
    done
    test -f "$file"
}

session_from_log() {
    pattern="$1"
    file="$2"
    awk -v pattern="$pattern" 'index($0, pattern) { print $3; exit }' "$file"
}

cc -O2 -Wall -Wextra -Werror -std=c11 -DAES_SESSION_FAULT_TEST \
    aes_session_agent.c aes_session_regs.c ecdh_session_crypto.c \
    -o "$tmp_dir/aes-session-agent-test" -lcrypto

# Exact weak-profile derivation and strict Jetson management parsing are
# deterministic host-only checks and do not need a live RX process.
AES_SESSION_TEST_WEAK_KEY=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/weak-key-counter" \
    >"$tmp_dir/weak-key.log" 2>&1
grep -q "exact ZYBO-SEED-v1 weak-key derivation" "$tmp_dir/weak-key.log"

AES_SESSION_TEST_MANAGEMENT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/management-counter" \
    >"$tmp_dir/management.log" 2>&1
grep -q "strict management parsing and request-id reply cache" \
    "$tmp_dir/management.log"

# Pure control-state regression: a termination generation observed during a
# failed exchange must not be lost, and a fresh request must stay behind an
# unfinished local CLEAR/COMMIT instead of letting RX advance first.
AES_SESSION_TEST_CONTROL_STATE=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/control-state-counter" \
    >"$tmp_dir/control-state.log" 2>&1
grep -q "TX termination event retention and PL-update gating" \
    "$tmp_dir/control-state.log"

# Production init intentionally omits --peer so RX's UDP announcement selects
# its current DHCP source address.  Exercise that discovery path end to end,
# with no Jetson management sender and no fixed peer address.
"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once --counter "$tmp_dir/discovery-rx-state" \
    >"$tmp_dir/discovery-rx.log" 2>&1 &
rx_pid=$!
sleep 1

"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --no-hardware --once --counter "$tmp_dir/discovery-tx-counter" \
    >"$tmp_dir/discovery-tx.log" 2>&1
wait "$rx_pid"
rx_pid=""
grep -q "waiting for RX discovery" "$tmp_dir/discovery-tx.log"
grep -q "committed and confirmed" "$tmp_dir/discovery-tx.log"
grep -q "committed and confirmed" "$tmp_dir/discovery-rx.log"

# JTAG/RAM boot deliberately has no persistent local counter.  After an
# initial session, emulate a TX-only power cycle by deleting both volatile TX
# records while RX retains its authenticated replay floor.  RX must return an
# encrypted, candidate-bound floor response; TX advances to floor+1 and both
# sides converge without an SD card, fixed address, or manual state injection.
"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once --counter "$tmp_dir/floor-rx-state" \
    >"$tmp_dir/floor-rx1.log" 2>&1 &
rx_pid=$!
sleep 1

"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/floor-tx-counter" \
    --active-state "$tmp_dir/floor-tx-active" \
    >"$tmp_dir/floor-tx1.log" 2>&1
wait "$rx_pid"
rx_pid=""
test "$(sed -n '1p' "$tmp_dir/floor-tx-counter")" = 1
test "$(sed -n '1p' "$tmp_dir/floor-rx-state")" = 1

rm -f "$tmp_dir/floor-tx-counter" "$tmp_dir/floor-tx-active"
"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once --counter "$tmp_dir/floor-rx-state" \
    >"$tmp_dir/floor-rx2.log" 2>&1 &
rx_pid=$!
sleep 1

"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/floor-tx-counter" \
    --active-state "$tmp_dir/floor-tx-active" \
    >"$tmp_dir/floor-tx2.log" 2>&1
wait "$rx_pid"
rx_pid=""

grep -q "accepted authenticated RX counter floor 1" \
    "$tmp_dir/floor-tx2.log"
grep -q "rejected stale session counter 1.*floor 1" \
    "$tmp_dir/floor-rx2.log"
grep -q "counter 2 committed and confirmed" "$tmp_dir/floor-tx2.log"
grep -q "counter 2 committed and confirmed" "$tmp_dir/floor-rx2.log"
test "$(sed -n '1p' "$tmp_dir/floor-tx-counter")" = 2
test "$(sed -n '1p' "$tmp_dir/floor-rx-state")" = 2

# A lost first DONE must make TX retry the exact capsule.  RX recognizes the
# durable identity, returns DONE idempotently, and then accepts TERMINATE.
AES_SESSION_DROP_DONE_ONCE="$tmp_dir/drop-done.marker" \
AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/rx-state" >"$tmp_dir/rx.log" 2>&1 &
rx_pid=$!
sleep 1

AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/tx-counter" >"$tmp_dir/tx.log" 2>&1
wait "$rx_pid"
rx_pid=""

grep -q "retaining pending key and retrying" "$tmp_dir/tx.log"
grep -q "committed and confirmed" "$tmp_dir/tx.log"
grep -q "reconfirmed after duplicate" "$tmp_dir/rx.log"
grep -q "terminated on both boards" "$tmp_dir/tx.log"
grep -q "terminated and key cleared" "$tmp_dir/rx.log"
test "$(wc -l < "$tmp_dir/rx-state")" -eq 8
test "$(stat -c %a "$tmp_dir/rx-state")" = 600
test "$(sed -n '7p' "$tmp_dir/rx-state")" = 1
test "$(sed -n '8p' "$tmp_dir/rx-state")" = TERMINATED

# RX1 exits after the PL commit point while the durable record is still
# PENDING.  RX2 must replay/promote that exact authorized key to ACTIVE and
# let TX finish without allocating another counter or capsule.
AES_SESSION_EXIT_AFTER_PL_COMMIT_ONCE="$tmp_dir/pl-commit.marker" \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/pending-rx-state" >"$tmp_dir/pending-rx1.log" 2>&1 &
rx_pid=$!
sleep 1

"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/pending-tx-counter" >"$tmp_dir/pending-tx.log" 2>&1 &
tx_pid=$!

wait_for_file "$tmp_dir/pl-commit.marker"
wait "$rx_pid" || true
rx_pid=""
test "$(sed -n '8p' "$tmp_dir/pending-rx-state")" = PENDING

"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/pending-rx-state" >"$tmp_dir/pending-rx2.log" 2>&1 &
rx_pid=$!
wait "$tx_pid"
tx_pid=""
wait "$rx_pid"
rx_pid=""

grep -q "RX recovered session .* (active)" "$tmp_dir/pending-rx2.log"
grep -q "reconfirmed after duplicate" "$tmp_dir/pending-rx2.log"
grep -q "committed and confirmed" "$tmp_dir/pending-tx.log"
test "$(sed -n '1p' "$tmp_dir/pending-tx-counter")" = 1
test "$(sed -n '1p' "$tmp_dir/pending-rx-state")" = 1
test "$(sed -n '8p' "$tmp_dir/pending-rx-state")" = ACTIVE

# Establish active A, then inject BTN3 cancellation immediately after RX has
# committed B and returned DONE.  TX must terminate with B, not stale A.
AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/race-rx-state" >"$tmp_dir/race-rx.log" 2>&1 &
rx_pid=$!
sleep 1

AES_SESSION_TEST_REKEY_CANCEL_AFTER_DONE=1 \
"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/race-tx-counter" >"$tmp_dir/race-tx.log" 2>&1
wait "$rx_pid"
rx_pid=""

old_session="$(session_from_log 'committed and confirmed' "$tmp_dir/race-tx.log")"
candidate_session="$(session_from_log 'remote DONE received' "$tmp_dir/race-tx.log")"
terminated_session="$(session_from_log 'terminated on both boards' "$tmp_dir/race-tx.log")"
rx_terminated_session="$(session_from_log 'terminated and key cleared' "$tmp_dir/race-rx.log")"

test -n "$old_session"
test -n "$candidate_session"
test "$old_session" != "$candidate_session"
test "$candidate_session" = "$terminated_session"
test "$candidate_session" = "$rx_terminated_session"

# The same race with final BTN3 level already released must still be detected
# by termination_count; a level-only implementation would incorrectly commit B.
AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/pulse-rx-state" >"$tmp_dir/pulse-rx.log" 2>&1 &
rx_pid=$!
sleep 1

AES_SESSION_TEST_REKEY_PRESS_RELEASE=1 \
"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/pulse-tx-counter" >"$tmp_dir/pulse-tx.log" 2>&1
wait "$rx_pid"
rx_pid=""

pulse_candidate="$(session_from_log 'remote DONE received' "$tmp_dir/pulse-tx.log")"
pulse_terminated="$(session_from_log 'terminated on both boards' "$tmp_dir/pulse-tx.log")"
test -n "$pulse_candidate"
test "$pulse_candidate" = "$pulse_terminated"

# RX1 clears A and durably records its tombstone, but loses TERMINATED and
# exits.  RX2 must decrypt the exact persisted capsule and authenticate TX's
# retry without generating a new counter/session.
AES_SESSION_DROP_TERMINATED_ONCE="$tmp_dir/drop-terminated.marker" \
AES_SESSION_EXIT_AFTER_DROP_TERMINATED=1 \
AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/restart-rx-state" >"$tmp_dir/restart-rx1.log" 2>&1 &
rx_pid=$!
sleep 1

AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
AES_SESSION_TEST_RETRY_TERMINATE=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/restart-tx-counter" >"$tmp_dir/restart-tx.log" 2>&1 &
tx_pid=$!

wait_for_file "$tmp_dir/drop-terminated.marker"
wait "$rx_pid"
rx_pid=""
state_hash_before="$(sha256sum "$tmp_dir/restart-rx-state" | awk '{print $1}')"

"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/restart-rx-state" >"$tmp_dir/restart-rx2.log" 2>&1 &
rx_pid=$!
wait "$tx_pid"
tx_pid=""
wait "$rx_pid"
rx_pid=""
state_hash_after="$(sha256sum "$tmp_dir/restart-rx-state" | awk '{print $1}')"

grep -q "termination; retrying" "$tmp_dir/restart-tx.log"
grep -q "RX recovered session .* (terminated)" "$tmp_dir/restart-rx2.log"
grep -q "terminated on both boards" "$tmp_dir/restart-tx.log"
grep -q "terminated and key cleared" "$tmp_dir/restart-rx2.log"
test "$state_hash_before" = "$state_hash_after"
test "$(stat -c %a "$tmp_dir/restart-rx-state")" = 600
test "$(sed -n '7p' "$tmp_dir/restart-rx-state")" = 1
test "$(sed -n '8p' "$tmp_dir/restart-rx-state")" = TERMINATED

# If TERMINATED(A) remains unavailable but BTN3 has been released, the new RTL
# request must exchange fresh C instead of leaving video blocked forever.
AES_SESSION_DROP_TERMINATED_ONCE="$tmp_dir/release-drop.marker" \
AES_SESSION_EXIT_AFTER_DROP_TERMINATED=1 \
AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/release-rx-state" >"$tmp_dir/release-rx1.log" 2>&1 &
rx_pid=$!
sleep 1

AES_SESSION_TEST_RELEASE_REKEY_AFTER_LOST_TERMINATE=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/release-tx-counter" \
    --active-state "$tmp_dir/release-tx-active" \
    >"$tmp_dir/release-tx.log" 2>&1 &
tx_pid=$!

wait_for_file "$tmp_dir/release-drop.marker"
wait "$rx_pid"
rx_pid=""

"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/release-rx-state" >"$tmp_dir/release-rx2.log" 2>&1 &
rx_pid=$!
wait "$tx_pid"
tx_pid=""
wait "$rx_pid"
rx_pid=""

release_a="$(session_from_log 'committed and confirmed' "$tmp_dir/release-tx.log")"
release_c="$(awk '/release request superseded/ { print $9; exit }' \
    "$tmp_dir/release-tx.log")"
release_committed_c="$(awk '/committed and confirmed/ { value = $3 } END { print value }' \
    "$tmp_dir/release-tx.log")"
test -n "$release_a"
test -n "$release_c"
test "$release_a" != "$release_c"
test "$release_c" = "$release_committed_c"
grep -q "RX recovered session .* (terminated)" "$tmp_dir/release-rx2.log"
grep -q "counter 2 committed and confirmed" "$tmp_dir/release-rx2.log"
test "$(sed -n '1p' "$tmp_dir/release-rx-state")" = 2
test "$(sed -n '7p' "$tmp_dir/release-rx-state")" = 0
test "$(sed -n '8p' "$tmp_dir/release-rx-state")" = ACTIVE
test -f "$tmp_dir/release-tx-active"
test "$(stat -c %a "$tmp_dir/release-tx-active")" = 600

# A USB-driven TX agent restart must retain the already-committed secret only
# in a root/user-owner 0600 boot-ephemeral record.  The replacement process may
# recover it solely when the simulated PL active session/key-valid state
# matches, authenticate BTN3 termination to RX, erase the record, and then let
# the next release exchange a genuinely fresh session.
AES_SESSION_TEST_TERMINATE_AFTER_COMMIT=1 \
    "$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/tx-restart-rx-state" \
    >"$tmp_dir/tx-restart-rx.log" 2>&1 &
rx_pid=$!
sleep 1

"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/tx-restart-counter" \
    --active-state "$tmp_dir/tx-active" \
    >"$tmp_dir/tx-before-restart.log" 2>&1

restart_session="$(session_from_log 'committed and confirmed' \
    "$tmp_dir/tx-before-restart.log")"
test -n "$restart_session"
test -f "$tmp_dir/tx-active"
test "$(stat -c %a "$tmp_dir/tx-active")" = 600
test "$(stat -c %s "$tmp_dir/tx-active")" = 112

AES_SESSION_TEST_PL_ACTIVE_SESSION=0 \
AES_SESSION_TEST_PL_STATUS=100 \
AES_SESSION_TEST_PL_TERMINATION_COUNT=1 \
AES_SESSION_TEST_RESTART_TERMINATE=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/tx-restart-counter" \
    --active-state "$tmp_dir/tx-active" \
    >"$tmp_dir/tx-after-restart.log" 2>&1
wait "$rx_pid"
rx_pid=""

grep -q "TX recovered termination credential for session $restart_session" \
    "$tmp_dir/tx-after-restart.log"
grep -q "TX session $restart_session terminated on both boards" \
    "$tmp_dir/tx-after-restart.log"
grep -q "RX session $restart_session terminated and key cleared" \
    "$tmp_dir/tx-restart-rx.log"
test ! -e "$tmp_dir/tx-active"

"$tmp_dir/aes-session-agent-test" \
    --rx keys/rx-demo-private.pem keys/tx-demo-public.pem \
    --no-hardware --once \
    --counter "$tmp_dir/tx-restart-rx-state" \
    >"$tmp_dir/tx-release-rx.log" 2>&1 &
rx_pid=$!
sleep 1

"$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/tx-restart-counter" \
    --active-state "$tmp_dir/tx-active" \
    >"$tmp_dir/tx-release.log" 2>&1
wait "$rx_pid"
rx_pid=""

release_session="$(session_from_log 'committed and confirmed' \
    "$tmp_dir/tx-release.log")"
test -n "$release_session"
test "$release_session" != "$restart_session"
test -f "$tmp_dir/tx-active"
test "$(sed -n '1p' "$tmp_dir/tx-restart-counter")" = 2

# A persisted secret with a nonmatching PL session must never be loaded and is
# securely removed before the process attempts any further operation.
if AES_SESSION_TEST_PL_ACTIVE_SESSION=deadbeef \
   AES_SESSION_TEST_RESTART_TERMINATE=1 \
    "$tmp_dir/aes-session-agent-test" \
    --tx keys/tx-demo-private.pem keys/rx-demo-public.pem \
    --peer 127.0.0.1 --no-hardware --once \
    --counter "$tmp_dir/tx-restart-counter" \
    --active-state "$tmp_dir/tx-active" \
    >"$tmp_dir/tx-mismatch.log" 2>&1; then
    echo "mismatched PL session unexpectedly recovered" >&2
    exit 1
fi
test ! -e "$tmp_dir/tx-active"
grep -q "TX restart termination state" "$tmp_dir/tx-mismatch.log"

echo "PASS: lost DONE self-recovers with the exact capsule"
echo "PASS: exact Weak Demo KDF and strict Jetson management parsing"
echo "PASS: RX announcement discovers the current DHCP peer without Jetson or fixed --peer"
echo "PASS: TX termination event survives exchange errors; PL updates gate RX"
echo "PASS: RX restart promotes write-ahead PENDING after PL commit crash"
echo "PASS: remote DONE -> local cancel -> candidate B TERMINATE -> TERMINATED"
echo "PASS: press+release inside exchange is detected by termination_count"
echo "PASS: RX restart authenticates duplicate TERMINATE after lost response"
echo "PASS: BTN3 release rekeys C instead of blocking on old TERMINATED(A)"
echo "PASS: TX restart recovers keyless BTN3 teardown credential, terminates, and rekeys"
