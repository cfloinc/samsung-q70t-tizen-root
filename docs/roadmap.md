# Learning roadmap — reverse engineering for this project

This is a curated path, adapted to the artefacts in this repository. It borrows
heavily from the **REA** (Reverse Engineering Anything) material and the
`JoasASantos/REA-Prompts` collection; links are collected at the bottom. The
point is not to read everything — it is to be able to answer, for a TV you own:

> what does this binary do, what does this firmware contain, and why does this
> protection reject my file?

## Stage 0 — tooling you actually need here

| Tool | Why |
|---|---|
| **Ghidra** | ARM32 ELF disassembly/decompilation. The TV's launcher is an unstripped ARM ELF — a good first target. |
| **ILSpy** | .NET assemblies. Tizen TVs run managed code; the archive-root payloads and our own helpers are IL. |
| **objdump / readelf** | Fast triage before opening a GUI. What this repo used for the launcher. |
| **Our tools** | `foreshell.py`, `tvshell_server.py`, `uep-test.sh`, `capscan.sh`, `tee-client/`. |
| **REA (optional)** | Agentic RE workflows (feature tracing, version diffing, crash tracing). Useful later; not required for any step below. |

Deliberately **not** applicable to Tizen TVs: JADX/Frida/x64dbg (Android,
dynamic instrumentation, Windows). A Tizen TV is Linux/ARMv7 with its own
sandboxing — the on-device shell and `dlogutil` replace Frida here.

## Stage 1 — static basics on real artefacts

1. `file`, `readelf -h`, `readelf -s` on `dotnet-launcher-inhouse` (ARM, EABI5,
   not stripped). Note the symbols; they tell you more than the disassembly.
2. `strings` first. On this project it revealed the launcher's contract
   (`--standalone`, `coreclr_execute_assembly`, `Run it standalone`) in seconds.
3. Ghidra: import the ELF, let it find `main`, then follow the string xrefs.
4. Repeat on a small managed payload with ILSpy.

**Exercise:** find where the launcher decides to strip capabilities. (Answer:
it is not in the launcher — it is in the zone attach, via
`libsecurity-privilege-manager.so`; see [07](methodology/07-capabilities-and-zones.md).)

## Stage 2 — managed code

Tizen .NET payloads are ordinary assemblies. ILSpy on:

* `SamsungTvRootAgent.dll` — the archive-root agent protocol,
* our `tee.dll` — the TrustZone client,
* anything you build for a target.

**Exercise:** trace `getuid()` to the P/Invoke and explain why the reported uid
is `0` in the archive-root case but the SMACK label is still `User`.

## Stage 3 — firmware

Work through [02](methodology/02-firmware-container.md),
[03](methodology/03-tee-decrypt.md), [04](methodology/04-kernel-recovery.md).
This is the part most guides do not cover: an encrypted update container and a
TrustZone application that will decrypt it for a local app.

## Stage 4 — dynamic, on the device

There is no ptrace-based debugger on a retail TV. The equivalents are:

* the SDB injection + capture channel ([01](methodology/01-foothold.md)),
* a root shell over TCP ([10](methodology/10-debug-channels.md)),
* `dlogutil` for the device's own logs,
* `uep-test.sh` to classify execution policy empirically.

## Stage 5 — write it down

A target page ([targets/](targets/)) with the firmware string, the measured
facts, the addresses marked build-specific, and a "what did not work" section.
That last section is the most valuable one to the next person.

## External material

**Start here (REA):**
[repository](https://github.com/morluto/rea) ·
[website](https://rea.tools) ·
[installation](https://github.com/morluto/rea/blob/main/docs/installation.md) ·
[first investigation](https://rea.tools/first-investigation/) ·
[guides](https://rea.tools/guides/) ·
[guided MCP prompts](https://github.com/morluto/rea/blob/main/docs/mcp-prompts.md) ·
[REA-Prompts](https://github.com/JoasASantos/REA-Prompts)

**Tool repos:**
[Ghidra](https://github.com/NationalSecurityAgency/ghidra) ·
[ILSpy](https://github.com/icsharpcode/ILSpy) ·
[JADX](https://github.com/skylot/jadx) ·
[Frida](https://github.com/frida/frida) ·
[x64dbg](https://github.com/x64dbg/x64dbg) ·
[awesome-reverse-engineering](https://github.com/morluto/awesome-reverse-engineering) ·
[awesome-reverse-engineered](https://github.com/alexgaoth/awesome-reverse-engineered)

**Books:**
[The Ghidra Book, 2e](https://nostarch.com/ghidra-book-2e) ·
[Reverse Engineering for Beginners](https://go.yurichev.com) ·
[Practical Binary Analysis](https://nostarch.com/binaryanalysis/) ·
[Practical Malware Analysis](https://nostarch.com/malware) ·
[Reversing: Secrets of RE](https://wiley.com/en-us/Reversing%3A+Secrets+of+Reverse+Engineering-p-9780764574818)

**Practice:**
[pwn.college RE](https://pwn.college/intro-re-pwn~5933fc84/reversing/) ·
[pwn.college Reversing Hell](https://pwn.college/reversing-hell/) ·
[Malware Unicorn RE101](https://malwareunicorn.org/workshops/re101) ·
[OST2 x86-64 Assembly](https://p.ost2.fyi/courses/course-v1%3AOpenSecurityTraining2%2BArch1001_x86-64_Asm%2B2021_v1/about) ·
[Nightmare](https://github.com/guyinatuxedo/nightmare) ·
[RPISEC MBE](https://github.com/RPISEC/MBE) ·
[OWASP MAS](https://mas.owasp.org)

**Papers worth knowing (decompilation / agent reliability):**
LLM4Decompile ([2403.05286](https://arxiv.org/abs/2403.05286)) ·
SALT4Decompile ([2509.14646](https://arxiv.org/abs/2509.14646)) ·
Decomperson ([USENIX Sec '22](https://usenix.org/conference/usenixsecurity22/presentation/burk)) ·
DIRTY ([PDF](https://usenix.org/system/files/sec22-chen-qibin.pdf)) ·
Does RE need a bigger model? ([REA blog](https://rea.tools/blog/reverse-engineering-models/))

**Caveat on AI-assisted RE:** adversarial instructions can be embedded in the
binary under study and steer an agent. Treat model output as a hypothesis and
confirm it on the device or against known bytes — the same standard this repo
applies to every address it publishes.
