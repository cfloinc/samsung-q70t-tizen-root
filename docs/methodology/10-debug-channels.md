# 10 — Debug channels: why nothing "happened"

Most of the time lost on this project was not exploitation. It was believing
that silence meant failure, or that a command had run when it had not.

## Rules

1. **Injection-spawned background jobs die with the session.** `nohup` from an
   sdb injection does not survive. Start long work from a real root shell.
2. **Interactive bash over a raw TCP beacon truncates long pasted lines** at
   roughly the terminal width (~64 chars observed). Deliver files as base64 in
   ≤60-char appends and verify the size after each append.
3. **Half-dead sockets are worse than dead ones.** The TV→host direction can die
   while host→TV still works: your commands execute, but you see nothing. Verify
   effects through an independent channel.
4. **A blocked `sh -n` becomes a D-state zombie** on a busy eMMC and silently
   queues every later command in that session. Kill it, or start a new session.
5. **`/tmp` is uid-sticky.** A file created by uid 901 cannot be deleted or
   appended by uid 5001. Use a fresh filename for each attempt.
6. **tmpfs guard flags are ground truth** for boot-hook execution —
   `/run/.tvroot-hook` cannot survive a reboot.
7. **After a raw write, drop caches** before trusting a filesystem hash.
8. **`sdb` wedges after a few operations.** Host-side `kill-server` /
   `start-server` clears it sometimes; a reboot always does.
9. **The TV in standby looks identical to a hang**: ping loss, HTTP `000`, sdb
   unregistered. Wake-on-LAN can recover it; the remote cannot power it *off*.

## A working pattern

```sh
# 1. one command per send, short lines
# 2. write output to a file on the TV
nohup sh -c "$(cat /opt/usr/share/tvroot/hook.sh)" >/tmp/hook.log 2>&1 &

# 3. verify through a different channel (sdb), with recovery
kill-server; start-server; connect; cat /tmp/hook.log
```

## When to stop debugging the channel

If two different channels disagree, trust the one that shows **state on disk**
(hashes, tmpfs flags, log files). Everything else can lie.
