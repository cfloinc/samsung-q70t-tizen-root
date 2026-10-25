#!/bin/sh
# tvroot root command agent — runs as root, started by the boot hook.
# Executes files dropped in cmd/in as root (content passed to bash, never exec'd,
# so UEP is not involved) and writes their output to cmd/out.
#
# Access control: the cmd/in directory is 0777. Anything at sdk level can queue a
# root command. Kill switch: touch cmd/disabled, or rm agent.sh and reboot.
D=/opt/usr/share/tvroot/cmd
IN="$D/in"; OUT="$D/out"
mkdir -p "$IN" "$OUT" 2>/dev/null
chmod 0777 "$D" "$IN" "$OUT" 2>/dev/null
echo $$ > /run/tvroot-agent.pid 2>/dev/null
while :; do
  if [ -e "$D/disabled" ]; then sleep 5; continue; fi
  for f in "$IN"/*.sh; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .sh)
    /bin/bash -c "$(cat "$f")" > "$OUT/$n.txt" 2>&1
    rc=$?
    printf '\n[exit=%s]\n' "$rc" >> "$OUT/$n.txt"
    rm -f "$f"
  done
  sleep 1
done
