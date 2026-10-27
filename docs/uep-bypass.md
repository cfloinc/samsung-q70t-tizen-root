# UEP bypass on the Q90T (verified 2026-10-25)

UEP (Unsigned Executable Prevention) is down on QN55Q90TAFXZC /
T-NKMAKUC-REL-202505100505. Unsigned binaries exec, dropbear serves
interactive root SSH on port 22, and a persistent root command agent runs on
every boot. This doc records the mechanism so the state is reproducible.

## 1. The enforcement chain (from the Samsung kernel source)

The exec path is, in order:

1. The LSM (SMACK) exec hook dispatches into the SFD subsystem, which calls
   `SfdUepVerifyFileSignature()` (`security/sfd/uep/SfdUepHookHandlers.c`).
2. That function (the whole verifier is inlined into it in the shipped
   binary) checks the mount flags (`bIsRW`), the per-inode verdict cache,
   the `:UEP` trailer and the RSA signature, and finally applies the master
   override:

   ```c
   /* SfdUepHookHandlers.c:1271 */
   if( s_uepStatus == 0 )
       result = SF_STATUS_UEP_SIGNATURE_CORRECT;
   ```

3. The dispatcher maps the verdict with `SfReturn()`: deny statuses
   (`SIGNATURE_INCORRECT`, `FILE_NOT_SIGNED`, `RESOURCE_BLOCK`) become
   `-EPERM` in enforce mode — the "Operation not permitted" a blocked exec
   produces. The hook also writes `current->uepLevel` (task field), which
   SMACK consults for secure-container label operations.

The master switch is a file-static:

```c
/* SfdUepHookHandlers.c:100 */
static Int s_uepStatus = 1;
```

It is only ever cleared (the DUID-match branch at line 472 sets it to 0 and
logs `[%s] UEP has been disabled`). No code path re-arms it to 1.

## 2. The bypass

In the shipped kernel (4.1.10, build `abuild@A0510LHG` Fri May 9 2025),
`s_uepStatus` lives at **`0xc069342c`** and the hook reads it at exactly
three places, all inside the inlined verifier function at **`0xc01de028`**:

| Site (R VA) | File offset | Original | Patched |
|---|---|---|---|
| `0xc01de10c` | `0x1d610c` | `ldr r3, [r3]` (`00 30 93 e5`) | `mov r3, #0` (`00 30 a0 e3`) |
| `0xc01de23c` | `0x1d623c` | `ldr r3, [r3]` | `mov r3, #0` |
| `0xc01de524` | `0x1d6524` | `ldr r3, [r3]` | `mov r3, #0` |

The file offsets are **payload-relative** (raw kernel): the decrypted
`uImage` section starts with a 64-byte u-boot header (magic `27 05 19 56`),
so add `0x40` when working from the section as-is — the gates sit at
`0x1d614c`/`0x1d627c`/`0x1d6564` and `s_uepStatus` at `0x68b46c` there (see
`methodology/04-kernel-recovery.md`).

Forcing the three loads to 0 makes every verification take the
`s_uepStatus == 0` branch permanently — bit-for-bit the line-1271 override
state — without ever writing the data word (so nothing that re-arms the
word matters).

The three writes are applied from the kernel-stage payload of the exploit
image at every cold boot (`samsung-tv-usb-root`, profile `nikem-uep2`) —
from the USB stick, or stickless from a loop device (`loopback-uep.md`)
— followed by a `v7_coherent_kern_range` flush of `[0xc01de10c, 0xc01de528)`.

The patch is RAM-only: it is re-applied on every firing. On boots where the
image does not fire, UEP returns (the command agent still works; it runs
scripts by content through the signed `/bin/bash`, so UEP never sees an exec).

## 3. Kernel provenance (why the offsets are trustworthy)

The offsets were first derived from a decrypted upgrade-firmware kernel
(built 2026-07-02). The TV itself runs the 2025-05-09 build. The two images
were compared directly after dumping the TV's own kernel partition
(`mmcblk0p5`, a plain uImage with a 256-byte signature block at the end of
the partition):

* total difference: **62 bytes** in 3 regions — the `Linux version` banner
  (build host `A0510LHG` vs `B3203DRG`) and two small data blobs;
* every UEP structure is **byte-identical**: verifier entry, the three gate
  loads, the P1-P4 verdict-assignment sites, and `s_uepStatus` itself
  (`01 00 00 00` at file offset `0x68b42c`).

Address space note that cost a boot loop early on: the kernel runs with
`TEXT_OFFSET 0x8000`, so runtime VA = file offset + `0xc0008000`
("R-space"). Ghidra imports at base `0xc0000000` ("G-space") — mixing the
two puts a patch 0x8000 bytes off.

## 4. Module loading is UEP-gated (and requires a UEP signature)

`kernel/module.c` (Samsung patch, `CONFIG_INSMOD_FASTBOOT`) runs
`sf_security_kernel_module_from_file()` on every module, which dispatches a
`PROT_EXEC` mmap-style operation through UEP. Two consequences:

1. An *unsigned* `.ko` is refused even when UEP is down for executables —
   the loader prints `%s: sections missing` and returns `-ENOEXEC`
   ("Invalid module format").
2. Every Samsung `.ko` on the TV carries a **UEP signature trailer**
   appended after the ELF (`\n##UEP530…`, cf. `c_uep_lead_meta` in
   `SfdUepHookHandlers.c`). Example: `acm/acmd.ko` (42698 bytes) has 534
   trailing bytes starting `0a23235545503533 30` = `\n##UEP530`.

Hand-building a loadable third-party module is therefore not possible
without Samsung's signing key. The TV's vermagic, for the record, is
`0000000, release SMP preempt mod_unload ARMv7 p2v8 ` (the
`DTV_KERNEL_VERSION` from `linux/vdlp_version.h`, not the UTS release), and
the kernel is a THUMB-2 build — ARM-mode modules are refused at relocation
("unsupported interworking call").

## 5. Operational state

* **Dropbear**: `/opt/bin/dropbearmulti` (static ARM EABI5 soft-float) with
  `-r /opt/etc/dropbear/dropbear_host_ed25519`. The host-key *paths* are
  NOT patched (the build wants `/etc/dropbear/…` on the read-only VDFS —
  pass `-r`); the `authorized_keys` path IS patched to
  `/opt/etc/dropbear/authorized_keys`. Started every boot by the persistent
  profile.d hook, best-effort (fails silently when UEP is up on stickless
  boots).
* **Command agent**: `agent.sh` (same as the q70t repo) polls
  `/opt/usr/share/tvroot/cmd/in` (0777) as root and executes jobs by
  content; output in `cmd/out`. Kill switch: `touch cmd/disabled`.
* **Exfil**: `sdb push` to `/home/owner/share/tmp/sdk_tools` + the uid-901
  injection runner; big files stream over TCP (`cat f > /dev/tcp/…`).
* Boot-chain quirks to keep in mind: script *file* loading is UEP-refused
  (`sh file` kills the caller silently — always `sh -c "$(cat file)"`);
  `/mnt` is on the read-only VDFS (`mkdir` there fails — use `/tmp`);
  storaged serializes p1/p2 mounts so the stage self-mounts p2
  (`mount -t vfat /dev/sda2 /tmp/p2`); the ~60 s kernel-stage shell window
  is the storage timeout tearing down the hijacked mount's session.

See also `q90t-field-notes.md` for the manual procedures,
`loopback-uep.md` for the stickless persistent firing, and the
stick/tooling details in `samsung-tv-usb-root`.
