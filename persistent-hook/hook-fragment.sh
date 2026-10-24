# --- tvroot boot hook (appended to the vendor profile.d script) -------------
# Runs once per boot, as root, from /etc/profile sourced by
# tizen-system-env.service. Everything is best-effort: a failure here must
# never stall the boot shell.
#
# IMPORTANT: /bin/sh "$DIR/boot.sh" would trip UEP (Tizen checks script file
# loading). Passing the CONTENT as an argument never execve()s the file:
if [ ! -e /run/.tvroot-hook ]; then
: > /run/.tvroot-hook 2>/dev/null
( n=0; while [ $n -lt 120 ]; do [ -f /opt/usr/share/tvroot/boot.sh ] && break; /bin/sleep 1; n=$((n+1)); done; /bin/sh -c "$(cat /opt/usr/share/tvroot/boot.sh)" ) >/dev/null 2>&1 &
fi
