#!/bin/sh
# tvroot boot debloat v4 — v3 with two fixes:
#   * the agent starts BEFORE any kill pass (it must not be collateral)
#   * pkill patterns are bracketed ([A]irPlay) so they cannot match this
#     script's own command line, which is passed whole to /bin/sh -c.
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
echo "--- v7 masks installed at uptime=$(up) ($(echo $UNITS | wc -w) units)" >> "$LOG"
systemctl daemon-reload 2>/dev/null

# --- on-demand root agent: start FIRST, never in the kill path ---------------
AG=/opt/usr/share/tvroot/agent.sh
if [ -f "$AG" ]; then
  if [ -e /run/tvroot-agent.pid ] && kill -0 "$(cat /run/tvroot-agent.pid)" 2>/dev/null; then
    echo "--- root agent already running (pid $(cat /run/tvroot-agent.pid))" >> "$LOG"
  else
    setsid /bin/bash -c 'while :; do /bin/bash -c "$(cat /opt/usr/share/tvroot/agent.sh)"; sleep 5; done' </dev/null >/dev/null 2>&1 &
    sleep 2
    echo "--- root agent started (pid $(cat /run/tvroot-agent.pid 2>/dev/null))" >> "$LOG"
  fi
else
  echo "--- root agent not installed" >> "$LOG"
fi

for u in $STOPS; do systemctl --no-block stop "$u" 2>/dev/null; done

# --- hosts sinkhole: ad/ACR domains resolve to 0.0.0.0 even if DNS is bypassed --
HOSTS=/opt/usr/share/tvroot/hosts.block
if [ -f "$HOSTS" ]; then
  if mount --bind "$HOSTS" /etc/hosts 2>/dev/null; then
    echo "--- hosts sinkhole active" >> "$LOG"
  else
    echo "--- hosts sinkhole FAILED" >> "$LOG"
  fi
fi

# bracketed patterns: the literal text in this script does not match the regex
for p in '[a]mbientapp' '[A]irPlay' '[h]bbtv_app'; do pkill -f "$p" 2>/dev/null; done

for p in $PKGS; do pkgcmd -D -t app -n "$p" --uid 5001 >/dev/null 2>&1; done

# --- UEP down via loopback + dropbear, with guards ---------------------------
# Enable file: /opt/usr/share/tvroot/uep-enable   (remove to disable)
# Try counter: decremented before firing; a panic loop exhausts it.
# 60 s delay: every boot gives a window to disable before the fire.
UEPIMG=/opt/usr/share/tvroot/uep2.img
UEPEN=/opt/usr/share/tvroot/uep-enable
if [ -f "$UEPIMG" ] && [ -f "$UEPEN" ] && [ ! -e /run/uep-fired ]; then
  (
    T=/opt/usr/share/tvroot/uep-tries
    n=$(cat "$T" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=3 ;; esac
    if [ "$n" -le 0 ]; then echo "--- uep: tries exhausted, skipped" ; exit 0; fi
    echo $((n-1)) > "$T" 2>/dev/null; sync
    echo "--- uep: firing in 60s (tries left $((n-1)))"
    sleep 60
    LP=$(losetup -f 2>/dev/null)
    [ -n "$LP" ] || { echo "--- uep: no loop device"; exit 0; }
    if ! losetup "$LP" "$UEPIMG" 2>/dev/null; then echo "--- uep: losetup failed"; exit 0; fi
    mkdir -p /tmp/uep 2>/dev/null
    if ! mount -t exfat "$LP" /tmp/uep 2>/dev/null; then
      echo "--- uep: mount failed"; losetup -d "$LP" 2>/dev/null; exit 0
    fi
    : > /run/uep-fired
    ( ls /tmp/uep >/dev/null 2>&1 & )
    ( sleep 30; umount -l /tmp/uep 2>/dev/null; losetup -d "$LP" 2>/dev/null ) &
    i=0
    while [ $i -lt 30 ]; do
      /opt/usr/share/tvroot/ldtest.static >/dev/null 2>&1 && break
      sleep 1; i=$((i+1))
    done
    if /opt/usr/share/tvroot/ldtest.static >/dev/null 2>&1; then
      echo "--- uep: DOWN after ${i}s; resetting tries"
      echo 3 > "$T" 2>/dev/null; sync
      D=/opt/etc/dropbear
      if [ -x /opt/bin/dropbearmulti ] && [ -f "$D/dropbear_ed25519_host_key" ]; then
        [ -f /run/dropbear.pid ] && kill "$(cat /run/dropbear.pid)" 2>/dev/null
        sleep 1
        nohup /opt/bin/dropbearmulti dropbear \
          -r "$D/dropbear_ed25519_host_key" -r "$D/dropbear_rsa_host_key" \
          -P /run/dropbear.pid -p 0.0.0.0:22 -s -g >/tmp/dropbear.log 2>&1 &
        sleep 2
        echo "--- dropbear pid=$(cat /run/dropbear.pid 2>/dev/null)"
      fi
    else
      echo "--- uep: still up after ${i}s"
    fi
  ) >> /opt/usr/share/tvroot/uep-loop.log 2>&1 &
fi

sleep 25
echo "--- v7 delayed pass done at uptime=$(up)" >> "$LOG"
echo "--- census:" >> "$LOG"
for u in acr contents-recognition-service vision-data-recognition-service \
vdsystem-update-manager org.tizen.remotepc background-update \
com.samsung.tv.airplay-service hbbtv-service ambient-ua-agent; do
  printf '      %s: %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)" >> "$LOG"
done
if [ -e /run/tvroot-agent.pid ] && kill -0 "$(cat /run/tvroot-agent.pid)" 2>/dev/null; then
  echo "      root-agent: running (pid $(cat /run/tvroot-agent.pid))" >> "$LOG"
else
  echo "      root-agent: NOT running" >> "$LOG"
fi
free -m 2>/dev/null | sed -n '1,2p' >> "$LOG"
