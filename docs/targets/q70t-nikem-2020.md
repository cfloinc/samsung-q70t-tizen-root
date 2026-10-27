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

## Kernel module ABI (tested 2026-10-27)

The stock `acm/acmd.ko` is the ABI oracle. Its `.gnu.linkonce.this_module`
section is **`0x134` bytes**, with `init_module` at **`0xc0`** and
`cleanup_module` at **`0x12c`**. The upstream
[gtalusan recipe](https://github.com/gtalusan/samsung-tizen-kmod-recipe)
builds **`0x150` / `0xc0` / `0x148`** against its generic Samsung 4.1.10
headers; loading that here would be an ABI mismatch.

Two changes make it exact:

1. **`CONFIG_KALLSYMS` off.** This set has no `/proc/kallsyms`, so the
   `struct module` has no `kallsyms`, `sect_attrs`, or `notes_attrs`
   fields (−24 bytes).
2. **`unwind[6]`, not `unwind[ARM_SEC_MAX]`.** The recipe's
   `struct mod_arch_specific` has eight pointers (32 B); this set's
   `struct module` has six (24 B), so the arch array is 8 bytes smaller
   than the recipe's. Patch `arch/arm/include/asm/module.h`:

   ```c
   struct mod_arch_specific {
           struct unwind_table *unwind[6];
   };
   ```

After both, the section is **`0x134` bytes**, `init` at **`0xc0`**,
`exit` at **`0x12c`** — the stock layout. The build still passes every
loader wall: exact vermagic, `.core.plt`/`.init.plt` present, no
`__aeabi_unwind_cpp_pr*`, relocations restricted to `{2, 43, 44}` (no
Thumb `MOVW`/`MOVT` 47/48).

Load test over root SSH (`context="_"`, UEP already down):

```sh
insmod research_kmem.ko enable=1 \
  dump_vas=0xc01de10c:0xc01de23c:0xc01de524:0xc069342c
```

```
research_kmem: dump@0xc01de10c rc=0: 00 30 a0 e3 00 00 53 e3 ...
research_kmem: dump@0xc01de23c rc=0: 00 30 a0 e3 00 00 53 e3 ...
research_kmem: dump@0xc01de524 rc=0: 00 30 a0 e3 00 00 53 e3 ...
research_kmem: dump@0xc069342c rc=0: 01 00 00 00 00 01 00 00 ...
```

All three UEP gate instructions are the patched `mov r3, #0`
(`00 30 a0 e3`), and `s_uepStatus` still reads `01 00 00 00`. `lsmod`
showed `research_kmem 1801 0`.

`rmmod research_kmem` also succeeded (`research_kmem mod uld` in dmesg),
so this set **can** unload modules — the earlier "cannot unload" caveat
does not apply to `T-NKMAKUC-2743.0`. Tizen's mdev leaves the
`/dev/kmem` node behind after unload; it was removed manually. The module
registers root-only (`0600`) `/dev/kmem` backed by arbitrary
`probe_kernel_read`/`probe_kernel_write` once `enable=1` is passed; the
test used init-time reads only and never opened the device. The known
`copy_to_user` read crash was not exercised.

## Home routing on Tizen 6.0 (read-only baseline, 2026-10-24)

The Home/start-screen schema differs from the Tizen 6.5 sets other write-ups target:

| Key / API | Result here |
|---|---|
| `db/first_screen/type` | **the Home-button target on this firmware** — `com.samsung.tv.csfs` by default. Setting it to a launcher app id makes Home open that launcher (verified from inside another app) |
| `db/appfw/home_appid` | **absent** (`No such file or directory`) |
| `db/appfw/startup_appid` | absent |
| `db/appfw/booting_appid_backup` | `org.tizen.tv-viewer` |
| `db/menu/smart_hub/ontvsetting/auto_start` | `0` |
| `aul_get_default_app` | **symbol absent** from `libaul.so.0` |
| `app_operation_get_default_app` | present, but `rc=-1` from uid 5001 (denied) |
| `vconftool` | present and usable as uid 901 via the SDB injection |

Consequence: guides that remap Home by writing `db/appfw/home_appid` (Tizen 6.5) do
not apply unchanged here. On 6.0 the working write is:

```sh
vconftool set -f -t string db/first_screen/type <launcher-app-id>
# rollback
vconftool set -f -t string db/first_screen/type com.samsung.tv.csfs
```

Verified on this set with `FreeMyTVio.FreeMyTV`: pressing Home inside another app
opens the launcher. Baseline and
restore values are recorded in the private tree before any write.

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
