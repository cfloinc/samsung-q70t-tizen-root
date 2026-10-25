#!/bin/sh
# tvroot boot debloat v3 — v2 plus the on-demand root command agent.
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
echo "--- v3 masks installed at uptime=$(up) ($(echo $UNITS | wc -w) units)" >> "$LOG"
systemctl daemon-reload 2>/dev/null

for u in $STOPS; do systemctl --no-block stop "$u" 2>/dev/null; done
for p in ambientapp AirPlay hbbtv_app; do pkill -f "$p" 2>/dev/null; done
for p in $PKGS; do pkgcmd -D -t app -n "$p" --uid 5001 >/dev/null 2>&1; done

# --- on-demand root agent (root execution without the USB stick) -------------
AG=/opt/usr/share/tvroot/agent.sh
if [ -f "$AG" ]; then
  if [ -e /run/tvroot-agent.pid ] && kill -0 "$(cat /run/tvroot-agent.pid)" 2>/dev/null; then
    echo "--- root agent already running (pid $(cat /run/tvroot-agent.pid))" >> "$LOG"
  else
    setsid /bin/bash -c "$(cat "$AG")" </dev/null >/dev/null 2>&1 &
    sleep 1
    echo "--- root agent started (pid $(cat /run/tvroot-agent.pid 2>/dev/null))" >> "$LOG"
  fi
else
  echo "--- root agent not installed" >> "$LOG"
fi

sleep 25
echo "--- v3 delayed pass done at uptime=$(up)" >> "$LOG"
echo "--- census:" >> "$LOG"
for u in acr contents-recognition-service vision-data-recognition-service \
vdsystem-update-manager org.tizen.remotepc background-update \
com.samsung.tv.airplay-service hbbtv-service ambient-ua-agent; do
  printf '      %s: %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)" >> "$LOG"
done
pgrep -f '/opt/usr/share/tvroot/cmd' >/dev/null 2>&1 && echo "      root-agent: running" >> "$LOG" || echo "      root-agent: not running" >> "$LOG"
free -m 2>/dev/null | sed -n '1,2p' >> "$LOG"
