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
| `0x0FC` | TOC ciphertext, **3984 bytes** (ends at `0x108C`) |
| after TOC | 9 section blobs |

The TOC is **encrypted**. It decrypts to a header containing
`Tizen Software Upgrade Tree Binary Format ver. 1.9` and a section table
(offset, length, name, salt, CRC32).

**Validate the layout before decrypting.** `tools/swu-layout.py` checks the
marker, the salt offset, the 3984-byte TOC and — the useful part — that
everything from `0x108C` to EOF is a multiple of 16. Starting at `0x1000` shifts
the body by `0x8C` (140 = 12 mod 16), so the mistake is detectable without
decrypting a byte:

```
$ tools/swu-layout.py upgrade.msd
sections @0x108C: 1689748880 bytes of ciphertext (105609305.00 AES blocks)
block-aligned   : YES  (body % 16 = 0)
if sections started at 0x1000: ... (body % 16 = 12) -> INVALID, 0x8C shift
```

**Section start offset:** sections begin at `0x108C` (`0xFC` + 3984). If you
assume a 3844-byte TOC instead, sections start at `0x1000` and every section
decrypts to garbage — the ciphertext is shifted by exactly `0x8C`, so the key,
salt and TEEC calls are all fine while the pad byte and CRC are nonsense. This
exact mistake cost a reader a day; the symptom is "TOC parses, every section
fails".

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
