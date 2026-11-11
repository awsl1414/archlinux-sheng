#!/usr/bin/env bash
# lib-pac.sh —— chroot 内使用的 pacman 封装 + 包列表读取
# 由 in-chroot/ 下各脚本 source（与 ubuntu 版的 lib-apt.sh 一一对应）。
#
# 与 apt 的关键差异：
#   * Arch 没有 policy-rc.d 机制（那是 Debian 的 dpkg 特性）。pacman 安装包时
#     不会启动服务 —— systemd 在 chroot 里根本没在运行，.INSTALL 脚本自身
#     带 `[ -d /run/systemd/system ]` 守卫，因此不需要 prepare_apt 那种垫片。
#   * Arch 是滚动发行版：`pacman -Sy` 之后如果只装个别新包而不升级已装的包，
#     会形成「部分升级」（库版本与包不匹配）。因此 10-base.sh 与 20-desktop.sh
#     都先做 `pacman -Syu` 再装包；本文件只提供装包的薄封装。
# shellcheck shell=bash

# pacman 的公共参数：--noconfirm 全程不问；--needed 不重复安装；--color never 让日志可读
PAC_OPTS=(--noconfirm --needed --color never)

# ---------------------------------------------------------------------------
# 判断某包在 sync 数据库里是否存在（存在说明可以走 pacman -S）
# ---------------------------------------------------------------------------
pac_in_sync() {
  local pkg="$1"
  pacman -Si --color never "$pkg" >/dev/null 2>&1
}

# 判断某包是否已安装
pac_installed() {
  local pkg="$1"
  pacman -Q --color never "$pkg" >/dev/null 2>&1
}

# 已安装的版本（未安装则输出空）
pac_version() {
  local pkg="$1"
  pacman -Q --color never "$pkg" 2>/dev/null | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# 读取包列表文件：过滤注释与空行，输出空格分隔的一行
#   一行只能写一个包名。曾出现 `a / b / c` 这种斜杠写法：`/` 会被当成包名送进
#   pacman，整批安装必然失败、退回逐个安装，最后打出一条全是 `/` 的"未安装包"警告，
#   真正的缺失包反而被淹没。这里直接对格式报错。
#   注意：grep 在"文件全是注释/空行"时返回 1；若不做兜底，调用方的
#   `pkgs="$(list_packages ...)"` 会在 set -e 下直接终止脚本且没有任何可读错误
#   （与 ubuntu-sheng 的 lib-apt.sh 同一处修复）。
# ---------------------------------------------------------------------------
list_packages() {
  local file="$1" out line n=0
  [[ -f "$file" ]] || die "包列表不存在: $file"

  while IFS= read -r line; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" == *[[:space:]]* ]]; then
      die "$file 第 $n 行含空白（一行只能写一个包）: $line"
    fi
    if [[ ! "$line" =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]; then
      die "$file 第 $n 行不是合法的 Arch 包名: $line"
    fi
  done < "$file"

  out="$(grep -vE '^[[:space:]]*(#|$)' "$file" | tr '\n' ' ' || true)"
  [[ -n "${out// /}" ]] || die "包列表为空（只有注释或空行）: $file"
  printf '%s' "${out% }"
}

# ---------------------------------------------------------------------------
# 安装包（pacman -S）
#   pac_install <包...>
#   pac_install --from-file <列表文件>   （等价于 pac_install_list）
# ---------------------------------------------------------------------------
pac_install() {
  [[ "$#" -gt 0 ]] || return 0
  if [[ "${1:-}" == "--from-file" ]]; then
    shift
    pac_install_list "$@"
    return
  fi
  pacman -S "${PAC_OPTS[@]}" "$@"
}

# 安装列表文件中的全部包
pac_install_list() {
  local file="$1" pkgs
  pkgs="$(list_packages "$file")"
  [[ -n "$pkgs" ]] || { warn "包列表是空的: $file"; return 0; }
  # shellcheck disable=SC2086
  pac_install $pkgs
}

# 尽力而为的安装：某个包在当前仓库里不存在时不至于让整个构建失败，
# 但会打印警告（90-verify.sh 会对关键包做硬校验）。
pac_install_best_effort() {
  [[ "$#" -gt 0 ]] || return 0
  pac_install "$@" || warn "可选包安装失败（已忽略）: $*"
}

# 尽力而为地安装列表文件里的包：
#   先整批安装（快、依赖解析最完整）；若失败再逐个安装，跳过装不上的包。
#   比「逐个安装」优先的原因：Arch 是滚动发行版，整批安装与逐包安装的依赖解析
#   结果一致，但整批只需一次「数据库 + 依赖」解算，速度更快。
#   跳过原则：已经装了同名包（provides 命中）也算成功，不算失败。
pac_install_list_best_effort() {
  local file="$1" pkg failed=()
  local pkgs
  pkgs="$(list_packages "$file")"
  [[ -n "$pkgs" ]] || { warn "包列表是空的: $file"; return 0; }

  log "整批安装: $(basename "$file")"
  # 保留整批安装的 stderr：失败原因（缺包 / 版本冲突 / 签名）只在这里出现一次，
  # 直接丢掉的话，日志里只剩一条"整批安装失败"，无从判断是哪个包的问题。
  local batch_err
  batch_err="$(mktemp)"
  # shellcheck disable=SC2086
  if pacman -S "${PAC_OPTS[@]}" $pkgs >"$batch_err" 2>&1; then
    rm -f "$batch_err"
    log "整批安装成功: $(basename "$file")"
    return 0
  fi
  warn "整批安装失败，原因如下（随后退回逐个安装）："
  grep -E '^(error|warning):|^:: ' "$batch_err" | sed 's/^/    /' || sed 's/^/    /' "$batch_err"
  rm -f "$batch_err"

  warn "退回逐个安装（跳过 ALARM 仓库里缺失或改名的包）"
  for pkg in $pkgs; do
    if pac_installed "$pkg"; then
      printf '    [已有] %s\n' "$pkg"
      continue
    fi
    if pacman -S "${PAC_OPTS[@]}" "$pkg" >/dev/null 2>&1; then
      printf '    [ 装 ] %s\n' "$pkg"
    else
      printf '    [跳过] %s\n' "$pkg"
      failed+=("$pkg")
    fi
  done
  if [[ "${#failed[@]}" -gt 0 ]]; then
    warn "以下包未安装（ALARM 仓库里可能没有，或已改名，请在 lists/ 里核对）: ${failed[*]}"
  fi
}

# ---------------------------------------------------------------------------
# 安装本地已构建的 pacman 包（/tmp/pkgs/*.pkg.tar.*）
# ---------------------------------------------------------------------------
pac_install_local() {
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0
  pacman -U "${PAC_OPTS[@]}" "${pkgs[@]}"
}
