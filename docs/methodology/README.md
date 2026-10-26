# Methodology

The order below is the order that actually worked on a 2020 NIKEM Q70T. Each
document states what was measured, where the uncertainty is, and what to check
on a different model before trusting it.

| # | Document | Question it answers |
|---|---|---|
| 01 | [Foothold](01-foothold.md) | How do I get code execution as `uid 901` over sdb? |
| 02 | [Firmware container](02-firmware-container.md) | What is inside `upgrade.msd`, and which part do I need? |
| 03 | [TEE decryption](03-tee-decrypt.md) | How do I decrypt the container without a signing key? |
| 04 | [Kernel recovery](04-kernel-recovery.md) | How do I turn a section into a usable kernel image? |
| 05 | [Address derivation](05-address-derivation.md) | How do I find the gadgets and functions for my build? |
| 06 | [UEP](06-uep.md) | Why are my scripts refused, and what actually bypasses it? |
| 07 | [Capabilities and zones](07-capabilities-and-zones.md) | Where do capabilities come from, and where are they stripped? |
| 08 | [Boot chain and persistence](08-boot-chain-and-persistence.md) | What runs as root at boot, and how do I hook it? |
| 09 | [Debloat](09-debloat.md) | Which disabling mechanisms actually survive a reboot? |
| — | [UEP bypass (kernel-level)](../uep-bypass.md) | What the gate actually checks, the three patch sites, and why modules are signed differently |
| — | [Stickless UEP firing](../loopback-uep.md) | Firing the same exploit from a loop device, so UEP is down at every boot with no USB stick |
| 10 | [Debug channels](10-debug-channels.md) | Why did my command silently not run, and how do I avoid it? |

Target profiles live in [`../targets/`](../targets/). The finished Q70T case
study is [`../../WRITEUP.md`](../../WRITEUP.md); the raw journal with all the
dead ends is [`../../FINDINGS.md`](../../FINDINGS.md).
