#!/usr/bin/env bash
# 30-device-packages.sh —— 安装全部设备功能包（/tmp/pkgs/*.pkg.tar.*）并做设备侧收尾
#
# 对应 ubuntu-sheng 的 30-device-packages.sh，语义一致：
#   安装本地包 → 修复可执行权限 → depmod → enable 传感器/devauth 服务。
#
# Arch 侧差异（重要）：
#   * 全部设备包都是本仓库用 makepkg 构建的原生 pacman 包（见
#     scripts/host/21-build-pkg.sh 与 packages/_shared/deb2pkg.sh），因此依赖
#     解析由 pacman 完成；依赖缺失时 pacman -U 直接失败（不会像 apt 那样
#     静默留在半配置状态）
#   * ALARM 官方仓库里已经有 libssc 0.4.4-1 与 iio-sensor-proxy 3.9-1，而本仓库
#     构建的 libssc（0.4.2，带 QRTR 等待补丁）与 iio-sensor-proxy-sheng（3.9）
#     需要取而代之。pacman 默认拒绝「降级」，因此这里先把仓库版本移出
#     （-Rdd 不删依赖），再安装本地包
#   * 包内不 enable 服务（Arch 惯例 + 上游 postinst 的 enable 未移植），
#     统一在这里 systemctl enable
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/sheng-build/in-chroot/30-device-packages.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/sheng-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-pac.sh"

shopt -s nullglob
pkgs=(/tmp/pkgs/*.pkg.tar.*)
[[ "${#pkgs[@]}" -gt 0 ]] || die "/tmp/pkgs 下没有 .pkg.tar.*"


log "待安装设备包（${#pkgs[@]} 个）："
for f in "${pkgs[@]}"; do
  # 包名/版本直接从文件名解析（makepkg 的命名规则：
  # <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.*），避免依赖 pacman -Qp 的额外开关
  base="$(basename "$f")"
  base="${base%.pkg.tar.*}"
  printf '    %-56s\n' "$base"
done

# ---------------------------------------------------------------------------
# 1) 移除 ALARM 仓库/基础镜像里与本地包冲突的版本
#    -Rdd：不删除依赖它的包，只删自己（随后会被本地包顶上）
#    * libssc / iio-sensor-proxy：ALARM extra 里本来就有（0.4.4-1 / 3.9-1，且
#      iio-sensor-proxy 依赖 libssc）。我们需要的是带 QRTR 等待补丁的 libssc
#      与显式 -Dssc-support=enabled 的 proxy，因此换成本仓库构建的包。
#    * linux-firmware*：ALARM 的 rootfs tarball 预装了 linux-firmware 元包
#      （它把 linux-firmware-qcom 放在 optdepends，不显式装就没有 Adreno 固件）。
#      Debian 侧 firmware-xiaomi-sheng 的语义就是「替换 linux-firmware」，
#      Arch 侧同样声明了 provides/conflicts/replaces=('linux-firmware')；但 pacman
#      与元包冲突时**不会**顺带移除它的分包，而分包与本包文件路径会重叠
#      （例如 ath12k/WCN7850/hw2.0/*），会让后面的 pacman -U 因文件冲突直接失败。
#      因此这里显式移除全部 linux-firmware* 包，设备固件统一由本仓库的包提供。
#    * fprintd / libfprint：本仓库自己编的版本与 ALARM 仓库同名同路径。
#      base.list 已经不装 fprintd，但设备包里的 fprintd 依赖 libfprint，
#      不能让仓库版本先被解析进来，所以这两个也在这里显式移除。
#    * linux-aarch64：ALARM 的 rootfs tarball 预装的 stock 内核（无 sheng DTB）。
#      linux-xiaomi-sheng 声明了 conflicts=('linux' 'linux-aarch64')，但 pacman 在
#      `--noconfirm` 下对"是否移除冲突包"默认回答 N，实测报
#        error: unresolvable package conflicts detected
#        :: linux-xiaomi-sheng-... and linux-aarch64-... are in conflict (linux)
#      所以必须在这里显式先删掉（-Rdd 跳过依赖检查）。
# ---------------------------------------------------------------------------
for name in libssc iio-sensor-proxy fprintd libfprint linux-aarch64; do
  if pac_installed "$name"; then
    warn "移除 $name（$(pac_version "$name")）：与本地包同名/冲突，改由本仓库提供"
    pacman -Rdd --noconfirm --color never "$name" || warn "移除 $name 失败（继续）"
  fi
done

mapfile -t fw_pkgs < <(pacman -Qq --color never 2>/dev/null | grep -E '^linux-firmware' || true)
if [[ "${#fw_pkgs[@]}" -gt 0 ]]; then
  warn "移除基础镜像预装的固件包（${#fw_pkgs[@]} 个）：${fw_pkgs[*]}"
  pacman -Rdd --noconfirm --color never "${fw_pkgs[@]}" \
    || warn "移除固件包失败（若随后 pacman -U 报文件冲突，请检查本步骤）"
fi

# ---------------------------------------------------------------------------
# 2) 安装本地包
# ---------------------------------------------------------------------------
log "安装中（pacman -U）"
if ! pacman -U --noconfirm --needed --color never "${pkgs[@]}"; then
  # 第一次失败通常是缺少运行期依赖（本地包相互依赖或依赖官方仓库的包）。
  # pacman -U 本身不会去仓库解析依赖，因此这里再从仓库补装一轮依赖
  # （`yes |` 是为了自动接受可选的构建依赖，避免交互等待）。
  warn "首次安装失败，尝试从官方仓库补齐依赖后重试"
  yes | pacman -S --needed --color never base-devel >/dev/null 2>&1 || true
  pacman -U --noconfirm --color never "${pkgs[@]}" || die "设备包安装失败，请检查上面的依赖错误"
fi

# ---------------------------------------------------------------------------
# 3) 权限修复：deb2pkg 的载荷搬运可能保留上游 deb 的 644 权限，
#    pacman 的 fakeroot 打包不会自动补执行位，这里显式修复
# ---------------------------------------------------------------------------
log "修复可执行权限"
for f in /usr/bin/adsprpcd /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor /usr/bin/ssccli; do
  if [[ -e "$f" ]]; then
    chmod +x "$f"
    printf '    +x %s\n' "$f"
  else
    printf '    (跳过，不存在) %s\n' "$f"
  fi
done

# ---------------------------------------------------------------------------
# 4) depmod：让 /usr/lib/modules/<kver>/modules.dep 等索引在镜像内就生成
# ---------------------------------------------------------------------------
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" ]]; then
  log "为内核 $KVER 生成模块依赖索引（depmod）"
  depmod -a "$KVER" || warn "depmod 失败"
  [[ -f "/usr/lib/modules/$KVER/modules.dep" ]] || warn "modules.dep 未生成，开机可能无法加载模块"
else
  warn "未找到 /usr/lib/modules/*，内核包可能没有装上"
fi

# ---------------------------------------------------------------------------
# 5) 服务启用
#    清单在 scripts/lists/services.enable，90-verify.sh 用同一份做校验。
#
#    旧版在这儿手写 `if [[ -f … ]]; then systemctl enable …`，漏写一个没有任何提示：
#    xiaomi-sheng-thp（触控）就是这样在整轮构建里静默缺席的，设备上只剩裸触控设备。
#    现在 required 的 unit 缺文件直接失败。
#
#    清单里只放必须 enable 的 unit。靠 udev / D-Bus 激活的（iio-sensor-proxy、
#    xiaomi-mipps-auth、keyboard-helper 的两个）没有 [Install] 段，不要写进来。
# ---------------------------------------------------------------------------
SERVICES_ENABLE="$BUILD_DIR/lists/services.enable"

log "启用开机自启服务（scripts/lists/services.enable）"
while read -r scope unit req; do
  [[ -z "${scope:-}" || "$scope" == \#* ]] && continue
  case "$scope" in system|global) ;; *) die "services.enable 格式错误: scope=$scope" ;; esac
  case "$req" in required|optional) ;; *) die "services.enable 格式错误: requirement=$req" ;; esac

  if [[ ! -e "/usr/lib/systemd/system/$unit" && ! -e "/usr/lib/systemd/user/$unit" ]]; then
    if [[ "$req" == "required" ]]; then
      die "必需的服务不存在: $unit（对应的包没有装上？见 services.enable）"
    fi
    warn "服务不存在，跳过启用: $unit（optional）"
    continue
  fi

  if [[ "$scope" == "global" ]]; then
    systemctl --global enable "$unit" || die "全局启用 $unit 失败"
  else
    systemctl enable "$unit" || die "启用 $unit 失败"
  fi
  log "  已启用: $unit"
done < "$SERVICES_ENABLE"

log "设备包安装完成"
