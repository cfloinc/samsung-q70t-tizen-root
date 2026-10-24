# 03 — Decrypting the firmware with the TV's own TrustZone

## The idea

The TV must be able to decrypt its own update files, so the decrypt key lives in
a Trusted Application. A normal app can ask that TA to decrypt a buffer. On the
Q70T this works from **`uid 5001`, with no capabilities at all**.

The missing piece for years of failed attempts was the **legacy TEEC ABI** the
2020 runtime expects.

## The ABI that works here

* `TEEC_Operation` is **60 bytes** (not the modern larger struct).
* Each parameter is **12 bytes**: `{ void* buffer; uint32_t size; uint32_t type; }`.
* `paramTypes` is **one byte per parameter**, not a bitfield.
* Buffers must be **shared memory** allocated with `TEEC_AllocateSharedMemory`.
* Use `TEEC_PARAM_TYPE_PARTIAL_INOUT` for the memrefs.
* Open the session with the SWU TA UUID; no login, no capabilities.

`tools/tee-client/` contains the C# client used on the device
(`tee.cs`, `tee.csproj`, `tizen-manifest.xml`). It runs as an ordinary
managed app.

## Flow

1. Send the TOC ciphertext + its salt → receive plaintext TOC.
2. Parse the section table.
3. For the kernel section: send ciphertext + that section's salt → receive the
   raw image.
4. Verify against the CRC32 recorded in the TOC before using it.

## Exfiltration

The decrypted blob leaves the TV through the `sdb pull` whitelist: write it as
`/home/owner/share/tmp/sdk_tools/profctl_<name>.log`, then `sdb pull` it.
Do not try to print tens of megabytes through the injection.

## What this proves about the device

The update container's confidentiality does not depend on the signing key being
secret from the owner — the TA will decrypt for any local app. That is a design
observation, not an exploit: it requires code execution on the TV first.
