# fwx 跨内核差异 & 补丁对照表（LeenWrt vs fanchmwrt）

> 用途：解释 LeenWrt（immortalwrt 内核 6.12）复用 fanchmwrt 的 fwx 模块时，三处内核 ABI 差异与补丁依据。

## 背景

LeenWrt 直接复用 fanchmwrt 的 fwx 四组件（`fwx` / `fwxd` / `libfwx_common` / `luci-theme-fanchmwrt`），但运行在
immortalwrt 自带的 6.12 内核上。fanchmwrt 自己的内核为 fwx 适配过 ABI，immortalwrt 没有。因此 fwx 模块在
immortalwrt 上**不是"有 bug"，而是内核符号 ABI 不兼容**，须由补丁弥合。

补丁时机：`scripts/diy.sh` `before` 阶段（`WITH_FWX=1`），`_apply_fwx_src_patch` 为 **fail-fast**（上下文不符即
`error_exit` 中断构建，不静默跳过）。CI 用 `sync-fwx.sh` 按 `FWX_COMMIT` 钉死 SHA 拉取源码，防上游改 `fwx_main.c` 致漂移。

## 差异与补丁对照

| # | 差异点 | fanchmwrt 侧 | immortalwrt 6.12 侧 | 后果（不修） | 补丁 |
|---|--------|--------------|---------------------|-------------|------|
| 1 | `nf_send_reset` 签名（**已推翻**） | 早期误判：6.12 仅导 3 参，需改 3 参 | 6.12 主线原生即 4 参 `(net,sk,oldskb,hook)`（5.11+），fwx `>5.10.197` 分支 4 参调用**本就正确** | 旧 3 参补丁方向错误（RST 时 `sk` 取错寄存器→panic），**已废弃删除** | — |
| 2 | DPI `read_skb` L4 解析边界 | `parse_flow_proto` 未钳制，靠上游内核保护未暴露 | `kmalloc(len)` 的 `len` 由发送方 `tot_len/udph->len/doff` 派生，未钳到 skb 尾 → FORTIFY memcpy BUG → panic | `fwx-match-feature-crash.patch`（skb 尾钳制 + `doff<5` / `udp_len<8` 守卫） | ✅ clean apply |
| 3 | `struct nf_conn` 扩展字段 `fwx_data` | 内核自带 | 无此字段，模块访问 `ct->fwx_data` 越界 | 内存损坏 / 规则无法关联 conntrack | `950-fwx-nf-conn-struct-user-hook.patch`（注入 `hack-6.12/`） | ✅ dry-run 通过 |

## 审计结论

- **`nf_send_reset` 无需补丁**：6.12 原生导出 4 参，fwx 源码 `extern` @127 与调用 @2054/2406/2426 均为 4 参，签名一致。
  据此写的 3 参改写补丁方向错误，**已废弃删除、勿回退**。
- **panic 真因是 #2（DPI `read_skb` 越界）**：`parse_flow_proto` @1190 对 TCP/UDP 不校验 `l4_data/l4_len` 是否落在
  skb 内，二者直接喂给 `read_skb` @2179/2370 → 越界读 → FORTIFY BUG。
- **"新建规则后重启"机理**：用户规则存 UCI（持久），`rule_manager` 每 10s 读 UCI 写入 `/dev/fwx` 挂链表；
  规则本身不触发崩溃，但**规则生效后第一个匹配流量**走到包钩子即 panic → 重启 → 再应用 → 重启循环。
  用户感知为"规则未保存"，实为崩溃循环。补丁就位后现象消失。
- **"补丁 apply 仍 panic" = 构建复用旧 `.o`**：fwx `Makefile` 无 `PKG_RELEASE`，改 `*.c` 后 Makefile 时间戳未变 →
  构建系统复用 `build_dir` 旧 `.o` → 静默产出**未打补丁的 `fwx.ko`**。已在 diy.sh 加两道闸门：
  ① 应用后 `grep -q skb_tail_pointer` 自检，缺失即 `error_exit`；② `touch Makefile` 强制重编。

## 已知注意点

- `fwx-match-feature-crash.patch` 文件为 CRLF；GNU `patch` 会自动剥离 CR 并 clean apply，无需处理。
- 950 仅针对 6.12 系列（`FWX_KERNEL_BASELINE=6.12`，系列内任意子版本放行，跨系列 fail-fast）。
