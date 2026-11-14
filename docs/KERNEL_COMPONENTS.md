# 内核组件和补丁清单

本清单描述此仓库的构建配置，不代表手机当前加载状态。目标内核源码、依赖和精确提交以 [`configs/sources.env`](../configs/sources.env) 为准；实际选项和最终配置以对应构建产物的 `options.env`、`kernel.config` 为准。

## 基础组件

| 组件 | 来源和固定版本 | 接入方式 |
| --- | --- | --- |
| Sony SM8550 内核 | [LineageOS](https://github.com/LineageOS/android_kernel_sony_sm8550)，`db39b3851f98` | 内核源码基线，目标为 pdx234 / XQ-DQ72。 |
| BakaSU | [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU)，`548d1dda060c` | 通过 `drivers/kernelsu` 接入；构建脚本要求 `CONFIG_KSU=y`，内建而非 `.ko`。 |
| SUSFS | [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)，`fe943d15ec6a`，v2.4.0 | 复制上游 `fs/` 和头文件，并应用上游 `50_add_susfs_in_gki-android13-5.15.patch`；`CONFIG_KSU_SUSFS=y`。 |
| Baseband-guard | [vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard)，`028ff7fd509e` | 作为 LSM 接入，要求 `CONFIG_BBG=y`；`BBG_BLOCK_BOOT` 和 `BBG_BLOCK_RECOVERY` 关闭。 |
| LZ4K / LZ4KD 与 ZRAM | [ShirkNeko/SukiSU_patch](https://github.com/ShirkNeko/SukiSU_patch)，`eec45788c9a1` | `ENABLE_ZRAM=true` 时复制实现并应用本地适配补丁；要求 ZRAM、ZSMALLOC、LZ4KD 内建，默认压缩算法为 LZ4KD。 |
| LZ4 1.10.0 | [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)，`735933d45095` | 仅 `ENABLE_LZ4=true` 时替换相关源码，并应用本地适配补丁。 |

`ENABLE_ZRAM=false` 时，构建检查要求 `CONFIG_ZRAM=m` 和 `CONFIG_ZSMALLOC=m`；这些是可加载内核模块，具体模块加载和兼容性仍取决于目标系统。KPM 未接入。BakaSU、SUSFS 与 Baseband-guard 不是上述独立 `.ko`。

## 本地补丁及应用顺序

补丁由 [`scripts/prepare-kernel.sh`](../scripts/prepare-kernel.sh) 依次应用；上游 SUSFS 主补丁先于下面的本地补丁。每次应用先检查再以零 fuzz 执行。

| 顺序 | 补丁 | 用途 | 条件 / 来源 |
| --- | --- | --- | --- |
| 1 | [`fix_priority_uid_filter_kconfig.patch`](../patches/fix_priority_uid_filter_kconfig.patch) | 为当前 BakaSU/SUSFS 组合补齐 Priority UID Filter 的 Kconfig。 | 始终应用；Kingo64 仓库有相同目的的补丁，此处适配固定 BakaSU。 |
| 2 | [`susfs-2.4.0-priority-uid-filter-unused-fix.patch`](../patches/susfs-2.4.0-priority-uid-filter-unused-fix.patch) | 对 Priority UID Filter 辅助函数加条件编译，修复未使用函数编译错误。 | 始终应用；本地兼容修复。 |
| 3 | [`silence-log-spam.patch`](../patches/silence-log-spam.patch) | 将两处 KernelSU umount 常规日志降级，并禁用 watchdog IRQ 统计输出。 | 始终应用；本地修改。watchdog 统计计算仍在，异常时也失去这部分输出。 |
| 4 | [`selinux-app-zygote-oracle-hide.patch`](../patches/selinux-app-zygote-oracle-hide.patch) | 为 app_zygote 的 context、权限和进程域切换查询接入 BakaSU 的备份策略路径。 | 始终应用；运行时依赖 `selinux_hide` 启用和备份策略可用。独立源码见 [`app_zygote_filter.c`](../kernel/selinux/app_zygote_filter.c)。 |
| 5 | [`lz4-1.10.0-5.15.patch`](../patches/lz4-1.10.0-5.15.patch) | 将 LZ4 1.10.0 实现适配到本内核调用点，含 F2FS 参数修正。 | 仅 `ENABLE_LZ4=true`；基于固定 zzh20188 源码及本地适配。 |
| 6 | [`lz4kd-5.15.211.patch`](../patches/lz4kd-5.15.211.patch) | 将 LZ4K/LZ4KD 接入压缩框架和 ZRAM 配置。 | 仅 `ENABLE_ZRAM=true`；基于固定 SukiSU_patch 的经筛选适配。 |
| 7 | [`zram-builtin-module-guard.patch`](../patches/zram-builtin-module-guard.patch) | 防止已内建的 ZRAM/ZSMALLOC 重复作为模块加载。 | 仅 `ENABLE_ZRAM=true`；本地兼容补丁。 |

## 配置与验证

GitHub Actions 的 `workflow_dispatch` 当前默认 `enable_zram=true`、`enable_lz4=true`；本地准备脚本分别默认 `ENABLE_ZRAM=true`、`ENABLE_LZ4=true`。实际运行可以覆盖这些值，不能仅凭默认值判断某个产物。

`dist/built-modules.txt` 是某次构建输出目录中的 `.ko` 路径清单，不是手机上实际加载的模块清单，也不保证每个 `.ko` 都进入刷机包。内建选项和 `CONFIG_*=m` 应以该次构建的 `kernel.config` 为准；设备实际加载情况需要在设备上单独核对。

补丁能够应用或生成不等于真机验证通过。特别是 SELinux 检测行为、提权和 ZRAM 模块兼容性，需要针对对应刷入产物验证。
