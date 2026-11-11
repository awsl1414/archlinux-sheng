# archlinux-sheng

[![Validate](https://github.com/code002-2/archlinux-sheng/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/code002-2/archlinux-sheng/actions/workflows/validate.yml)
[![Build RootFS](https://github.com/code002-2/archlinux-sheng/actions/workflows/rootfs.yml/badge.svg?branch=main)](https://github.com/code002-2/archlinux-sheng/actions/workflows/rootfs.yml)

用 **GitHub Actions** 为**小米平板 6S Pro（sheng / 高通 SM8550）**构建 **Arch Linux ARM（aarch64）** 的
`rootfs.img` 与 `boot.img`，产物可直接用 `fastboot` 刷入设备，设备功能包全部以 pacman 原生方式打包
（`makepkg` 产出真正的 pacman 包）。

## 参数说明

| 参数 | 默认值 | 说明 |
|---|---|---|
| **rootfs_base** | `alarm` | 底包与软件源：Arch Linux ARM 官方 tarball + `core/extra/alarm` 滚动仓库。`holo-core` 已移除（脚本在 `e960212` 删除），选它会直接报错 |
| **桌面环境** | `KDE Plasma` | `GNOME` / `server`（无图形界面） |
| **plasma_mobile** | `false` | 勾选后用 `plasma-mobile` 替代 `plasma-desktop` |
| **browser** | `firefox` | `none` 则不安装（Arch 官方仓库的 firefox 是普通包） |
| **autologin** | `true` | 自动登录（GNOME → `/etc/gdm/custom.conf`；KDE → `/etc/sddm.conf.d/autologin.conf`） |
| **username / hostname** | `username` / `xiaomi-sheng` | 用户加入 `wheel` 组，并写 `/etc/sudoers.d/10-wheel` |
| **password** | *(空)* | 镜像密码（普通用户与 `root` 同密码）。优先用本输入项；留空则用仓库 Secret `ROOTFS_PASSWORD`；都为空时为 `password`。输入项会 `::add-mask::` 打码，但**值仍显示在该次运行的输入摘要里**，介意请改用 Secret |
| **language** | `None (C.UTF-8)` | 系统语言，10 种可选；写 `/etc/locale.conf`（Arch 无 `/etc/default/locale`）。选 `None` 时写 `LANG=C.UTF-8`，不是 ALARM tarball 自带的 `LANG=C` |
| **gen_locales** | *(空)* | 额外生成的 locale，逗号分隔（如 `zh_CN.UTF-8,ja_JP.UTF-8`）；留空则只生成 `language` 选中的那个。用于系统用英文但需要中文/日文程序正常显示的场合 |
| **timezone** | `Asia/Shanghai` | 时区，写 `/etc/localtime` 软链 |
| **boot_mode** | `dual (linux)` | `single (userdata)` / `dual (linux)` / `custom` |
| **custom_partition** | *(空)* | 仅 `boot_mode=custom` 需要，且必须搭配 `kernel_source=custom_build` |
| **quiet_boot** | `true` | 安装 Plymouth 并选用 `*_plymouth.img`；`server` 模式自动忽略 |
| **kernel_source** | `prebuilt` | `prebuilt` = 取 ianchb 内核 deb 并**重打包成 pacman 包**；`custom_build` = 自行编译后打包 |
| **kernel_release** | `7.3.0` | `prebuilt` 取哪个 release（留空则取最新；固定版本便于复现），boot 镜像与内核 deb 同源 |
| **kernel_repo / kernel_branch / kernel_config** | `ianchb/sm8550-mainline` / `sheng-7.3.0` / `sm8550.config` | 仅 `custom_build` 使用；仓库内 `sm8550.config` 与上游同名 release 同步（当前 = 7.3.0，内核 `7.3.0-sm8550-00104-g1fb56e66091e`） |
| **kernel_localversion** | `-sm8550-00104-g1fb56e66091e` | 仅 `custom_build` 使用。钉住 `CONFIG_LOCALVERSION`，必须与 `kernel_release` 的 deb 一致，否则模块与 boot.img 的 vermagic 不匹配 |
| **firmware_repo / firmware_branch** | `ianchb/sheng-firmware` / `master` | 设备固件来源（构建时打成 tar.zst 供 makepkg 离线使用） |
| **rootfs_size** | `10G` | 镜像初始大小；构建后收缩，首启由 `x-systemd.growfs` 扩到分区实际大小 |
| **shrink_image** | `true` | 构建后 `e2fsck -fy` + `resize2fs -M` 收缩镜像并截断文件。卸载失败或收缩后校验不通过会直接让构建失败（否则会静默产出 10 GiB 的未收缩镜像） |
| **upload_artifacts** | `true` | 设为 `false` 只验证流程、不产出 Artifact |

与姊妹项目 ubuntu-sheng 的差异只有两处：没有 `ubuntu_series` 输入；`browser` 默认为 `firefox`。

**设备功能包**由 `_packages.yml` 构建：内核、固件、传感器、`xiaomi-*` 等，一个包一个作业。
构建用的 ALARM chroot 由 `prepare-chroot` 作业准备一次，打成快照走 artifact 分发给各构建作业，
不要在作业里改回 `actions/cache`：并行作业共用一个 key 时只有一个能保存。

**服务自启**由 `scripts/lists/services.enable` 声明，`30-device-packages.sh` 按它 enable，
`90-verify.sh` 按同一份清单校验。靠 udev / D-Bus 激活的 unit 不要写进这份清单
（它们没有 `[Install]` 段，`systemctl enable` 会静默返回 0）。

**语言与时区**：

- `language` 决定 `/etc/locale.conf` 里的 `LANG`。选 `None (C.UTF-8)` 时写的是 `C.UTF-8`，
  不是 ALARM tarball 自带的 `LANG=C`——后者按 ASCII 处理，非 ASCII 字符会出问题。
- `gen_locales` 只负责"额外生成"，不影响系统 `LANG`。典型用法是系统用英文
  （`language=english` 或 `None`），但需要中文程序正常显示，就填 `gen_locales=zh_CN.UTF-8`。
  留空时只生成 `language` 选中的那一个。
- `timezone` 写 `/etc/localtime` 软链。旧版本完全没有这一步，镜像按 UTC 走，桌面时间会差几个小时。

`rootfs_base=holo-core` 已移除：`scripts/host/holo-lib.sh`、`01b-bootstrap-holo.sh` 与
`scripts/lists-holo/` 在 `e960212` 删除，`distro-env.sh` 现在会直接拒绝该值。

## 许可与第三方组件

本仓库是构建脚本与 PKGBUILD 集合，自身不声明开源许可证（上游 `debian-sheng` 亦未声明）。
仓库内包含的第三方内容如下，版权归各自权利人：

| 内容 | 来源 | 许可 |
|---|---|---|
| `mkbootimg` | AOSP `system/tools/mkbootimg` | Apache-2.0 |
| `sm8550.config` | [ianchb/sm8550-mainline](https://github.com/ianchb/sm8550-mainline) | GPL-2.0（Linux 内核配置） |
| `patches/`（`adsprpcd-sensorspd.service`、`wait_for_qmi_service.patch`） | 上游 `debian-sheng` 及其各自上游 | 随各上游仓库 |
| `packages/*/payload/`（UCM2 配置、`sheng-devauth` unit、SSC 传感器注册表） | 上游 `alsa-xiaomi-sheng` / `sheng-devauth` / `sheng-sensors` 包 | 随上游 |
| 构建期下载的内核源码/deb、`xiaomi-*` deb、设备固件 | 各自的 GitHub release / 仓库 | 见各 `PKGBUILD` 的 `license=` |

`firmware-xiaomi-sheng` 在本仓库内只有 PKGBUILD，**固件二进制在构建时从上游 `sheng-firmware`
下载**，本仓库不重新分发；这些固件版权归高通 / 小米等各自权利人，仅用于在自有设备上运行 Linux。

## 致谢

- **map220v** — TWRP、主线内核移植与大量设备适配
- **alghiffaryfa19** — 上游原始构建脚本
- **ianchb** — [debian-sheng](https://github.com/ianchb/debian-sheng) 与 `xiaomi-*` 设备功能包
- **Dylan Van Assche** — `libssc` 与 `iio-sensor-proxy` 的 SSC 后端
