# Q90T field notes — 2026-10-25

App-booting eligibility, the standby/wake wedge, and CleanFrame-first, all
reverse-engineered and verified on the living room QN55Q90TAFXZC
(T-NKMAKUC-REL-202505100505, Tizen 5.5.0, armv7l). Companion doc:
`docs/loopback-uep.md` (the stickless/persistent loopback UEP exploit,
TV-agnostic).

## RPAC is not what it looks like

Samsung's `#RPAC=` headers in systemd units are attestation metadata, not
ciphering. The relevant binaries (`app-boot-manager`, `tvctx-manager`,
`libapp-context-manager-common.so`, `deviced`) are ordinary stripped ELFs with
**plaintext strings** — `grep -a` works. (The TV's `strings` binary is
missing; that once made binaries look encrypted.)

## App-booting eligibility (the gate that ate three experiments)

Boot decision chain, from config + decompilation:

- `tvctx-manager` runs from `/etc/tvctx-manager/appctx-config.json`. Wake/boot
  events: `power.app` → run `last:app` (in `system:app_booting_mode`),
  `power.livetv` → launch `last:source`.
- `libapp-context-manager-common.so::util_get_appbooting_supported_webapp_byappid`
  gates **web apps** via pkgmgr metadata *equality* checks
  (`pkgmgrinfo_appinfo_get_metadata_value`; absent key = fail):
  - `http://samsung.com/tv/metadata/disable.appbooting` must NOT equal `"true"`
  - `http://samsung.com/tv/metadata/transparent.support` must NOT equal `"true"`
  - `http://samsung.com/tv/metadata/multitasking.support` /
    `http://samsung.com/tv/metadata/transparent.opaque.support` combo
  - plus system-info flag `SYSTEM_INFO_KEY_APP_BOOTING_SUPPORT` (0x11e)
- Native apps take a single check: `appbootingsupport` = `"true"`.
- An eligible foreground app makes tvctx's recorder ("app booting appid
  updated by PIG") write `memory/volt/last_service` = `app-source`,
  `memory/volt/last_service_app_booting` = appid, and **both**
  `memory/appfw/booting_appid` + `db/appfw/booting_appid_backup`.
- Therefore those `booting_appid*` keys are **outputs** of the boot flow, not
  inputs: writing them by hand does nothing for an ineligible app, and the TV
  rewrites them with what it actually booted. (Three wall-cycle experiments
  confirmed this the hard way.)

Fix for a WGT launcher — add to `config.xml`:

```xml
<tizen:metadata key="http://samsung.com/tv/metadata/appbootingsupport" value="true"/>
<tizen:metadata key="http://samsung.com/tv/metadata/multitasking.support" value="true"/>
<tizen:metadata key="http://samsung.com/tv/metadata/disable.appbooting" value="false"/>
```

With those installed, graceful power-off while the launcher is foreground
saves it (PIG), and the next **cold boot** brings it up first. Verified
visually by the owner.

## The standby/wake wedge

Observed at standby (deviced log):

    power_suspend : 1, instant_on : 1, save_error_log : -1,
    request_cold_poweroff(), interval(60)

- Wakes attempted across the post-standby poweroff boundary repeatedly landed
  the TV in a half-state: `memory/sysman/power_state = 6`, SSH alive, display
  dark, remote dead. Only a mains cycle recovers. Quick wakes inside the
  window worked — the intermittency across tests is consistent with this race.
- Tests where `db/menu/smart_hub/ontvsetting/auto_start = 1` (`fs_autostart`,
  which launches the first-screen app below the booting app at wake) was
  active also wedged; whether that path or something else was causal is
  **unresolved** — the correlation is recorded, the mechanism is not claimed.
- Current state (owner-verified): standby → full poweroff; power-on = clean
  cold boot the remote always wins. `db/boot/instant_on` is currently 0
  (set 2026-10-25). Whether that setting, the stick's retirement, or both
  explain the change is unresolved.

## USB stick hazards (now retired)

- The crafted p1 mount hangs I/O on that filesystem; with it mounted, `df`
  (mount enumeration) hangs system-wide.
- `echo 2-1 > /sys/bus/usb/drivers/usb/unbind` **hangs the kernel USB path**
  and wedges the VFS; `umount -l /opt/media/USBDriveA1` detaches a wedged
  mount instantly and is the recovery move. Never unbind a mounted device.
- Samsung's storage stack mounts p1/p2 serially (~60s apart) as
  `/opt/media/USBDriveA{1,2}`; the wake path's USB re-mount attempt against
  the parked exFAT state is a plausible contributor to the wedge — moot now.
- The stick is retired by the loopback UEP exploit — see the companion doc
  for the boot-time firing and the stickless-boot verification.

## Signing notes (CleanFrame repo side)

- The Tizen CLI signs with **no password and no prompts** when run as a plain
  subprocess; under a pty it reports success while writing an unsigned package.
- `tizen cli-config default.profiles.path=…` prints success but is ignored on
  this CLI version — the profile store is fixed at
  `~/tizen-studio-data/profile/profiles.xml`. The Q90T profile is `q90t-sdk`
  (author.p12 + tizen-distributor-signer.p12).
- On-TV install path: `ssh root@TV 'pkgcmd -i -t wgt -p <path> -n <pkgid>'`
  (sdb's `vd_appinstall` hangs; a wedged pkgmgr needs a reboot and can trip
  the watchdog).

## Open items

- Instant-wake-style resume (if the full-poweroff standby is ever traded back
  for fast wake): an agent-based wake hook watching
  `memory/sysman/power_state` and launching the launcher ~5s after wake,
  avoiding the fs_autostart path.
