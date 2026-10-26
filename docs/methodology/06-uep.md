# 06 — UEP: unsigned executable prevention

## Symptom

Every file you create is refused, while `/bin/sh` from the read-only image runs
fine:

```
bash: /opt/hermes/root.sh: Operation not permitted      (EPERM)
```

Diagnostics that are **red herrings**: the SUID bit, file mode, SMACK label
(`_` and `System` both fail), `noexec`/`nosuid` mount flags, remounts and bind
mounts. The decision is **signature-based**.

Run the script and the kernel tells you the real reason:

```
[uep][bash] the file is NOT signed!! : /opt/hermes/root.sh
```

## Properties measured

* Built into the kernel, not a loadable module (`/sys/module/uep` exposes only
  `uevent` and `version`).
* **Root does not lift it.** A `uid=0` process still cannot execute an unsigned
  file.
* It re-arms on reboot, and has been observed re-arming **within a session**
  after several minutes.
* It hooks **script file loading** — `sh script.sh` and `sh -s < script.sh` both
  trip it, because the shell opens the path as a script.

## The bypass that works

Pass the script as **content**, so no unsigned file is ever `execve`d:

```sh
sh -c "$(cat /opt/usr/share/tvroot/boot.sh)"
```

This is not a corruption of the check; it simply never gives UEP a file to
inspect. Both links in this project's boot chain use it.

## The kernel-level levers (build-specific)

Two other levers exist, both volatile and both requiring a kernel write primitive:

| Lever | Meaning |
|---|---|
| UEP verifier entry (this build: `0xc01de028`) | patch the gate itself to return "allowed" |
| UEP status global (this build: `0xc069342c`) | `1` = enforce, `0` = disabled |

Patching the verifier entry caused a **boot loop** on a Q90T and was not
attempted on this set. Writing the status global to `0` allowed unsigned
binaries on that set but was reported unstable. Neither is needed if you use the
content-as-argument form.

## Executable mappings are path-gated as well (measured)

The loader is not a way around it. Preloading the same library from different
paths, with `/bin/true` as the (signed) host:

| `LD_PRELOAD=` | Result |
|---|---|
| `/usr/lib/libvconf.so.0` (original, signed) | loads, no error |
| a copy in `/opt` | `failed to map segment from shared object` |
| a copy in `/tmp` (tmpfs) | same |
| a copy in `/dev/shm` (tmpfs) | same |
| a copy in `sdk_tools` | same |
| an unsigned `.so` anywhere | same |

None of those mounts is `noexec` (`/proc/mounts` shows plain `rw`), so the gate
is the **path**, not the filesystem and not the signature. Practical
consequence: `LD_PRELOAD`, `ld.so <file>`, and "copy a signed binary to writable
storage" are all closed. Managed assemblies still work because CoreCLR maps them
as **data**, not as executable segments.

## UEP is path-based, not content-based (measured)

A byte-identical copy of a **signed** system binary is still refused:

```sh
cp -a /bin/bash /opt/usr/share/tvroot/tvsh2   # same SHA-256, xattrs preserved
chmod 4755 /opt/usr/share/tvroot/tvsh2
/opt/usr/share/tvroot/tvsh2 -p -c 'id'
# bash: .../tvsh2: Operation not permitted
```

Same bytes, same signature, SUID set — blocked. So the gate is not "is this file
signed" but "is this **path** on the allowed list". Consequences:

* copying a signed binary off the rootfs never yields an executable copy;
* the SUID-root-on-`/opt` shortcut does not work here;
* script content passed as an argument (`sh -c "$(cat …)"`) works because the
  *signed* `/bin/sh` is what gets executed, and it never opens the file as a
  script.

## Taking UEP down from a loop device (verified on the Q70T)

The three gate patches can be fired from a **file** instead of a USB stick:
`losetup` the trigger image, `mount -t exfat`, then read the crafted directory.
The readdir overflows the frame, runs the payload, and parks the thread — the
hang is the success signal. See [stickless firing](../loopback-uep.md) for the
full procedure.

Verified here on `T-NKMAKUC-2743.0` with the `nikem-uep2` profile:

* three stores of `mov r3,#0` at `0xc01de10c`, `0xc01de23c`, `0xc01de524`
  (file offsets `0x1d614c`, `0x1d627c`, `0x1d6564` **including the 0x40 uImage
  header**), then `v7_coherent_kern_range` over `[0xc01de10c, 0xc01de528)`;
* after the fire, an unsigned static ARM binary executed as uid 901 — the
  first time unsigned native code ran on this set;
* with UEP down, dropbear (unsigned) serves **root SSH on :22**.

Boot integration uses four guards: a 60 s delay, an enable file
(`/opt/usr/share/tvroot/uep-enable`), a try counter decremented and synced
before each fire (three failed boots and it stops trying), and the root agent
started before the fire so a recovery channel exists.

## Test it yourself

`tools/uep-test.sh` writes a trivial unsigned script and reports which
invocation forms succeed. Run it as root; it distinguishes "UEP is enforcing"
from "the filesystem is the problem".
