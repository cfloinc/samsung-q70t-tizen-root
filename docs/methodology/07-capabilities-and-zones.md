# 07 — Capabilities, the launcher, and zones

## Why this matters

Most Samsung Tizen root chains assume a **signed host binary with file
capabilities** that runs your code. Those capabilities, not the user id, are what
make the bind-mount + `sdbd-tarlauncher` trick possible:

```
mount --bind fake/public.pem /usr/share/sdbd/public.pem
mount --bind fake/passwd     /etc/passwd
sdbd-tarlauncher ... --to-command=/bin/sh     → uid 0 in the fake passwd view
```

That requires `cap_sys_admin` in the process doing the mounts.

## The capability map on this firmware (measured)

| Path | `CapEff` observed | Note |
|---|---|---|
| app launched by launchpad (`aul_test launch`) | `0x0` | loader strips |
| `dotnet-launcher --standalone` from the injection | `0x0` | zone attach scrubs |
| `dotnet-launcher-inhouse --standalone` | `0x0` | same |
| kernel `call_usermodehelper` child (USB exploit) | full, `uid 0`, SMACK `_` | the only full path |

## The launcher contract (and why it still fails)

`dotnet-launcher --standalone <dll>` does run the assembly in-process
(`coreclr_execute_assembly`), which looks like the answer. It is not:

* without an app context it fails `checkAppHasPlatformPrivilege`
  (`GetLaunchedAppPackageID` empty → `package_info_create` error `-18153359`);
* forging the context (`APP_ID=<installed app id>`) fixes the package id and the
  zone manager even classifies the process `[PLATFORM]`;
* a DUID-bound **Samsung partner certificate** changes nothing;
* the scrub happens via `libsecurity-privilege-manager.so.1` and the
  `dotnetzone` attach **before** `coreclr_execute_assembly`, so managed code
  never sees the capabilities.

## The lesson for other models

Check whether `/usr/bin/dotnet` exists **and** what `getcap` says about it before
assuming archive-root applies. A TV with only runtime directories and
`dotnet-launcher` plugins is a different class from one with a capped
`/usr/bin/dotnet` host.

## Inventory your own device

```sh
getcap -r /usr/bin /usr/sbin /bin /sbin 2>/dev/null
```

`tools/capscan.sh` prints the interesting subset (`sys_admin`, `setuid`,
`sys_module`) in a compact table.
