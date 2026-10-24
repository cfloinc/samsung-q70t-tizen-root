#!/bin/sh
# uep-test.sh — determine which ways of running an unsigned script work here.
# Run as root (su/root shell). Writes only to /tmp.
#
# UEP ("unsigned executable prevention") hooks script FILE loading, so the
# expected result on an enforcing device is:
#   exec file      : EPERM / "[uep][bash] the file is NOT signed!!"
#   sh file        : same
#   sh -s < file   : same
#   sh -c "$(cat)" : works   <-- the bypass
set -u
F=/tmp/uep-probe-$$.sh
printf '#!/bin/sh\necho UEP-PROBE-OK\n' > "$F"
chmod 755 "$F"

try() {
    label=$1; shift
    out=$("$@" 2>&1); rc=$?
    case "$out" in
        *UEP-PROBE-OK*) verdict="WORKS" ;;
        *uep*|*"not signed"*|*"Operation not permitted"*) verdict="BLOCKED" ;;
        *) verdict="other(rc=$rc)" ;;
    esac
    printf '%-22s %-10s %s\n' "$label" "$verdict" "$(echo "$out" | head -1 | cut -c1-70)"
}

echo "device: $(uname -a)"
echo "uid=$(id -u 2>/dev/null)  label=$(cat /proc/self/attr/current 2>/dev/null)"
echo
printf '%-22s %-10s %s\n' "invocation" "result" "first line"
try "exec file"        "$F"
try "sh file"          /bin/sh "$F"
try "sh -s < file"     /bin/sh -s < "$F"
try "sh -c cat"        /bin/sh -c "$(cat "$F")"
try "dot file"         /bin/sh -c ". $F"
rm -f "$F"
