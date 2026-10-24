#!/bin/sh
# apply-persistent-hook.sh — run as root on the Q70T (USB root shell, uid 0).
#
# Patches /etc/profile.d/bash_prompt_custom.sh IN PLACE on the raw rootfs
# block device so the tvroot boot hook fires on every boot, stick or not.
#
# Safety rules implemented here:
#   1. the live file must hash to the known vendor original before anything
#      is written;
#   2. the file is located on the raw device by content (marker grep), and a
#      candidate only counts if the full 776 bytes read back hash to the
#      vendor original — so every candidate is a byte-identical copy of the
#      same script and patching it is size- and semantics-safe;
#   3. a byte-exact backup of every touched 512-byte block is written to
#      /opt/usr/share/tvroot/backup/ and hashed BEFORE the write;
#   4. the write image = backup blocks with the new 776 bytes overlaid —
#      bytes outside the patched region are written back verbatim;
#   5. after each write: sync, block readback hash, drop_caches, and a hash
#      of the file as the filesystem serves it. If the FS still serves the
#      old bytes (wrong candidate), the candidate is restored from its
#      backup and the next one is tried.
#
# The patch keeps the file at exactly 776 bytes, so no filesystem metadata
# (block count / allocation) changes and no neighbouring file can be touched.

set -u

# Overridable for offline dry runs (TVROOT_TEST=1 skips the live-FS asserts):
DEV=${TVROOT_DEV:-/dev/mmcblk0p19}
DEVNAME=${TVROOT_DEVNAME:-p19}
FILE=${TVROOT_FILE:-/etc/profile.d/bash_prompt_custom.sh}
BK=${TVROOT_BK:-/opt/usr/share/tvroot/backup}
SIZE=776
BLK=512
ORIG_SHA=effe97f8ec948a15962fc8a1b85a4e1e446352b8c5caae703e1ed0684425e33c
NEW_SHA=ca30fa2bb89596b7e5db45185bb265487165072745a5455d7c0d2138de9d3154
MARKER='alias lr="ls -ltrZ"'
MARKER_OFF=629
NEW=/tmp/hook-patched.bin
BOOT=/tmp/tvroot-boot.sh
DEB=/tmp/tvroot-debloat.sh

fail() { echo "FAIL: $*"; exit 1; }
h_of() { sha256sum "$1" 2>/dev/null | sed 's/ .*$//'; }

[ -n "${TVROOT_TEST:-}" ] || [ "$(id -u 2>/dev/null)" = "0" ] \
    || fail "not root (run from the USB root shell)"
[ -f "$NEW" ] || fail "$NEW missing - transfer it first (base64 chunks)"
[ "$(h_of "$NEW")" = "$NEW_SHA" ] || fail "$NEW sha256 mismatch"

# ---- 0. sanity: this really is the active rootfs -------------------------
if [ -z "${TVROOT_TEST:-}" ]; then
    grep -q "root=/dev/mmcblk0p19" /proc/cmdline 2>/dev/null \
        || echo "WARN: /proc/cmdline does not say root=/dev/mmcblk0p19"
    grep -q " / vdfs " /proc/mounts 2>/dev/null || fail "/ is not mounted vdfs?"
fi

# ---- 1. the live file must be the untouched vendor original ---------------
live=$(h_of "$FILE")
[ "$live" = "$ORIG_SHA" ] || fail "live $FILE sha256=$live != vendor $ORIG_SHA (already patched?)"
echo "[ok] live file = vendor original ($ORIG_SHA)"

# ---- 2. locate it on the raw device by content ----------------------------
hits=$(grep -abo "$MARKER" "$DEV" 2>/dev/null | sed 's/:.*$//')
[ -n "$hits" ] || fail "marker '$MARKER' not found on $DEV"
echo "[ok] raw marker hits at byte(s): $(echo $hits | tr '\n' ' ')"

mkdir -p "$BK" 2>/dev/null

DONE=""
for o in $hits; do
    s=$((o - MARKER_OFF))
    [ "$s" -ge 0 ] || continue
    BLKSTART=$((s / BLK)); BLKOFF=$((s % BLK))
    NBLOCKS=$(( (BLKOFF + SIZE + BLK - 1) / BLK ))

    # -- 2a. candidate must hash to the vendor original
    cand=/tmp/hook-cand-$$.bin
    dd if="$DEV" bs=$BLK skip=$BLKSTART count=$NBLOCKS of="$cand" 2>/dev/null || continue
    h=$(dd if="$cand" bs=1 skip=$BLKOFF count=$SIZE 2>/dev/null | sha256sum | sed 's/ .*$//')
    [ "$h" = "$ORIG_SHA" ] || { rm -f "$cand"; continue; }
    echo "[cand] block $BLKSTART (byte $s): matches the vendor original"

    # -- 2b. byte-exact backup BEFORE any write
    BKP=$BK/rootfs-$DEVNAME-blk$BLKSTART-$NBLOCKS.bin
    cp "$cand" "$BKP" || fail "cannot write backup"
    sync
    BKP_SHA=$(h_of "$BKP")
    cp "$FILE" "$BK/bash_prompt_custom.orig.sh" 2>/dev/null
    echo "[cand] backup: $BKP ($((NBLOCKS * BLK)) bytes, sha256 $BKP_SHA)"

    # -- 2c. build the write image (backup + overlaid patch)
    WRI=/tmp/hook-write.bin
    cp "$BKP" "$WRI" || fail "cannot stage write image"
    dd if="$NEW" of="$WRI" bs=1 seek=$BLKOFF conv=notrunc 2>/dev/null || fail "overlay failed"
    got=$(dd if="$WRI" bs=1 skip=$BLKOFF count=$SIZE 2>/dev/null | sha256sum | sed 's/ .*$//')
    [ "$got" = "$NEW_SHA" ] || fail "write image overlay check failed"
    if [ "$BLKOFF" -gt 0 ]; then
        a=$(dd if="$BKP" bs=1 count=$BLKOFF 2>/dev/null | sha256sum | sed 's/ .*$//')
        b=$(dd if="$WRI" bs=1 count=$BLKOFF 2>/dev/null | sha256sum | sed 's/ .*$//')
        [ "$a" = "$b" ] || fail "pre-region bytes changed"
    fi
    tail_off=$((BLKOFF + SIZE)); tail_len=$((NBLOCKS * BLK - tail_off))
    if [ "$tail_len" -gt 0 ]; then
        a=$(dd if="$BKP" bs=1 skip=$tail_off 2>/dev/null | sha256sum | sed 's/ .*$//')
        b=$(dd if="$WRI" bs=1 skip=$tail_off 2>/dev/null | sha256sum | sed 's/ .*$//')
        [ "$a" = "$b" ] || fail "post-region bytes changed"
    fi
    echo "[cand] write image staged: only the $SIZE patched bytes differ"

    # -- 2d. write + verify readback
    dd if="$WRI" of="$DEV" bs=$BLK seek=$BLKSTART count=$NBLOCKS conv=notrunc 2>/dev/null \
        || fail "raw write failed"
    sync
    rb=$(dd if="$DEV" bs=$BLK skip=$BLKSTART count=$NBLOCKS 2>/dev/null | sha256sum | sed 's/ .*$//')
    [ "$rb" = "$(h_of "$WRI")" ] || fail "readback mismatch"
    echo "[cand] block readback matches the write image"

    # -- 2e. does the filesystem serve the new bytes now?
    if [ -n "${TVROOT_TEST:-}" ]; then
        echo "[ok] TVROOT_TEST: accepting the first verified candidate"
        DONE=$s
        break
    fi
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    fh=$(h_of "$FILE")
    if [ "$fh" = "$NEW_SHA" ]; then
        echo "[ok] filesystem now serves the patched script - THIS IS THE LIVE COPY"
        DONE=$s
        break
    fi
    echo "[cand] FS still serves the old bytes -> stale copy, restoring..."
    dd if="$BKP" of="$DEV" bs=$BLK seek=$BLKSTART count=$NBLOCKS conv=notrunc 2>/dev/null
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    fh=$(h_of "$FILE")
    [ "$fh" = "$ORIG_SHA" ] || fail "restore of stale candidate failed (file sha $fh)"
    rm -f "$BKP"
done
rm -f /tmp/hook-cand-$$.bin
[ -n "$DONE" ] || fail "no live candidate found (all marker hits were stale copies)"
START=$DONE
BLKSTART=$((START / BLK)); BLKOFF=$((START % BLK))
NBLOCKS=$(( (BLKOFF + SIZE + BLK - 1) / BLK ))
BKP=$BK/rootfs-$DEVNAME-blk$BLKSTART-$NBLOCKS.bin
BKP_SHA=$(h_of "$BKP")
echo "[ok] target confirmed: $DEV byte $START (512-block $BLKSTART +$BLKOFF, $NBLOCKS block(s)))"

# ---- 3. install the /opt payload + rollback kit ---------------------------
OPTDIR=${TVROOT_OPT:-/opt/usr/share/tvroot}
if [ -f "$BOOT" ]; then mkdir -p "$OPTDIR" 2>/dev/null; cp "$BOOT" "$OPTDIR/boot.sh" && chmod 755 "$OPTDIR/boot.sh"; fi
if [ -f "$DEB" ]; then mkdir -p "$OPTDIR" 2>/dev/null; cp "$DEB" "$OPTDIR/debloat.sh" && chmod 755 "$OPTDIR/debloat.sh"; fi

cat > "$BK/hook-location.sh" <<LOC
DEV=$DEV
DEVNAME=$DEVNAME
BYTEOFF=$START
BLKSTART=$BLKSTART
BLKOFF=$BLKOFF
NBLOCKS=$NBLOCKS
BACKUP=$BKP
ORIG_SHA=$ORIG_SHA
NEW_SHA=$NEW_SHA
LOC

cat > "$BK/rollback.sh" <<'EOS'
#!/bin/sh
# rollback.sh - restore the vendor /etc/profile.d/bash_prompt_custom.sh
# from the byte-exact block backup taken by apply-persistent-hook.sh.
FILE=${TVROOT_FILE:-/etc/profile.d/bash_prompt_custom.sh}
. ${TVROOT_BK:-/opt/usr/share/tvroot/backup}/hook-location.sh
fail() { echo "FAIL: $*"; exit 1; }
[ -n "${TVROOT_TEST:-}" ] || [ "$(id -u 2>/dev/null)" = "0" ] || fail "not root"
[ -f "$BACKUP" ] || fail "backup missing: $BACKUP"
echo "restoring $NBLOCKS 512-byte block(s) at block $BLKSTART of $DEV"
echo "  from $BACKUP (sha256 $(sha256sum "$BACKUP" | sed 's/ .*$//'))"
dd if="$BACKUP" of="$DEV" bs=512 seek=$BLKSTART count=$NBLOCKS conv=notrunc 2>/dev/null || fail "write failed"
sync
rb=$(dd if="$DEV" bs=512 skip=$BLKSTART count=$NBLOCKS 2>/dev/null | sha256sum | sed 's/ .*$//')
[ "$rb" = "$(sha256sum "$BACKUP" | sed 's/ .*$//')" ] || fail "readback mismatch"
[ -n "${TVROOT_TEST:-}" ] || echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
echo "[ok] blocks restored; file sha256 now: $(h_of "$FILE")"
echo "     expected vendor sha256: $ORIG_SHA"
EOS
chmod 755 "$BK/rollback.sh" 2>/dev/null

echo "=============================================================="
echo "PERSISTENT HOOK APPLIED"
echo "  device      : $DEV byte $START (block $BLKSTART +$BLKOFF)"
echo "  backup      : $BKP"
echo "  backup sha  : $BKP_SHA"
echo "  new file    : sha256 $NEW_SHA"
echo "  rollback    : sh $BK/rollback.sh"
echo "  boot payload: $OPTDIR/boot.sh -> debloat.sh"
echo "  next boot   : tizen-system-env.service sources the patched"
echo "                script as root ~2s after boot; it waits up to"
echo "                120s for /opt then runs the debloat. No stick."
echo "=============================================================="
