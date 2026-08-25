#!/usr/bin/env python3
"""Measure byte statistics from the 1440-byte PCAM video body in a pcap."""

from __future__ import annotations

import argparse
import io
import json
import math
import statistics
import struct
from pathlib import Path


RECORD_BYTES = 1472
AAD_BYTES = 16
VIDEO_BYTES = 1440
TAG_BYTES = 16
MAGIC = b"PCAM"


def _pcap_packet_entries(source, label: str):
    magic = source.read(4)
    formats = {
        b"\xd4\xc3\xb2\xa1": ("<", 1_000),
        b"\xa1\xb2\xc3\xd4": (">", 1_000),
        b"\x4d\x3c\xb2\xa1": ("<", 1),
        b"\xa1\xb2\x3c\x4d": (">", 1),
    }
    if magic not in formats:
        raise ValueError(f"{label}: classic pcap required (bad magic {magic.hex()})")
    endian, fraction_to_ns = formats[magic]
    rest = source.read(20)
    if len(rest) != 20:
        raise ValueError(f"{label}: truncated global header")
    _, _, _, _, _, linktype = struct.unpack(endian + "HHIIII", rest)
    if linktype != 1:
        raise ValueError(f"{label}: Ethernet link type 1 required, got {linktype}")

    while True:
        header = source.read(16)
        if not header:
            break
        if len(header) != 16:
            raise ValueError(f"{label}: truncated packet header")
        seconds, fraction, captured, _ = struct.unpack(endian + "IIII", header)
        packet = source.read(captured)
        if len(packet) != captured:
            raise ValueError(f"{label}: truncated packet body")
        timestamp_ns = seconds * 1_000_000_000 + fraction * fraction_to_ns
        yield timestamp_ns, packet


def _pcap_packets(source, label: str):
    for _, packet in _pcap_packet_entries(source, label):
        yield packet


def pcap_packets(path: Path):
    with path.open("rb") as source:
        yield from _pcap_packets(source, str(path))


def pcap_packets_bytes(data: bytes):
    yield from _pcap_packets(io.BytesIO(data), "capture stream")


def pcap_packet_entries(path: Path):
    with path.open("rb") as source:
        yield from _pcap_packet_entries(source, str(path))


def pcap_packet_entries_bytes(data: bytes):
    yield from _pcap_packet_entries(io.BytesIO(data), "capture stream")


def udp_payload(frame: bytes) -> bytes | None:
    if len(frame) < 14:
        return None
    offset = 14
    ether_type = int.from_bytes(frame[12:14], "big")
    while ether_type in (0x8100, 0x88A8, 0x9100):
        if len(frame) < offset + 4:
            return None
        ether_type = int.from_bytes(frame[offset + 2 : offset + 4], "big")
        offset += 4
    if ether_type != 0x0800 or len(frame) < offset + 20:
        return None
    ihl = (frame[offset] & 0x0F) * 4
    if ihl < 20 or len(frame) < offset + ihl + 8 or frame[offset + 9] != 17:
        return None
    udp = offset + ihl
    source_port = int.from_bytes(frame[udp : udp + 2], "big")
    dest_port = int.from_bytes(frame[udp + 2 : udp + 4], "big")
    udp_length = int.from_bytes(frame[udp + 4 : udp + 6], "big")
    if source_port != 5602 or dest_port != 5602 or udp_length < 8:
        return None
    end = udp + udp_length
    if end > len(frame):
        return None
    return frame[udp + 8 : end]


def _records_from_frame(frame: bytes):
    payload = udp_payload(frame)
    if payload is None or len(payload) % RECORD_BYTES:
        return
    for offset in range(0, len(payload), RECORD_BYTES):
        record = payload[offset : offset + RECORD_BYTES]
        if record[:4] != MAGIC:
            continue
        flags = int.from_bytes(record[14:16], "big")
        if flags >> 12 != 1:
            continue
        yield {
            "mode": "ciphertext" if flags & 1 else "plaintext",
            "session_id": int.from_bytes(record[4:8], "big"),
            "frame_id": int.from_bytes(record[8:12], "big"),
            "packet_index": int.from_bytes(record[12:14], "big"),
            "body": record[AAD_BYTES : AAD_BYTES + VIDEO_BYTES],
            "tag": record[-TAG_BYTES:],
        }


def records_from_packets(packets):
    for frame in packets:
        yield from _records_from_frame(frame)


def timed_records_from_packets(packet_entries):
    for timestamp_ns, frame in packet_entries:
        for record in _records_from_frame(frame):
            record["capture_timestamp_ns"] = timestamp_ns
            yield record


def records(path: Path):
    yield from records_from_packets(pcap_packets(path))


def entropy(data: bytes) -> float:
    counts = [0] * 256
    for value in data:
        counts[value] += 1
    length = len(data)
    return -sum((count / length) * math.log2(count / length) for count in counts if count)


def correlation(data: bytes, lag: int) -> float:
    left = data[:-lag]
    right = data[lag:]
    length = len(left)
    sx = sum(left)
    sy = sum(right)
    sxx = sum(value * value for value in left)
    syy = sum(value * value for value in right)
    sxy = sum(x * y for x, y in zip(left, right))
    numerator = length * sxy - sx * sy
    denominator = math.sqrt((length * sxx - sx * sx) * (length * syy - sy * sy))
    return numerator / denominator if denominator else 0.0


def summary(values: list[float]) -> dict[str, float]:
    return {
        "mean": statistics.fmean(values),
        "std": statistics.pstdev(values),
        "min": min(values),
        "max": max(values),
    }


def analyze_records(record_stream, expected_mode: str | None = None) -> dict:
    packet_entropy: list[float] = []
    unique: list[float] = []
    correlations = {1: [], 2: [], 4: []}
    histogram = [0] * 256
    modes: set[str] = set()
    sessions: set[int] = set()
    frames: set[int] = set()
    packet_indexes: set[int] = set()
    capture_timestamps_ns: list[int] = []
    latest_session_id: int | None = None
    latest_frame_id: int | None = None
    latest_packet_id: int | None = None
    zero_tags = 0
    nonzero_tags = 0

    for record in record_stream:
        body = record["body"]
        modes.add(record["mode"])
        sessions.add(record["session_id"])
        frames.add(record["frame_id"])
        packet_indexes.add(record["packet_index"])
        timestamp_ns = record.get("capture_timestamp_ns")
        if isinstance(timestamp_ns, int):
            capture_timestamps_ns.append(timestamp_ns)
        latest_session_id = record["session_id"]
        latest_frame_id = record["frame_id"]
        latest_packet_id = record["packet_index"]
        zero_tags += not any(record["tag"])
        nonzero_tags += any(record["tag"])
        packet_entropy.append(entropy(body))
        unique.append(float(len(set(body))))
        for value in body:
            histogram[value] += 1
        for lag in correlations:
            correlations[lag].append(correlation(body, lag))

    if not packet_entropy:
        raise ValueError("no valid PCAM UDP 5602 records found")
    if len(modes) != 1:
        raise ValueError(f"mixed AES modes in capture: {sorted(modes)}")
    actual_mode = next(iter(modes))
    if expected_mode and actual_mode != expected_mode:
        raise ValueError(f"capture mode is {actual_mode}, expected {expected_mode}")

    sample_bytes = sum(histogram)
    expected = sample_bytes / 256.0
    chi_square = sum((count - expected) ** 2 / expected for count in histogram)
    frequencies = [count / sample_bytes for count in histogram]
    histogram_variance = statistics.pvariance(frequencies)
    inter_arrivals_ms = [
        (right - left) / 1_000_000.0
        for left, right in zip(capture_timestamps_ns, capture_timestamps_ns[1:])
        if right >= left
    ]
    packet_timing_jitter_ms = (
        statistics.pstdev(inter_arrivals_ms)
        if len(inter_arrivals_ms) >= 2 else None
    )
    capture_span_ns = (
        capture_timestamps_ns[-1] - capture_timestamps_ns[0]
        if len(capture_timestamps_ns) >= 2 else 0
    )
    packet_rate_pps = (
        (len(capture_timestamps_ns) - 1) * 1_000_000_000.0 / capture_span_ns
        if capture_span_ns > 0 else None
    )
    return {
        "mode": actual_mode,
        "packet_count": len(packet_entropy),
        "sample_bytes": sample_bytes,
        "session_count": len(sessions),
        "frame_count": len(frames),
        "sampled_packet_indexes": sorted(packet_indexes),
        "latest_session_id": latest_session_id,
        "latest_frame_id": latest_frame_id,
        "latest_packet_id": latest_packet_id,
        "packet_rate_pps": packet_rate_pps,
        "packet_rate_kpps": None if packet_rate_pps is None else packet_rate_pps / 1000.0,
        "packet_inter_arrival_ms": (
            None if not inter_arrivals_ms else statistics.fmean(inter_arrivals_ms)
        ),
        "packet_timing_jitter_ms": packet_timing_jitter_ms,
        "capture_span_ms": capture_span_ns / 1_000_000.0,
        "tag_zero_packets": zero_tags,
        "tag_nonzero_packets": nonzero_tags,
        "entropy": summary(packet_entropy),
        "unique_bytes": summary(unique),
        "serial_correlation": {
            f"lag_{lag}": summary(values) for lag, values in correlations.items()
        },
        "chi_square_from_uniform": chi_square,
        "reduced_chi_square": chi_square / 255.0,
        "histogram_variance": histogram_variance,
        "histogram": histogram,
    }


def analyze(paths: list[Path], expected_mode: str | None = None) -> dict:
    record_stream = (
        timed_records_from_packets(pcap_packet_entries(paths[0]))
        if len(paths) == 1
        else (record for path in paths for record in records(path))
    )
    return analyze_records(record_stream, expected_mode)


def analyze_pcap_bytes(data: bytes) -> dict:
    return analyze_records(timed_records_from_packets(pcap_packet_entries_bytes(data)))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcap", nargs="+", type=Path)
    parser.add_argument("--expected-mode", choices=("plaintext", "ciphertext"))
    parser.add_argument("--json-out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    result = analyze(args.pcap, args.expected_mode)
    rendered = json.dumps(result, indent=2, ensure_ascii=False)
    print(rendered)
    if args.json_out:
        args.json_out.write_text(rendered + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
