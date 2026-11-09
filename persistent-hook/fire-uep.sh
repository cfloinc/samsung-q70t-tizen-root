#!/bin/sh
# fire-uep.sh — manual, on-demand UEP-down + dropbear for the Q70T.
#
# Run as root, by content:
#   sh -c "$(cat /opt/usr/share/tvroot/fire-uep.sh)"
# or through the root agent:
#   printf 'sh -c "$(cat /opt/usr/share/tvroot/fire-uep.sh)"\n' \
#     > /opt/usr/share/tvroot/cmd/in/fire-uep.sh
#
# The loopback trigger parks a readdir task in D state. It cannot be frozen,
# and losetup -d does not detach while the task holds the device. Reboot after
# use if you need standby. See docs/loopback-uep.md ("Standby and freezer").
LOG=/opt/usr/share/tvroot/uep-loop.log
UEPIMG=/opt/usr/share/tvroot/uep2.img
LDTEST=/opt/usr/share/tvroot/ldtest.static
D=/opt/etc/dropbear

{
  echo "=== manual fire $(date -u 2>/dev/null) uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)s"
  if [ -e /run/uep-fired ]; then
    echo "--- already fired this boot"
  else
    if [ ! -f "$UEPIMG" ]; then echo "--- image missing"; exit 0; fi
    LP=$(losetup -f 2>/dev/null)
    [ -n "$LP" ] || { echo "--- no loop device"; exit 0; }
    losetup "$LP" "$UEPIMG" 2>/dev/null || { echo "--- losetup failed"; exit 0; }
    mkdir -p /tmp/uep 2>/dev/null
    if ! mount -t exfat "$LP" /tmp/uep 2>/dev/null; then
      echo "--- mount failed"
      losetup -d "$LP" 2>/dev/null
      exit 0
    fi
    : > /run/uep-fired
    ( ls /tmp/uep >/dev/null 2>&1 & )
    i=0
    while [ $i -lt 30 ]; do
      "$LDTEST" >/dev/null 2>&1 && break
      sleep 1
      i=$((i+1))
    done
    if "$LDTEST" >/dev/null 2>&1; then
      echo "--- UEP DOWN after ${i}s"
    else
      echo "--- UEP still up after ${i}s"
    fi
    ( sleep 30; umount -l /tmp/uep 2>/dev/null ) &
  fi
  if [ -x /opt/bin/dropbearmulti ] && [ -f "$D/dropbear_ed25519_host_key" ]; then
    if [ -f /run/dropbear.pid ] && kill -0 "$(cat /run/dropbear.pid)" 2>/dev/null; then
      echo "--- dropbear already running pid=$(cat /run/dropbear.pid)"
    else
      [ -f /run/dropbear.pid ] && kill "$(cat /run/dropbear.pid)" 2>/dev/null
      nohup /opt/bin/dropbearmulti dropbear \
        -r "$D/dropbear_ed25519_host_key" -r "$D/dropbear_rsa_host_key" \
        -P /run/dropbear.pid -p 0.0.0.0:22 -s -g >/tmp/dropbear.log 2>&1 &
      sleep 2
      echo "--- dropbear pid=$(cat /run/dropbear.pid 2>/dev/null)"
    fi
  fi
  echo "=== manual fire done; reboot to clear the parked readdir task"
} >> "$LOG" 2>&1
echo "fire-uep: see $LOG" 2>/dev/null
