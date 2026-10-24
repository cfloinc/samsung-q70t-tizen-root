#!/bin/sh
# tvroot boot debloat — volatile /run masks + delayed stop pass.
#
# Why /run/systemd/system: /etc/systemd/system is a read-only filesystem even
# for root on this firmware, and /run is FIRST in systemd's UnitPath, so a
# /dev/null symlink there overrides the vendor unit. /run is tmpfs, so this
# re-runs at every boot (that is the point of the profile.d hook).
#
# Idempotent: guarded by /run/.tvroot-debloat (set by boot.sh).
# Every command is error-tolerant; nothing here may stall the boot.

LOG=/opt/usr/share/tvroot/debloat.log

UNITS="acr.service acr.path contents-recognition-service.service vision-data-recognition-service.service vdsystem-update-manager.service org.tizen.remotepc.service"
STOPS="acr.path contents-recognition-service vision-data-recognition-service vdsystem-update-manager org.tizen.remotepc acr"

up() { read up rest < /proc/uptime 2>/dev/null; echo "${up%%.*}s"; }

mask_all() {
    mkdir -p /run/systemd/system 2>/dev/null
    for u in $UNITS; do ln -sf /dev/null /run/systemd/system/$u 2>/dev/null; done
    systemctl daemon-reload 2>/dev/null
}

{
    echo "--- masks installed at uptime=$(up)"
    for u in $UNITS; do echo "      $(ls -l /run/systemd/system/$u 2>/dev/null)"; done

    # services that may already be running: stop them once the boot settles
    ( /bin/sleep 25
      mask_all
      for u in $STOPS; do systemctl --no-block stop $u 2>/dev/null; done
      echo "--- delayed stop pass done at uptime=$(up)"
      echo "--- census:"
      for u in acr contents-recognition-service vision-data-recognition-service \
               vdsystem-update-manager org.tizen.remotepc; do
          echo "      $u: $(systemctl is-active $u 2>/dev/null)"
      done
      echo "--- load/mem:"
      cat /proc/loadavg 2>/dev/null
      free -m 2>/dev/null | head -2
    ) >> "$LOG" 2>&1 &
} >> "$LOG" 2>&1

exit 0
