#!/usr/bin/env bash
# 03-umount-chroot.sh —— 逆序卸载虚拟文件系统（即使前序步骤失败也要执行）
#
# 与 ubuntu-sheng 相同（本步骤与发行版无关）。
#
# 用法: sudo scripts/host/03-umount-chroot.sh [挂载点]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

MOUNT="${1:-/mnt/rootfs}"

# ---------------------------------------------------------------------------
# 杀掉 chroot 里残留的进程
#   chroot 阶段跑过 pacman-key / gpg，这些工具会留下常驻的 gpg-agent：
#   它的 cwd 或打开的 fd 仍在镜像内，导致 umount 报 "target is busy"。
#   2026-11-11 那次构建的失败就是这个（fuser 显示 root 2934 gpg-agent）。
#   只杀"可执行文件路径在 $MOUNT 内"的进程，不碰宿主自己的 gpg-agent。
# ---------------------------------------------------------------------------
stale=()
for pid in /proc/[0-9]*; do
  pid="${pid#/proc/}"
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
  root="$(readlink "/proc/$pid/root" 2>/dev/null)" || continue
  case "$exe$root" in
    "$MOUNT"*)
      stale+=("$pid")
      ;;
  esac
done

if [[ "${#stale[@]}" -gt 0 ]]; then
  log "清理 chroot 内残留进程（${#stale[@]} 个）：${stale[*]}"
  for pid in "${stale[@]}"; do
    printf '    PID %-6s %s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80)"
  done
  kill -TERM "${stale[@]}" 2>/dev/null || true
  # 给它们一点时间退出，仍活着的补 KILL
  alive=("${stale[@]}")
  for _ in 1 2 3 4 5; do
    next=()
    for pid in "${alive[@]}"; do [[ -d "/proc/$pid" ]] && next+=("$pid"); done
    alive=("${next[@]}")
    [[ "${#alive[@]}" -eq 0 ]] && break
    sleep 1
  done
  if [[ "${#alive[@]}" -gt 0 ]]; then
    warn "以下进程 TERM 后仍在，改用 KILL：${alive[*]}"
    kill -KILL "${alive[@]}" 2>/dev/null || true
  fi
fi

# 用 -R 递归卸载，这样 /dev 下的子挂载（/dev/pts 等）会一起清掉，
# 不需要单独列 dev/pts；顺序也不再重要。
for d in dev proc sys; do
  target="$MOUNT/$d"
  if mountpoint -q "$target"; then
    umount -R "$target" 2>/dev/null || umount -lR "$target" 2>/dev/null || warn "卸载失败: $target"
    log "已卸载 $target（含子挂载）"
  fi
done

# 兜底：检查 /mnt/rootfs 下是否还有残留挂载，有就列出来
# mountinfo 的第 5 列是挂载点（第 1/2 列是挂载 id 与父 id）
leftover="$(awk -v m="$MOUNT" 'index($5, m"/")==1 {print $5}' /proc/self/mountinfo 2>/dev/null)"
if [[ -n "$leftover" ]]; then
  warn "以下挂载点仍未卸载，04-finalize-image.sh 会因此失败："
  printf '    %s\n' $leftover >&2
fi

# 注意：这里只卸载 chroot 用的虚拟文件系统，不卸载镜像本身
# （镜像的卸载由 04-finalize-image.sh 负责，否则 e2fsck 会拒绝在"已挂载"的文件上运行）
log "虚拟文件系统清理完成"
