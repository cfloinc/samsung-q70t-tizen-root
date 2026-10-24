#!/bin/sh
# rollback.sh - restore the vendor /etc/profile.d/bash_prompt_custom.sh
# from the byte-exact block backup taken by apply-persistent-hook.sh.
#
# TEMPLATE: the real values are filled in by apply-persistent-hook.sh into
# /opt/usr/share/tvroot/backup/hook-location.sh (this file falls back to
# sourcing that, so the copy in the repo also works if values are exported).

: ${DEV:=/dev/mmcblk0p19}
: ${BLKSTART:?run apply-persistent-hook.sh first, or export BLKSTART/NBLOCKS/BACKUP}
: ${NBLOCKS:?}
: ${BACKUP:?}

fail() { echo "FAIL: $*"; exit 1; }
[ "$(id -u 2>/dev/null)" = "0" ] || fail "not root"
[ -f "$BACKUP" ] || fail "backup missing: $BACKUP"

echo "restoring $NBLOCKS 512-byte block(s) at block $BLKSTART of $DEV"
echo "  from $BACKUP (sha256 $(sha256sum "$BACKUP" | sed 's/ .*$//'))"
dd if="$BACKUP" of="$DEV" bs=512 seek=$BLKSTART count=$NBLOCKS conv=notrunc 2>/dev/null || fail "write failed"
sync
rb=$(dd if="$DEV" bs=512 skip=$BLKSTART count=$NBLOCKS 2>/dev/null | sha256sum | sed 's/ .*$//')
[ "$rb" = "$(sha256sum "$BACKUP" | sed 's/ .*$//')" ] || fail "readback mismatch"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
echo "[ok] blocks restored; vendor file sha256 now: $(sha256sum /etc/profile.d/bash_prompt_custom.sh 2>/dev/null | sed 's/ .*$//')"
echo "     expected vendor sha256: effe97f8ec948a15962fc8a1b85a4e1e446352b8c5caae703e1ed0684425e33c"
