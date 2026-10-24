#!/usr/bin/env python3
"""Build a same-size patched copy of YOUR OWN profile.d prompt script.

Why: Tizen's tizen-system-env.service runs
`/usr/bin/env -i sh -c 'source /etc/profile'` at boot, and /etc/profile
sources every /etc/profile.d/*.sh **as root**. The vendor ships a small
prompt/alias script there inside `if [ "$PS1" ]`, so it is inert during a boot
source - which makes it the ideal hook carrier.

This tool appends hook-fragment.sh to a copy of your vendor file, compacting
only if necessary, and pads with '#' so the result is EXACTLY the same byte
length. Only the file's data blocks are rewritten in place; no filesystem
metadata is touched.

Usage:
    build-patch.py <vendor-script> <output.bin> [--hook hook-fragment.sh]

Compaction ladder (each step only if the previous does not fit):
    1. strip comments / blank lines from the hook
    2. strip trailing comment-only lines from the vendor body
    3. drop vendor `alias ...` lines
    4. drop the whole `if [ "$PS1" ] ... fi` prompt block

Then, on the TV as root:
    dd if=/tmp/hook-patched.bin of=/dev/mmcblk0pNN bs=512 seek=<BLOCK> conv=notrunc
    sync; echo 3 > /proc/sys/vm/drop_caches
    sha256sum /etc/profile.d/<script>        # must equal the new hash
"""
import argparse, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

def strip_comments(s: str) -> str:
    out = []
    for line in s.split("\n"):
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        out.append(line.rstrip())
    return "\n".join(out) + ("\n" if out else "")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vendor"); ap.add_argument("output")
    ap.add_argument("--hook", default=str(HERE / "hook-fragment.sh"))
    a = ap.parse_args()

    vendor = Path(a.vendor).read_bytes()
    hook = strip_comments(Path(a.hook).read_text(encoding="utf-8"))
    text = vendor.decode("utf-8", "replace")
    size = len(vendor)

    # body candidates, most faithful first
    body0 = text
    body1 = "\n".join(l for l in body0.split("\n")
                      if l.strip() and set(l.strip()) != {"#"}).rstrip("\n") + "\n"
    body2 = "\n".join(l for l in body1.split("\n")
                      if not l.strip().startswith("alias ")).rstrip("\n") + "\n"
    m = re.search(r'(?ms)^if \[ "\$PS1" \].*?^fi\s*$', body1)
    body3 = re.sub(r'(?ms)^if \[ "\$PS1" \].*?^fi\s*$', "", body1).strip("\n") + "\n" if m else body2

    chosen, label = None, None
    for body, name in ((body1, "full vendor body (comments trimmed)"),
                       (body2, "vendor prompt minus alias lines"),
                       (body3, "hook only (prompt block dropped)")):
        cand = body + hook
        if len(cand) <= size:
            chosen, label = cand, name
            break
    if chosen is None:
        shortest = body3 + hook
        sys.exit(f"still does not fit: need {len(shortest)-size} more bytes than "
                 f"the {size}-byte file has. Use a bigger vendor script or a "
                 f"shorter hook.")

    chosen += "#" * (size - len(chosen))
    assert len(chosen) == size
    p = subprocess.run(["sh", "-n"], input=chosen.encode(), capture_output=True)
    if p.returncode != 0:
        sys.exit("generated script fails sh -n:\n" + p.stderr.decode())

    Path(a.output).write_bytes(chosen.encode())
    sha = subprocess.run(["sha256sum", a.output], capture_output=True, text=True).stdout.split()[0]
    print(f"vendor : {size} bytes")
    print(f"variant: {label}")
    print(f"output : {len(chosen)} bytes, sh -n clean")
    print(f"sha256 : {sha}")

if __name__ == "__main__":
    main()
