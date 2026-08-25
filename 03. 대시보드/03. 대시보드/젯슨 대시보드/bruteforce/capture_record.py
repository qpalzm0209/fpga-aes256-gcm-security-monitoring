#!/usr/bin/env python3
"""Capture one live encrypted Zybo UDP record and write the CUDA input file."""

from __future__ import annotations

import argparse
import json
import struct
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


CAPTURE_FILTER = (
    "ether src 02:00:00:00:00:02 and ether dst 02:00:00:00:00:03 and "
    "src host 10.10.15.2 and dst host 10.10.15.3 and "
    "udp src port 5602 and udp dst port 5602 and udp[4:2] = 1480 and "
    "udp[8:4] = 0x5043414d and udp[20:2] = 0 and (udp[22:2] & 1) = 1"
)
RECORD = struct.Struct("<8sIIIHH16s1440s16s")


def read_first_pcap_packet(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 40:
        raise ValueError("pcap contains no packet")
    magic = data[:4]
    endian = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    if magic not in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4",
                     b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"):
        raise ValueError("not a classic pcap")
    captured = struct.unpack_from(endian + "I", data, 24 + 8)[0]
    packet = data[24 + 16:24 + 16 + captured]
    if len(packet) != captured:
        raise ValueError("truncated pcap packet")
    return packet


def parse_packet(packet: bytes) -> dict[str, object]:
    if len(packet) < 14 + 20 + 8 + 1472:
        raise ValueError(f"short Ethernet frame: {len(packet)}")
    if packet[:6] != bytes.fromhex("020000000003") or packet[6:12] != bytes.fromhex("020000000002"):
        raise ValueError("unexpected Ethernet direction")
    if struct.unpack_from("!H", packet, 12)[0] != 0x0800:
        raise ValueError("not IPv4")
    ip_offset = 14
    ihl = (packet[ip_offset] & 0x0F) * 4
    if ihl < 20 or packet[ip_offset + 9] != 17:
        raise ValueError("unexpected IP header")
    udp_offset = ip_offset + ihl
    source, destination, udp_len = struct.unpack_from("!HHH", packet, udp_offset)
    if (source, destination, udp_len) != (5602, 5602, 1480):
        raise ValueError("unexpected UDP contract")
    payload = packet[udp_offset + 8:udp_offset + 8 + 1472]
    if len(payload) != 1472:
        raise ValueError("truncated UDP payload")
    magic, session_id, frame_id, packet_index, flags = struct.unpack_from("!IIIHH", payload)
    if magic != 0x5043414D or packet_index != 0 or not (flags & 1):
        raise ValueError("record is not encrypted packet index 0")
    return {
        "session_id": session_id, "frame_id": frame_id,
        "packet_index": packet_index, "flags": flags,
        "aad": payload[:16], "ciphertext": payload[16:1456],
        "tag": payload[1456:1472], "ethernet_frame_length": len(packet),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", default="eno1")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    metadata_path = args.metadata or args.output.with_suffix(".json")
    with tempfile.TemporaryDirectory(prefix="weak-record-") as directory:
        capture = Path(directory) / "record.pcap"
        subprocess.run([
            "/usr/bin/dumpcap", "-q", "-i", args.interface, "-f", CAPTURE_FILTER,
            "-s", "1600", "-c", "1", "-P", "-w", str(capture),
        ], check=True, timeout=10.0)
        parsed = parse_packet(read_first_pcap_packet(capture))
    args.output.write_bytes(RECORD.pack(
        b"ZYBOGCM1", 1, int(parsed["session_id"]), int(parsed["frame_id"]),
        int(parsed["packet_index"]), int(parsed["flags"]), parsed["aad"],
        parsed["ciphertext"], parsed["tag"],
    ))
    metadata = {
        "source": "CAPTURED FROM LIVE STREAM", "captured_at": datetime.now(timezone.utc).isoformat(),
        "interface": args.interface, "record_file": str(args.output),
        "aad_length": 16, "ciphertext_length": 1440, "tag_length": 16,
        "session_id": f"0x{int(parsed['session_id']):08x}",
        "frame_id": parsed["frame_id"], "packet_index": parsed["packet_index"],
        "flags": f"0x{int(parsed['flags']):04x}",
        "ethernet_frame_length": parsed["ethernet_frame_length"],
        "capture_filter": CAPTURE_FILTER,
        "secret_key_included": False,
    }
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
