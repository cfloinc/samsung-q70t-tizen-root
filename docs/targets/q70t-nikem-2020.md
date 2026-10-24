# QN65Q70TAFXZA — `20_NIKEM_QTV` — 2020

| Item | Value |
|---|---|
| Model | `QN65Q70TAFXZA` (Q70T) |
| Platform | NIKEM, ARMv7 |
| OS / kernel | Tizen 6.0, Linux `4.1.10` |
| Firmware | `T-NKMAKUC-2743.0` (kernel built 2026-07-02) |
| .NET | runtime dirs `2.0.0 / 2.1.x / 3.0.0`; **no `/usr/bin/dotnet`** |
| Managed hosts | `/usr/bin/dotnet-launcher`, `dotnet-launcher-inhouse` |
| Rootfs | `/dev/mmcblk0p19`, vdfs, read-only |
| Foothold | SVE-2025-50109 sdb injection → `uid 901 (sdk)`, SMACK `System` |
| Root path | exFAT USB kernel LPE → `uid 0`, SMACK `_` |
| Persistence | 776-byte in-place `profile.d` patch, block `3150336` |

## Measured facts

* No `/usr/bin/dotnet` host. Managed code only runs through the launchpad
  launcher plugins, always with `CapEff=0x0`.
* `systemctl mask` fails (`/etc` read-only). `/run/systemd/system` masks work
  until reboot; a boot hook re-applies them.
* `pkgcmd -D` exists; `pkgcmd -u` on preloads returns `-4`.
* Load average idles at 11–15 with an idle CPU (D-state processes waiting on
  absent tuner hardware). Not a performance signal.
* `kmod` has `cap_sys_module` but module loading from the `System` SMACK label
  returns `EPERM`.

## Addresses — **only for `T-NKMAKUC-2743.0`-class builds**

Derived from the TV's own TEE-decrypted kernel; all shared values independently
confirmed against a sibling Q90T build.

| Purpose | Address |
|---|---|
| `call_usermodehelper` | `0xc003b87c` |
| `memcpy` | `0xc020b120` |
| `v7_coherent_kern_range` | `0xc001d808` |
| `schedule_timeout_uninterruptible` | `0xc05330e0` |
| `ldm ip,{…,pc}` gadget | `0xc05455bc` |
| cave / copy destination | `0xc0008358..0x9000` / `0xc00083d8` |
| UEP verifier gate | `0xc01de028` |
| UEP status global | `0xc069342c` |

## What did not work

* archive-root: no dotnet host; launcher scrubs capabilities even with a forged
  app context and a Samsung partner certificate.
* `sdp_mem` physical-memory scan: the 2026 driver returns a zero page for RAM
  addresses.
* UEP verifier-entry patch: reported boot loop on a sibling model; not attempted
  here.

## References

* [WRITEUP.md](../../WRITEUP.md) — the full case study
* [FINDINGS.md](../../FINDINGS.md) — journal, §15–§22 for this target
* [USB-EXPLOIT.md](../../USB-EXPLOIT.md) — derivation
