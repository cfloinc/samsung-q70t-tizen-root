# 04 — From a section to a usable kernel image

## What you get from the TEE

The decrypted kernel section on this firmware is **not** a compressed zImage or
a u-boot wrapped image. After decryption it is a **raw, uncompressed ARM Linux
image**:

```
Linux version 4.1.10 (abuild@B3203DRG)
(gcc version 6.2.1 20161213 (Tizen/Linaro GCC 6.2.1 2016.12/VDCosmos-20190704 7.13)
 #1 SMP PREEMPT Thu Jul 2 08:49:56 UTC 2026
```

Verify that banner against `/proc/version` on the TV before deriving anything.
If it does not match, you have the wrong section or the wrong firmware.

## Establishing the load base

`PAGE_OFFSET` is `0xC0000000` on this platform, and **there is no KASLR**. That
means a virtual address in the image maps to a file offset by:

```
file_offset = VA - 0xC0000000
```

Check this before trusting it: take a known string from a known function, find
it in the raw image, and confirm the offset matches `VA - 0xC0000000`.

## Cross-check the CRC

The TOC stores a CRC32 per section. Compute it on the decrypted bytes. A match
proves both decryption and exfiltration were lossless.

## Cross-check a module

`exfat_core.ko` on the TV has a SHA-256; compare it to the module published with
the matching trigger. On this TV it is `9905f0dd…`, byte-identical to the module
the public NikeL trigger was built for. That is strong evidence the exploit's
structure transfers, even though the addresses must still be derived per build.

## What to keep

* the raw image (offline analysis only),
* the TOC section table,
* the banner string,
* the CRC values,
* the list of loaded modules + hashes from `/proc/modules` and the module tree.

Do **not** commit the image to a public repo.
