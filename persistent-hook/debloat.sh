#!/bin/sh
# tvroot boot debloat v2 — /run masks + delayed stop + package deactivation.
# Executed by boot.sh via  sh -c "$(cat ...)"  (UEP-safe: no execve of this file).
# Everything is best-effort; nothing here may stall the boot.
LOG=/opt/usr/share/tvroot/debloat.log

UNITS="acr.service acr.path contents-recognition-service.service \
vision-data-recognition-service.service vdsystem-update-manager.service \
org.tizen.remotepc.service background-update.service background-update.path \
bootmode-system-update.service com.samsung.tv.airplay-service.service \
com.samsung.tv.airplay-service-2.service hbbtv-service.service \
ambient-ua-agent.service"

STOPS="acr acr.path contents-recognition-service vision-data-recognition-service \
vdsystem-update-manager org.tizen.remotepc background-update background-update.path \
com.samsung.tv.airplay-service com.samsung.tv.airplay-service-2 hbbtv-service \
ambient-ua-agent"

PKGS="org.tizen.ambientapp com.samsung.tv.airplay-app org.tizen.hbbtv"

up() { read u rest < /proc/uptime 2>/dev/null; echo "${u%%.*}s"; }

mkdir -p /run/systemd/system 2>/dev/null
for u in $UNITS; do ln -sf /dev/null "/run/systemd/system/$u" 2>/dev/null; done
echo "--- v2 masks installed at uptime=$(up) ($(echo $UNITS | wc -w) units)" >> "$LOG"
systemctl daemon-reload 2>/dev/null

for u in $STOPS; do systemctl --no-block stop "$u" 2>/dev/null; done

# immediate effect on the running system
for p in ambientapp AirPlay hbbtv_app; do pkill -f "$p" 2>/dev/null; done

# persistent, reversible package deactivation for the owner
for p in $PKGS; do pkgcmd -D -t app -n "$p" --uid 5001 >/dev/null 2>&1; done

sleep 25
echo "--- v2 delayed pass done at uptime=$(up)" >> "$LOG"
echo "--- census:" >> "$LOG"
for u in acr contents-recognition-service vision-data-recognition-service \
vdsystem-update-manager org.tizen.remotepc background-update \
com.samsung.tv.airplay-service hbbtv-service ambient-ua-agent; do
  printf '      %s: %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)" >> "$LOG"
done
free -m 2>/dev/null | sed -n '1,2p' >> "$LOG"
