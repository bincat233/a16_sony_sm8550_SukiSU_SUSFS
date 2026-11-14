#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/configs/sources.env"
WORK=${WORK:-"$ROOT/work"}
ENABLE_ZRAM=${ENABLE_ZRAM:-true}
ENABLE_LZ4=${ENABLE_LZ4:-true}
USE_THINLTO=${USE_THINLTO:-false}
for value in "$ENABLE_ZRAM" "$ENABLE_LZ4" "$USE_THINLTO"; do
  [[ $value == true || $value == false ]] || { echo "Invalid boolean: $value" >&2; exit 1; }
done
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
KERNEL="$WORK/kernel"

fetch_source() {
  local repo=$1 sha=$2 dest=$3 full=${4:-false}
  # Refuse reuse of patched sources; configuration must start from a fresh checkout.
  [[ ! -e $dest ]] || { echo "Source destination already exists: $dest" >&2; return 1; }
  if [[ $full == true ]]; then
    git clone --no-checkout "$repo" "$dest"
    git -C "$dest" checkout --detach "$sha"
  else
    git init -q "$dest"
    git -C "$dest" remote add origin "$repo"
    git -C "$dest" fetch --depth=1 origin "$sha"
    git -C "$dest" checkout --detach FETCH_HEAD
  fi
  [[ $(git -C "$dest" rev-parse HEAD) == "$sha" ]]
}
apply_patch() {
  local file=$1
  patch --dry-run --batch --forward --fuzz=0 -p1 -d "$KERNEL" < "$file"
  patch --batch --forward --fuzz=0 -p1 -d "$KERNEL" < "$file"
}

fetch_source "$KERNEL_REPO" "$KERNEL_SHA" "$KERNEL"
# Full history preserves BakaSU's commit-count version code and offline tag lookup.
fetch_source "$KSU_REPO" "$KSU_SHA" "$KERNEL/KernelSU" true
fetch_source "$SUSFS_REPO" "$SUSFS_SHA" "$WORK/susfs"
fetch_source "$BBG_REPO" "$BBG_SHA" "$KERNEL/Baseband-guard"

# Integrate checked-out sources directly: do not execute a moving setup script.
ln -s ../KernelSU/kernel "$KERNEL/drivers/kernelsu"
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL/drivers/Makefile"
printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL/drivers/Kconfig"
ln -s ../Baseband-guard "$KERNEL/security/baseband-guard"
printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> "$KERNEL/security/Makefile"
printf '\nsource "security/baseband-guard/Kconfig"\n' >> "$KERNEL/security/Kconfig"
# BBG's pinned setup explicitly skips extra SELinux changes on modern DEFINE_LSM kernels.
grep -q '#define DEFINE_LSM(lsm)' "$KERNEL/include/linux/lsm_hooks.h"

cp "$WORK/susfs/kernel_patches/fs/"* "$KERNEL/fs/"
cp "$WORK/susfs/kernel_patches/include/linux/"* "$KERNEL/include/linux/"
apply_patch "$WORK/susfs/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
# Restore missing KSU_SUSFS_PRIORITY_UID_FILTER to KernelSU Kconfig (SUSFS 2.4.0 feature)
apply_patch "$ROOT/patches/fix_priority_uid_filter_kconfig.patch"
# Guard unused helpers as fallback when CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER is disabled
apply_patch "$ROOT/patches/susfs-2.4.0-priority-uid-filter-unused-fix.patch"
apply_patch "$ROOT/patches/silence-log-spam.patch"
apply_patch "$ROOT/patches/selinux-app-zygote-oracle-hide.patch"

if [[ $ENABLE_LZ4 == true ]]; then
  fetch_source "$LZ4_REPO" "$LZ4_SHA" "$WORK/lz4"
  # Replace the old implementation, including its Makefile, as required by this upgrade.
  rm "$KERNEL/lib/lz4/lz4_compress.c" "$KERNEL/lib/lz4/lz4_decompress.c" \
     "$KERNEL/lib/lz4/lz4defs.h" "$KERNEL/lib/lz4/lz4hc_compress.c"
  cp -r "$WORK/lz4/zram/lz4/." "$KERNEL/lib/lz4/"
  cp -r "$WORK/lz4/zram/include/linux/." "$KERNEL/include/linux/"
  apply_patch "$ROOT/patches/lz4-1.10.0-5.15.patch"
fi
if [[ $ENABLE_ZRAM == true ]]; then
  fetch_source "$ZRAM_REPO" "$ZRAM_SHA" "$WORK/zram"
  for part in include/linux lib crypto; do
    cp -r "$WORK/zram/other/zram/lz4k/$part/." "$KERNEL/$part/"
  done
  # Reviewed subset: exclude upstream's unrelated module-blacklist edits.
  apply_patch "$ROOT/patches/lz4kd-5.15.211.patch"
  apply_patch "$ROOT/patches/zram-builtin-module-guard.patch"
fi
if find "$KERNEL" -type f -name '*.rej' -print -quit | grep -q .; then
  echo 'Rejected patch hunks found' >&2; exit 1
fi
printf '%s  %s\n' "$STOCK_CONFIG_SHA256" "$ROOT/pdx234_defconfig" | sha256sum -c -
cp "$ROOT/pdx234_defconfig" "$KERNEL/arch/arm64/configs/pdx234_defconfig"
CFG="$KERNEL/arch/arm64/configs/pdx234_defconfig"
CONFIG="$KERNEL/scripts/config"
"$CONFIG" --file "$CFG" -e KSU -e KSU_SUSFS -d KSU_TRACEPOINT_HOOK -d KSU_MANUAL_HOOK \
  -e KSU_MULTI_MANAGER_SUPPORT -e BBG -d BBG_BLOCK_BOOT -d BBG_BLOCK_RECOVERY \
  --set-str LSM 'landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard' \
  -d LOCALVERSION_AUTO --set-str LOCALVERSION '-gdb39b3851f98'
"$CONFIG" --file "$CFG" -e TMPFS_XATTR -e TMPFS_POSIX_ACL -e IP_NF_TARGET_TTL \
  -e IP6_NF_TARGET_HL -e IP6_NF_MATCH_HL -e TCP_CONG_ADVANCED \
  -e TCP_CONG_BBR -e NET_SCH_FQ -e DEFAULT_BBR \
  -e LRU_GEN -e LRU_GEN_ENABLED \
  -e KSU_SUSFS_PRIORITY_UID_FILTER \
  -e NTFS3_FS -e NTFS3_FS_POSIX_ACL \
  -e EROFS_FS_ZIP_LZMA \
  -e IP_SET -e IP_SET_HASH_IP -e IP_SET_HASH_NET \
  -e TCP_CONG_WESTWOOD -e TCP_CONG_BBR \
  -e NET_SCH_CAKE -e USER_NS -e PID_NS -e POSIX_MQUEUE -e IPC_NS -e UTS_NS -e CPU_FREQ_GOV_ONDEMAND
if [[ $USE_THINLTO == true ]]; then
  "$CONFIG" --file "$CFG" -d LTO_CLANG_FULL -e LTO_CLANG_THIN
fi
# Existing SUSFS feature defaults are taken from pinned BakaSU, not stale symbol names.
if [[ $ENABLE_ZRAM == true ]]; then
  "$CONFIG" --file "$CFG" -e ZSMALLOC -e ZRAM -e CRYPTO_LZ4K -e CRYPTO_LZ4KD \
    -d ZRAM_DEF_COMP_LZORLE -e ZRAM_DEF_COMP_LZ4KD
fi
mkdir -p "$ROOT/dist"
cp "$ROOT/configs/sources.env" "$ROOT/dist/sources.env"
printf 'ENABLE_ZRAM=%s\nENABLE_LZ4=%s\nUSE_THINLTO=%s\n' "$ENABLE_ZRAM" "$ENABLE_LZ4" "$USE_THINLTO" > "$ROOT/dist/options.env"
git -C "$KERNEL" diff --binary > "$ROOT/dist/applied-kernel.diff"
# Pin input records; final .config is saved by build-kernel.sh after Kconfig resolves it.
echo 'Kernel preparation completed without rejected hunks.'
