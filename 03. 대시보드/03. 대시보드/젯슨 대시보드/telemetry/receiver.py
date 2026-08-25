#!/usr/bin/env python3
"""Receive and validate Zybo RX telemetry over UDP."""

from __future__ import annotations

import argparse
import json
import math
import socket
import statistics
import time
from pathlib import Path
from typing import Any


PROTOCOL_VERSION = 1
REQUIRED_FIELDS = {
    "protocol_version",
    "seq",
    "monotonic_ms",
    "session_id",
    "valid_frame_rate",
    "frame_attempt_rate",
    "auth_reject_rate",
    "replay_reject_rate",
    "frame_drop_ratio",
    "frame_jitter_ms",
    "network_loss_delta",
    "queue_overrun_delta",
    "stale_drop_delta",
}
RATE_FIELDS = (
    "valid_frame_rate",
    "frame_attempt_rate",
    "auth_reject_rate",
    "replay_reject_rate",
    "frame_drop_ratio",
    "frame_jitter_ms",
)
DELTA_FIELDS = (
    "network_loss_delta",
    "queue_overrun_delta",
    "stale_drop_delta",
    "status_failure_delta",
)
OPTIONAL_COUNTER_FIELDS = (
    "processed_frames_total",
    "authentication_failures_total",
    "replay_reject_total",
)


def finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def validate_payload(payload: Any) -> list[str]:
    if not isinstance(payload, dict):
        return ["JSON root is not an object"]

    missing = sorted(REQUIRED_FIELDS - payload.keys())
    errors = [f"missing field: {name}" for name in missing]

    if payload.get("protocol_version") != PROTOCOL_VERSION:
        errors.append(
            f"protocol_version={payload.get('protocol_version')!r}, expected 1"
        )
    if not isinstance(payload.get("seq"), int) or isinstance(payload.get("seq"), bool):
        errors.append("seq is not an integer")
    if not isinstance(payload.get("monotonic_ms"), int) or isinstance(
        payload.get("monotonic_ms"), bool
    ):
        errors.append("monotonic_ms is not an integer")
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        errors.append("session_id is not a non-empty string")

    for name in RATE_FIELDS:
        if name in payload and not finite_number(payload[name]):
            errors.append(f"{name} is not a finite number")
    for name in DELTA_FIELDS + OPTIONAL_COUNTER_FIELDS:
        if name in payload and (
            not isinstance(payload[name], int)
            or isinstance(payload[name], bool)
            or payload[name] < 0
        ):
            errors.append(f"{name} is not a non-negative integer")
    return errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="10.10.15.1", help="local bind address")
    parser.add_argument("--port", type=int, default=47000, help="local UDP port")
    parser.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="stop after this many seconds; 0 runs until Ctrl+C",
    )
    parser.add_argument(
        "--save-samples",
        type=Path,
        help="save the first three valid payloads as a JSON array",
    )
    return parser.parse_args()


def print_summary(
    started: float,
    arrivals: list[float],
    values: dict[str, list[float]],
    invalid_packets: int,
    sequence_gaps: int,
    latest: dict[str, Any] | None,
) -> None:
    elapsed = time.monotonic() - started
    intervals_ms = [
        (current - previous) * 1000.0
        for previous, current in zip(arrivals, arrivals[1:])
    ]
    average_hz = (
        (len(arrivals) - 1) / (arrivals[-1] - arrivals[0])
        if len(arrivals) > 1 and arrivals[-1] > arrivals[0]
        else 0.0
    )

    print("\n--- TELEMETRY SUMMARY ---")
    print(f"elapsed_s={elapsed:.3f}")
    print(f"packet_count={len(arrivals)}")
    print(f"invalid_packets={invalid_packets}")
    print(f"average_hz={average_hz:.3f}")
    if intervals_ms:
        print(f"average_interval_ms={statistics.fmean(intervals_ms):.3f}")
        print(f"min_interval_ms={min(intervals_ms):.3f}")
        print(f"max_interval_ms={max(intervals_ms):.3f}")
    else:
        print("average_interval_ms=0.000")
        print("min_interval_ms=0.000")
        print("max_interval_ms=0.000")
    print(f"sequence_gaps={sequence_gaps}")
    for name in RATE_FIELDS:
        if values[name]:
            print(f"mean_{name}={statistics.fmean(values[name]):.6f}")
    for name in DELTA_FIELDS:
        if values[name]:
            print(f"sum_{name}={int(sum(values[name]))}")
    if latest is not None:
        print(f"latest_seq={latest['seq']}")
        print(f"latest_session_id={latest['session_id']}")


def main() -> int:
    args = parse_args()
    if not 0 < args.port <= 65535:
        raise SystemExit("port must be in the range 1..65535")
    if args.duration < 0:
        raise SystemExit("duration must be non-negative")

    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind((args.bind, args.port))
    receiver.settimeout(0.5)

    started = time.monotonic()
    arrivals: list[float] = []
    values = {name: [] for name in RATE_FIELDS + DELTA_FIELDS}
    samples: list[dict[str, Any]] = []
    latest: dict[str, Any] | None = None
    last_seq: int | None = None
    last_monotonic_ms: int | None = None
    sequence_gaps = 0
    invalid_packets = 0

    print(f"Listening for Zybo RX telemetry on {args.bind}:{args.port}")
    try:
        while True:
            if args.duration and time.monotonic() - started >= args.duration:
                break
            try:
                packet, peer = receiver.recvfrom(65535)
            except socket.timeout:
                continue

            arrived = time.monotonic()
            try:
                payload = json.loads(packet.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                invalid_packets += 1
                print(f"INVALID peer={peer[0]}:{peer[1]} error={error}", flush=True)
                continue

            errors = validate_payload(payload)
            if not errors and last_seq is not None:
                if payload["seq"] <= last_seq:
                    errors.append(f"seq did not increase: {last_seq} -> {payload['seq']}")
                elif payload["seq"] > last_seq + 1:
                    sequence_gaps += payload["seq"] - last_seq - 1
            if not errors and last_monotonic_ms is not None:
                if payload["monotonic_ms"] <= last_monotonic_ms:
                    errors.append(
                        "monotonic_ms did not increase: "
                        f"{last_monotonic_ms} -> {payload['monotonic_ms']}"
                    )
            if errors:
                invalid_packets += 1
                print(
                    f"INVALID peer={peer[0]}:{peer[1]} error={' | '.join(errors)}",
                    flush=True,
                )
                continue

            last_seq = payload["seq"]
            last_monotonic_ms = payload["monotonic_ms"]
            latest = payload
            arrivals.append(arrived)
            for name in values:
                if name in payload:
                    values[name].append(float(payload[name]))
            if len(samples) < 3:
                samples.append(payload)
                print(
                    "JSON_SAMPLE "
                    + json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
                    flush=True,
                )
            print(
                f"seq={payload['seq']} session={payload['session_id']} "
                f"valid={payload['valid_frame_rate']:.3f}fps "
                f"attempt={payload['frame_attempt_rate']:.3f}fps "
                f"auth={payload['auth_reject_rate']:.3f}/s "
                f"replay={payload['replay_reject_rate']:.3f}/s "
                f"loss={payload['network_loss_delta']} "
                f"queue={payload['queue_overrun_delta']} "
                f"stale={payload['stale_drop_delta']}",
                flush=True,
            )
    except KeyboardInterrupt:
        print("\nStopped by user")
    finally:
        receiver.close()
        if args.save_samples and samples:
            args.save_samples.parent.mkdir(parents=True, exist_ok=True)
            args.save_samples.write_text(
                json.dumps(samples, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            print(f"Saved {len(samples)} samples to {args.save_samples}")
        print_summary(
            started,
            arrivals,
            values,
            invalid_packets,
            sequence_gaps,
            latest,
        )

    return 0 if arrivals else 2


if __name__ == "__main__":
    raise SystemExit(main())
