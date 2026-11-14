#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/configs/sources.env"
WORK=${WORK:-"$ROOT/work"}
KERNEL="$WORK/kernel"
ENABLE_ZRAM=${ENABLE_ZRAM:-true}
ENABLE_LZ4=${ENABLE_LZ4:-true}
export PATH="${CLANG_DIR:-$ROOT/clang}/bin:$PATH"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" "$ROOT/dist"
export KBUILD_BUILD_USER=bincat233 KBUILD_BUILD_HOST=github-actions
export KBUILD_BUILD_TIMESTAMP='Sun Nov 8 00:00:00 UTC 2026'
export KBUILD_BUILD_VERSION=1
args=(O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=
  KBUILD_MODPOST_WARN=1
  CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  "-j${BUILD_JOBS:-2}" "LTO_JOBS=${LTO_JOBS:-2}")
clang --version > "$ROOT/dist/compiler.txt"
make -C "$KERNEL" "${args[@]}" pdx234_defconfig
CFG="$KERNEL/out/.config"
cp "$CFG" "$ROOT/dist/kernel.config"
require_config() { grep -qxF "$1" "$CFG" || { echo "Required config missing: $1" >&2; exit 1; }; }
for setting in CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_BBG=y CONFIG_MODVERSIONS=y \
  CONFIG_KSU_MULTI_MANAGER_SUPPORT=y CONFIG_MODULE_SIG_PROTECT=y \
  CONFIG_LRU_GEN_ENABLED=y CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER=y \
  CONFIG_NTFS3_FS=y CONFIG_EROFS_FS_ZIP_LZMA=y CONFIG_IP_SET=y CONFIG_TCP_CONG_WESTWOOD=y \
  CONFIG_TCP_CONG_BBR=y \
  CONFIG_NET_SCH_CAKE=y CONFIG_USER_NS=y CONFIG_PID_NS=y CONFIG_POSIX_MQUEUE=y CONFIG_IPC_NS=y CONFIG_UTS_NS=y \
  CONFIG_TMPFS=y CONFIG_TMPFS_POSIX_ACL=y CONFIG_TMPFS_XATTR=y CONFIG_TMPFS_INODE64=y \
  CONFIG_CPU_FREQ_GOV_ONDEMAND=y; do
  require_config "$setting"
done
if [[ $ENABLE_ZRAM == true ]]; then
  for setting in CONFIG_ZRAM=y CONFIG_ZSMALLOC=y CONFIG_CRYPTO_LZ4KD=y \
    CONFIG_ZRAM_DEF_COMP_LZ4KD=y 'CONFIG_ZRAM_DEF_COMP="lz4kd"'; do require_config "$setting"; done
else
  require_config CONFIG_ZRAM=m
  require_config CONFIG_ZSMALLOC=m
fi
# Keep ROM version checks compatible; matching this alone does not prove symbol ABI.
make -s -C "$KERNEL" "${args[@]}" kernelrelease > "$ROOT/dist/kernelrelease.txt"
[[ $(cat "$ROOT/dist/kernelrelease.txt") == "$STOCK_KERNEL_RELEASE" ]] || {
  echo 'Kernel release differs from the target ROM' >&2; exit 1;
}
if [[ ${CONFIG_ONLY:-false} == true ]]; then
  echo 'Configuration and kernel release checks passed.'
  exit 0
fi
make -C "$KERNEL" "${args[@]}" prepare
make -C "$KERNEL" "${args[@]}" all
cp "$KERNEL/out/arch/arm64/boot/Image" "$ROOT/dist/Image-pdx234"
cp "$KERNEL/out/Module.symvers" "$ROOT/dist/Module.symvers"
cp "$KERNEL/out/System.map" "$ROOT/dist/System.map"
# Image must fit the stock boot partition alongside its existing header/signature.
[[ $(stat -c %s "$ROOT/dist/Image-pdx234") -lt 100000000 ]]
# Keep newly built zram modules for inspection when building the stock-compression variant.
find "$KERNEL/out" -name '*.ko' -print > "$ROOT/dist/built-modules.txt"
if [[ ! -d "$WORK/anykernel/.git" ]] || [[ $(git -C "$WORK/anykernel" rev-parse HEAD 2>/dev/null) != "$AK3_SHA" ]]; then
  rm -rf "$WORK/anykernel"
  git init -q "$WORK/anykernel"
  git -C "$WORK/anykernel" remote add origin "$AK3_REPO"
  git -C "$WORK/anykernel" fetch --depth=1 origin "$AK3_SHA"
  git -C "$WORK/anykernel" checkout --detach FETCH_HEAD
fi
git -C "$WORK/anykernel" checkout -f
[[ $(git -C "$WORK/anykernel" rev-parse HEAD) == "$AK3_SHA" ]]
cp "$ROOT/dist/Image-pdx234" "$WORK/anykernel/Image"
python3 - "$WORK/anykernel/anykernel.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
for old,new in [('kernel.string=Wild Kernels by TheWildJames aka Morgan Weedman',
                 'kernel.string=pdx234 LineageOS 24 BakaSU SUSFS'),
                ('do.devicecheck=0','do.devicecheck=1'),('device.name1=','device.name1=pdx234'),
                ('device.name2=','device.name2=XQ-DQ72')]:
    assert s.count(old)==1, old
    s=s.replace(old,new)
p.write_text(s)
PY
(cd "$WORK/anykernel" && zip -r9 "$ROOT/dist/AnyKernel3-pdx234-bakasu.zip" . \
  -x '.git/*' '.github/*' README.md '*placeholder')
(cd "$ROOT/dist" && sha256sum Image-pdx234 AnyKernel3-pdx234-bakasu.zip kernel.config \
  sources.env options.env Module.symvers > SHA256SUMS)
