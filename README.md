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
- `enable_lz4=true`：默认启用额外的 LZ4 1.10.0 升级；可以独立关闭。
- 构建与下载写入 runner 磁盘，不建立 tmpfs。仅生成 Actions artifacts，不自动发布 Release。
- 管理器只获取与固定 BakaSU SHA 一致的成功构建，找不到就失败，不回退到任意最新版。

本地可调用 `scripts/prepare-kernel.sh` 和 `scripts/build-kernel.sh`。`WORK` 目录必须是新的；源代码准备拒绝复用已有目标目录。`CLANG_DIR` 指向解压的 Android Clang；默认是仓库 `clang/`。`CONFIG_ONLY=true` 仅生成并检查配置，不编译。

## 修改本地内核补丁

本地改动保存在 `patches/`；我们自行维护的 SELinux 过滤函数另有完整源码 `kernel/selinux/app_zygote_filter.c`。其他上游文件不在仓库复制，修改时通过临时 Git 工作区查看和编辑完整文件。

例如修改 SELinux 补丁：

```bash
# 首次为该补丁创建编辑工作区（不会覆盖已有工作区）。
scripts/update-patches.py create selinux-app-zygote-oracle-hide

# 编辑 work/patch-edit/selinux-app-zygote-oracle-hide/ 下的完整源码。
# 查看相对于上游的修改：
git -C work/patch-edit/selinux-app-zygote-oracle-hide diff

# 从工作区导出补丁。
scripts/update-patches.py export selinux-app-zygote-oracle-hide
```

其他补丁使用对应的文件名或不带 `.patch` 的名称。脚本依据 `configs/sources.env` 的固定版本构造补丁前基线，应用现有补丁并创建独立 Git 工作区；导出时用 `git diff` 生成补丁，重新应用并逐文件核对。需要已准备的 `work/kernel`、`work/susfs`；修改 LZ4 补丁还需要固定版本的 `work/lz4`。编辑工作区位于被忽略的 `work/`，不要直接提交它。

SELinux 的 `app_zygote_filter.c` 在创建工作区时从 `kernel/selinux/` 复制进去，导出时从工作区同步回仓库。准备构建时会检查独立源码与补丁一致。修改并导出后，重新准备内核源码才能应用新补丁；编辑工作区不会自动改变 `work/kernel`。

## 补丁审核

组件来源、内建与模块状态、补丁应用顺序见 [内核组件和补丁清单](docs/KERNEL_COMPONENTS.md)。


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
