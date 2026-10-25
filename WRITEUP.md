# Rooting and permanently debloating a Samsung QN65Q70TAFXZA

**Result:** full `uid=0` root on a 2020 Samsung Q70T (Tizen 6.0, firmware
**`T-NKMAKUC-2743.0`**, kernel built 2026-07-02), and a debloat that re-applies
itself **as root ~0.73 s after every boot, with no USB stick and no computer
involved.**

**Scope:** every address, offset and behaviour here is specific to that firmware
build. A matching model number is not compatibility — see §1 and §6.

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

Everything below was measured on the device. Dead ends are documented as dead
ends; nothing is claimed that wasn't observed.

---

## 1. The target

| Item | Value |
|---|---|
| Model | `QN65Q70TAFXZA` (Q70T, 2020) |
| SoC platform | NIKEM, ARMv7 (32-bit) |
| OS | Tizen 6.0 (Tizen6/TV) |
| Kernel | `Linux 4.1.10 #1 SMP PREEMPT Thu Jul 2 08:49:56 UTC 2026` |
| Firmware | `T-NKMAKUC-2743.0` |
| Build toolchain | gcc 6.2.1 (Tizen/Linaro VDCosmos) |
| RAM | 1.8 GB, 4 cores |
| Rootfs | `/dev/mmcblk0p19`, Samsung **vdfs**, mounted read-only |
| DUID | `<DUID>` (TVkey `<TVKEY_ID>`) |

Two structural facts shape everything:

* **`/` and `/etc` are read-only vdfs**, even for root. Units cannot be added,
  edited or persistently masked there.
* **`/opt` and `/opt/usr/home/owner` are writable vdfs on eMMC** and survive
  reboots. `/run` and `/tmp` are tmpfs.

---

## 2. Timeline

| Day | What happened |
|---|---|
| 1 | Developer Mode + SDB injection foothold (`uid=901 sdk`, SMACK `System`). Firmware `upgrade.msd` downloaded and its MSDU11 container decoded. TEE/SWU TrustZone TA used to decrypt the firmware **from an unprivileged managed app**. Kernel image extracted and NIKEM gadget addresses derived. |
| 2 | USB exFAT trigger built from the derived addresses. **Root achieved** (`uid=0`, SMACK `_`). Debloat applied by hand; discovered which mechanisms persist and which don't. Attempts at a no-USB root via the upstream archive-root chain; found the launcher's capability scrub. |
| 3 | Persistence designed: a 776-byte in-place patch of a root-sourced `profile.d` script. Blocked by UEP. Found the bypass (`sh -c "$(cat …)"`), applied the patch, and **verified the TV debloats itself at boot+0.74 s with no stick inserted.** |

---

## 3. The chain

```
SDB injection (SVE-2025-50109)            uid 901 (sdk), SMACK System
        │
        ├─ TEE / SWU TrustZone TA ─────── decrypt firmware MSDU11 (no key needed)
        │        └─ kernel uImage ─────── derive NIKEM gadget addresses
        │
        ├─ USB exFAT trigger ─────────── kernel LPE → uid 0, context "_"
        │
        ├─ raw block write p19 ───────── 776-byte profile.d patch (same size)
        │
        └─ boot: tizen-system-env.service → /etc/profile → profile.d
                 └─ UEP bypass: sh -c "$(cat boot.sh)"
                          └─ sh -c "$(cat debloat.sh)"
                                   └─ 6 /run masks + stops at uptime 0.74 s
```

---

## 4. Foothold: the SDB injection

Samsung's `sdb` accepts a crafted package-installer argument that runs a shell
command as `uid=901(sdk)` with SMACK label `System`
(SVE-2025-50109). On this firmware the shell itself is unreliable — only a
retry-wrapped *capture* path works, because the daemon wedges after a handful
of operations.

Practical rules learned the hard way:

* `sdb shell "0 applist"` works; interactive `sdb shell` closes immediately.
* **Every injection-fired background process dies when the injection session
  ends.** Background work must be started from a real root shell.
* The injection dies after ~2–6 operations, and `kill-server` / `start-server`
  on the **host** clears the wedge (not always; a reboot always does).
* Never glob `/opt/media/*` once the USB trigger has fired — that partition's
  filesystem is the one the exploit corrupts, and a readdir hangs in D-state.

`foreshell.py` in `tvroot-app/` wraps all of this with recovery.

---

## 5. Reading the firmware without the key

The firmware update file `T-NKMAKUC/image/upgrade.msd` (1.7 GB) is an MSDU11
container:

* TOC marker `Salted__` at `0xEC`, salt `9cdd28651baf3f28`,
* TOC ciphertext at `0xFC` (3984 bytes), 9 sections,
* every candidate public T-NKM key fails.

**The TV decrypts it for us.** The SWU TrustZone trusted application accepts
the encrypted passphrase and TOC salt from an ordinary managed app. The trick
is the *legacy* TEEC ABI that the 2020 runtime expects:

* 60-byte `TEEC_Operation`, 12-byte params, one byte per param type,
* `PARTIAL_INOUT` for all memrefs, `TEEC_AllocateSharedMemory` buffers.

`TEEC_OpenSession` succeeds as **uid 5001 with no capabilities**. The decrypted
TOC reports `Tizen Software Upgrade Tree Binary Format ver. 1.9`; extraction
gives the kernel image:

* `uImage` = section 3, `0x6b7110` bytes, salt `d1f7e55f5ae26010`,
* CRC32 `0xa4af26ca` — matches the TOC,
* raw uncompressed Linux 4.1.10, build banner identical to `/proc/version`.

Exfiltration uses the `sdb pull` whitelist: files named
`profctl_[a-zA-Z]{1,30}.log` in `sdk_tools/`.

---

## 6. The USB kernel exploit

`exfat_core.ko` on this TV is sha256 `9905f0dd…` — byte-identical to the module
the published NikeL trigger was built for. An exFAT directory with a crafted
`num_ext` overflows a 30-byte-per-fragment copy into a fixed kernel cave; the
cave blob restores the frame and jumps through `call_usermodehelper`.

Addresses derived from **our own decrypted kernel**, then independently
confirmed against a QE75Q90TATXXU image published by metaljay (identical for
every shared value):

| purpose | address |
|---|---:|
| `call_usermodehelper` | `0xc003b87c` |
| `memcpy` | `0xc020b120` |
| `v7_coherent_kern_range` | `0xc001d808` |
| `schedule_timeout_uninterruptible` | `0xc05330e0` |
| `ldm ip,{…,pc}` gadget | `0xc05455bc` |
| cave / copy dest | `0xc0008358..0x9000` / `0xc00083d8` |
| UEP verifier gate | `0xc01de028` |
| UEP status global | `0xc069342c` |

The trigger fires when the TV mounts the stick at boot. `call_usermodehelper`
runs the **signed** `/bin/bash`, so no unsigned code is executed at that stage:

```
KERNEL-STAGE-OK
bash-3.2# id
uid=0(root) gid=0(root) context="_"
```

`context="_"` is the important part: a kernel-spawned process has no SMACK
label, so it is not confined.

### Hard-won geometry rule

Every edit to the kernel-stage command string changes the cave blob length and
therefore `num_ext` (the number of 30-byte fragments the driver copies). Only
**`num_ext = 67` (cave ≤ 547 bytes)** is field-validated on this TV. Images at
`num_ext = 70` boot-looped the television (content → ~10 s → reboot).
`build-nikem-usb.py` now refuses to ship anything else.

A second, subtler rule: the beacon `exec 9<>/dev/tcp/…` runs **inside the
exFAT mount syscall**. If nothing is listening, the connect blocks and stalls
the mount — the watchdog reboots the TV. Always have the listener armed before
powering the TV on with the stick inserted.

> Physical note: macOS `fsKit` auto-mounts the stick and can "repair" the
> deliberately malformed exFAT entry, silently defusing the trigger. Flash and
> go straight to the TV; never let the Mac mount it in between.

---

## 7. Debloat: what actually works on Tizen 6.0

Measured, in order of durability:

| Mechanism | Persists reboot? | Notes |
|---|---|---|
| `ConditionPathExists` markers in `/opt/usr/share/systemd/system/` | ✅ | Only for units that ship the condition (`pisa-service`, `canalysis-daemon`, …). Creating the file **disables** the unit. |
| `systemctl mask` | ❌ | `/etc/systemd/system` is read-only even for root. |
| `systemctl disable` | ❌ | Vendor targets / path units / D-Bus re-activate "disabled" services. |
| `/run/systemd/system/<unit> → /dev/null` | ✅ if re-applied | `/run` is first in `UnitPath` and writable; tmpfs, so it must be re-created every boot. |
| `pkgcmd -D -t app -n <pkg> --uid 5001` | ✅ | Deactivates an app for the user; nothing is uninstalled. |
| `pkgcmd -u` on preloads | ❌ | `Operation not allowed [-4]`. |

`systemctl stop` can hang forever on this TV when the job touches a D-state
unit — **always use `systemctl --no-block stop`** in scripts.

The result of the boot hook (measured): six runtime masks, `acr`,
`contents-recognition-service`, `vision-data-recognition-service` and
`vdsystem-update-manager` inactive; `org.tizen.remotepc` deactivating. Free RAM
went from ~213 MB to ~830 MB across the session; the load average, however, is
**not** a useful performance signal on these sets — roughly ten processes sit
in uninterruptible D-state waiting on absent tuner hardware, so idle load
sits around 11–15 regardless of CPU work.

---

## 8. Persistence: a 776-byte in-place rootfs patch

The only root-run, writable-adjacent code path on this firmware is:

```
tizen-system-env.service
  ExecStart=/usr/bin/env -i sh -c 'source /etc/profile; …'
        └─ /etc/profile
              └─ for i in /etc/profile.d/*.sh; do . "$i"; done
                    └─ /etc/profile.d/bash_prompt_custom.sh   ← 776 bytes
```

`tizen-system-env.service` is `WantedBy=basic.target`, `DefaultDependencies=no`,
and is active ~2 s after boot. It **sources** the profile.d scripts as root.

The vendor file `bash_prompt_custom.sh` is 776 bytes of prompt/alias sugar
inside `if [ "$PS1" ]`, so it does nothing during a non-interactive boot
source. We replace it **in place, same size** — no filesystem metadata is
touched:

```
device      : /dev/mmcblk0p19  byte 1612972032  (512-block 3150336 +0, 2 blocks)
backup      : /opt/usr/share/tvroot/backup/rootfs-p19-blk3150336-2.bin
vendor sha  : effe97f8ec948a15962fc8a1b85a4e1e446352b8c5caae703e1ed0684425e33c
v1 patch    : ca30fa2bb89596b7e5db45185bb265487165072745a5455d7c0d2138de9d3154
v2 patch    : 6c5a2ceb62586047…  (current — UEP bypass baked in)
rollback    : sh /opt/usr/share/tvroot/backup/rollback.sh
```

Locating it on the live device needs no filesystem maths: grep the raw block
device for a unique marker string, then verify the 776 bytes at that offset
hash to the vendor original before writing anything.

The patched body keeps the vendor prompt logic (minified) and adds a once-per-boot
hook:

```sh
if [ ! -e /run/.tvroot-hook ]; then
  : > /run/.tvroot-hook 2>/dev/null
  ( …wait up to 120 s for /opt…;
    /bin/sh -c "$(cat /opt/usr/share/tvroot/boot.sh)" ) >/dev/null 2>&1 &
fi
```

`boot.sh` and `debloat.sh` live on the writable `/opt` partition, so they can be
edited without touching flash again.

---

## 9. The last wall: UEP, and the bypass

Every attempt to run our own scripts failed with:

```
[uep][bash] the file is NOT signed!! : /opt/usr/share/tvroot/boot.sh
```

UEP ("unsigned executable prevention") is built into the kernel; a reboot
re-arms it, and on some sets it re-arms **within a session** after a few
minutes. Root alone does not lift it.

The decisive observation, from [txtsamu's NT72172 writeup](https://github.com/txtsamu/claude-research/blob/master/samsung-tv-uep-bypass-and-kants2-root.md):

> Tizen's shell hooks script loading, so the file path alone triggers the check.
> The content-as-argument form does not, because nothing unsigned is ever
> executed: `sh -c "$(cat /opt/hermes/debloat.sh)"`

**Both links** in our boot chain now use that form — the profile.d hook invokes
`boot.sh` by content, and `boot.sh` invokes `debloat.sh` by content. No unsigned
file is ever `execve`'d, so UEP has nothing to inspect. (Sourcing `. file` also
worked in testing, but content-as-argument is the documented, reliable form.)

---

## 10. Verification

After the final power cycle **with the USB stick removed**:

```
/run/.tvroot-hook      created by the patched profile.d script this boot
/run/.tvroot-debloat   created by boot.sh
debloat.log mtime      ~21 s after power-on
masks                  6
acr / contents-recognition-service / vision-data-recognition-service  inactive
```

and the log entry itself:

```
=== tvroot boot entry uptime=0.74s uid=0 ctx=_
--- masks installed at uptime=0s
--- delayed stop pass done at uptime=31s
```

`uptime=0.74s` is the proof: the hook ran before userspace had finished starting,
as `uid=0`, on the firmware's own boot path.

---

## 11. Rollback

Everything is reversible without reflashing:

```sh
sh /opt/usr/share/tvroot/backup/rollback.sh     # restores the vendor 776 bytes
rm /opt/usr/share/tvroot/boot.sh /opt/usr/share/tvroot/debloat.sh
# masks are tmpfs; they vanish on the next boot
```

The markers under `/opt/usr/share/systemd/system/` are removed with `rm`.

---

## 12. Dead ends (so you don't repeat them)

* **sdp_mem physmap cred patch** — the 2026 firmware's `sdp_mem_mmap()` checks
  the request against DTS memory regions and returns a zero page for all RAM.
  Every offset "reads" zeros. Dead.
* **`/usr/bin/dotnet` archive-root** — this 2020 firmware has the .NET
  *runtimes* (2.0/2.1/3.0) but **no dotnet host binary**. `dotnet-launcher`
  exists, but it scrubs capabilities (`CapEff=0x0`) before
  `coreclr_execute_assembly`, and requires an AUL app context
  (`GetLaunchedAppPackageID`). Even with a forged `APP_ID` and a Samsung partner
  certificate, the assembly runs capless.
* **`kmod insmod`** — `/usr/bin/kmod` carries `cap_sys_module`, but loading a
  module from the `System` SMACK label returns `EPERM`; module load needs `_`.
* **UEP verifier-entry patch** — patching the gate itself (`0xc01de028`) caused
  a boot loop on a Q90T (metaljay) and was not attempted on this set; the
  status global `0xc069342c` was reported to allow unsigned binaries but leave
  the system unstable. The content-as-argument bypass makes both unnecessary.
* **`num_ext` drift** — see §6; unvalidated trigger geometry boot-loops the TV.

---

## 13. Prior art and thanks

This work stands on several people's shoulders:

* **[chris-ritsen/samsung-tv-root](https://github.com/chris-ritsen/samsung-tv-root)** —
  the SDB injection foothold, archive-root, and the QN90B UEP note.
* **[txtsamu/claude-research](https://github.com/txtsamu/claude-research)** —
  the NT72172 UEP analysis and the content-as-argument bypass that finished
  this project.
* **metaljay / [tiz0wn #1](https://github.com/sebastianspicker/tiz0wn/issues/1)** —
  independent NIKEM address confirmation, the UEP boot-loop warning, and the
  raw-block `profile.d` persistence technique.
* **Luminger's samsung-tv-usb-root** — the exFAT trigger and `ksymtab` tooling.
* **[splitcipher/couchroot](https://github.com/splitcipher/couchroot)** — the
  QN90A audit that established "disable doesn't stick, `/run` masks do".
* **[berteotti/custom-tv](https://github.com/berteotti/custom-tv)**,
  **[abhiigatty](https://abhiigatty.com/blog/samsung-tv-modding-with-ai-tizen-9-home-and-debloating/)**,
  **[Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv)** — the
  marker census, `pkgcmd -D --uid 5001` idiom, and confirmation that package
  disable flags re-enable themselves after reboots.
* Prior Tizen 6.0 field reports in
  [chris-ritsen/samsung-tv-root#5](https://github.com/chris-ritsen/samsung-tv-root/issues/5) —
  preload packages cannot be uninstalled; markers are the durable route.

---

## 14. Reproducing it

1. Enable Developer Mode; confirm the SDB injection (`uv run python tvroot-app/foreshell.py 'id'`).
2. Extract the kernel: use the TEEC client in `tvroot-app/` against your own
   `upgrade.msd`; verify the section CRC.
3. Derive or confirm the gadget addresses (`ksymtab` tooling in
   `references/samsung-tv-usb-root/`), or use the table in §6 **only** for
   `T-NKMAKUC-2743.0`-class firmware.
4. Build the stick with `python3 tvroot-app/build-nikem-usb.py` (guard enforces
   `num_ext=67`), flash it, arm `tvshell_server.py` on `:4444`, and boot the TV
   with the stick in.
5. From the root shell, stage `hook.tar` to
   `/home/owner/share/tmp/sdk_tools/`, then apply the profile.d patch
   (`persistent-hook/`), remembering both UEP-safe invocations.
6. Pull the stick, power cycle, and read
   `/opt/usr/share/tvroot/debloat.log` for `uptime=<1s`.

Full field journal with every measurement, dead end and hash:
**[FINDINGS.md](FINDINGS.md)**.
Operational state and restore steps: **[DEBLOAT-STATE.md](DEBLOAT-STATE.md)**.
