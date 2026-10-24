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
| `debloat.sh` | The `/run/systemd/system` masks + delayed `--no-block` stop pass + census. |
| `rollback.sh` | Restores the vendor blocks from the backup. |

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
* Worst case is a broken prompt script; `rollback.sh` restores it exactly.
* A firmware **update** rewrites `/etc` and removes the hook — the block offset
  must be re-derived afterwards.
