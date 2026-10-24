#!/bin/sh
# tvroot boot entry — runs as root from the patched profile.d script.
# UEP-safe: debloat.sh is passed by CONTENT, never exec'd.
LOG=/opt/usr/share/tvroot/debloat.log
DIR=/opt/usr/share/tvroot
[ -e /run/.tvroot-debloat ] && exit 0
: > /run/.tvroot-debloat 2>/dev/null
mkdir -p "$DIR" 2>/dev/null
{
  up=$(read up rest < /proc/uptime 2>/dev/null; echo "$up")
  echo "=== tvroot boot entry uptime=${up}s uid=$(id -u 2>/dev/null) ctx=$(cat /proc/self/attr/current 2>/dev/null)"
  if [ -f "$DIR/debloat.sh" ]; then
    /bin/sh -c "$(cat "$DIR/debloat.sh")"
  else
    echo "=== debloat.sh missing"
  fi
  echo "=== tvroot boot entry done"
} >> "$LOG" 2>&1
:
