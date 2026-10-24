# tee-client

The TrustZone client that decrypts the firmware update container on the Q70T.

It runs as an ordinary managed Tizen app (`uid 5001`, no capabilities) and talks
to the SWU trusted application using the **legacy TEEC ABI** this 2020 firmware
expects:

* `TEEC_Operation` is 60 bytes,
* parameters are 12 bytes each,
* `paramTypes` is one byte per parameter,
* buffers come from `TEEC_AllocateSharedMemory`,
* memrefs use `PARTIAL_INOUT`.

## Build and install

```sh
export TV_IP=<your TV>
export PROFILE=<your signing profile>     # see ../../METHODOLOGY.md
./build.sh
```

## Use

The app sends the TOC ciphertext + salt, then a chosen section + salt, and
writes the plaintext where the caller asks. Exfiltrate large blobs through the
`sdb pull` whitelist (`sdk_tools/profctl_<name>.log`), not through stdout.

Verify the result against the CRC32 recorded in the TOC.

## Scope

This is a research tool for a device you own. It does not bypass signing: the
TA simply performs the decryption the TV is designed to perform.
