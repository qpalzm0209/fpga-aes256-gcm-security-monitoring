#!/usr/bin/env python3
"""Minimal UDP client for the deployed TX session-management contract."""

from __future__ import annotations

import argparse
import json
import secrets
import socket
import time


CONTROL_PORT = 46101


def request_session(command: str, host: str, argument: int | None = None,
                    timeout: float = 15.0,
                    request_id: int | None = None) -> dict[str, object]:
    request_id = request_id if request_id is not None else (secrets.randbits(64) or 1)
    if request_id not in range(1, 2**64):
        raise ValueError("request_id must be a nonzero 64-bit integer")
    if timeout <= 0:
        raise ValueError("timeout must be positive")
    suffix = "" if argument is None else f" {argument}"
    message = f"{command} {request_id}{suffix}\n".encode("ascii")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind(("0.0.0.0", 0))
        sock.settimeout(1.0)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            sock.sendto(message, (host, CONTROL_PORT))
            interval_deadline = min(deadline, time.monotonic() + 1.0)
            while time.monotonic() < interval_deadline:
                try:
                    reply, source = sock.recvfrom(1024)
                except socket.timeout:
                    break
                text = reply.decode("ascii", "strict").strip()
                fields = text.split()
                if len(fields) >= 2 and fields[1] == str(request_id):
                    if fields[0] == "ERROR":
                        raise RuntimeError(f"TX session error from {source[0]}: {' '.join(fields[2:])}")
                    if fields[0] == "SECURE_SESSION_ACTIVE" and len(fields) == 3:
                        return {"profile": "secure", "request_id": request_id,
                                "session_id": f"0x{int(fields[2], 0):08x}", "tx_host": source[0]}
                    if fields[0] == "WEAK_SESSION_ACTIVE" and len(fields) == 4:
                        return {"profile": "weak", "request_id": request_id,
                                "session_id": f"0x{int(fields[2], 0):08x}",
                                "seed_bits": int(fields[3]), "tx_host": source[0]}
        raise TimeoutError(f"no session ACK from {host}:{CONTROL_PORT}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--weak", type=int, choices=range(1, 33), metavar="BITS")
    group.add_argument("--secure", action="store_true")
    parser.add_argument("--host", default="10.10.15.2")
    parser.add_argument("--request-id", type=int)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    result = (
        request_session(
            "CREATE_SECURE_SESSION", args.host,
            timeout=args.timeout, request_id=args.request_id,
        )
        if args.secure
        else request_session(
            "CREATE_WEAK_SESSION", args.host, args.weak,
            timeout=args.timeout, request_id=args.request_id,
        )
    )
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
