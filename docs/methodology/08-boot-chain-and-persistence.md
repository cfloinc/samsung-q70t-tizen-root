# 08 — Boot chain and persistence

## The problem

`/` and `/etc` are **read-only vdfs**, even for root. You cannot add a unit, edit
a drop-in, or `systemctl mask` persistently. Most write-ups stop here and call
persistence impossible.

## The path that exists

On this firmware there is a root-run, writable-adjacent code path:

```
tizen-system-env.service            enabled, WantedBy=basic.target
                                    DefaultDependencies=no, Before=basic.target
  ExecStart=/usr/bin/env -i sh -c 'source /etc/profile; …'
        └─ /etc/profile
              └─ for i in /etc/profile.d/*.sh; do . "$i"; done
                    └─ /etc/profile.d/bash_prompt_custom.sh     776 bytes
```

It is active ~2 s after boot and sources those scripts **as root**. The vendor
script there is prompt/alias sugar wrapped in `if [ "$PS1" ]`, so it is inert
during a boot source — which makes it the ideal carrier: replace it in place,
same byte length, and the hook runs as root on every boot.

## The patch

* Same-size replacement (776 bytes here): no filesystem metadata changes, no
  neighbouring file blocks touched.
* The hook is backgrounded and waits up to 120 s for `/opt` to appear.
* Locate the file on the raw device by grepping for a unique marker; verify the
  bytes at that offset hash to **your** vendor original before writing.
* Keep a byte-exact backup of the containing blocks and a rollback script.

Observed result on a stick-free power cycle:

```
=== tvroot boot entry uptime=0.74s uid=0 ctx=_
--- masks installed at uptime=0s
--- delayed stop pass done at uptime=31s
```

## The UEP requirement

The hook must invoke its payloads **by content**, never by path
(see [06 — UEP](06-uep.md)):

```sh
sh -c "$(cat /opt/usr/share/tvroot/boot.sh)"
```

Both links (profile.d → `boot.sh`, `boot.sh` → `debloat.sh`) do this. Sourcing
(`. file`) also worked in testing, but content-as-argument is the documented,
reliable form.

## The UEP fire is opt-in (2026-11-09)

The loopback UEP trigger parks a user task in D state. On the Q70T that task
survives in `schedule_timeout_uninterruptible`, cannot be frozen, and makes
`losetup -d` return 0 without detaching the loop. The system standby freezer
deadline is 20 s; a transition can therefore fail and restart the TV. The
default boot hook now leaves UEP up: it still applies the debloat masks,
starts the root agent, and mounts the hosts sinkhole. Use
[`persistent-hook/fire-uep.sh`](../../persistent-hook/fire-uep.sh) when root
SSH or unsigned binaries are needed, and reboot afterwards to clear the parked
task. Re-enabling boot-time fire is a rename of `uep-enable.off` back to
`uep-enable`, with the standby caveat. See
[loopback-uep.md](../loopback-uep.md#standby-and-freezer).

The try counter is two-phase: the attempt marker is written immediately before
the fire, not before the 60 s wait; a previous attempt without a success marker
consumes one try at the next boot.

## After a raw write

```
sync
echo 3 > /proc/sys/vm/drop_caches
sha256sum /etc/profile.d/<script>
```

Without dropping caches, the filesystem serves the old page and the write looks
like it failed.

## Limits

* A **firmware update** rewrites `/etc`. The patch and the block offset must be
  re-derived afterwards.
* This is a *persistence* mechanism for privileged actions, not a root backdoor
  by itself — but the same hook could re-arm root.
