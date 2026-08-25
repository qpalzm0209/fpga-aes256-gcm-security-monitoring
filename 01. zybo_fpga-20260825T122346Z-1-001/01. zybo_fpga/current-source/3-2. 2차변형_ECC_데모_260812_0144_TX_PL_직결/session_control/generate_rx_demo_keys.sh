#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KEYS="$HERE/keys"
mkdir -p "$KEYS"

for role in tx rx; do
    openssl genpkey -algorithm X25519 -out "$KEYS/$role-demo-private.pem"
    chmod 600 "$KEYS/$role-demo-private.pem"
    openssl pkey -in "$KEYS/$role-demo-private.pem" -pubout \
        -out "$KEYS/$role-demo-public.pem"
    printf '%s pinned public key SHA-256: ' "$role"
    openssl pkey -pubin -in "$KEYS/$role-demo-public.pem" -outform DER |
        openssl dgst -sha256
done
