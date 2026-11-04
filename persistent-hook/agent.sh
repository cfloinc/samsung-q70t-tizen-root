#!/bin/sh
# tvroot root command agent v3 — audit trail + job archive + ownership checks.
# Started by the boot hook; supervised so it restarts if it dies.
# Executes job files as root via bash -c "$(cat ...)" (no file exec, so no UEP).
#
# Access control: cmd and cmd/in are 1777 sticky; job files must be regular,
# non-symlink and owned by the expected UID (sdk=901 by default). The parent
# /opt/usr/share/tvroot is 0755 root, so other UIDs cannot replace this agent.
# Kill switch: touch cmd/disabled (same owner check).
D=/opt/usr/share/tvroot/cmd
IN="$D/in"; OUT="$D/out"; ARC="$D/archive"; LOG=/opt/usr/share/tvroot/rootcmd.log
EXPECTED_UID=${TVROOT_AGENT_UID:-901}

# Refuse symlinked command directories outright.
for dir in "$D" "$IN" "$OUT" "$ARC"; do
    [ -L "$dir" ] && { echo "agent: refusing symlinked $dir" >&2; exit 1; }
done
mkdir -p "$IN" "$OUT" "$ARC" 2>/dev/null || exit 1
for dir in "$IN" "$OUT" "$ARC"; do
    [ -d "$dir" ] || { echo "agent: missing $dir" >&2; exit 1; }
done
# Command dirs are root-owned; sticky keeps other UIDs from removing sdk jobs.
chown 0:0 "$D" "$IN" "$OUT" "$ARC" 2>/dev/null
chmod 1777 "$D" "$IN" 2>/dev/null
chmod 0755 "$OUT" "$ARC" 2>/dev/null
[ -L "$LOG" ] && rm -f "$LOG"
chown 0:0 "$LOG" 2>/dev/null
chmod 0644 "$LOG" 2>/dev/null

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
    ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)
    [ -n "$ts" ] || ts=$(date +%s)
    out="$OUT/$n.txt"
    [ -L "$out" ] && rm -f "$out"
    /bin/bash -c "$(cat "$f")" > "$out" 2>&1
    rc=$?
    printf '\n[exit=%s]\n' "$rc" >> "$out"
    arc="$ARC/$ts-$n.sh"
    [ -L "$arc" ] && rm -f "$arc"
    cp "$f" "$arc" 2>/dev/null
    printf '%s job=%s exit=%s\n' "$ts" "$n" "$rc" >> "$LOG" 2>/dev/null
    rm -f "$f"
  done
  sleep 1
done
