# persistent-hook — make the debloat run at every boot

The boot chain on this firmware:

```
tizen-system-env.service                      (enabled, WantedBy=basic.target)
 └─ /usr/bin/env -i sh -c 'source /etc/profile'
     └─ /etc/profile → for i in /etc/profile.d/*.sh; do . "$i"; done
         └─ bash_prompt_custom.sh             ← 776 bytes, prompt/alias sugar
```

`tizen-system-env.service` runs ~2 s after boot and **sources** the profile.d
scripts as root. The vendor script is inert during that source (it is wrapped in
`if [ "$PS1" ]`), which makes it a perfect hook carrier: replace it in place,
same byte length, and the hook runs as root on every boot.

## Files

| File | Purpose |
|---|---|
| `hook-fragment.sh` | The hook itself (once per boot, backgrounded, waits for `/opt`). |
| `build-patch.py` | Builds a **same-size** patched copy of *your own* vendor script, compacting only if needed. |
| `apply-persistent-hook.sh` | Locates the file on the raw eMMC device, verifies it against the vendor hash, backs up the exact blocks, writes the patch, verifies the readback. |
| `boot.sh` | Runs once per boot: calls `debloat.sh` **by content** (UEP-safe). |
| `debloat.sh` | The `/run/systemd/system` masks + delayed `--no-block` stop pass + census + the opt-in UEP fire (v9 two-phase try counter). |
| `fire-uep.sh` | Manual, on-demand UEP-down + dropbear. Run it by content as root; reboot afterwards for standby. |
| `rollback.sh` | Restores the vendor blocks from the backup. |

## On-demand root: the command agent (`agent.sh`)

The boot hook can also start a small **root command agent**, which turns "root at
boot" into "root whenever you ask" without the USB stick.

```sh
# as sdk (uid 901), any time after boot:
printf 'id\ncat /proc/self/attr/current\n' > /opt/usr/share/tvroot/cmd/in/job1.sh
sleep 2
cat /opt/usr/share/tvroot/cmd/out/job1.txt
# uid=0(root) ...
```

How it works: `agent.sh` runs as root, polls `cmd/in/`, and executes each `*.sh`
with `bash -c "$(cat file)"` (content, not exec — so UEP is not involved). Output
goes to `cmd/out/<name>.txt`, then the job file is deleted. Each job is also
archived under `cmd/archive/` and logged to `/opt/usr/share/tvroot/rootcmd.log`.

**This is a deliberate privilege boundary change.** `cmd` and `cmd/in` are
`1777` (sticky), and the agent only runs regular, non-symlink job files owned by
the sdk UID (901 by default). Anything at sdk level can execute commands as
root; files from other UIDs are ignored. On a single-user TV on a trusted LAN
that is usually the point; do not enable it on a shared or exposed network.

Kill switch, without a reboot:

```sh
touch /opt/usr/share/tvroot/cmd/disabled     # agent idles until removed
```

Or remove `agent.sh` and reboot; the boot hook then logs "root agent not installed".

## The UEP rule (read this twice)

Tizen's UEP gate hooks **script file loading**. Any of these is refused:

```sh
sh /opt/usr/share/tvroot/boot.sh
sh -s < /opt/usr/share/tvroot/boot.sh
/opt/usr/share/tvroot/boot.sh
```

This is not:

```sh
sh -c "$(cat /opt/usr/share/tvroot/boot.sh)"
```

Nothing unsigned is ever `execve`d, so there is nothing for UEP to check. Both
links in this kit (profile.d → `boot.sh`, `boot.sh` → `debloat.sh`) use it.

## UEP fire is opt-in (read this if you care about standby)

The loopback UEP trigger parks a user task in D state. On the Q70T that task
cannot be frozen, `kill -9` leaves the signal pending, and `losetup -d` returns
0 without detaching the loop. The system standby freezer deadline is 20 s, so a
standby transition can restart the TV. The default is therefore:

* `/opt/usr/share/tvroot/uep-enable` **absent** (the deployed file is
  `uep-enable.off`);
* no boot-time UEP fire;
* debloat masks, hosts sinkhole, and the root agent still run;
* UEP stays up, so no dropbear and no unsigned binaries.

When you need root SSH or unsigned binaries, run the manual helper **as root**
by content:

```sh
sh -c "$(cat /opt/usr/share/tvroot/fire-uep.sh)"
```

The simplest way is a job through the root agent:

```sh
printf 'sh -c "$(cat /opt/usr/share/tvroot/fire-uep.sh)"\n' \
  > /opt/usr/share/tvroot/cmd/in/fire-uep.sh
sleep 3
cat /opt/usr/share/tvroot/cmd/out/fire-uep.txt
cat /opt/usr/share/tvroot/uep-loop.log
```

It fires immediately and starts dropbear. **Reboot afterwards** if you need
standby: the parked readdir task is only cleared by a reboot. Re-enabling
boot-time fire is a rename of `uep-enable.off` back to `uep-enable`, with the
standby caveat. See [loopback-uep.md](../docs/loopback-uep.md#standby-and-freezer).

The v9 try counter is two-phase: the attempt marker is written immediately
before the fire, not before the 60 s wait. A previous attempt without a success
marker consumes one try at the next boot; a power cycle during the 60 s wait
does not.

## Procedure

1. Copy `boot.sh` and `debloat.sh` to `/opt/usr/share/tvroot/` (writable,
   survives reboot), `chmod 755`.
2. On the control host, build the same-size patch from **your** vendor file:

   ```sh
   ./build-patch.py vendor-bash_prompt_custom.sh hook-patched.bin
   ```

3. Push `hook-patched.bin` to the TV (e.g. `/tmp/`), then run
   `apply-persistent-hook.sh` **as root**. It finds the file by grepping the raw
   block device for a unique marker, verifies the 776 bytes there against the
   vendor hash, backs up the blocks, writes, and verifies.
4. `sync; echo 3 > /proc/sys/vm/drop_caches`, then confirm the filesystem hash
   matches the new file.
5. Pull the USB stick, power cycle, and check:

   ```sh
   cat /opt/usr/share/tvroot/debloat.log     # wants: uptime=<1s
   ls -l /run/systemd/system/ | grep dev/null
   ```

## Undo

```sh
sh /opt/usr/share/tvroot/backup/rollback.sh
rm -f /opt/usr/share/tvroot/boot.sh /opt/usr/share/tvroot/debloat.sh
# /run masks are tmpfs and vanish at the next boot
```

## Safety notes

* The patch is **exactly the same size** as the vendor file, so no filesystem
  metadata and no other file's blocks are touched.
* The apply script refuses to write unless the bytes at the target offset hash
  to the vendor original, and it keeps a byte-exact backup.
* Optional `TVROOT_WINDOW_SHA` pins the whole containing window (all touched
  512-byte blocks) before any write; rollback re-checks the recorded window
  hash.
* Worst case is a broken prompt script; `rollback.sh` restores it exactly.
* A firmware **update** rewrites `/etc` and removes the hook — the block offset
  must be re-derived afterwards.
