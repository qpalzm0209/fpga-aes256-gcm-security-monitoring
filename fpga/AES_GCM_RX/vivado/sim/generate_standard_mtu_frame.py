from pathlib import Path
from struct import pack
import sys

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


KEY = bytes(range(32))
MAGIC = 0x5043414D
VERSION = 1
SESSION = 0x26080330
FRAME = 7
PACKET_COUNT = 1280
PAYLOAD_BYTES = 1440
OUTPUT = (Path(sys.argv[1]) if len(sys.argv) > 1
          else Path.cwd() / "rx_encrypted_frame_1280x1472.bin")


def flags(index: int) -> int:
    value = VERSION << 12
    value |= 1  # encrypted
    if index == 0:
        value |= 1 << 1
    if index == PACKET_COUNT - 1:
        value |= 1 << 2
    return value


aesgcm = AESGCM(KEY)
records = bytearray()
for index in range(PACKET_COUNT):
    aad = pack(">IIIHH", MAGIC, SESSION, FRAME, index, flags(index))
    nonce = pack(">IIHH", SESSION, FRAME, 0, index)
    payload = bytes(((index * PAYLOAD_BYTES + offset) & 0xFF)
                    for offset in range(PAYLOAD_BYTES))
    ciphertext_and_tag = aesgcm.encrypt(nonce, payload, aad)
    records += aad + ciphertext_and_tag

expected = PACKET_COUNT * (16 + PAYLOAD_BYTES + 16)
if len(records) != expected:
    raise RuntimeError(f"generated {len(records)} bytes, expected {expected}")
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_bytes(records)
print(f"generated {OUTPUT} ({len(records)} bytes)")
