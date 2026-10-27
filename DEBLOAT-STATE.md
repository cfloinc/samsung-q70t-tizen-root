# Q70T debloat state — what is deployed, how to undo it

**Status 2026-10-24: PERSISTENT. The TV debloats itself at boot+0.74 s, with no
USB stick and no computer.** Verified on a stick-free power cycle:
`/run/.tvroot-hook` and `/run/.tvroot-debloat` both present, `debloat.log`
written ~21 s after power-on, six `/run` masks, ACR trio inactive.

Verified on a **cold boot, 2026-10-26** (`uptime=0 min`), with no manual steps:

```
v6 masks installed at uptime=0s (13 units)
root agent started (pid 527)
hosts sinkhole active
masks 13 · background-update / airplay / hbbtv / ambient-ua-agent: inactive
db/first_screen/type = FreeMyTVio.FreeMyTV

post-reboot root job:
uid=0(root) gid=0(root) context="_"
```

Earlier, verified on **two consecutive stick-free boots**:
`=== tvroot boot entry uptime=0.74s uid=0 ctx=_` and
`=== tvroot boot entry uptime=0.73s uid=0 ctx=_`, with `/opt/media` empty and no
`/dev/sd*` present.

See [WRITEUP.md](WRITEUP.md) for the full story and
[FINDINGS.md](FINDINGS.md) §16–§21 for the measurements.

## What runs at every boot

```
tizen-system-env.service            (enabled, WantedBy=basic.target)
 └─ /usr/bin/env -i sh -c 'source /etc/profile'
     └─ /etc/profile → sources /etc/profile.d/*.sh
         └─ bash_prompt_custom.sh   ← PATCHED IN PLACE (776 B, same size)
             └─ sh -c "$(cat /opt/usr/share/tvroot/boot.sh)"     ← UEP bypass
                 └─ sh -c "$(cat /opt/usr/share/tvroot/debloat.sh)"
                     ├─ 6 /run/systemd/system/<unit> → /dev/null masks
                     ├─ systemctl daemon-reload
                     └─ +31 s: systemctl --no-block stop <unit> … + census
```

The UEP point matters: **never** `sh /path/script.sh` on this TV — Tizen hooks
script *file loading* and refuses unsigned files. Always
`sh -c "$(cat /path/script.sh)"`.

## Deployed changes

| Change | Mechanism | Persists? | Restore |
|---|---|---|---|
| `bash_prompt_custom.sh` 776-byte patch | raw write, `/dev/mmcblk0p19` block **3150336** (byte 1612972032) | ✅ | `sh /opt/usr/share/tvroot/backup/rollback.sh` |
| `boot.sh`, `debloat.sh` | files on writable `/opt` | ✅ | `rm /opt/usr/share/tvroot/{boot,debloat}.sh` |
| **13 runtime masks** (v2): `acr.service`, `acr.path`, `contents-recognition-service.service`, `vision-data-recognition-service.service`, `vdsystem-update-manager.service`, `org.tizen.remotepc.service`, **`background-update.service`**, **`background-update.path`**, **`bootmode-system-update.service`**, **`com.samsung.tv.airplay-service.service`**, **`com.samsung.tv.airplay-service-2.service`**, **`hbbtv-service.service`**, **`ambient-ua-agent.service`** | `/run/systemd/system/<unit>` → `/dev/null`, re-created by `debloat.sh` v2 | ✅ via boot hook | remove from `debloat.sh`, or `rm` the symlinks for the current boot |
| Package deactivation: `org.tizen.ambientapp`, `com.samsung.tv.airplay-app`, `org.tizen.hbbtv` | `pkgcmd -D -t app -n <pkg> --uid 5001` (also re-applied by the boot hook) | ✅ | `pkgcmd -A -t app -n <pkg> --uid 5001` |
| Marker `/opt/usr/share/systemd/system/pisa-service` | vendor `ConditionPathExists` guard (gates **pisa + adagent**) | ✅ | delete the file |
| Marker `/opt/usr/share/systemd/system/slive-provider-daemon` | same pattern (TV Plus backend) | ✅ | delete the file |
| **Root command agent** (`agent.sh`, started by the boot hook) | polls `/opt/usr/share/tvroot/cmd/in/*.sh`, runs them as root via `bash -c "$(cat …)"` | ✅ | `touch cmd/disabled` (immediate) or remove `agent.sh` + reboot |
| **`/etc/hosts` sinkhole** (v6) | boot hook bind-mounts `/opt/usr/share/tvroot/hosts.block` over `/etc/hosts` — ad/ACR domains resolve to `0.0.0.0` even if DNS is bypassed | ✅ via boot hook | `umount /etc/hosts` (this boot) or remove the mount block from `debloat.sh` |
| **Home/start-screen target** → `FreeMyTVio.FreeMyTV` | `vconftool set -f -t string db/first_screen/type FreeMyTVio.FreeMyTV` (vconf write) | ✅ **verified: Home opens the launcher from inside another app** | `vconftool set -f -t string db/first_screen/type com.samsung.tv.csfs` |
| **UEP down at boot** (loopback-fired `nikem-uep2`) | `losetup` + `mount -t exfat` + `readdir` on `/opt/usr/share/tvroot/uep2.img`, 60 s after boot | ✅ RAM-only, re-applied per boot | `rm /opt/usr/share/tvroot/uep-enable` (next boot); try counter stops after 3 failures |
| **Root SSH on :22** (dropbear, unsigned) | started by the boot hook once UEP is down; ed25519 host key + `authorized_keys` in `/opt/etc/dropbear` | ✅ | `kill $(cat /run/dropbear.pid)`; remove the start block from `debloat.sh` |
| TV DNS → AdGuard Home | TV network settings | ✅ | TV settings → DNS auto |
| `Free My TV` launcher | signed web app | ✅ | uninstall |

## Settings-level steps (no root — do these too)

Root removes the *processes*; the consent switches remove the *permission*. Both
matter, and these are reversible in the UI.

On a 2019–2020 Samsung (this set's menu path), from
[cleanyour.tv/not-android](https://cleanyour.tv/not-android#samsung), which cites
the IMC 2024 study:

**Settings → Support → Terms & Privacy → Privacy Choices**

| Setting | Value |
|---|---|
| Viewing Information Services | **Off** (this is ACR — the big one) |
| Interest-Based Advertisements | Off |
| Customization Service | Off |
| Improve personalized ads | Off |
| Get news and special offers | Off |
| Do not track | **On** |

Also: **Reset PSID** (new ad id), Bixby **Voice Wake-Up → Off**, and the hardware
**mic switch** if your panel has one. After a firmware update, check them again —
owners report some switching back.

## Why the update services are masked (v2)

`background-update.service` was **active**. An OTA rewrites `/etc`, which removes
the 776-byte `profile.d` patch and therefore the boot hook. Masking the update
units is persistence protection, not debloat. Update popups are unaffected by
the mask; if they appear, use the notification settings route.

## Hashes

```
vendor  effe97f8ec948a15962fc8a1b85a4e1e446352b8c5caae703e1ed0684425e33c
v1      ca30fa2bb89596b7e5db45185bb265487165072745a5455d7c0d2138de9d3154  (exec form — blocked by UEP)
v2      6c5a2ceb62586047…  (current: UEP-safe in both links)
backup  7d0f116e201ba20692cab9e34d52231fb0dbceddcf51aa2ceb2c8b2a2346b98f
        /opt/usr/share/tvroot/backup/rootfs-p19-blk3150336-2.bin
```

After a raw write, `echo 3 > /proc/sys/vm/drop_caches` before trusting a
filesystem-level `sha256sum` — vdfs caches the old page.

## Useful commands (root shell)

```sh
sh -c "$(cat /opt/usr/share/tvroot/debloat.sh)"   # run the debloat now
cat /opt/usr/share/tvroot/debloat.log             # what the boot hook did
ls -l /run/systemd/system/ | grep dev/null        # current masks
systemctl --no-block stop <unit>                  # plain stop can hang
sh /opt/usr/share/tvroot/backup/rollback.sh       # restore vendor profile.d
```

## Measured effect

* Free RAM: ~213 MB (before) → ~830 MB after the ACR trio + ads are gone.
* `acr`, `contents-recognition-service`, `vision-data-recognition-service`,
  `vdsystem-update-manager`: inactive. `org.tizen.remotepc`: deactivating.
* Load average is **not** a performance signal on this set: ~10 processes sit in
  D-state on absent tuner hardware, so idle load stays ~11–15 regardless.

## Not done / deliberately left

* No package uninstalls. `pkgcmd -D` (deactivate) was available but the boot
  hook covers the CPU cost; leftovers can be deactivated later with
  `pkgcmd -D -t app -n <pkg> --uid 5001`.
* `/usr/apps` is on the read-only rootfs and cannot be removed.
* Samsung's own ACR opt-out (**Viewing Information Services**) should also be
  off in the TV privacy settings — belt and braces.
