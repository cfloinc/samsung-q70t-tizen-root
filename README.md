# Samsung Tizen TV — reverse engineering notes and tools

Field notes from taking apart a retail Samsung Tizen TV: the SDB foothold, the
encrypted firmware container, the TrustZone decryption path, kernel recovery,
address derivation, UEP, the capability model, the boot chain, and what actually
survives a reboot.

The first fully documented target is a **QN65Q70TAFXZA** (2020 Q70T, NIKEM,
Tizen 6.0, kernel 4.1.10, ARMv7), which now roots itself and re-applies its
debloat **as root 0.74 seconds after every boot**, with no USB stick and no
computer attached:

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

> **Warning.** Hobby research, not an installer. It involves a kernel exploit,
> raw block writes to a read-only filesystem and a patched boot script. A mistake
> can leave a TV unbootable. Only on hardware you own. No warranty.

---

## How to read this repository

### Methodology — the transferable part

| # | Document | Question |
|---|---|---|
| 01 | [Foothold over sdb](docs/methodology/01-foothold.md) | How do I get code execution as `uid 901`? |
| 02 | [Firmware container](docs/methodology/02-firmware-container.md) | What is inside `upgrade.msd`? |
| 03 | [TEE decryption](docs/methodology/03-tee-decrypt.md) | How do I decrypt it without a key? |
| 04 | [Kernel recovery](docs/methodology/04-kernel-recovery.md) | How do I get a usable kernel image? |
| 05 | [Address derivation](docs/methodology/05-address-derivation.md) | How do I find gadgets for *my* build? |
| 06 | [UEP](docs/methodology/06-uep.md) | Why are unsigned scripts refused, and what bypasses it? |
| 07 | [Capabilities and zones](docs/methodology/07-capabilities-and-zones.md) | Where do capabilities come from, and where are they stripped? |
| 08 | [Boot chain and persistence](docs/methodology/08-boot-chain-and-persistence.md) | What runs as root at boot, and how do I hook it? |
| 09 | [Debloat](docs/methodology/09-debloat.md) | Which disabling mechanisms survive a reboot? |
| 10 | [Debug channels](docs/methodology/10-debug-channels.md) | Why did my command silently not run? |

### Targets — measured per device

| Target | Platform | Year | Root path | Persistence |
|---|---|---|---|---|
| [QN65Q70TAFXZA](docs/targets/q70t-nikem-2020.md) | `20_NIKEM_QTV` | 2020 | exFAT USB kernel LPE | raw-block `profile.d` patch |

A target page states the firmware string next to any address table. Addresses are
**not portable** across builds.

### Case study and raw evidence

| Document | Contents |
|---|---|
| **[WRITEUP.md](WRITEUP.md)** | The finished Q70T narrative: timeline, chain, verification, dead ends |
| **[USB-EXPLOIT.md](USB-EXPLOIT.md)** | Full derivation: container, TEE, kernel, gadget selection, cave layout, trigger |
| **[FINDINGS.md](FINDINGS.md)** | Chronological journal — every measurement, failure and correction |
| **[LESSONS.md](LESSONS.md)** | 89 transferable rules of thumb |
| **[METHODOLOGY.md](METHODOLOGY.md)** | Build/sign/install a dev-signed .NET helper with no Samsung account |
| **[DEBLOAT-STATE.md](DEBLOAT-STATE.md)** | What is deployed, hashes, inspect and restore |

### Tools

| Tool | Purpose |
|---|---|
| `tools/foreshell.py` | Resilient SDB command runner (injection + capture + wedge recovery) |
| `tools/tvshell_server.py` | Persistent beacon/root-shell server with keepalive |
| `tools/uep-test.sh` | Empirically determines which script invocations UEP allows |
| `tools/capscan.sh` | Compact capability-bearing binary inventory |
| `tools/tee-client/` | The TrustZone client that decrypts the firmware container |
| `tools/persistent-hook/` | Same-size `profile.d` patcher, boot hook, debloat, rollback |

---

## The chain in one diagram

```
SDB injection (Developer Mode)            uid 901 (sdk)
   │
   ├── TEE / SWU TrustZone TA ────────────  decrypt the firmware update container
   │        └── kernel image ─────────────  derive the gadget addresses
   │
   ├── USB exFAT trigger ─────────────────  kernel LPE → uid 0, SMACK "_"
   │
   ├── raw block write (rootfs) ──────────  same-size profile.d patch
   │
   └── boot: tizen-system-env.service → /etc/profile → profile.d
            └── UEP bypass: sh -c "$(cat boot.sh)"
                     └── sh -c "$(cat debloat.sh)"
                              └── /run masks + stops at uptime 0.74 s
```

Two ideas carry it:

1. **The TV decrypts its own firmware.** No signing key needed: the SWU
   TrustZone application accepts the encrypted blob from an ordinary app.
2. **Never `execve()` an unsigned script.** UEP hooks script *file loading*;
   `sh -c "$(cat file)"` never gives it a file to inspect.

---

## Starting on a different model

1. Inventory the device: firmware string, kernel, runtime dirs, `capscan.sh`,
   read-only vs writable partitions, what is in `/etc/profile.d`.
2. Confirm the foothold and what uid it gives you.
3. Decide which root path the device class supports:
   * `/usr/bin/dotnet` with `cap_sys_admin` → archive-root may apply;
   * no dotnet host, launcher plugins only → managed code runs capless (see 07);
   * a world-writable DMA device → physical-memory route.
4. Get the firmware container, decrypt via the TEE, recover the kernel, derive
   addresses **for that build**.
5. For persistence, look for a boot path that sources or executes something on a
   writable partition, and verify it runs as root.
6. Test every claim on the device; write down the firmware string next to every
   address.

---

## Legal and safety

Research on hardware you own, for interoperability and to remove unwanted
behaviour from your own device. Nothing here is affiliated with Samsung. No
firmware, Samsung binaries, keys or vendor scripts are included — see
[NOTICE.md](NOTICE.md) and [SANITIZATION.md](SANITIZATION.md).

## License

MIT for the code and documentation — see [LICENSE](LICENSE). Third-party work
retains its own license.
