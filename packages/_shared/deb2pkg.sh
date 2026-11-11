#!/usr/bin/env bash
# deb2pkg.sh —— 把 Debian/Ubuntu 的 .deb 载荷"原生化"为 Arch Linux (aarch64) 布局
#
# 设计原则：
#   * 所有 Arch 包仍由 makepkg 生成 —— 包名/版本/依赖/.PKGINFO/.MTREE 全部由 PKGBUILD 声明，
#     本脚本只负责「.deb → $pkgdir」的载荷搬运 + Debian 专有布局修正，不产出任何元数据文件。
#   * 因此产出的包是真正的 pacman 包（可 pacman -Q / -U / -R，可被依赖解析），不是伪装的 deb。
#
# 在 PKGBUILD 的 package() 中使用：
#   source "$startdir/../_shared/deb2pkg.sh"
#   deb_extract_payload "$srcdir/foo.deb" "$pkgdir"
#
# 移植期独立核对元数据（不写文件）：
#   bash deb2pkg.sh --report path/to/foo.deb

# 严格模式只在"作为独立脚本运行"时启用：
# 本文件主要用途是被 PKGBUILD 的 package() source，若在此处 set -euo pipefail
# 会连带改变 makepkg 调用方的 shell 选项，属于副作用。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

_warn() { printf '\033[33m[deb2pkg] %s\033[0m\n' "$*" >&2; }
_info() { printf '[deb2pkg] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Debian 包名 → Arch 包名映射（用于 --report 给出的 depends 建议；未收录的会标 UNMAPPED）
# ---------------------------------------------------------------------------
# 必须 declare -A：否则 bash 会把 [libgudev-1.0-0] 这类键当作**索引数组的算术下标**求值
# （含小数点 → invalid arithmetic operator 报错），映射表会退化成索引数组，
# 且每次 source 都会往 stderr 打错误。声明为关联数组后键按字符串处理。
declare -A _deb_dep_map=(
  [libc6]=glibc
  [libgcc-s1]=gcc-libs
  [libstdc++6]=gcc-libs
  [libglib2.0-0]=glib2
  [libglib2.0-0t64]=glib2
  [libprotobuf-c1]=protobuf-c
  [libqmi-glib5]=libqmi
  [libmbim-glib4]=libmbim
  [libyaml-0-2]=libyaml
  [libgudev-1.0-0]=libgudev
  [libpolkit-gobject-1-0]=polkit
  [libsystemd0]=systemd-libs
  [libudev1]=systemd-libs
  [libdbus-1-3]=dbus
  [libcap2]=libcap
  [libpam0g]=pam
  [libssl3]=openssl
  [libssl3t64]=openssl
  [libqt6core6]=qt6-base
  [libqt6widgets6]=qt6-base
  [libqt6network6]=qt6-base
  [libqt6dbus6]=qt6-base
  [libqt6svg6]=qt6-svg
  [qml6-module-qtquick]=qt6-declarative
  [systemd]=systemd
  [systemd-sysv]=systemd
  [dbus]=dbus
  [kmod]=kmod
  [python3]=python
  [python3-gi]=python-gobject
  [python3-pyqt6]=python-pyqt6
  [network-manager]=networkmanager
  [wpasupplicant]=wpa_supplicant
  [openssh-server]=openssh
  [bluez]=bluez
  [alsa-ucm-conf]=alsa-ucm-conf
  [alsa-utils]=alsa-utils
  [libfprint-2-2]=libfprint
  [libfprint-2-tod1]=libfprint-tod
  [fprintd]=fprintd
  [iio-sensor-proxy]=iio-sensor-proxy
  [libssc]=libssc
  [linux-firmware]=linux-firmware
  [wireless-regdb]=wireless-regdb
  [locales]=glibc
  [ca-certificates]=ca-certificates
  [chrony]=chrony
  [libusb-1.0-0]=libusb
  [libevdev2]=libevdev
  [libinput10]=libinput
  [zlib1g]=zlib
  [libzstd1]=zstd
  [liblzma5]=xz
  [libffi8]=libffi
  [libexpat1]=expat
  [libpcre2-8-0]=pcre2
)

# ---------------------------------------------------------------------------
# 内部：从 .deb 解出 control 内容到 stdout
# ---------------------------------------------------------------------------
_deb_control() {
  local deb="$1" tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  bsdtar -xf "$deb" -C "$tmp" 2>/dev/null
  local ctl
  ctl="$(find "$tmp" -maxdepth 1 -name 'control.tar*' -print -quit)"
  [[ -n "$ctl" ]] || { _warn "未找到 control.tar*：$deb"; return 1; }
  bsdtar -xOf "$ctl" ./control 2>/dev/null || bsdtar -xOf "$ctl" control
}

_deb_field() { # <deb> <Field>
  _deb_control "$1" | awk -v f="$2" '
    $0 ~ "^"f":" { sub("^"f":[ \t]*", ""); print; exit }'
}

# ---------------------------------------------------------------------------
# 内部：Debian 布局 → Arch 布局
#   /bin /sbin      → /usr/bin      （Arch 自 filesystem 2024 起无独立 /bin /sbin）
#   /lib            → /usr/lib      （Debian usrmerge 等价物；固件/模块/udev/security 都在这）
#   /usr/sbin       → /usr/bin
#   /etc/init.d     → 丢弃（Arch 无 SysV init，全部走 systemd）
# ---------------------------------------------------------------------------
_deb_normalize_layout() {
  local root="$1" d
  for d in bin sbin lib; do
    [[ -d "$root/$d" ]] || continue
    mkdir -p "$root/usr/$d"
    _info "布局修正：/$d → /usr/$d"
    cp -a --no-preserve=ownership "$root/$d/." "$root/usr/$d/"
    rm -rf "${root:?}/$d"
  done
  if [[ -d "$root/usr/sbin" ]]; then
    _info "布局修正：/usr/sbin → /usr/bin"
    mkdir -p "$root/usr/bin"
    cp -a --no-preserve=ownership "$root/usr/sbin/." "$root/usr/bin/"
    rm -rf "$root/usr/sbin"
  fi
  if [[ -d "$root/etc/init.d" ]]; then
    _warn "/etc/init.d 下的 SysV 脚本已丢弃（Arch 不使用），请确认 systemd unit 已由包提供"
    rm -rf "$root/etc/init.d"
  fi
  # Debian 版权文件位置与 Arch 惯例不同，仅提示不搬移（避免破坏上游 deb 的内容一致性）
  if [[ -d "$root/usr/share/doc" ]]; then
    _info "提示：/usr/share/doc 为 Debian 惯例，Arch 通常放 /usr/share/licenses；本脚本保持原样"
  fi
}

# ---------------------------------------------------------------------------
# 公开：把 deb 的 data 载荷解到 $pkgdir 并修正布局
#   deb_extract_payload <deb> <destdir>
# ---------------------------------------------------------------------------
deb_extract_payload() {
  local deb="$1" dest="$2" tmp data
  [[ -f "$deb" ]] || { _warn "找不到 deb：$deb"; return 1; }
  mkdir -p "$dest"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  bsdtar -xf "$deb" -C "$tmp" 2>/dev/null
  data="$(find "$tmp" -maxdepth 1 -name 'data.tar*' -print -quit)"
  [[ -n "$data" ]] || { _warn "未找到 data.tar*：$deb"; return 1; }
  # -p 保留权限位；非 root 时所有权由 makepkg/fakeroot 统一收归 root:root
  bsdtar -xpf "$data" -C "$dest"
  # 清掉误带入的打包目录
  rm -rf "$dest/DEBIAN"

  # Debian 的目录权限普遍是 775，Arch 是 755。不归一化的话，pacman 安装时会打
  #   warning: directory permissions differ on /usr/lib/: filesystem: 755  package: 775
  # 而且包**新建**的目录（如 /usr/lib/xiaomi-sheng-fingerprint）会真的留在 775 ——
  # 组可写，比 Arch 惯例宽。只规范目录，文件权限保持原样。
  find "$dest" -mindepth 1 -type d -exec chmod 755 {} +

  _deb_normalize_layout "$dest"
}

# ---------------------------------------------------------------------------
# 公开：打印 deb 元数据与「Arch 依赖建议」，供编写 PKGBUILD 时参考
#   bash deb2pkg.sh --report <deb>
# ---------------------------------------------------------------------------
deb_report() {
  local deb="$1" f name
  echo "== $deb =="
  for f in Package Version Architecture Maintainer Section Priority Depends Pre-Depends \
           Recommends Provides Conflicts Replaces Description; do
    local v
    v="$(_deb_field "$deb" "$f" || true)"
    # 注意：不能写成 [[ -n "$v" ]] && printf ...，字段为空时该复合命令返回 1，
    # 在 set -e 下会让整个 report 提前退出
    if [[ -n "$v" ]]; then
      printf '%-14s %s\n' "$f:" "$v"
    fi
  done
  echo
  echo "-- Depends → Arch 建议 --"
  local deps
  deps="$(_deb_field "$deb" Depends || true)"
  if [[ -z "$deps" ]]; then
    echo "   (无)"
  fi
  local IFS=','
  local item
  for item in $deps; do
    item="${item#"${item%%[![:space:]]*}"}"          # 去前导空白
    item="${item%"${item##*[![:space:]]}"}"          # 去尾随空白
    item="${item%%|*}"                                # 备选项只取第一个
    name="${item%% *}"; name="${name%%(*}"            # 去掉版本约束
    name="${name%%:*}"                                # 去掉 :any / :arm64 架构后缀
    if [[ -n "${_deb_dep_map[$name]:-}" ]]; then
      printf '   %-28s → %s\n' "$name" "${_deb_dep_map[$name]}"
    else
      printf '   %-28s → UNMAPPED（需人工确认 Arch 侧包名）\n' "$name"
    fi
  done
  echo
  echo "-- 维护者脚本 --"
  local tmp ctl
  # shellcheck disable=SC2064  # $tmp 是局部变量，必须在"设 trap 时"就插值（RETURN 时已失效）
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  bsdtar -xf "$deb" -C "$tmp" 2>/dev/null || { _warn "无法解包（不是有效的 .deb？）：$deb"; return 1; }
  ctl="$(find "$tmp" -maxdepth 1 -name 'control.tar*' -print -quit)"
  if [[ -n "$ctl" ]]; then
    bsdtar -tf "$ctl" | sed 's|^\./||' \
      | grep -Ev '^(control|md5sums|conffiles|triggers|shlibs|symbols)$' \
      | sed 's/^/   /' || echo "   (无)"
  fi
  echo "   提示：Debian 的 postinst/prerm 必须改写为 pacman 的 .INSTALL（post_install/post_upgrade/pre_remove）"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --report|-r) shift; deb_report "$@" ;;
    *) echo "用法: $0 --report <file.deb>" >&2; exit 2 ;;
  esac
fi
