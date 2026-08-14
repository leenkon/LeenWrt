# fwx 应用过滤栈（vendored，LeenWrt 可选组件）

fwx 是 fork 自 OpenAppFilter 谱系的应用层过滤栈，由 `kmod-fwx`（内核模块）、
`fwxd`（守护）、`libfwx_common`（库）+ 15 个 `luci-app-fwx-*`（Luci 界面）组成。

## 来源（版本锚点）
- 上游仓库：fanchmwrt/fanchmwrt
- 上游分支：fanchmwrt-25.12.4
- 锚点 commit：75d011a8c317d88e6cf78f89403a349cceff2827  (2026-08-10)

> 升级时运行 `scripts/sync-fwx.sh` 会刷新以上锚点并同步源码 / 补丁。

## 组成
- `feeds/fwx/fwx` (kmod-fwx)：内核模块。硬依赖下方 950 内核补丁提供的 `struct nf_conn.fwx_data` 成员。
- `feeds/fwx/fwxd`：守护进程。
- `feeds/fwx/libfwx_common`：公共库。
- 15 个 `luci-app-fwx-*`：来自 `feeds/25.12.conf` 的 `src-git fwxluci`（fanchmwrt-packages），跟随上游不钉死。

## 内核补丁（构建必须）
- `patches/fwx/950-fwx-nf-conn-struct-user-hook.patch`
  port 自 fanchmwrt 的 `target/linux/generic/hack-6.12/`，给 `struct nf_conn` 加 `fwx_data` 成员
  （fwx 源码无条件读写 `ct->fwx_data`）。构建期由 `diy.sh before --with-fwx` 注入 openwrt 内核树自动 apply。

## kmod 6.12 兼容补丁（构建必须）
- `patches/fwx/kmod-nf_send_reset-6.12.patch`
  上游 `fwx_main.c` 在 `>5.10.197` 分支把 `nf_send_reset` 写成 4 参数，而 6.12 内核实际为 3 参数
  `(net, oldskb, hook)`。构建期由 `diy.sh before --with-fwx` 应用到 `feeds/fwx/fwx` 源码树。

## 升级（fork fwx）
运行 `scripts/sync-fwx.sh [branch]`（默认 `fanchmwrt-25.12.4`）：
1. 从 fanchmwrt 拉取最新 fwx kmod 源码覆盖 `feeds/fwx/fwx/`；
2. 同步 950 内核补丁；
3. 自动重放 kmod 6.12 补丁（若上游已自带 6.12 修复则跳过并警告）；
4. 刷新本 README 的版本锚点。
审阅 `git diff` 后提交推送。
