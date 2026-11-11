#!/usr/bin/env bash
# 04-finalize-image.sh —— 卸载镜像 → 校验 → 收缩 → 固定 UUID
#
# 与 ubuntu-sheng 相同（本步骤与发行版无关，文件系统同样是 ext4）。
# 相对上游补齐：上游只 umount + tune2fs -U，产物永远是 10 GiB 稀疏文件
# （上传压缩率低、刷写慢）。这里增加 e2fsck + resize2fs -M 收缩，
# 首启再由 fstab 的 x-systemd.growfs 扩到分区实际大小。
#
# 环境变量：
#   FS_UUID       要写入的文件系统 UUID（默认沿用上游固定值）
#   SHRINK_IMAGE  true/false，默认 true
#
# 用法: sudo scripts/host/04-finalize-image.sh [镜像] [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

IMAGE="${1:-rootfs.img}"
MOUNT="${2:-/mnt/rootfs}"
FS_UUID="${FS_UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"
SHRINK_IMAGE="${SHRINK_IMAGE:-true}"

# ---------------------------------------------------------------------------
# 卸载
#   硬失败。实测镜像仍挂载时 umount 失败后，后面的 e2fsck / resize2fs / tune2fs
#   会全部静默失败，脚本一路"成功"退出，产物保持 10 GiB —— 这个脚本的产出就是
#   收缩好的镜像，卸载失败就等于失败。
#   03-umount-chroot.sh 只卸 chroot 的虚拟文件系统，镜像本身在这里卸。
# ---------------------------------------------------------------------------
# 两级卸载：先递归（清掉 chroot 阶段可能残留的子挂载），再直接卸本身。
# 只留 -R 会失败：递归卸载在某些内核状态下会因残留的 mount 记录报 busy，
# 而普通的 umount 反而能成功 —— 2026-11-11 那次构建就是这么挂的。
umount_out="$(
  umount -R "$MOUNT" 2>&1 || umount "$MOUNT" 2>&1
)" || true
if mountpoint -q "$MOUNT"; then
  # 失败时把 umount 报错、挂载点归属、占用进程全打出来。
  # 没有这些信息，下一轮失败还是只能看到"仍在挂载"。
  [[ -n "$umount_out" ]] && printf '%s\n' "$umount_out" | sed 's/^/    /' >&2
  echo "  $MOUNT 的挂载信息：" >&2
  awk -v m="$MOUNT" 'index($5, m)==1 {print "    "$5" ("$9")"}' /proc/self/mountinfo >&2
  echo "  占用 $MOUNT 的进程：" >&2
  fuser -vm "$MOUNT" 2>&1 | sed 's/^/    /' >&2 || echo "    （fuser 不可用或无进程）" >&2
  die "无法卸载 $MOUNT：镜像仍在挂载"
fi
sync
log "镜像已卸载"

# e2fsck 返回 0 = 干净，1 = 已修复（可接受），>=2 = 无法修复
# 输出留一份：失败时 die 之前把它打出来，否则下一轮构建失败无从排查
FE_OUT="$(mktemp)"
rc=0
e2fsck -fy "$IMAGE" >"$FE_OUT" 2>&1 || rc=$?
case "$rc" in
  0) : ;;
  1) warn "e2fsck 修复了文件系统错误（镜像仍可用）" ;;
  *)
    sed 's/^/    /' "$FE_OUT" | tail -20 >&2
    rm -f "$FE_OUT"
    die "e2fsck 失败（退出码 $rc）：镜像文件系统已损坏，不可刷写" ;;
esac
rm -f "$FE_OUT"

if [[ "$SHRINK_IMAGE" == "true" ]]; then
  before="$(du -h --apparent-size "$IMAGE" | cut -f1)"
  resize2fs -M "$IMAGE" || die "resize2fs -M 失败（镜像仍是 $before，不能作为产物上传）"

  # resize2fs -M 只缩文件系统，不缩文件本身；必须自己 truncate
  blocks="$(dumpe2fs -h "$IMAGE" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2; exit}')"
  bsize="$(dumpe2fs -h "$IMAGE" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2; exit}')"
  [[ -n "$blocks" && -n "$bsize" ]] || die "无法从 dumpe2fs 读取块数/块大小"
  truncate -s "$((blocks * bsize))" "$IMAGE"

  SHRINK_RESULT="成功（$before → $(du -h --apparent-size "$IMAGE" | cut -f1)）"
  log "镜像已收缩: $SHRINK_RESULT"
else
  SHRINK_RESULT="已跳过（shrink_image=false）"
fi

tune2fs -U "$FS_UUID" "$IMAGE" || die "设置文件系统 UUID 失败"

log "最终产物:"
ls -lh "$IMAGE" | sed 's/^/    /'
du -h --apparent-size "$IMAGE" | sed 's/^/    实际大小(逻辑): /'

# 把「是否真的收缩成功」写进 step summary：这一步全部是 best-effort，
# 不显式报告的话，产物保持 10 GiB 也不会有人注意到。
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### rootfs.img"
    echo ""
    echo "| 项 | 值 |"
    echo "|---|---|"
    echo "| 最终大小（逻辑） | $(du -h --apparent-size "$IMAGE" | cut -f1) |"
    echo "| 文件系统 UUID | $(tune2fs -l "$IMAGE" 2>/dev/null | awk -F': ' '/Filesystem UUID/{print $2}') |"
    echo "| shrink_image | $SHRINK_IMAGE |"
    echo "| 收缩结果 | $SHRINK_RESULT |"
  } >> "$GITHUB_STEP_SUMMARY"
fi
