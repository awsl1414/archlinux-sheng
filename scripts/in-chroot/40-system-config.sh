#!/usr/bin/env bash
# 40-system-config.sh —— 系统级配置：主机名 / locale / 用户 / 密码 / 显示管理器 /
# 自动登录 / 网络 / fstab / 清理
#
# 对应 ubuntu-sheng 的 40-system-config.sh，语义一一对应，Arch 侧的差异：
#   * locale：写 /etc/locale.conf（Arch 没有 /etc/default/locale），
#     放开 /etc/locale.gen 后 locale-gen
#   * 用户：useradd -m -s /bin/bash -G wheel，并写 /etc/sudoers.d/10-wheel
#     （Ubuntu 用 sudo 组，Arch 的惯例是 wheel）
#   * GDM：Arch 的包是 gdm（不是 gdm3），自动登录写 /etc/gdm/custom.conf
#   * SDDM：同样写 /etc/sddm.conf.d/autologin.conf（Arch 的 sddm 会读该目录）
#   * 清理：pacman -Scc + 删 /var/cache/pacman/pkg/*
#
# 环境变量：
#   /root/build.env 提供 HOSTNAME / USERNAME / LANGUAGE / AUTOLOGIN / DESKTOP /
#                    PLASMA_MOBILE / PARTITION_LABEL / QUIET_BOOT
#   ROOTFS_PASSWORD 由 workflow 通过 env 传入（不落盘；为空则回退到上游的 password）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" env ROOTFS_PASSWORD=... /root/sheng-build/in-chroot/40-system-config.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/sheng-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-pac.sh"

if [[ -f /root/build.env ]]; then
  # shellcheck source=/dev/null
  source /root/build.env
fi

: "${HOSTNAME:?需要 HOSTNAME}"
: "${USERNAME:?需要 USERNAME}"
DESKTOP="${DESKTOP:-server}"
AUTOLOGIN="${AUTOLOGIN:-false}"
PLASMA_MOBILE="${PLASMA_MOBILE:-false}"
LANGUAGE="${LANGUAGE:-None (C.UTF-8)}"
GEN_LOCALES="${GEN_LOCALES:-}"
PARTITION_LABEL="${PARTITION_LABEL:-linux}"

# ---------------------------------------------------------------------------
# 1) 主机名
# ---------------------------------------------------------------------------
log "设置主机名: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*$HOSTNAME" /etc/hosts 2>/dev/null; then
  echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# 2) locale
#    Arch：locale 由 glibc 提供，/etc/locale.gen 决定生成哪些，然后 locale-gen
#
#    LANGUAGE        系统语言，写进 /etc/locale.conf 的 LANG
#    GEN_LOCALES     额外要生成的 locale（逗号分隔），留空则只生成系统语言
#                    用途：系统用英文、但想让中文/日文程序正常显示的场合
#    C.UTF-8 是 glibc 内建的，不需要生成。
# ---------------------------------------------------------------------------
if [[ "$LANGUAGE" == "None (C.UTF-8)" ]]; then
  # 必须显式写 locale.conf。ALARM tarball 自带的 /etc/locale.conf 是 LANG=C，
  # 与 C.UTF-8 不是一回事：前者按 ASCII 处理非 ASCII 字符，setlocale 会失败。
  want_lang="C.UTF-8"
else
  want_lang="$LANGUAGE"
fi

# 生成列表 = 系统语言 + 额外列表，去重，跳过内建的 C.UTF-8
GEN=()
_add_gen() {
  [[ "$1" == "C.UTF-8" || -z "$1" ]] && return
  local x
  for x in "${GEN[@]}"; do [[ "$x" == "$1" ]] && return; done
  GEN+=("$1")
}
_add_gen "$want_lang"
for l in ${GEN_LOCALES//,/ }; do _add_gen "$l"; done

if [[ "${#GEN[@]}" -eq 0 ]]; then
  log "locale: C.UTF-8（glibc 内建，无需生成）"
else
  [[ -f /etc/locale.gen ]] || die "缺少 /etc/locale.gen（glibc 是否已安装？）"

  log "生成 locale: ${GEN[*]}（系统 LANG=$want_lang）"
  for l in "${GEN[@]}"; do
    esc="$(printf '%s' "$l" | sed 's/\./\\./g')"
    sed -i "s/^# *\(${esc}\)/\1/" /etc/locale.gen
    grep -qE "^${esc}[[:space:]]" /etc/locale.gen \
      || die "/etc/locale.gen 里没有 $l 这个条目（名字写错了？）"
  done

  locale-gen || die "locale-gen 失败"

  # locale -a 的命名与 locale.gen 不完全一致（zh_CN.UTF-8 → zh_CN.utf8），归一化后比对
  for l in "${GEN[@]}"; do
    _want="$(printf '%s' "$l" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
    locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$_want" \
      || die "locale-gen 后 locale -a 里没有 $_want"
    log "  locale 已生成: $l"
  done
fi

# Arch（systemd）约定：/etc/locale.conf
printf 'LANG=%s\n' "$want_lang" > /etc/locale.conf

# ---------------------------------------------------------------------------
# 2.5) 时区
#   旧实现没有这一步，镜像里没有 /etc/localtime，systemd 按 UTC 处理，
#   桌面上的时间比本地慢几个小时。
#   tzdata 已在 base.list 里安装，/usr/share/zoneinfo/<TZ> 存在。
#   chroot 内没有运行中的 systemd，timedatectl 不可用，直接建软链。
#   systemd 只认 /etc/localtime；/etc/timezone 是 Debian 的约定，不写。
# ---------------------------------------------------------------------------
: "${TIMEZONE:?需要 TIMEZONE}"
[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "时区不存在: /usr/share/zoneinfo/$TIMEZONE"
rm -f /etc/localtime
ln -s "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
log "时区已设置: $TIMEZONE"

# ---------------------------------------------------------------------------
# 3) 用户与密码（上游语义：用户与 root 同密码）
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
  log "创建用户: $USERNAME（加入 wheel 组）"
  useradd -m -s /bin/bash -G wheel "$USERNAME"
fi

# wheel 组可 sudo（Arch 惯例；Ubuntu 那边是 sudo 组）
install -d -m 755 /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'EOF'
# archlinux-sheng：wheel 组可提权
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-wheel

# 密码由 workflow 写入 /root/build.pw（600），读完即删，避免出现在命令行参数里
if [[ -z "${ROOTFS_PASSWORD:-}" && -f /root/build.pw ]]; then
  ROOTFS_PASSWORD="$(cat /root/build.pw)"
fi
if [[ -z "${ROOTFS_PASSWORD:-}" ]]; then
  warn "ROOTFS_PASSWORD 未设置，使用上游同样的默认密码: password"
  ROOTFS_PASSWORD="password"
fi
printf '%s:%s\n' "$USERNAME" "$ROOTFS_PASSWORD" | chpasswd
printf 'root:%s\n' "$ROOTFS_PASSWORD" | chpasswd
rm -f /root/build.pw
log "已设置 $USERNAME 与 root 的密码"

# ---------------------------------------------------------------------------
# 4) 网络
# ---------------------------------------------------------------------------
log "启用 NetworkManager"
systemctl enable NetworkManager.service || warn "启用 NetworkManager 失败"

# ---------------------------------------------------------------------------
# 5) 显示管理器 + 自动登录
# ---------------------------------------------------------------------------
case "$DESKTOP" in
  GNOME)
    if [[ "$AUTOLOGIN" == "true" ]]; then
      log "配置 GDM 自动登录: $USERNAME"
      install -d /etc/gdm
      cat > /etc/gdm/custom.conf <<EOF
# archlinux-sheng：自动登录配置
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$USERNAME
EOF
    fi
    systemctl enable gdm.service || warn "启用 gdm 失败"
    systemctl set-default graphical.target
    ;;
  "KDE Plasma")
    if [[ "$AUTOLOGIN" == "true" ]]; then
      if [[ "$PLASMA_MOBILE" == "true" ]]; then SDDM_SESSION="plasmamobile"; else SDDM_SESSION="plasma"; fi
      log "配置 SDDM 自动登录: $USERNAME (session=$SDDM_SESSION)"
      install -d /etc/sddm.conf.d
      cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=$SDDM_SESSION
EOF
    fi
    systemctl enable sddm.service || warn "启用 sddm 失败"
    systemctl set-default graphical.target
    ;;
  server)
    log "server 模式：不配置显示管理器"
    systemctl set-default multi-user.target
    ;;
esac

# ---------------------------------------------------------------------------
# 6) fstab（PARTLABEL 定位根分区；x-systemd.growfs 首启自动扩容）
# ---------------------------------------------------------------------------
log "写入 fstab: PARTLABEL=$PARTITION_LABEL"
cat > /etc/fstab <<EOF
# <file system>            <mount point>  <type>  <options>                          <dump> <pass>
PARTLABEL=$PARTITION_LABEL /              ext4    defaults,x-systemd.growfs         0      1
EOF

# ---------------------------------------------------------------------------
# 7) 清理
#    注意：pacman 缓存（含 sync 数据库/var/lib/pacman/sync）**不在这里清**，
#    因为 90-verify.sh 紧随其后运行。真正的清理由 workflow 的最后一步
#    「[chroot] Clean pacman cache」负责（跑在 verify 通过之后）。
# ---------------------------------------------------------------------------
log "清理临时文件"
rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
rm -f /var/log/pacman.log.old 2>/dev/null || true
# /tmp/pkgs 保留到 90-verify.sh 通过之后再删（见 90-verify.sh 末尾），
# 这样设备包校验阶段仍能列出包清单。

log "系统配置完成"
