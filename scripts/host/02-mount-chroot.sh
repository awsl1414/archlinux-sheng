#!/usr/bin/env bash
# 02-mount-chroot.sh —— 挂载虚拟文件系统并准备 chroot 环境
#
# 与 ubuntu-sheng 的 02-mount-chroot.sh 对应，差异：
#   * 设备包从 /tmp/debs（.deb）改为 /tmp/pkgs（.pkg.tar.*）
#   * 不拷贝「解包设备 deb」之类的东西：Arch 侧全部设备包都是本地构建的 pacman 包
#
# 与上游一致：bind /dev、/dev/pts、proc、sysfs，并借用宿主 resolv.conf
# （收尾阶段会删除）。额外把仓库脚本与编译好的包拷进镜像，
# 让后续步骤用 `chroot` 执行镜像内脚本，而不是在宿主上拼超长命令行。
#
# 说明：runner 是原生 arm64，镜像内是 aarch64 的 Arch，因此这是原生 chroot，
# 不需要 qemu-user-static / binfmt_misc（脚本里也不需要 qemu 存在性检查）。
#
# 用法: sudo scripts/host/02-mount-chroot.sh [挂载点] [要拷入镜像的 payload 目录...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

MOUNT="${1:-/mnt/rootfs}"
shift || true
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

[[ -d "$MOUNT" ]] || die "挂载点不存在: $MOUNT"

# 挂载点目录必须存在：ALARM 的 tarball 自带 /dev /proc /sys，但覆盖安装时
# 也可能缺其中几个（实测报 mount: /mnt/rootfs/dev: mount point does not exist）
# 因此先统一补齐目录与权限。
for d in dev dev/pts dev/shm proc sys run tmp var/tmp root mnt home srv opt; do
  install -d "$MOUNT/$d"
done
chmod 1777 "$MOUNT/tmp" "$MOUNT/var/tmp" "$MOUNT/dev/shm" 2>/dev/null || true

mount --bind /dev      "$MOUNT/dev"
mount --bind /dev/pts  "$MOUNT/dev/pts"
mount -t proc  proc    "$MOUNT/proc"
mount -t sysfs sys     "$MOUNT/sys"
# ALARM 的根文件系统里 /etc/resolv.conf 很可能是指向 /run/systemd/resolve/stub-resolv.conf
# 的软链，而 chroot 里 /run 是空的；直接 `cp -f` 会跟随软链写到不存在的目录并失败 ——
# 在 set -e 下会终止引导之后的所有步骤。因此先删再装（与 ubuntu-sheng 的 02 保持一致）。
rm -f "$MOUNT/etc/resolv.conf"
install -m644 /etc/resolv.conf "$MOUNT/etc/resolv.conf"

# 构建脚本入镜像（/root/sheng-build）
install -d "$MOUNT/root/sheng-build"
cp -a "$REPO_ROOT/scripts/common"    "$MOUNT/root/sheng-build/"
cp -a "$REPO_ROOT/scripts/in-chroot" "$MOUNT/root/sheng-build/"
cp -a "$REPO_ROOT/scripts/lists"     "$MOUNT/root/sheng-build/"
chmod -R 755 "$MOUNT/root/sheng-build"

# 设备包 .pkg.tar.* 入镜像 /tmp/pkgs
if [[ -d "$REPO_ROOT/pkgs" ]]; then
  install -d "$MOUNT/tmp/pkgs"
  cp -a "$REPO_ROOT/pkgs/." "$MOUNT/tmp/pkgs/"
  log "已拷入 $(find "$MOUNT/tmp/pkgs" -name '*.pkg.tar.*' | wc -l) 个 pacman 包到 /tmp/pkgs"
fi

# 其余 payload（boot.img / Image.gz-dtb_sheng 等）
for extra in "$@"; do
  [[ -e "$extra" ]] || { warn "payload 不存在，跳过: $extra"; continue; }
  cp -a "$extra" "$MOUNT/root/sheng-build/"
done

log "chroot 环境就绪: $MOUNT"
