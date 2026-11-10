# uep_unfreeze.ko — research prototype (unbuilt/untested)

## Why

The loopback UEP fire parks a user task (`ls /tmp/uep`) in D state. On the
Q70T the task sits in `schedule_timeout_uninterruptible` (`0xc05330e0`), has
the exFAT directory fd open, cannot be frozen, and makes `losetup -d` return 0
without detaching the loop. The system standby freezer deadline is 20 s, so
standby can fail and restart the TV. See
[`docs/loopback-uep.md`](../../docs/loopback-uep.md#standby-and-freezer).

This module is the kernel-side experiment: find the parked task by PID and set
`PF_NOFREEZE`, so the freezer skips it instead of waiting for it.

## Status

**Source only. Unbuilt and untested.** The kernel tree and Docker build
environment used for the Q70T `research_kmem.ko` are not present in this
checkout. Do not load an untested module on a TV you care about.

## Design

1. At module init, start from `current` (the `insmod` task) and walk the
   global `tasks` list; `task_pid_nr(p)` matches the requested PID. This avoids
   `init_task`/`find_task_by_vpid` export questions.
2. Set `p->flags |= PF_NOFREEZE`.
3. Optional `wake=1` calls `wake_up_process(p)`. Treat this as dangerous: the
   task is parked inside the exploit payload; waking it may return into a
   corrupted frame. `PF_NOFREEZE` alone is the intended fix.
4. The flag remains after module unload; a reboot clears it.

## Build

Use the exact TV kernel and gtalusan's
[samsung-tizen-kmod-recipe](https://github.com/gtalusan/samsung-tizen-kmod-recipe)
commit `330a4d0`. For the Q70T `T-NKMAKUC-2743.0` the ABI fixes were:

* `CONFIG_KALLSYMS` off (no `/proc/kallsyms` on this TV);
* `struct mod_arch_specific { struct unwind_table *unwind[6]; }` (24 B, not
  32 B);
* exact vermagic `0000000, release SMP preempt mod_unload ARMv7 p2v8 `;
* compile in ARM mode, not Thumb; `-fno-unwind-tables`;
* emit `.core.plt` and `.init.plt`, and `.gnu.linkonce.this_module`.

The ABI oracle is the stock `acm/acmd.ko`: on the Q70T `__this_module` is
**0x134** bytes, `init_module` at **0xc0**, `cleanup_module` at **0x12c**.
Compare the built module before loading. A different build will need its own
stock-module oracle.

## Test (only on a lab TV)

1. Fire UEP manually and note the parked `ls` PID:
   `sh -c "$(cat /opt/usr/share/tvroot/fire-uep.sh)"`;
   `ps -eo pid,stat,comm,args | grep '[l]s /tmp/uep'`.
2. Insert with UEP down: `insmod uep_unfreeze.ko pid=<pid>`.
3. Check dmesg for the task line and `PF_NOFREEZE set`.
4. Check `/proc/<pid>/stat` field 9 (flags) has bit `0x80`.
5. Freezer test without standby: create a fresh `freezer` cgroup, move the
   task in, write `FROZEN`, and poll `freezer.state`. If it reaches `FROZEN`
   within a second or two, the flag is working; then `THAWED`, move the task
   back, and remove the cgroup.
6. Only then test an actual standby/wake. Keep a mains-power recovery path.

## Risks

* A mismatched `task_struct`/`module` layout can crash or corrupt the TV.
* `wake=1` can make the parked task return into the exploit payload; it may
  crash. Prefer `PF_NOFREEZE` alone.
* The parked task still holds the loop device; the loop stays attached until
  reboot. `PF_NOFREEZE` only fixes the freezer/standby symptom, not the
  resource reference.
* A proper fix is a trigger that does not park a user task, or a payload that
  exits cleanly after patching UEP. A clean-return stage was tried on a Q85R
  and boot-looped; the park is deliberate.

## References

* [`docs/loopback-uep.md`](../../docs/loopback-uep.md#standby-and-freezer)
* [`FINDINGS.md`](../../FINDINGS.md) §26
* [`docs/uep-bypass.md`](../../docs/uep-bypass.md) §4
