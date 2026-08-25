#!/usr/bin/env python3
import struct
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PACKETS = 1280
BLOCKS = 90
SESSION = 0x11223344
MAGIC = 0x5043414D
KEY = bytes(range(32))


def payload(packet: int) -> bytes:
    return bytes(
        (packet * 13 + block * 17 + lane * 29) & 0xFF
        for block in range(BLOCKS)
        for lane in range(16)
    )


def aad(packet: int) -> bytes:
    # flags: version=1, encrypted=1, plus SOF/EOF at frame boundaries.
    flags = (0x1001 | (0x0002 if packet == 0 else 0) |
             (0x0004 if packet == PACKETS - 1 else 0))
    return struct.pack(">IIIHH", MAGIC, SESSION, 0, packet, flags)


def nonce(packet: int) -> bytes:
    return struct.pack(">IIHH", SESSION, 0, 0, packet)


def read_rows(path: Path):
    rows = {}
    for line in path.read_text(encoding="ascii").splitlines():
        packet, index, data = line.split()
        key = (int(packet), int(index))
        if key in rows:
            raise SystemExit(f"duplicate row {key} in {path}")
        rows[key] = bytes.fromhex(data)
    return rows


def main() -> None:
    work = Path(__file__).resolve().parent / "xsim_backpressure_work"
    cipher_rows = read_rows(work / "tx_backpressure_cipher.hex")
    meta_rows = read_rows(work / "tx_backpressure_meta.hex")
    if len(cipher_rows) != PACKETS * BLOCKS:
        raise SystemExit(f"cipher rows {len(cipher_rows)}")
    if len(meta_rows) != PACKETS * 2:
        raise SystemExit(f"metadata rows {len(meta_rows)}")

    aesgcm = AESGCM(KEY)
    for packet in range(PACKETS):
        expected_aad = aad(packet)
        encrypted = aesgcm.encrypt(nonce(packet), payload(packet), expected_aad)
        expected_cipher, expected_tag = encrypted[:-16], encrypted[-16:]
        actual_cipher = b"".join(
            cipher_rows[(packet, block)] for block in range(BLOCKS)
        )
        actual_aad = meta_rows[(packet, 0)]
        actual_tag = meta_rows[(packet, 1)]
        if actual_cipher != expected_cipher:
            first = next(
                i for i, pair in enumerate(zip(actual_cipher, expected_cipher))
                if pair[0] != pair[1]
            )
            raise SystemExit(
                f"packet {packet}: ciphertext mismatch at byte {first}: "
                f"got={actual_cipher[first]:02x} want={expected_cipher[first]:02x}"
            )
        if actual_aad != expected_aad:
            raise SystemExit(
                f"packet {packet}: AAD mismatch "
                f"got={actual_aad.hex()} want={expected_aad.hex()}"
            )
        if actual_tag != expected_tag:
            raise SystemExit(
                f"packet {packet}: TAG mismatch "
                f"got={actual_tag.hex()} want={expected_tag.hex()}"
            )
    print(f"PASS: {PACKETS} encrypted packets survive independent AXI data/meta backpressure")


if __name__ == "__main__":
    main()
