#!/usr/bin/env python3
"""Recover one live 1280x720 YUYV frame after a weak seed is found."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


PACKET_COUNT = 1280
PLAINTEXT_BYTES = 1440
WIDTH = 1280
HEIGHT = 720
FRAME_BYTES = WIDTH * HEIGHT * 2


def pcap_packets(path: Path):
    data = path.read_bytes()
    if len(data) < 24:
        raise ValueError("pcap header is missing")
    magic = data[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        raise ValueError("not a classic pcap")
    if struct.unpack_from(endian + "I", data, 20)[0] != 1:
        raise ValueError("pcap is not Ethernet")
    offset = 24
    while offset + 16 <= len(data):
        captured = struct.unpack_from(endian + "I", data, offset + 8)[0]
        offset += 16
        packet = data[offset:offset + captured]
        if len(packet) != captured:
            raise ValueError("truncated pcap packet")
        yield packet
        offset += captured


def parse_packet(packet: bytes) -> dict[str, object]:
    if len(packet) < 14 + 20 + 8 + 1472:
        raise ValueError("short Ethernet frame")
    if packet[:6] != bytes.fromhex("020000000003") or \
       packet[6:12] != bytes.fromhex("020000000002"):
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
    magic, session, frame, index, flags = struct.unpack_from("!IIIHH", payload)
    if magic != 0x5043414D or index >= PACKET_COUNT or not (flags & 1):
        raise ValueError("not an encrypted Zybo video packet")
    return {
        "session": session,
        "frame": frame,
        "index": index,
        "aad": payload[:16],
        "ciphertext": payload[16:1456],
        "tag": payload[1456:1472],
    }


def derive_key(seed: int) -> bytes:
    return hashlib.sha256(b"ZYBO-SEED-v1" + struct.pack("!I", seed)).digest()


def decrypt_packet(packet: dict[str, object], seed: int) -> bytes:
    iv = struct.pack(
        "!IIHH", int(packet["session"]), int(packet["frame"]),
        0, int(packet["index"]),
    )
    return AESGCM(derive_key(seed)).decrypt(
        iv, bytes(packet["ciphertext"]) + bytes(packet["tag"]),
        bytes(packet["aad"]),
    )


def complete_frames(path: Path, expected_session: int):
    frames: dict[tuple[int, int], list[dict[str, object] | None]] = {}
    for raw in pcap_packets(path):
        try:
            packet = parse_packet(raw)
        except ValueError:
            continue
        session = int(packet["session"])
        if session != expected_session:
            continue
        key = (session, int(packet["frame"]))
        slots = frames.setdefault(key, [None] * PACKET_COUNT)
        slots[int(packet["index"])] = packet
    complete = [(key, slots) for key, slots in frames.items() if all(slots)]
    if complete:
        return complete
    counts = sorted((sum(item is not None for item in slots), key)
                    for key, slots in frames.items())
    best = counts[-1][0] if counts else 0
    raise RuntimeError(f"no complete encrypted frame captured; best={best}/{PACKET_COUNT}")


def capture_filter(session: int) -> str:
    return (
        "ether src 02:00:00:00:00:02 and ether dst 02:00:00:00:00:03 and "
        "src host 10.10.15.2 and dst host 10.10.15.3 and "
        "udp src port 5602 and udp dst port 5602 and udp[4:2] = 1480 and "
        "udp[8:4] = 0x5043414d and "
        f"udp[12:4] = 0x{session:08x} and (udp[22:2] & 1) = 1"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--session", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--interface", default="eno1")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--capture-count", type=int, default=5120)
    args = parser.parse_args()
    if not 0 <= args.seed <= 0xFFFFFFFF or args.capture_count < PACKET_COUNT * 2:
        raise ValueError("invalid seed or capture count")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.metadata.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="weak-frame-") as directory:
        capture = Path(directory) / "frame.pcap"
        subprocess.run([
            "/usr/bin/dumpcap", "-q", "-i", args.interface, "-p",
            "-f", capture_filter(args.session), "-s", "1600", "-c",
            str(args.capture_count), "-P", "-w", str(capture),
        ], check=True, timeout=15.0, stdout=subprocess.DEVNULL,
           stderr=subprocess.PIPE)
        candidates = complete_frames(capture, args.session)

    # A single mirrored packet can occasionally arrive damaged while its
    # frame still appears index-complete.  Validate whole candidate frames and
    # use the first one whose 1,280 packet tags all pass; never render partial
    # or unauthenticated data.
    plaintext = None
    last_tag_error = None
    for (session, frame), packets in candidates:
        try:
            plaintext = b"".join(decrypt_packet(packet, args.seed)
                                 for packet in packets if packet is not None)
            break
        except InvalidTag as error:
            last_tag_error = error
    if plaintext is None:
        raise RuntimeError(
            f"GCM TAG validation failed for {len(candidates)} complete frames"
        ) from last_tag_error
    if len(plaintext) != FRAME_BYTES:
        raise RuntimeError(f"unexpected plaintext size {len(plaintext)}")
    yuyv = np.frombuffer(plaintext, dtype=np.uint8).reshape(HEIGHT, WIDTH, 2)
    bgr = cv2.cvtColor(yuyv, cv2.COLOR_YUV2BGR_YUY2)
    now = datetime.now().astimezone()
    filename = f"recovered_{now:%Y%m%d_%H%M%S}_run{args.run_id:02d}.png"
    output = args.output_dir / filename
    if not cv2.imwrite(str(output), bgr, [cv2.IMWRITE_PNG_COMPRESSION, 3]):
        raise RuntimeError("PNG write failed")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    metadata = {
        "phase": "ready",
        "source": "DECRYPTED FROM LIVE WEAK SESSION",
        "run_id": args.run_id,
        "recovered_at": now.isoformat(),
        "session_id": f"0x{session:08x}",
        "frame_id": frame,
        "seed": args.seed,
        "width": WIDTH,
        "height": HEIGHT,
        "packet_count": PACKET_COUNT,
        "plaintext_bytes": len(plaintext),
        "desktop_path": str(output),
        "filename": filename,
        "sha256": digest,
    }
    args.metadata.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
