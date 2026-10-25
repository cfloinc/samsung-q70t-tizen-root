#!/usr/bin/env python3
"""Validate an MSDU11 firmware container's layout BEFORE decrypting anything.

The expensive failure mode this prevents: assuming the wrong TOC ciphertext
length, which shifts every section by 0x8C while the key, salt and TEEC calls
all remain correct. The result is "TOC parses, every section decrypts to
garbage" with a bad pad byte and a CRC that never matches.

Why the check works: section ciphertexts are AES blocks, so everything from
0x108C to EOF must be a multiple of 16. Starting sections at 0x1000 instead
adds 0x8C (140) bytes, which is 12 mod 16, so the misalignment is detectable
without decrypting anything. (The "0x8C at EOF" figure seen in one report is
really the gap between the assumed 0x1000 and the true 0x108C.)

Usage:
    swu-layout.py <upgrade.msd>
"""
import sys
from pathlib import Path

SALTED_OFF = 0xEC
SALT_OFF = 0xF4
TOC_OFF = 0xFC
TOC_LEN = 3984          # MSDU11 on T-NKMAKUC-class firmware
SECTIONS_OFF = TOC_OFF + TOC_LEN      # 0x108C
TRAILER = 0          # no trailer: sections run to EOF


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    p = Path(sys.argv[1])
    data = p.read_bytes()
    size = len(data)
    ok = True

    print(f"file            : {p} ({size} bytes)")

    magic = data[SALTED_OFF:SALTED_OFF + 8]
    print(f"marker @0x{SALTED_OFF:X}  : {magic!r} {'OK' if magic == b'Salted__' else 'MISMATCH'}")
    ok &= magic == b"Salted__"

    salt = data[SALT_OFF:SALT_OFF + 8]
    print(f"salt   @0x{SALT_OFF:X}  : {salt.hex()}")

    print(f"TOC    @0x{TOC_OFF:X}  : {TOC_LEN} bytes -> ends 0x{TOC_OFF + TOC_LEN:X}")
    body = size - SECTIONS_OFF - TRAILER
    print(f"sections @0x{SECTIONS_OFF:X}: {body} bytes of ciphertext "
          f"({body / 16:.2f} AES blocks)")

    aligned = body % 16 == 0
    print(f"block-aligned   : {'YES' if aligned else 'NO'}  (body % 16 = {body % 16})")
    ok &= aligned

    # Demonstrate the classic mistake.
    bad_body = size - 0x1000 - TRAILER
    print(f"if sections started at 0x1000: {bad_body} bytes "
          f"(body % 16 = {bad_body % 16}) -> {'would look valid' if bad_body % 16 == 0 else 'INVALID, 0x8C shift'}")

    if not ok:
        print("\nRESULT: layout does not validate; do not decrypt yet.")
        return 1
    print("\nRESULT: layout validates. Extract the TOC as")
    print(f"  dd if={p.name} bs=1 skip={TOC_OFF} count={TOC_LEN} of=toc.bin")
    print("and a section at its TOC-declared offset, never at 0x1000.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
