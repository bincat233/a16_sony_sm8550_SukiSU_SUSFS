# Xperia 1 V：LineageOS 24 + BakaSU / SUSFS

个人维护分支，从 [spacealtctrl 原项目](https://github.com/spacealtctrl/a16_sony_sm8550_SukiSU_SUSFS) 的 main `976f8cdf` 重新开始。没有合并 Kingo64 dev。

当前目标仅为 **pdx234 / XQ-DQ72**，官方 `lineage-24.0-20261108-nightly-pdx234`（Android 17）。这是内核与 root 组件构建，不是完整 ROM。

## 固定组件

完整提交见 [configs/sources.env](configs/sources.env)：

| 组件 | 固定来源 |
|---|---|
| 内核 | LineageOS lineage-24.0，`db39b3851f98`，与目标 ROM 构建清单一致 |
| 内核配置 | 从同版官方 boot.img 的 IKCONFIG 提取；SHA256 锁定 |
| BakaSU（原 ReSukiSU） | `548d1dda060c`，builtin + SUSFS inline hook |
| SUSFS | simonpunk `fe943d15ec6a`，v2.4.0 |
| Baseband-guard | `028ff7fd509e`；boot/recovery 写保护关闭 |
| 编译器 | Android Clang r596125，下载来源提交固定 |
| AnyKernel3 | WildKernels gki-2.0 `e1e9dce98430`；启用机型检查 |

KPM 不在当前 BakaSU 中，构建不提供 KPM 修补。保留 BBR、TTL/HL 和 tmpfs 扩展配置。

## 构建

在 `lineage-24-maintenance` 分支手动运行 **Build pdx234 LineageOS 24**：

- `enable_zram=true`：默认启用 LZ4KD，并将 ZRAM/ZSMALLOC 内建。
- `enable_lz4=false`：额外的 LZ4 1.10.0 升级独立保留，默认关闭；验证时可单独开启。
- 构建与下载写入 runner 磁盘，不建立 tmpfs。仅生成 Actions artifacts，不自动发布 Release。
- 管理器只获取与固定 BakaSU SHA 一致的成功构建，找不到就失败，不回退到任意最新版。

本地可调用 `scripts/prepare-kernel.sh` 和 `scripts/build-kernel.sh`。`WORK` 目录必须是新的；源代码准备拒绝复用已有目标目录。`CLANG_DIR` 指向解压的 Android Clang；默认是仓库 `clang/`。`CONFIG_ONLY=true` 仅生成并检查配置，不编译。

## 修改本地内核补丁

本地补丁的可编辑源码在 `kernel/patches/<补丁名>/`，目录保留目标内核的文件路径。这里保存的是每个本地补丁修改后的完整文件，方便直接用编辑器阅读；固定版本上游代码和上游 SUSFS 主补丁仍由准备脚本获取，不在此单独维护。

例如 SELinux 的过滤函数在 `kernel/patches/selinux-app-zygote-oracle-hide/security/selinux/ss/app_zygote_filter.c`，查询接线在同目录下的 `hooks.c` 和 `selinuxfs.c`。其他目录分别对应同名的 `.patch`，其中包含 C、Kconfig 或 Makefile 等实际修改文件。

修改源码后，确保 `work/kernel`、`work/susfs` 等已准备并与 `configs/sources.env` 的固定版本一致，然后执行：

```bash
# 只更新一个补丁；省略参数可更新所有本地补丁。
scripts/update-patches.py selinux-app-zygote-oracle-hide
```

脚本从固定版本的内核、BakaSU、SUSFS 和 LZ4 构造补丁前的临时 Git 基线，再从可编辑源码生成 `git diff`，并检查生成的补丁能否重现源码。无需依赖 `work/kernel` 中是否应用了本地补丁；生成 LZ4 补丁时需要已有固定版本的 `work/lz4`。审查并同时提交源码和生成的补丁。准备内核时会比较补丁结果与可编辑源码，不一致时停止。

重新运行 `prepare-kernel.sh` 可应用新补丁。若要在当前工作区直接编译，需要把修改后的文件复制到 `work/kernel` 的对应位置；重新生成补丁不会自动覆盖工作区。

## 补丁审核

- 固定的 SUSFS 主补丁在目标 Sony 源码上零 fuzz 应用；Priority UID Filter 的 Kconfig 和未使用函数问题由本地补丁处理。
- 不执行移动分支的 setup.sh；直接接入已核对、已固定的 KSU/BBG 源码。
- `patch` 先 dry-run，再以零 fuzz 应用；拒绝 `.rej`。Shell 启用 pipefail，依赖逐个校验 SHA。
- `patches/lz4kd-5.15.211.patch` 来自固定的 SukiSU_patch，重新生成精确上下文，排除其 module.c 改动。
- `patches/zram-builtin-module-guard.patch` 单独阻止重复加载已内建的 zram/zsmalloc，保留原加载器错误返回，不引入其他机型的黑名单。
- LZ4 1.10.0 保留原来源 `735933d4` 的实现，修正原补丁 F2FS 非 NEON 分支中多余的第五个参数。
- 没有删除 Sony 的 show_pad 逻辑；当前 SUSFS 补丁无需此前的粗略替换。
- 原配置更新器已移除定时触发。当前构建使用锁定配置，不自动跟随其他 ROM 版本。

## 验证与刷写状态

补丁应用、Kconfig 解析、内核版本字符串检查已在本地通过。完整编译及设备测试以实际 Actions 结果和后续记录为准，不能把这些预检查视为已适配完成。

构建产物包括 Image、AnyKernel3 ZIP、匹配管理器、SHA256SUMS、最终 `.config`、`Module.symvers`、源码锁和完整日志。版本字符串对齐原 ROM `5.15.211-gdb39b3851f98`；这本身不保证模块符号 CRC 或运行时兼容。

LZ4KD 内建方案与 ROM 中原有 ZRAM 模块共存时，加载器会拒绝重复模块；刷写后需核对启动日志、ZRAM 是否创建及 `/sys/block/zram0/comp_algorithm`，Android 初始化可能重新选择算法。保留原 boot 以便回退。SUSFS 用户态模块也需与 v2.4.0 对齐，旧 v2.1.0-R28 尚未验证。

尚未将本分支产物刷入设备。原项目说明仍可从 Git 历史查看。
