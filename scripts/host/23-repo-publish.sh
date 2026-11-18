#!/usr/bin/env bash
# 23-repo-publish.sh —— 把构建产出的 pacman 包整理成可分发的仓库目录
#
# 用法（不需要 root）:
#   scripts/host/23-repo-publish.sh <包含 .pkg.tar.* 的目录> <输出目录> [<仓库名>]
#
# 产物是标准的 pacman 仓库（<name>.db.tar.gz / <name>.files.tar.gz / 包文件 /
# <name>.conf），整体放到 Release 或 Pages 后，客户端加一段 Server= 即可
# pacman -S / -Syu。不能改用 Actions artifact：它会过期，且下载需要 API 认证，
# makepkg 与 pacman 都取不到。
#
# 输出目录必须是累积的。workflow 先拉回上一版仓库，本脚本在它之上追加新包并裁掉
# 过旧版本；从空目录开始会让旧版本文件和对应数据库条目一起消失。
#
# 环境变量：
#   REPO_KEEP     每个包保留的版本数（默认 3，保留版本号最高的 N 个）
#   REPO_URL      客户端访问仓库的基础 URL，写进生成的 <name>.conf
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"

SRC_DIR="${1:?用法: 23-repo-publish.sh <包所在目录> <输出目录> [仓库名]}"
OUT_DIR="${2:?用法: 23-repo-publish.sh <包所在目录> <输出目录> [仓库名]}"
REPO_NAME="${3:-sheng}"
REPO_KEEP="${REPO_KEEP:-3}"
REPO_URL="${REPO_URL:-}"

[[ -d "$SRC_DIR" ]] || die "源目录不存在: $SRC_DIR"
# 排除 .sig：`*.pkg.tar.*` 会匹配到 foo-1.0-1-aarch64.pkg.tar.zst.sig，交给 repo-add 会报错
mapfile -t pkgs < <(find "$SRC_DIR" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' -type f | sort)
[[ "${#pkgs[@]}" -gt 0 ]] || die "源目录下没有 .pkg.tar.*: $SRC_DIR"

# repo-add 来自 pacman，宿主是 Ubuntu runner 时由 workflow 安装
command -v repo-add >/dev/null 2>&1 || die "缺少 repo-add（Ubuntu 上由 pacman-package-manager 提供）"
# repo-add 用 bsdtar 读每个包的 .PKGINFO，缺失时只会逐包报 "is not a package file"
command -v bsdtar >/dev/null 2>&1 || die "缺少 bsdtar（Ubuntu 上由 libarchive-tools 提供，repo-add 读包需要它）"

mkdir -p "$OUT_DIR"

log "整理 ${#pkgs[@]} 个包到 $OUT_DIR（仓库名 $REPO_NAME）"
for f in "${pkgs[@]}"; do
  cp -f "$f" "$OUT_DIR/"
done

# makepkg 的命名是 <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.*。pkgrel 只含数字与点，
# pkgver 不允许含 '-'，所以从右往左切四段即可。解析失败返回非 0。
#
# 输出两个版本号，用途不同：
#   PKG_VER      只有 pkgver，用于「同一版本」分组（同版本重打包算一组）
#   PKG_FULLVER  pkgver-pkgrel，用于比较新旧。少了 pkgrel 会把 1.94.5-1 与
#                1.94.5-2 判成相等，进而按文件名顺序挑到旧的那个，重打包就丢了。
#
# 用法: parse_pkg_filename <文件名> → 设置 PKG_NAME / PKG_VER / PKG_FULLVER
parse_pkg_filename() {
  local base rest pkgrel
  PKG_NAME=""; PKG_VER=""; PKG_FULLVER=""
  base="${1##*/}"
  base="${base%%.pkg.tar.*}"
  rest="${base%-*}"            # 去掉 -<arch>
  pkgrel="${rest##*-}"
  [[ "$pkgrel" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1   # 必须形如 pkgrel
  rest="${rest%-*}"            # 去掉 -<pkgrel>
  PKG_VER="${rest##*-}"
  PKG_NAME="${rest%-*}"
  # 缺 pkgrel 的 <pkgname>-<arch> 会切出 PKG_NAME 与 PKG_VER 相同，这种文件不该登记。
  [[ -n "$PKG_NAME" && "$PKG_NAME" != "$PKG_VER" ]] || return 1
  PKG_FULLVER="$PKG_VER-$pkgrel"
}

# $1 > $2 时返回 0。优先用 vercmp（与 pacman 判定一致）；Ubuntu 的
# pacman-package-manager 不带它，退回 sort -V。后者在 1.0rc1 这类版本上与 vercmp
# 结论不同（vercmp 认为 1.0rc1 < 1.0），本仓库现有 pkgver 全是数字与点，两者一致。
ver_gt() {
  [[ "$1" != "$2" ]] || return 1
  if command -v vercmp >/dev/null 2>&1; then
    [[ "$(vercmp "$1" "$2")" == "1" ]]
  else
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
  fi
}

# 清理旧版本。必须在 repo-add 之前：repo-add 只增不删，只删文件不重建数据库，
# 被删的版本会以「库里有、文件没有」的悬空条目留在库里。
#
# REPO_KEEP 按版本计。同一 pkgver 下的多个 pkgrel（同版本重打包）算一个版本，
# 整组保留或整组删除。
prune_old_versions() {
  local f pkgname version versions to_delete
  declare -A by_name=()

  for f in "$OUT_DIR"/*.pkg.tar.*; do
    [[ -f "$f" && "$f" != *.sig ]] || continue
    parse_pkg_filename "$f" || continue
    by_name["$PKG_NAME"]+="$PKG_VER"$'\n'
  done

  for pkgname in "${!by_name[@]}"; do
    mapfile -t versions < <(printf '%s' "${by_name[$pkgname]}" | sed '/^$/d' | sort -uV)
    if [[ "${#versions[@]}" -le "$REPO_KEEP" ]]; then
      continue
    fi
    # 保留版本号最高的 REPO_KEEP 个，其余版本的**全部** pkgrel 文件删除
    to_delete=("${versions[@]:0:${#versions[@]}-REPO_KEEP}")
    log "  清理 $pkgname 的旧版本 ${#to_delete[@]} 个（保留 $REPO_KEEP 个）"
    for version in "${to_delete[@]}"; do
      rm -f "$OUT_DIR/$pkgname-$version-"*.pkg.tar.*
    done
  done
}

if [[ "$REPO_KEEP" -gt 0 ]]; then
  prune_old_versions
fi

# 数据库里每个包名只能有一条记录，所以只登记每个包的最高版本；其余版本的文件
# 留在目录里，供 `pacman -U <完整 URL>` 回退。
#
# 不能把目录里的全部文件都交给 repo-add：它是后写入者胜出，最终登记哪个版本取决于
# 传参顺序（只对「比库里更旧」的条目告警，不阻止覆盖）。显式挑出最高版本就与顺序无关。
#
# 比较用 PKG_FULLVER（带 pkgrel）：只比 pkgver 时，同一版本重打包（1.94.5-1 与
# 1.94.5-2 并存）会被判成相等，最终登记哪个取决于文件名排序，通常留下旧的那个。
newest_per_pkg() {
  local f pkgname
  declare -A newest=()      # pkgname -> 该包最高版本的文件路径
  declare -A newest_ver=()  # pkgname -> 对应的 PKG_FULLVER

  for f in "$OUT_DIR"/*.pkg.tar.*; do
    [[ -f "$f" && "$f" != *.sig ]] || continue
    parse_pkg_filename "$f" || continue
    pkgname="$PKG_NAME"
    if [[ -z "${newest[$pkgname]:-}" ]] || ver_gt "$PKG_FULLVER" "${newest_ver[$pkgname]}"; then
      newest["$pkgname"]="$f"
      newest_ver["$pkgname"]="$PKG_FULLVER"
    fi
  done

  for pkgname in "${!newest[@]}"; do
    printf '%s\n' "${newest[$pkgname]}"
  done | sort
}

mapfile -t pkgs < <(newest_per_pkg)
[[ "${#pkgs[@]}" -gt 0 ]] || die "无法从 $OUT_DIR 解析出任何包（文件名不符合 makepkg 命名规则？）"
log "重建数据库（$([[ -f "$OUT_DIR/$REPO_NAME.db.tar.gz" ]] && echo 增量 || echo 首次)，登记 ${#pkgs[@]} 个包）"
repo-add --nocolor -q "$OUT_DIR/$REPO_NAME.db.tar.gz" "${pkgs[@]}"

# pacman 读的是不带 .tar.gz 的软链名（sheng.db / sheng.files）
for ext in db files; do
  target="$OUT_DIR/$REPO_NAME.$ext.tar.gz"
  if [[ -f "$target" ]]; then
    ln -sfn "$REPO_NAME.$ext.tar.gz" "$OUT_DIR/$REPO_NAME.$ext"
  fi
  # repo-add 留的 .old 备份对客户端无用，别传上 Release
  rm -f "$target.old"
done

cat > "$OUT_DIR/$REPO_NAME.conf" <<EOF
# 把这一段放在 /etc/pacman.conf 里所有官方仓库段之前：
# 本仓库的设备包替换了官方仓库的同名包（linux / linux-firmware / libssc 等），
# 排在后面时 pacman 会优先解析官方版本。
#
# 注意：升级 linux-xiaomi-sheng 后必须重刷对应的 boot.img，否则开机黑屏。
# boot 分区不由 pacman 管理，只升级 rootfs 会让内核模块与 boot.img 版本不一致。
# 详见 README 的「升级内核必须重刷 boot.img」。
[$REPO_NAME]
SigLevel = Optional TrustAll
Server = ${REPO_URL:-__REPO_URL__}
EOF

log "仓库已生成："
ls -lh "$OUT_DIR" | sed 's/^/    /'
log "包数量: $(find "$OUT_DIR" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' | wc -l)"
