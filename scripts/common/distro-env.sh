#!/usr/bin/env bash
# 公共环境：Arch 侧常量 + 底包选择 + 日志工具
# 被 host/ 与 in-chroot/ 下的脚本共同 source。
#
# 与 ubuntu-sheng 的差异：Arch 是滚动发行版，没有「版本 ↔ suite 代号」映射，
# 因此这里不再有 DISTRO_SERIES / DISTRO_SUITE，改为集中维护底包地址、镜像地址
# 与架构常量，避免散落在 workflow YAML 里。
#
# 底包：目前只支持 alarm（Arch Linux ARM 官方滚动 tarball + core/extra/alarm 仓库）。
# holo-core 底包在 e960212 里移除了相关脚本，ROOTFS_BASE=holo-core 会直接报错。

log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# 镜像内由 workflow 写入的构建参数（/root/build.env）；宿主阶段不存在该文件
if [[ -f /root/build.env ]]; then
  set -a
  # shellcheck source=/dev/null
  . /root/build.env
  set +a
fi

# ---------------------------------------------------------------------------
# 架构
# ---------------------------------------------------------------------------
export ARCH="${ARCH:-aarch64}"

# ---------------------------------------------------------------------------
# 底包选择
# ---------------------------------------------------------------------------
export ROOTFS_BASE="${ROOTFS_BASE:-alarm}"
case "$ROOTFS_BASE" in
  alarm)             export ROOTFS_BASE="alarm" ;;
  holo|holo-core)
    # holo-core 底包在 e960212 里被移除：holo-lib.sh、01b-bootstrap-holo.sh、
    # scripts/lists-holo/ 都已删除。保留这个分支只会让构建跑到一半才因为
    # "找不到 holo-lib.sh" 或 "包列表不存在" 失败，不如在这里说清楚。
    die "rootfs_base=holo-core 已不支持：相关脚本（scripts/host/holo-lib.sh、01b-bootstrap-holo.sh、scripts/lists-holo/）已删除。请使用 rootfs_base=alarm" ;;
  *) die "不支持的 ROOTFS_BASE: $ROOTFS_BASE（可选 alarm）" ;;
esac

# ---------------------------------------------------------------------------
# Arch Linux ARM（滚动）
# ---------------------------------------------------------------------------
export ALARM_TARBALL_URL="${ALARM_TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
# 包镜像：Server = $ALARM_MIRROR/$arch/$repo（写入镜像内 /etc/pacman.d/mirrorlist）
# 中国大陆可换用 https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm 等镜像
export ALARM_MIRROR="${ALARM_MIRROR:-http://mirror.archlinuxarm.org}"

# ---------------------------------------------------------------------------
# 宿主上可复用的构建 chroot（供 makepkg 使用，见 host/20-alarm-chroot.sh）
# ---------------------------------------------------------------------------
export ALARM_CHROOT="${ALARM_CHROOT:-/mnt/alarm}"
export BUILD_CHROOT="${BUILD_CHROOT:-$ALARM_CHROOT}"

# chroot 内可选的 AUR 源码包（官方仓库里没有的包）
# 语法：<包名>|<git 仓库 URL>，多个用空格分隔。默认留空。
export ALARM_AUR_SOURCE_PKGS="${ALARM_AUR_SOURCE_PKGS:-}"

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "需要 root 权限（请用 sudo 调用本脚本）"
}
