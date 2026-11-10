// SPDX-License-Identifier: GPL-2.0-only
/*
 * uep_unfreeze.c — prototype: mark the parked UEP readdir task PF_NOFREEZE.
 *
 * The loopback UEP trigger parks a user task in
 * schedule_timeout_uninterruptible().  That task cannot be frozen, so the
 * system freezer times out and standby can restart the TV.  This module walks
 * the task list from current and sets PF_NOFREEZE on the task with the given
 * PID, which makes the freezer skip it.
 *
 * Build against the exact TV kernel with the Q70T ABI fixes; see README.md.
 * UNTESTED.  Loading a mismatched module can crash the TV.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/list.h>

static unsigned long pid;
module_param(pid, ulong, 0444);
MODULE_PARM_DESC(pid, "PID of the parked UEP task (see ps)");

static bool wake;
module_param(wake, bool, 0444);
MODULE_PARM_DESC(wake, "Also try to wake the task (experimental, unsafe)");

static struct task_struct *find_task_by_pid_walk(pid_t want)
{
	struct task_struct *start = current;
	struct task_struct *p = start;

	do {
		if (task_pid_nr(p) == want)
			return p;
		p = list_entry(p->tasks.next, struct task_struct, tasks);
	} while (p != start);

	return NULL;
}

static int __init uep_unfreeze_init(void)
{
	struct task_struct *p;

	if (!pid) {
		pr_err("uep_unfreeze: pid=0; pass the parked task PID\n");
		return -EINVAL;
	}

	p = find_task_by_pid_walk((pid_t)pid);
	if (!p) {
		pr_err("uep_unfreeze: no task with pid %lu\n", pid);
		return -ESRCH;
	}

	pr_info("uep_unfreeze: pid %lu comm=%s state=%ld flags=0x%lx\n",
		pid, p->comm, (long)p->state, (unsigned long)p->flags);

	p->flags |= PF_NOFREEZE;
	pr_info("uep_unfreeze: PF_NOFREEZE set; flags=0x%lx\n",
		(unsigned long)p->flags);

	if (wake) {
		pr_warn("uep_unfreeze: wake=1 — experimental, task may not return safely\n");
		wake_up_process(p);
	}

	return 0;
}

static void __exit uep_unfreeze_exit(void)
{
	pr_info("uep_unfreeze: unloaded; PF_NOFREEZE remains on the task\n");
}

module_init(uep_unfreeze_init);
module_exit(uep_unfreeze_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Mark a parked UEP task PF_NOFREEZE (Q70T research prototype)");
