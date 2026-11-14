# SELinux DirtySepolicy / Oracle 拦截补丁评审与交接文档 (Handoff to Codex)

## 1. 任务背景与核心目标

- **硬件/系统环境**：Sony Xperia 1 V (XQ-DQ72 / pdx234 / SM8550)，LineageOS 23.2 (Android 16)，Linux 5.15 GKI。
- **Root 方案**：BakaSU (ReSukiSU 5.15 分支) + SUSFS v2.4.0 (10 项全功能开启)。
- **前序问题 (Regression)**：
  在引入对 DirtySepolicy / Duck-Detector (基于 `app_zygote` 的 SELinux Oracle 探测) 的拦截补丁 `patches/selinux-app-zygote-oracle-hide.patch` 后，系统虽然成功伪装了 SELinux 敏感 Context，但导致**应用层所有 Root 提权功能全部失效**。
  真机抓取到内核报错：
  ```log
  KernelSU: security_secctx_to_secid u:r:ksu:s0 -> sid: 0, error: -22
  ```
- **核心目标**：
  请 Codex 重点审查对 `patches/selinux-app-zygote-oracle-hide.patch` 的精准重构方案，确认其：
  1. 彻底解决 KernelSU 运行时无法解析 `u:r:ksu:s0` 导致的提权失效问题；
  2. 依然能 100% 阻断 DirtySepolicy 依赖 `app_zygote` 充当预言机的探测攻击；
  3. 内核安全性、并发安全（RCU、锁）与性能影响无隐患。

---

## 2. 根因剖析与对比机制

### 2.1 原有错误实现 (Broken Implementation)
原补丁位于 `security/selinux/ss/services.c`：
```c
static inline bool susfs_is_untrusted_caller(void)
{
    if (susfs_is_current_ksu_domain())
        return false;
    if (current_uid().val >= 10000)
        return true;
    return false;
}
```
并在 `security_context_to_sid_core` 及 `susfs_security_context_to_sid_core` 中加入：
```c
if (susfs_is_untrusted_caller() && susfs_is_sensitive_root_context(scontext2)) {
    kfree(scontext2);
    return -EINVAL;
}
```

**为什么失效**：
1. 普通应用申请 root（运行 `su`）时，该应用的 UID $\ge$ 10000，且此时尚未完成提权，进程依然运行在 `untrusted_app` 域，`susfs_is_current_ksu_domain()` 返回 `false`。
2. KernelSU 在内核代表该应用执行 `transive_to_domain(KERNEL_SU_CONTEXT, cred, false)`，内部调用 `security_secctx_to_secid("u:r:ksu:s0", ...)`。
3. 进入 `security_context_to_sid_core` 时，`current_uid().val >= 10000` 命中，判定为不可信 caller；
4. `scontext2` 包含 `:ksu`，命中敏感 context；
5. 直接返回 `-EINVAL` (-22)；
6. 导致 KernelSU 无法获取 `u:r:ksu:s0` 的 SID，提权流程彻底中断。

---

### 2.2 修复后实现 (Fixed Implementation)

根据 DirtySepolicy 的攻击面分析：
DirtySepolicy 必须依赖应用声明 `<service android:name="..." android:useAppZygote="true" android:isolatedProcess="true" />`，让代码运行在 **`u:r:app_zygote:s0`** 域内。因为在 AOSP 默认策略中，只有 `app_zygote` 拥有 `selinux_check_access`（`security compute_av`）权限，普通应用（`untrusted_app`）直接发起查询会被 SELinux 本身 Deny。

因此，**拦截必须以调用者的 SELinux 域作为判定条件，绝不能单以 UID 作为过滤依据**。

**重构后的代码**（位于 `security/selinux/ss/services.c`）：
```c
#ifdef CONFIG_KSU_SUSFS
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_sus_type_rcu(u32 sid);
extern void susfs_spoof_avd_allowed_rcu(u32 s_type, u32 t_type, u32 c_type, u32 *avd_allowed);
extern struct selinux_state selinux_state;

static inline bool susfs_is_sensitive_root_context(const char *ctx)
{
	if (!ctx)
		return false;
	if (strstr(ctx, ":ksu") ||
	    strstr(ctx, ":magisk") ||
	    strstr(ctx, ":lsposed") ||
	    strstr(ctx, ":xposed") ||
	    strstr(ctx, ":su:s0"))
		return true;
	return false;
}

static inline bool susfs_is_untrusted_caller(struct selinux_state *state)
{
	struct selinux_policy *policy;
	struct sidtab *sidtab;
	struct context *ctx;
	const char *type_name;
	u32 sid;

	/* 1. 已经在 ksu 域的进程直接放行 */
	if (susfs_is_current_ksu_domain())
		return false;

	/* 2. 系统服务与特权 UID (init, system_server 等) 直接放行 */
	if (current_uid().val < 10000)
		return false;

	/* 3. SELinux 尚未初始化阶段直接放行 */
	if (!selinux_initialized(state))
		return false;

	sid = current_sid();
	if (sid == SECSID_NULL)
		return false;

	/* 4. 在 RCU 读保护下根据 caller 的 SID 解析其 SELinux domain 类型名 */
	rcu_read_lock();
	policy = rcu_dereference(state->policy);
	if (!policy) {
		rcu_read_unlock();
		return false;
	}

	sidtab = policy->sidtab;
	ctx = sidtab_search(sidtab, sid);
	if (!ctx || !ctx->type || ctx->type > policy->policydb.p_types.nprim) {
		rcu_read_unlock();
		return false;
	}

	type_name = sym_name(&policy->policydb, SYM_TYPES, ctx->type - 1);
	if (type_name) {
		/* 仅当调用者处于 app_zygote 或 isolated_app 域时判定为不可信探测者 */
		if (!strcmp(type_name, "app_zygote") ||
		    !strcmp(type_name, "isolated_app")) {
			rcu_read_unlock();
			return true;
		}
	}
	rcu_read_unlock();
	return false;
}
#endif // #ifdef CONFIG_KSU_SUSFS
```

**调用点调整（先判敏感字串，短路保障零开销）**：
```c
#ifdef CONFIG_KSU_SUSFS
	if (susfs_is_sensitive_root_context(scontext2) && susfs_is_untrusted_caller(state)) {
		kfree(scontext2);
		return -EINVAL;
	}
#endif
```

---

## 3. 请 Codex 审查的核心检查清单 (Review Checklist)

请重点从以下四个维度对该修改进行 Review：

1. **KernelSU 提权完整性与误伤排查**：
   - 普通 App 申请 su 时，进程处于 `u:r:untrusted_app:s0`（或 `untrusted_app_29` 等），`type_name` 不等于 `app_zygote`，`susfs_is_untrusted_caller` 是否确保返回 `false`？
   - KernelSU Manager 应用本身（UID $\ge$ 10000）是否会被误伤？
   - 早期 init/zygote/adb 提权阶段是否有任何隐性路径被误拦？

2. **SELinux 探测阻断的完备性**：
   - DirtySepolicy PoC 与各类商用检测（如春秋、Duck Detector）通过 `app_zygote` 发起的 context 解析是否能稳定收到 `-EINVAL`？
   - 是否还需要防范除 `app_zygote` 和 `isolated_app` 之外的其它探测宿主域？（注：AOSP 官方 sepolicy 中，`untrusted_app` 无 `security compute_av` 权限，尝试直连 `/sys/fs/selinux/` 会被 neverallow 规则阻断）。

3. **内核安全性与并发（Concurrency & Safety）**：
   - `rcu_read_lock()` / `rcu_read_unlock()` 成对性检查；
   - `sidtab_search(sidtab, sid)` 在 RCU 下读访问的安全性；
   - 边界校验：`ctx->type > policy->policydb.p_types.nprim` 防越界；
   - `sym_name` 获取类型字符串的生命周期与内存安全性。

4. **性能评估**：
   - 先执行 `susfs_is_sensitive_root_context(scontext2)`，绝大多数普通 Context 查询是否实现完全短路？

---

## 4. 关键文件路径索引

- 补丁源码文件：
  [`patches/selinux-app-zygote-oracle-hide.patch`](file:///home/bear/Documents/projects/pdx234/a16_sony_sm8550_SukiSU_SUSFS/patches/selinux-app-zygote-oracle-hide.patch)
- 内核修改文件：
  [`work/kernel/security/selinux/ss/services.c`](file:///home/bear/Documents/projects/pdx234/a16_sony_sm8550_SukiSU_SUSFS/work/kernel/security/selinux/ss/services.c#L70-L150)
- 构建脚本：
  [`scripts/build-kernel.sh`](file:///home/bear/Documents/projects/pdx234/a16_sony_sm8550_SukiSU_SUSFS/scripts/build-kernel.sh)
- 产物输出路径：
  [`dist/AnyKernel3-pdx234-bakasu.zip`](file:///home/bear/Documents/projects/pdx234/a16_sony_sm8550_SukiSU_SUSFS/dist/AnyKernel3-pdx234-bakasu.zip)
