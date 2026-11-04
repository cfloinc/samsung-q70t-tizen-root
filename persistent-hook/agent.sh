#!/bin/sh
# tvroot root command agent — runs as root, started by the boot hook.
# Executes files dropped in cmd/in as root (content passed to bash, never exec'd,
# so UEP is not involved) and writes their output to cmd/out.
#
# Access control: cmd and cmd/in are 1777 (sticky, world-writable). A job file
# must be a regular file, not a symlink, and owned by the expected UID (sdk=901
# by default). This keeps the "any sdk process can queue a root command"
# workflow while rejecting symlink/hijack attempts from other UIDs. Set
# TVROOT_AGENT_UID if the sdk user differs on another build.
# Kill switch: touch cmd/disabled (must be a regular file owned by the expected
# UID); or rm agent.sh and reboot.
D=/opt/usr/share/tvroot/cmd
IN="$D/in"; OUT="$D/out"
EXPECTED_UID=${TVROOT_AGENT_UID:-901}

# Refuse symlinked command directories outright.
if [ -L "$D" ] || [ -L "$IN" ] || [ -L "$OUT" ]; then
    echo "agent: refusing symlinked command directory" >&2
    exit 1
fi
mkdir -p "$IN" "$OUT" 2>/dev/null || exit 1
if [ ! -d "$IN" ] || [ ! -d "$OUT" ]; then
    echo "agent: command directory missing" >&2
    exit 1
fi
chmod 1777 "$D" "$IN" 2>/dev/null
chmod 0755 "$OUT" 2>/dev/null

owner_of() {
    # shellcheck disable=SC2012
    stat -c %u -- "$1" 2>/dev/null || ls -ln -- "$1" 2>/dev/null | awk 'NR==1{print $3}'
}

echo $$ > /run/tvroot-agent.pid 2>/dev/null
while :; do
  if [ -e "$D/disabled" ] && [ -f "$D/disabled" ] && [ ! -L "$D/disabled" ]; then
      if [ "$(owner_of "$D/disabled")" = "$EXPECTED_UID" ]; then
          sleep 5; continue
      fi
  fi
  for f in "$IN"/*.sh; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$(owner_of "$f")" = "$EXPECTED_UID" ] || continue
    n=$(basename "$f" .sh)
    out="$OUT/$n.txt"
    [ -L "$out" ] && rm -f "$out"
    /bin/bash -c "$(cat "$f")" > "$out" 2>&1
    rc=$?
    printf '\n[exit=%s]\n' "$rc" >> "$out"
    rm -f "$f"
  done
  sleep 1
done
