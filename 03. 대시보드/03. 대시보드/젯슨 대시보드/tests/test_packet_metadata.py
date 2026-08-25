import importlib.util
import struct
import unittest
from pathlib import Path


PARSER = Path(__file__).parents[1] / "stream-randomness" / "pcap_stats.py"


def load_parser():
    spec = importlib.util.spec_from_file_location("pcap_stats", PARSER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def encrypted_record(frame_id: int, packet_id: int) -> bytes:
    flags = (1 << 12) | 1
    return (
        b"PCAM"
        + (0x49688523).to_bytes(4, "big")
        + frame_id.to_bytes(4, "big")
        + packet_id.to_bytes(2, "big")
        + flags.to_bytes(2, "big")
        + bytes([packet_id % 256]) * 1440
        + bytes(range(16))
    )


def ethernet_udp(payload: bytes) -> bytes:
    ethernet = (
        b"\x02\x00\x00\x00\x00\x03"
        b"\x02\x00\x00\x00\x00\x02"
        b"\x08\x00"
    )
    total_length = 20 + 8 + len(payload)
    ipv4 = (
        b"\x45\x00"
        + total_length.to_bytes(2, "big")
        + b"\x00\x00\x00\x00\x40\x11\x00\x00"
        + bytes([10, 10, 15, 2, 10, 10, 15, 3])
    )
    udp = (
        (5602).to_bytes(2, "big")
        + (5602).to_bytes(2, "big")
        + (8 + len(payload)).to_bytes(2, "big")
        + b"\x00\x00"
    )
    return ethernet + ipv4 + udp + payload


def classic_pcap(frames: list[bytes], timestamps_us: list[int] | None = None) -> bytes:
    result = b"\xd4\xc3\xb2\xa1" + struct.pack("<HHIIII", 2, 4, 0, 0, 65535, 1)
    for index, frame in enumerate(frames):
        timestamp_us = index * 50 if timestamps_us is None else timestamps_us[index]
        result += struct.pack("<IIII", 1, timestamp_us, len(frame), len(frame)) + frame
    return result


class PacketMetadataTest(unittest.TestCase):
    def test_latest_metadata_is_the_last_real_record(self):
        parser = load_parser()
        pcap = classic_pcap([
            ethernet_udp(encrypted_record(184231, 730)),
            ethernet_udp(encrypted_record(184231, 731)),
        ])

        analysis = parser.analyze_pcap_bytes(pcap)

        self.assertEqual(analysis["mode"], "ciphertext")
        self.assertEqual(analysis["packet_count"], 2)
        self.assertEqual(analysis["latest_frame_id"], 184231)
        self.assertEqual(analysis["latest_packet_id"], 731)
        self.assertAlmostEqual(analysis["packet_rate_kpps"], 20.0)
        self.assertAlmostEqual(analysis["packet_inter_arrival_ms"], 0.05)

    def test_packet_timing_jitter_is_timestamp_standard_deviation(self):
        parser = load_parser()
        frames = [
            ethernet_udp(encrypted_record(10, packet_id))
            for packet_id in (0, 1, 2, 3)
        ]
        analysis = parser.analyze_pcap_bytes(
            classic_pcap(frames, timestamps_us=[0, 40, 100, 150])
        )

        self.assertAlmostEqual(analysis["packet_inter_arrival_ms"], 0.05)
        self.assertAlmostEqual(analysis["packet_timing_jitter_ms"], 0.0081649658)


if __name__ == "__main__":
    unittest.main()
