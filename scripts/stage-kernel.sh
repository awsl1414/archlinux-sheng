#!/usr/bin/env bash
# stage-kernel.sh —— 用 sm8550-mainline 源码编译内核，并把产物铺成
# linux-xiaomi-sheng 的 custom PKGBUILD 所需的 stage/ 树
#
# 与上游 ianchb/debian-sheng 的 build-kernel 作业保持一致的编译设定
# （clang + LLVM=1 + ccache），因此产物与 Debian 版内核等价
#
# 用法: scripts/stage-kernel.sh <kernel_src_dir> <sm8550.config> <stage_dir>
#
# 产出:
#   <stage>/usr/lib/modules/<kver>/...         模块（makepkg 由此推导 pkgver）
#   <stage>/boot/Image.gz-dtb_sheng            内核+DTB（供 mkbootimg 生成 boot.img）
#   <stage>/boot/vmlinuz-linux-xiaomi-sheng    Arch 惯例命名（供 mkinitcpio / 参考）
#   <stage>/boot/config-<kver>  System.map-<kver>
set -euo pipefail

SRC="${1:?需要内核源码目录}"
CFG="${2:?需要内核 config 文件}"
STAGE="${3:?需要 stage 目录}"
JOBS="${JOBS:-$(nproc)}"

[[ -d "$SRC" ]] || { echo "[stage-kernel] 找不到源码目录: $SRC" >&2; exit 1; }
[[ -f "$CFG" ]] || { echo "[stage-kernel] 找不到 config: $CFG" >&2; exit 1; }

# ccache（存在则启用）
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  export PATH="/usr/lib/ccache:$PATH"
  export CC="ccache clang"
  export CXX="ccache clang++"
  ccache --set-config=max_size=10G >/dev/null 2>&1 || true
  echo "[stage-kernel] ccache 已启用: $CCACHE_DIR"
else
  export CC=clang
  export CXX=clang++
fi

install -Dm644 "$CFG" "$SRC/.config"

# 版本号必须与上游 release 的 deb 一致（7.3.0-sm8550-00104-g1fb56e66091e），
# 否则 custom_build 产出的模块与 prebuilt 的 boot.img 内核 vermagic 不匹配。
# 上游的 `7.3.0` 是轻量 tag 且正好指向 HEAD，setlocalversion 只认 annotated tag，
# 用 --depth 1 克隆时又拿不到提交计数，算出来会缺 `00104`。
# 所以钉住完整版本号：LOCALVERSION 写死，关掉 AUTO。
if [[ -n "${KERNEL_LOCALVERSION:-}" ]]; then
  echo "[stage-kernel] 钉住 LOCALVERSION=$KERNEL_LOCALVERSION"
  sed -i -E 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-'"${KERNEL_LOCALVERSION#-}"'"|;
             s|^CONFIG_LOCALVERSION_AUTO=y|# CONFIG_LOCALVERSION_AUTO is not set|' "$SRC/.config"
  rm -f "$SRC/include/config/auto.conf" "$SRC/include/config/auto.conf.cmd" \
        "$SRC/include/generated/autoconf.h"
  make -C "$SRC" ARCH=arm64 LLVM=1 syncconfig >/dev/null
fi

echo "[stage-kernel] 编译内核 (JOBS=$JOBS)"
make -C "$SRC" -j"$JOBS" ARCH=arm64 LLVM=1

KVER="$(make -C "$SRC" -s ARCH=arm64 LLVM=1 kernelrelease)"
[[ -n "$KVER" ]] || { echo "[stage-kernel] 无法获取 kernelrelease" >&2; exit 1; }
echo "[stage-kernel] 内核版本: $KVER"

echo "[stage-kernel] 安装模块 -> $STAGE/usr/lib/modules/$KVER"
make -C "$SRC" -j"$JOBS" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$STAGE/usr" modules_install
rm -rf "$STAGE/usr/lib/modules/$KVER/build" "$STAGE/usr/lib/modules/$KVER/source"

install -d "$STAGE/boot"
cat "$SRC/arch/arm64/boot/Image.gz" \
    "$SRC/arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb" \
    > "$STAGE/boot/Image.gz-dtb_sheng"
install -Dm644 "$SRC/arch/arm64/boot/Image.gz" "$STAGE/boot/vmlinuz-linux-xiaomi-sheng"
install -Dm644 "$SRC/.config"                  "$STAGE/boot/config-$KVER"
install -Dm644 "$SRC/System.map"               "$STAGE/boot/System.map-$KVER"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "kernel_version=$KVER"
    echo "kernel_image=$STAGE/boot/Image.gz-dtb_sheng"
  } >> "$GITHUB_OUTPUT"
fi

echo "[stage-kernel] 完成"
du -h "$STAGE/boot/Image.gz-dtb_sheng" | sed 's/^/    /'
