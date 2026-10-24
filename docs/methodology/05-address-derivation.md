# 05 — Deriving addresses for your own build

Public address tables are only valid for the exact firmware build. On this
project the addresses came from the TV's own decrypted kernel, and were then
independently confirmed against a sibling build published by another researcher
— every shared value matched.

## What you need

| Item | Why |
|---|---|
| `call_usermodehelper` | to run a signed binary as root from kernel context |
| `memcpy` | to stage the payload |
| `v7_coherent_kern_range` | to publish the written code/icache safely |
| `schedule_timeout_uninterruptible` | to park the exploited thread |
| a `ldm ip,{…,pc}`-style gadget | to restore the saved frame and jump |
| an unreferenced code cave | to place the payload |
| the UEP verifier entry / status word | only if you need unsigned execution |

## Methods that worked

1. **ksymtab scanning** — the kernel exports symbols with relative offsets;
   reconstruct the table from the image and resolve the three functions above.
2. **String cross-reference** — find a driver's format strings in `.rodata`,
   convert to VA (`offset + PAGE_OFFSET`), then find the code that references
   them.
3. **`movw`/`movt` reconstruction** — ARM does not always use PC-relative
   literal pools. Track `movw`/`movt` pairs per register and match the assembled
   32-bit value. This is what located the UEP state word after a naive
   literal-pool scan found nothing.
4. **Frame-semantics gadget search** — do not pattern-match a published gadget
   blindly. Search for instructions whose epilogue restores the exact register
   set and stack adjustment your payload expects.

## Validate before you flash

Simulate the copy loop against the actual driver behaviour:

* count the fragments the driver will copy (`num_ext`),
* replay the sequence and record which registers hold what at the jump,
* reconstruct the final byte stream,
* compare it to the cave blob byte-for-byte, with only the deliberately
  disposable registers differing.

On this project the simulation predicted `pc=0xc05455bc`, `sp=0xc0008e00`, and
the real device behaved identically.

## The geometry trap

Every byte you add to the kernel-stage command string changes the cave length
and therefore `num_ext`. Only **`num_ext = 67`** (cave ≤ 547 bytes) was
field-validated here. Images at 70 boot-looped the television. Freeze the payload
size, or re-validate after every edit.
