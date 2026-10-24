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

## Test it yourself

`tools/uep-test.sh` writes a trivial unsigned script and reports which
invocation forms succeed. Run it as root; it distinguishes "UEP is enforcing"
from "the filesystem is the problem".
