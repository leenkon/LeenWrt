# apps/ —— 离线安装包目录（自编译或本地上传皆可）

本目录存放**离线**的 `.apk` 安装包——既可以是你本地编译的产物，也可以是从可信来源
下载 / **手动上传**的预编译包——统一在首次启动时由 `files/etc/init.d/firstboot-pkgs`
离线安装（`apk --allow-untrusted add`）。
来源不限，关键是**与目标内核的 vermagic 匹配、且来源可信**。

## 适用场景
- **带 vermagic 的 kmod**（内核模块，如网卡驱动、kmod-tun、fwx 等）：
  官方 release 源的 kmod 与自编译内核的 vermagic 不一致，`insmod` 会拒绝加载，
  因此必须随固件编译进镜像（由 `build.sh` / workflow 在 `.config` 追加 `CONFIG_PACKAGE_kmod-*` 段 + `make defconfig` 生成）或作为同源编译的 `.apk` 离线装。
- **闭源 / 自编译 / 非官方源的 userspace 包**（如 OpenClash、AdGuardHome 包装成的 `.apk`、
  你自己的 Lua 应用等），官方 apk 源取不到的，放这里离线装。

## 放置规则
- 直接把 `.apk` 丢进本目录即可，构建脚本会自动拷到镜像的
  `/etc/firstboot-pkgs/apps/` 并在首启安装。
- `*.apk` 已被 `.gitignore` 忽略，**不会提交进仓库**（避免大二进制入库）；
  这些包可以是本地编译产物，也可以是手动上传 / 下载的预编译包，只要来源可信即可。
- 纯官方源就能取到的 userspace 包，请随固件编译进镜像（在对应 `.config` 追加 `CONFIG_PACKAGE_*`）或离线 `.apk` 放入本目录，不要放这里。

## 注意
- 原始二进制（如 OpenClash 的 clash_meta 核心、AdGuardHome 可执行文件）不是 `.apk`，
  应直接放进对应核心的 `files/<core>/`（编译进镜像），而不是本目录。
- fwx 应用过滤栈：`kmod-fwx` 由 build.sh 构建期按钉死 SHA 从 upstream 动态拉取（不 vendored 进仓库）；`fwxd`/`libfwx_common` 由本地 vendored feed `feeds/fwx/` 提供；15 个 `luci-app-fwx-*` 界面包通过 `feeds/25.12.conf` 中的 `src-git fwxluci` 跟随上游。三者均随固件编译进镜像，无需放这里。若拿到自编译 / 手动上传的可信 `.apk`（含 `kmod-fwx*.apk`），放这里即可在首启离线安装。
