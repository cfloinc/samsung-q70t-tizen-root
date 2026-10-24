# 02 — The firmware container (`upgrade.msd`)

## Why

You need the **kernel image** to derive gadget addresses for *your* build.
Public address tables are only valid for the exact firmware they came from.

## Format observed on `T-NKMAKUC-2743.0`

`upgrade.msd` is an **MSDU11** container:

| Offset | Content |
|---|---|
| `0x000` | MSDU11 header |
| `0x0EC` | ASCII `Salted__` |
| `0x0F4` | 8-byte salt — `9cdd28651baf3f28` on this image |
| `0x0FC` | TOC ciphertext, 3844 bytes |
| after TOC | 9 section blobs |

The TOC is **encrypted**. It decrypts to a header containing
`Tizen Software Upgrade Tree Binary Format ver. 1.9` and a section table
(offset, length, name, salt, CRC32).

Sections are independently encrypted, each with its own salt. On this image:

| Section | Content | Notes |
|---|---|---|
| 3 | `uImage` | `0x6b7110` bytes, salt `d1f7e55f5ae26010`, CRC32 `0xa4af26ca` |
| 8 | `platform.img` | ~1.67 GB, the system rootfs, salt `11abbc9067638bc4` |

## The key does not matter

All public T-NKM key candidates failed on this image. Do not spend time on the
key: the TV's own TrustZone application decrypts the container for you — see
[03 — TEE decryption](03-tee-decrypt.md).

## How to inspect

1. Pull the TOC via the TEE client, and parse the section table from the
   plaintext.
2. Identify the section whose name/CRC corresponds to the kernel (usually
   `uImage`).
3. Decrypt that section via the TEE, exfiltrate it, and verify the CRC32 from
   the TOC.

Never assume section numbering is stable across firmware. Parse the TOC.
