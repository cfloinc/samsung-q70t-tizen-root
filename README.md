# Rooting a Samsung Q70T (Tizen 6.0) and making the debloat permanent

A field report and toolkit from rooting a **Samsung QN65Q70TAFXZA** (Q70T, 2020,
NIKEM platform, Tizen 6.0, kernel 4.1.10, ARMv7) and removing the advertising,
telemetry and content-recognition services **permanently** — the TV now applies
its own debloat as root **0.74 seconds after every boot**, with no USB stick and
no computer attached.

```
=== tvroot boot entry uptime=0.74s uid=0 ctx=_
--- masks installed at uptime=0s
--- delayed stop pass done at uptime=31s
--- census:
      acr: inactive
      contents-recognition-service: inactive
      vision-data-recognition-service: inactive
      vdsystem-update-manager: inactive
      org.tizen.remotepc: deactivating
```

> **Warning.** This is a hobby project, not an installer. It involves a kernel
> exploit, raw block writes to a read-only filesystem, and a patched boot
> script. A mistake can leave the TV unbootable. Only do this on hardware you
> own, and read the whole writeup first. No warranty of any kind.

## What is in this repository

| Document | Contents |
|---|---|
| **[WRITEUP.md](WRITEUP.md)** | The full narrative: target, timeline, exploit chain, firmware decryption, debloat mechanics, persistence design, UEP bypass, verification, dead ends, credits. **Start here.** |
| **[FINDINGS.md](FINDINGS.md)** | The raw field journal — every measurement, hash, failure and correction, in order, including the negative results. |
| **[DEBLOAT-STATE.md](DEBLOAT-STATE.md)** | Exactly what is deployed on the TV, how to inspect it, and how to undo it. |
| `persistent-hook/` | The boot-hook kit: `boot.sh`, `debloat.sh`, a generic same-size patcher (`build-patch.py`), the hook fragment, the apply/rollback tooling. |
| `tools/` | `foreshell.py` (resilient SDB command runner) and `tvshell_server.py` (persistent root-shell server). |
| **[LESSONS.md](LESSONS.md)** | 89 transferable rules of thumb (Developer Mode, certificates, SDB wedges, debloat, persistence) if you own a different Tizen model. |
| **[METHODOLOGY.md](METHODOLOGY.md)** | How to build, sign and install a dev-signed .NET helper app on a retail Tizen TV with no Samsung account. |
| **[USB-EXPLOIT.md](USB-EXPLOIT.md)** | The full derivation: firmware container, TEE decrypt, kernel recovery, gadget selection, cave layout, trigger build. |
| **[SANITIZATION.md](SANITIZATION.md)** | What was redacted from this public copy and how to re-check it. |
| **[NOTICE.md](NOTICE.md)** | Prior art, credits, and what is deliberately *not* included. |

## The chain, in one diagram

```
SDB injection (Developer Mode)            uid 901 (sdk)
   │
   ├── TEE / SWU TrustZone TA ────────────  decrypt the firmware update container
   │        └── kernel image ─────────────  derive the gadget addresses
   │
   ├── USB exFAT trigger ─────────────────  kernel LPE → uid 0, SMACK "_"
   │
   ├── raw block write (rootfs p19) ──────  776-byte profile.d patch, same size
   │
   └── boot: tizen-system-env.service → /etc/profile → profile.d
            └── UEP bypass: sh -c "$(cat boot.sh)"
                     └── sh -c "$(cat debloat.sh)"
                              └── 6 /run masks + stops at uptime 0.74 s
```

The two ideas that make it work:

1. **The TV decrypts its own firmware.** No Samsung signing key is needed: the
   SWU TrustZone application accepts the encrypted blob from an ordinary
   unprivileged app and hands back plaintext.
2. **Never `execve()` an unsigned script.** Tizen's UEP hooks script *file
   loading*, so `sh /path/x.sh` is refused even as root. Passing the content as
   an argument — `sh -c "$(cat /path/x.sh)"` — never touches that path.

## Reproducing it

The writeup has the full sequence ([§14](WRITEUP.md#14-reproducing-it)). In
short:

1. Enable Developer Mode and confirm the SDB injection foothold.
2. Decrypt your own firmware image with the TEEC client; verify the section CRC.
3. Derive or confirm the kernel gadget addresses for **your** build.
4. Build the USB trigger — the cave blob must stay within the validated size
   (this model: `num_ext = 67`) — arm the listener, and boot the TV with the
   stick inserted.
5. From the root shell, stage the hook kit to `/opt` and patch the profile.d
   script in place, same size, with `build-patch.py` + `apply-persistent-hook.sh`.
6. Remove the stick, power cycle, and read `/opt/usr/share/tvroot/debloat.log`
   for `uptime=<1s`.

**Every address and offset in the writeup is specific to firmware
`T-NKMAKUC-2743.0`-class images.** Other models/firmware will need their own.

## Measured effect

* Six runtime masks re-applied at every boot; ACR, content-recognition,
  vision-data and the update manager inactive from boot.
* Free RAM roughly 213 MB → 830 MB after the ACR/ad/TV-Plus services are gone.
* Load average is **not** a useful performance signal on these sets: about ten
  processes sit in `D` state waiting on absent tuner hardware, so idle load
  stays around 11–15 regardless of CPU work.

## License

MIT for the code and documentation in this repository — see [LICENSE](LICENSE).
Third-party projects referenced here keep their own licenses; no Samsung
firmware, binaries, keys, or vendor scripts are included. See [NOTICE.md](NOTICE.md).
