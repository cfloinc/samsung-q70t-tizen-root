# QN55Q90TAFXZC — `20_NIKEM_QTV` — 2020

| Item | Value |
|---|---|
| Model | `QN55Q90TAFXZC` (Q90T, 55") |
| Platform | NIKEM 2.5G (`dtsversion=0000000_nikem-2.5G`), ARMv7 |
| OS / kernel | Tizen 5.5.0, Linux `4.1.10 #1 SMP PREEMPT` |
| Firmware | `T-NKMAKUC-REL-202505100505` (About: `T-NKMAKUC-2700.6`, kernel built 2025-05-09) |
| .NET | Tizen 6.0-style dotnet apps run (netcoreapp3.0 BCL); **no `/usr/bin/dotnet`** |
| Rootfs | `/dev/mmcblk0p18`, vdfs, read-only |
| Foothold | SVE-2025-50109 sdb injection → `uid 901 (sdk)`, SMACK `System` |
| Root path | exFAT USB kernel LPE → `uid 0`, SMACK `_` |
| Persistence | 776-byte in-place `profile.d` patch, block `3147008` (2 blocks, p18) |

## Measured facts

* The published NikeM chain-address table works on **both** the 2743.0
  kernel (from `T-NKMAKUC.zip`, built 2026-07-02) and the **installed
  2700.6 kernel (built 2025-05-09)** — the family builds share the chain
  addresses. No firmware update was needed to root.
* `exfat_core.ko` / `exfat_fs.ko` sha256 `9905f0dd…` / `ecba9abb…` —
  byte-identical to the NikeL references; trigger geometry transfers.
* TEE decryption works with the shipped client unchanged; the TOC
  ciphertext is **3984 bytes at 0xFC** and sections start at `0x108C`
  (see `docs/q90t-nkmakuc-2743.0-verification.md` for the nine-section
  map with per-section evidence).
* Root shells: the kernel-stage beacon fires at USB mount (~20–40s) and
  dies ~60s later with the stage's process-group SIGHUP; `nohup bash -i
  >&9 2>&1 <&9 &` detaches a durable shell. Standby/resume does NOT
  re-fire the trigger — cold boots only.
* Persistence surgery was done **by hand** (the shipped apply script
  wedged twice in D-state on this box; the manual block procedure is in
  `docs/q90t-field-notes.md`). The vendor profile.d script is byte-
  identical to the Q70T's (md5 `e8a3d347…`).
* The profile.d hook runs `boot.sh` by content at ~0.7s after power-on;
  its dial-back must nohup + retry (network is down at 0.7s) — see the
  field notes.

## Addresses (build-specific)

None beyond the published table; the installed 2700.6 kernel accepts the
2743.0-derived constants (verified by live exploit, not by re-derivation).

## What did not work

* CIFS/Remote-PC bounded root was chased first (the password field mangles
  spaces/`<`, the credential join inserts commas) — superseded by the USB
  path; see the field notes.
* `nikem-uep` (UEP gate patch) does not fit num_ext=67: the patch adds 44
  stage bytes and the cave blob exceeds the copy window. Deferred.
* Dropbear: UEP up, unsigned binaries never exec (silently killed).

## References

* `docs/q90t-nkmakuc-2743.0-verification.md` — verified firmware map
* `docs/q90t-field-notes.md` — campaign record and manual procedures
* Upstream: [Luminger/samsung-tv-usb-root](https://github.com/Luminger/samsung-tv-usb-root)
