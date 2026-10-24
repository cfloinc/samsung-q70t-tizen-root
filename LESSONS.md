# LESSONS.md — transferable lessons from rooting a 2020 Samsung Tizen TV

Distilled from the Q70T journal ([FINDINGS.md](FINDINGS.md)). If you own a
different Samsung Tizen model, these are the rules of thumb that survived
contact with the hardware.

## Developer Mode

1. It's a hidden easter egg: **Apps screen → highlight App Settings gear → 12345**.
   Not in any settings menu.
2. Number-less Smart Remote? A **USB keyboard plugged into the TV** types the code.
   SmartThings' virtual number pad is unreliable.
3. The dialog's **host IP field is not optional** — empty (`0.0.0.0`) means the
   `sdb` port never opens. Check via `http://<TV>:8001/api/v2/` →
   `device.developerIP`.
4. The in-menu reboot often doesn't arm `sdbd`. **Unplug the TV for 30 s.**
5. **DHCP-reserve both the TV and the controller.** Developer Mode stores the
   host IP forever; a changed controller IP silently breaks everything.

## Certificates & sideloading (no Samsung account needed)

6. Tizen Studio ships **public distributor certificates**; password for the
   bundled signer .p12 files is `tizenpkcs12passfordsigner`. Tizen < 7.0 devices
   accept the old signer, 7.0+ the `-new` one.
7. On macOS the CLI writes `.pwd` *paths* into `profiles.xml` but never creates
   the files — **hand-edit profiles.xml with literal passwords**.
8. `tizen package -t tpk -s <profile> -- file.tpk` re-signs an existing package:
   you can hand-zip your payload and let the CLI sign it.

## Tizen .NET apps on 2020-era TVs

9. The TV's shared framework is **.NET Core 3.0.0** (no 3.1/6.x). BCL-only
   netcoreapp3.0 code runs; don't reference TizenFX unless you need it.
10. The manifest trio that makes the app actually execute:
    `type="dotnet-inhouse"`, **`multiple="true"`**, `<dll>.deps.json` at package
    **root**. Get one wrong and the launcher silently parks or dies.
11. **`tizen run` is a debug launch** — the launcher waits for a debugger instead
    of running your assembly. Launch with `aul_test launch <appid>`.
12. Your app's **stderr lands in `/tmp/dotnet_error.<pid>.*.log`** — the most
    reliable visibility channel; dlog's ring buffer rotates in seconds.
13. `aul` launches pass the token `zaybxcwdveuftgsh` as argv[1]. Dispatch on
    argument *shape*, never on presence.
14. 2020 TVs have **no `/usr/bin/dotnet`** — managed code only runs through
    `dotnet-launcher(-inhouse)`, a launchpad plugin. Any app launchpad runs
    through it inherits its file caps: **CAP_SETGID, CAP_SYS_ADMIN,
    CAP_MAC_OVERRIDE, CAP_MAC_ADMIN** (verified via `/proc/<pid>/status`).
15. File capabilities apply on exec regardless of caller — the entire privilege
    model of these TVs is "which cap-bearing Samsung binary did you get exec'd
    from".

## SMACK (the label MAC layer)

16. sdk (`uid 901`) **cannot exec uploaded binaries** from user storage, cannot
    kill owner processes, cannot read `/proc/<pid>/exe` — SMACK rules sit above
    POSIX permissions and above `cap_kill`.
17. Scripts are fine (bash only reads them); binaries must live in a labeled
    exec context — i.e. **be an installed app**.
18. `sdb pull` is blocked on retail; **exfil via `base64 file` over the
    `/dev/tcp` callback**.
19. `/proc/<pid>/status` and `cmdline` are world-readable even when `exe`/`fd`
    are not — enough to confirm another process's capabilities.

## The sdb foothold (SVE-2025-50109)

20. Injections are **≤510 bytes**; stage longer scripts with `sdb push` and
    source them.
21. Background processes in an injection **inherit the callback fd** — close it
    with `3>&-` or the capture hangs waiting for EOF.
22. The foothold wedges after bursts; `sdb kill-server`/`start-server` + a
    connect-retry loop recovers it in ~25-40 s. Never run unbounded recursive
    greps (`grep -r /usr`) — the callback window is 25-45 s.

## Why the TV is slow (measured, not vibes)

23. Idle Q70T: **load average 14 on 4 cores**, 366 processes, swap in use. The
    biggest offenders are all telemetry/ads: `contents-recognition-service`
    (continuous screen capture + OCR, ~9% of a core forever), `acr`,
    `vision-data-recognition-service`, `pisa-service`/`adagent-service` (ads),
    `slive-daemon` (TV Plus), `org.tizen.ambientapp` (94 MB RSS). The main TV
    service trips its own `MainSmartDeadlock` watchdog — that's the stutter.
24. Root isn't the point; **the kill list is the point**. Root is just the
    mechanism to disable them persistently.

## Method (the loop that actually worked)

25. Smallest possible probe → observe → write it down → next probe. Every
    "silent" failure was eventually explained by a dlog line, an empty error
    log, or a `/proc` read. Nothing on this TV fails without leaving *some*
    evidence — the trick is knowing which of the five output channels it uses.
