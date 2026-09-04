# fwx 应用过滤栈 + fanchmwrt 系统主题（四代码组件均构建期按钉死 SHA 动态拉取，不 vendored 进仓库；LeenWrt 可选组件）

fwx 是 fork 自 OpenAppFilter 谱系的应用层过滤栈，由 `kmod-fwx`（内核模块）、
`fwxd`（守护）、`libfwx_common`（库）+ 多个 `luci-app-fwx-*`（Luci 界面，清单见 fwx-packages.list）组成。

## 来源（版本锚点）
- 上游仓库：fanchmwrt/fanchmwrt
- 上游分支：fanchmwrt-25.12.4
- 路径：package/fcm/fwx
- 锚点 commit（= cores/leenwrt.conf 的 FWX_COMMIT）：75d011a8c317d88e6cf78f89403a349cceff2827  (2026-08-10)
- **kmod-fwx 核心在构建期由 LeenWrtBuilder.yml 调用 `scripts/sync-fwx.sh` 按 FWX_COMMIT 从 upstream 动态拉取到 `feeds/fwx/fwx`，源码不入库（构建产物）**；fanchmwrt 系统主题 `luci-theme-fanchmwrt` 同样按 `THEME_COMMIT`（同源同 SHA）动态拉取到 `feeds/fwx/luci-theme-fanchmwrt`，并设为 LuCI 默认主题。`scripts/sync-fwx.sh` 升级时一并刷新 FWX_COMMIT / THEME_COMMIT 与本条锚点，并刷新本地 `feeds/fwx/fwx`、`feeds/fwx/luci-theme-fanchmwrt` 副本供检视。

> 升级时运行 `scripts/sync-fwx.sh` 会刷新以上锚点并同步源码 / 补丁。

## 组成
- `feeds/fwx/fwx` (kmod-fwx)：内核模块。**构建期按钉死 SHA 动态拉取，不 vendored 进仓库**（见上「来源」）。硬依赖下方 950 内核补丁提供的 `struct nf_conn.fwx_data` 成员。
- `feeds/fwx/fwxd`：守护进程（构建期按 FWX_COMMIT 动态拉取，不 vendored 进仓库）。
- `feeds/fwx/libfwx_common`：公共库（构建期按 FWX_COMMIT 动态拉取，不 vendored 进仓库）。
- `luci-app-fwx-*`：来自 `feeds/25.12.conf` 的 `src-git fwxluci`（fanchmwrt-packages），清单见 fwx-packages.list，跟随上游不钉死。
- `feeds/fwx/luci-theme-fanchmwrt`（fanchmwrt 系统主题）：构建期按 `THEME_COMMIT` 从 `package/fcm/luci-theme-fanchmwrt` 动态拉取，不 vendored 进仓库；设为 LuCI 默认主题（`CONFIG_LUCI_DEFAULT_THEME="fanchmwrt"`），bootstrap 作为基础保留。

## 内核补丁（构建必须）
- `patches/fwx/950-fwx-nf-conn-struct-user-hook.patch`
  port 自 fanchmwrt 的 `target/linux/generic/hack-6.12/`，给 `struct nf_conn` 加 `fwx_data` 成员
  （fwx 源码无条件读写 `ct->fwx_data`）。构建期由 `diy.sh before --with-fwx` 注入 openwrt 内核树自动 apply。

## kmod 6.12 兼容补丁（已废弃，勿应用）
- 早期 `patches/fwx/kmod-nf_send_reset-6.12.patch`（把 `nf_send_reset` 改 3 参）方向错误：6.12 主线原生 4 参 `(net,sk,oldskb,hook)`，fwx 源码 `>5.10.197` 分支已正确调用 4 参；改 3 参会令 RST 时 `sk` 取错寄存器 → panic。该补丁**已删除、不再应用**，真正防 panic 的是下方 DPI 钳制补丁。

## 特征库（feature.cfg 与 feature.bin 双轨）

本仓库 fwx 与 OAF 两套应用过滤互斥，特征库载体不同：

- **fwx（fanchmwrt，`WITH_FWX=true`）**：守护 `fwxd` 读文本 `/etc/fwxd/feature.cfg`
  （`fwx.init` 软链 `/tmp/feature.cfg`），逐行经 netlink 下发内核；行格式 **v3.0**：
  `1002 微信:[tcp;;;weixin.qq;;]`（`id` + 空格 + 名字）。`fwxd` 用 `sscanf` 解析「第一个冒号前」片段，
  分隔符变化会直接破坏 app 名。**特征库由 `sync-fwx.sh` 按钉点带入的样例，构建期不再单独刷新**
  （保持钉点稳定，避免引入未验证版本）。
- **OAF（OpenAppFilter，与 fwx 互斥，`WITH_OAF=true`）**：守护 `oafd` 启动即解密
  `/etc/fwxd/feature.bin`（加密二进制），不读 `feature.cfg`。

| 项 | v3.0（fwx 现行） | v4.0（OAF 现行） |
| --- | --- | --- |
| 载体 | 文本 `feature.cfg` | 加密二进制 `feature.bin`（`/etc/fwxd/`） |
| 行格式 | `1002 微信:[...]` | `1101~Facebook:[...]`（`~` 分隔，附 `^` 等新语法） |
| 头标记 | `#version v26.4.10` / `#format v3.0` | `#version 26.01.01`（无 v）/ `#format v4.0` / `#type` / `#free` |
| 分发 | 随钉点打包 | 在线获取，免费档免 token |

`feature.bin` 格式（密钥随上游源码公开，非黑盒）：
24B 头 `magic "FWXB" | fmt=1 | alg=1(XTEA-CTR) | hdr_size=16b | plain_len=32b | crc32=32b | nonce=64b`（全 LE），
负载为 XTEA-CTR 流加密，keystream = `XTEA(nonce + 块序号)`，**计数器 64 位递增，截断成 32 位会让第 8 块起解密错乱**。
密钥 `8f4c29a1 73b6d502 c14e87f3 2ad95b60`；明文即与 feature.cfg 同构的文本行，crc32 不符即判损坏。

**OAF 官方免费库（无需订阅 key）**：`api.openappfilter.com` 在 `token` 留空（实际发 `0`，
即 LuCI 后台“更新列表”里 key 不填时的值）时返回 `free=1` 包——当前 `id=2606101`（`v26.06.10`，
**311 应用 + 507 图标**，约 1.2MB）。订阅包（`free=0`）才需 token。
仓库内置 `open-app-filter/files/feature.bin` 仅为 48 条国外样板，完整库走 API。

**OAF 特征库（首启自动更新）**：固件烧录的是 OAF 包内 48 条样板 `feature.bin`
（其 Makefile 装到 `/etc/fwxd/feature.bin`）。设备**首次启动**由 `diy.sh` 注入的
`rc.local` 一次性脚本，经 OAF 自带在线更新客户端（`ubus call fwx common`，UA 正确）
拉取官方最新 `free=1` 包（`id=2606101`，约 311 应用）覆盖之；成功后写
`/etc/oaf-feature-autoupdate.done` 守护，失败则下次启动重试。构建期不再手动拉取
（相关脚本已移除），以规避 CI 访问 api.openappfilter.com 不稳/易 403 的问题。

> fwx 侧若需升级到 v4.0 读 feature.bin，需从 OAF master 反向移植 `fwx_feature.c/.h` 等特征子系统
> （依赖 libcurl + json-c）并重打 DPI-clamp / nf_conn / nf_send_reset 补丁，非当前默认路径。

## 升级（fork fwx）
运行 `scripts/sync-fwx.sh [branch]`（默认 `fanchmwrt-25.12.4`）：
1. 从 fanchmwrt 拉取最新 fwx kmod 源码覆盖 `feeds/fwx/fwx/`，并同步 `luci-theme-fanchmwrt` 到 `feeds/fwx/luci-theme-fanchmwrt/`；
2. 同步 950 内核补丁；
3. 刷新本 README 的版本锚点。
审阅 `git diff` 后提交推送。
