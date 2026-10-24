#!/bin/sh
# capscan.sh — compact inventory of capability-bearing binaries.
# File capabilities, not uid, are what most Samsung Tizen root chains rely on.
set -u
for d in /usr/bin /usr/sbin /bin /sbin /usr/libexec; do
    [ -d "$d" ] || continue
    getcap -r "$d" 2>/dev/null
done | grep -E 'cap_sys_admin|cap_setuid|cap_sys_module|cap_sys_ptrace|cap_mac_admin' \
     | sed 's/ = /  /' | sort -u
echo
echo "--- SMACK label of this shell: $(cat /proc/self/attr/current 2>/dev/null)"
echo "--- uid: $(id -u 2>/dev/null)"
echo
echo "Note: 'cap_sys_admin' is what the bind-mount + tarlauncher root trick needs."
echo "      'cap_sys_module' is usually useless here: module load needs SMACK '_'."
