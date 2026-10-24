# tvroot-app: a dev-signed .NET app that roots a Samsung Tizen TV

Companion to [FINDINGS.md](FINDINGS.md). This document covers everything
needed to build, sign, install, and run a privileged helper app on a retail
Samsung Tizen TV (tested: QN65Q70TAFXZA / Tizen 6.0) using only the **sanctioned
Developer Mode** path — no Samsung account required.

## Files

| File | Purpose |
|---|---|
| `tvroot.cs` | The app. Diagnostic mode + the archive-root exploit port (mount-namespace bind of forged verification key + passwd, exec of `sdbd-tarlauncher`) |
| `tvroot.csproj` | netcoreapp3.0, BCL-only (no TizenFX needed) |
| `foreshell.py` | Resilient SDB foothold runner (auto-recovers the TV's intermittent sdb wedges) |
| `rootparty.py` | Host-side orchestrator: stage the signed archive, listen for the root shell |
| `tizen-manifest.xml` | App manifest (the exact shape that works — see gotchas) |

## The recipe (macOS, Apple Silicon host)

### 0. One-time: certificates without a Samsung account

```bash
# author cert (local, any details)
~/tizen-studio/tools/ide/bin/tizen certificate -a q70t -p q70tpass1 \
  -c US -s California -ct "San Francisco" -o personal -u dev \
  -n yourname -e you@example.org -f q70tauthor

# signing profile with the SDK's bundled PUBLIC distributor cert
# (password below is Samsung's documented default for these files)
D=~/tizen-studio/tools/certificate-generator/certificates/distributor
~/tizen-studio/tools/ide/bin/tizen security-profiles add -n q70t \
  -a ~/tizen-studio-data/keystore/author/q70tauthor.p12 -p q70tpass1 \
  -d "$D/tizen-distributor-signer.p12" -dp tizenpkcs12passfordsigner \
  -dc "$D/tizen-distributor-ca.cer"
~/tizen-studio/tools/ide/bin/tizen cli-config "profiles.path=$HOME/tizen-studio-data/profile/profiles.xml"
```

**macOS gotcha:** `security-profiles add` writes `.pwd` file *paths* into
`profiles.xml` but never creates the files. Edit
`~/tizen-studio-data/profile/profiles.xml` and replace the two
`password="...pwd"` values with the literal passwords
(`q70tpass1` / `tizenpkcs12passfordsigner`).

Which distributor signer: Tizen **< 7.0** TVs want the old
`tizen-distributor-signer.p12`; 7.0+ want `-new.p12`.

### 1. Build (netcoreapp3.0 — matches the TV's shared framework)

The TV's shared framework tops out at **Microsoft.NETCore.App 3.0.0** — no 3.1, no 6.x.

```bash
rm -rf build && mkdir -p build/obj && cp tvroot.cs tvroot.csproj build/
cd build
dotnet build tvroot.csproj -c Release -o out -p:BaseIntermediateOutputPath=obj/
```

`-p:BaseIntermediateOutputPath=obj/` (fresh dir) dodges the NETSDK1005
shared-obj/TFM clash you'll hit replaying the upstream Makefile.

### 2. Package layout (all of these are load-bearing)

```
tvroot.tpk (zip):
  tizen-manifest.xml
  bin/tvroot.dll
  bin/tvroot.runtimeconfig.json        # must request Microsoft.NETCore.App 3.0.0
  tvroot.deps.json                     # <AssemblyName>.deps.json at package ROOT —
                                       # the launcher needs it there, not just bin/
  res/tvroot.png                       # any png; manifest <icon> must resolve
```

Manifest requirements discovered by trial and error:

```xml
<ui-application appid="org.tvroot3.q70t" exec="tvroot.dll"
    launch_mode="single" multiple="true" nodisplay="true" taskmanage="false"
    type="dotnet-inhouse">
```

- `multiple="true"` is **the difference between the app running and not running**.
  With it, the launcher takes `realMain(98) > Run in standalone mode` and calls
  `execute assembly`. With `multiple="false"` every launch after the first routes
  into a parked "host" instance and *nothing executes*.
- `type="dotnet"` never dispatched at all; `dotnet-inhouse` works (and its
  `HasPlatformPrivilege` check is only fatal on the host/pipe path).
- `api-version="4"` + `<profile name="tv" />` matched the TV's own apps.

### 3. Sign + install + launch

```bash
zip -r tvroot.tpk tizen-manifest.xml bin res tvroot.deps.json
tizen package -t tpk -s q70t -- $PWD/tvroot.tpk     # re-signs the package file
tizen install -s <TV>:26101 -n tvroot.tpk
```

Launching — **do not use `tizen run`**: it is a *debug* launch, the launcher parks
at `handleDebugPipe` / "Process in Host" and never executes the assembly. Use a
normal launch instead, from the TV shell:

```bash
/usr/bin/aul_test launch <appid>
```

### 4. Seeing what the app did

- **stderr is redirected by the launcher to `/tmp/dotnet_error.<pid>.*.log`** —
  `Console.Error.WriteLine` in the app is the reliable output channel.
- dlog: start a **streaming** capture *before* launching (the 2 MB ring rotates in
  seconds on this box):
  `nohup /usr/bin/dlogutil > /home/owner/share/tmp/sdk_tools/dlog.txt 2>&1 < /dev/null 3>&- &`
  (the trailing `3>&-` stops the background process from holding the sdb callback
  socket open, which otherwise hangs the injection session).
- The app also reports over TCP to the controller (`Report()` in tvroot.cs).
- `aul` launches pass the token `zaybxcwdveuftgsh` as `argv[1]` — never treat
  argv presence as "package mode" (v0.0.9 learned this the hard way).

### 5. Confirming the privilege you just got

```bash
# find the launcher pid running your app, then:
grep -E '^(Name|Uid|CapEff)' /proc/<pid>/status
# CapEff: 0000000300200040  = CAP_SETGID | CAP_SYS_ADMIN | CAP_MAC_OVERRIDE | CAP_MAC_ADMIN
```

That capability set is what `dotnet-launcher-inhouse` carries as file caps and
what our app inherits — enough for `unshare(CLONE_NEWNS)`, bind mounts over
system files in a private namespace, and driving `sdbd-tarlauncher`
(`cap_setuid,cap_setuid`) to run our signed payload **as root**.

## Root flow (v0.0.10, in progress)

1. `rootparty.py` (host): generate an RSA keypair; write a forged `passwd`
   (`owner:x:0:0:...`) and `public.pem`; build `launch.sh` (a bash `/dev/tcp`
   root shell with a token check); tar+sign; push everything to
   `/home/owner/share/tmp/sdk_tools/archive-root-<hex16>/` +
   `on-demand/archive-root-<hex16>.tar.gz{,.signature}` via `sdb push`.
2. `aul_test launch org.tvroot3.q70t` — the app scans for the newest
   `archive-root-*` dir, bind-mounts `public.pem` over
   `/usr/share/sdbd/public.pem` and the forged `passwd` over `/etc/passwd` inside
   a private mount namespace, then execs
   `sdbd-tarlauncher --package_name <pkg> -xzf .../on-demand/<pkg>.tar.gz --to-command=/bin/sh`.
3. `sdbd-tarlauncher` (setuid via file caps, resolving `owner` → uid 0 through the
   forged passwd) verifies the archive against *our* mounted key and pipes
   `launch.sh` into `/bin/sh` **as root**.
4. `launch.sh` connects back to the controller over `/dev/tcp` and serves a root
   shell. `id` → `uid=0(root)`.
