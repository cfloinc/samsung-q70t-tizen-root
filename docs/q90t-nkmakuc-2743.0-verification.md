# Q90T / T-NKMAKUC-2743.0 — verified firmware map and field notes

Recorded 2026-10-24 on a QN55Q90TAFXZC (2020 Q90T, NikeM, Tizen 5.5, ARMv7).
The installed firmware is T-NKMAKUC-REL-202505100505 (kernel built 2025-05-09),
but the downloaded `T-NKMAKUC.zip` is the **2743.0 release** — its kernel is
byte-for-byte the image this project published (`Linux version 4.1.10 …
#1 SMP PREEMPT Thu Jul 2 08:49:56 UTC 2026`, abuild@B3203DRG).

Everything below was verified empirically: every decryptable section was
decrypted on the TV through the TEE client and checked for valid PKCS7 padding
(`padOK=True`) plus content signatures where one exists.

## The one correction: TOC ciphertext length

`docs/methodology/02-firmware-container.md` says 3844 bytes at 0xFC. The real
length is **3984 bytes** (0xF90, 16-aligned). Extracting 3840/3844 shifts every
section offset by 0x8C and produces deterministic garbage from correct keys —
the output looks exactly like a wrong-key failure (no ASCII anywhere). Check
the chain before suspecting the key: with the right base, the cumulative sizes
close **exactly** at EOF.

## Verified section map (T-NKMAKUC-2743.0)

| Section | Offset | Ciphertext size | Salt | Evidence |
|---|---|---:|---|---|
| ddr.init | 0x00108C | 0x6C010 | 214dccc0fde9407e | padOK |
| seret.bin | 0x06D09C | 0x2FE010 | 8d8a646b7ef2a69d | padOK, ARM code |
| uImage | 0x36B0AC | 0x6B7110 | d1f7e55f5ae26010 | padOK, CRC 0xa4af26ca, banner |
| dtb.bin | 0xA221BC | 0x17E010 | 74e8eabf6fc10a72 | padOK, DTB magic d00dfeed |
| sign.bin | 0xBA01CC | 0x410 | 0dd80fa5e6a10dc6 | padOK |
| secos.bin | 0xBA05DC | 0x3FE010 | 8cc1cd2caa84262f | padOK |
| secos_drv.bin | 0xF9E5EC | 0xFE010 | 2f3ed39a14ee4dd5 | padOK |
| platform.img | 0x109C5FC | 0x637ED010 | 11abbc9067638bc4 | salt + EOF closure (not decrypted: 1.67 GB) |
| factory_peq.img | 0x6488960C | 0x2F0010 | 10edba77fdbdb90d | padOK, squashfs "hsqs" |

Base = 0x108C (header 0xEC-0xF3 "Salted__", salt 9cdd28651baf3f28 at 0xF4,
TOC ciphertext 0xFC..0x108B). Cumulative sum ends at 0x64B7961C = EOF, exact.

## The client works as-is on this TA

On this TV's TA the shipped `tee.cs` decrypts sections unchanged once the
offset is right (uImage run: `plain total=0x6b7100`, `pad=16 padOK=True`,
`crc32=0xa4af26ca`). Observed TA behavior that matters:

- cmd1 returns the **full chunk** (n, not n−16) per call.
- The 16-byte hold-back in tee.cs re-frames the stream but preserves byte
  order, so the output is correct; the last 16 bytes (padding block) are
  flushed via the pending path and validated correctly.
- The TOC decrypt works even with a truncated input (3840 bytes fed): the
  banner/table sit early in the plaintext. Do not let a "working TOC" vouch
  for the extraction length.

## Updater protocol reference (Ghidra, SWUStandalone)

For future TA work, the shipped updater's own client (SWUTrustZoneClient)
does, in order:

1. cmd3 generatePassphrase — p0=IN (raw 416-byte encrypted blob), p1=OUT,
   p2=VALUE_INOUT {bool,0} (bool = encrypt flag; 0 for decrypt), result length
   in p2's **second** value word. Output = plaintext passphrase + PKCS7, pad
   stripped host-side.
2. cmd0 init — p0=passphrase IN, p1=salt IN, p2=VALUE_INOUT {0,0}, p3=NONE
   (paramTypes 0x30f0f).
3. cmd1 update — per ≤64 KiB chunk: p0=IN, p1=OUT with **p1.size = chunk
   size**, p2=VALUE_INOUT, length in p2's **first** value word. No hold-back;
   the TA keeps CBC state across calls in-session.
4. cmd2 finalize — p0=OUT, p1=VALUE_INOUT, length in first value word.

The salt acts as the IV only; key derivation does not depend on it (blocks 1+
are identical across salts). The old-shape cmd0 in tee.cs ({0,1}/{1,0x201}
VALUE_INPUTs) also works for init when fed the raw encrypted blob directly.

## Platform notes for this model

- Signing: the SDK's old distributor certs are expired (pkgcmd -22) and the
  2022 `-new` chain is not in this TV's trust store (pkgcmd -12). The only
  installer that works on this firmware is Apps2Samsung (its own channel).
- The `sdb pull` whitelist works for `sdk_tools/profctl_*.log`; general pulls
  are refused.
- sdb wedges hard after bursts of injections; a TV power-cycle always clears
  it, self-recovery takes minutes. Kill the local sdb server before retries.
- The TV's TEE decryption is a design property, not an exploit: any local app
  can ask the SWU TA to decrypt the update container (uid 5001, no caps).
