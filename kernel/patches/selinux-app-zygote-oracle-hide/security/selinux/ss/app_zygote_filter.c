// SPDX-License-Identifier: GPL-2.0-only
/* Included by services.c to use the SELinux policy and SID helpers. */

/* Called only at SELinux userspace query entry points. */
bool susfs_is_app_zygote(void)
{
	struct selinux_policy *policy;
	struct context *ctx;
	const char *type_name;
	bool match = false;

	if (!selinux_initialized(&selinux_state))
		return false;
	rcu_read_lock();
	policy = rcu_dereference(selinux_state.policy);
	if (!policy)
		goto out;
	ctx = sidtab_search(policy->sidtab, current_sid());
	if (!ctx || !ctx->type || ctx->type > policy->policydb.p_types.nprim)
		goto out;
	type_name = sym_name(&policy->policydb, SYM_TYPES, ctx->type - 1);
	match = type_name && !strcmp(type_name, "app_zygote");
out:
	rcu_read_unlock();
	return match;
}
