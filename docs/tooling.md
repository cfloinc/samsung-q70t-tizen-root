# Tooling, mapped to this project

| Tool | Kind | Applies here? | Use it for |
|---|---|---|---|
| [Ghidra](https://github.com/NationalSecurityAgency/ghidra) | disassembler/decompiler | ✅ | ARM32 ELF: `dotnet-launcher`, `sdbd-tarlauncher`, kernel image (raw, base `0xC0000000`) |
| [ILSpy](https://github.com/icsharpcode/ILSpy) | .NET decompiler | ✅ | Tizen managed payloads, archive-root agent, our helpers |
| `arm-none-eabi-objdump` / `readelf` | binutils | ✅ | fast triage; symbol tables (the launcher is **not stripped**) |
| `sdb` | Samsung debug bridge | ✅ | foothold, file push/pull, install |
| `dlogutil` | device logger | ✅ | launcher/zone decisions (`Package ID`, `[PLATFORM]`, UEP messages) |
| [REA](https://github.com/morluto/rea) | agentic RE workflows | ⚠️ optional, not installed here | feature tracing, version diffing, reconstruction; pin a version and sandbox it — an agent with shell access reading untrusted binaries is a prompt-injection risk |
| [JADX](https://github.com/skylot/jadx) | APK → Java | ❌ | Android only; Tizen apps are `.wgt` (web) or `.tpk` (native/.NET) |
| [Frida](https://github.com/frida/frida) | dynamic instrumentation | ❌ | no supported injector on retail Tizen; use the root shell + `dlogutil` |
| [x64dbg](https://github.com/x64dbg/x64dbg) | Windows debugger | ❌ | Windows only |
| `gdb` | debugger | ❌ | not shipped on the TV; no ptrace path from an app |

## This repo's tools

| Tool | What it does |
|---|---|
| `tools/foreshell.py` | SDB injection with capture + wedge recovery. Reads from `TV_IP`. |
| `tools/tvshell_server.py` | Persistent TCP server for the exploit's root shell; 15 s keepalive against Wi-Fi power-save. |
| `tools/uep-test.sh` | Classifies UEP empirically: exec / `sh file` / `sh -s` / `sh -c "$(cat)"` / source. |
| `tools/capscan.sh` | Capability-bearing binaries, filtered to the ones that matter. |
| `tools/tee-client/` | TrustZone client that decrypts the firmware container. |
| `persistent-hook/build-patch.py` | Same-size patcher for the reader's own boot script. |

## Quick triage recipe for a new binary

```sh
file <bin>                       # arch, static/dynamic, stripped?
readelf -h -s <bin> | head -40   # entry, symbols
strings -n 6 <bin> | head -80    # contracts, paths, messages
arm-none-eabi-objdump -d <bin> > /tmp/x.asm
```

Only then open Ghidra. In this project, `strings` found the launcher's
`--standalone` contract and the UEP message before any disassembly was needed.

## For the kernel image

It is raw and uncompressed. In Ghidra, import as a raw binary with base
**`0xC0000000`** (no KASLR). Use the TOC's CRC to confirm the image, and the
banner string against `/proc/version` to confirm the build.
