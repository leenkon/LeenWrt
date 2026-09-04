# fwx 跨内核差异 & 补丁对照表（LeenWrt vs fanchmwrt）

> 用途：解释 LeenWrt（immortalwrt v25.12.1 内核 6.12）为何必须给 fanchmwrt 的 fwx 模块源码打补丁，
> 以及三道补丁各自弥合的差异。作为"行为管理 / 应用过滤 / MAC 过滤操作后内核 panic + 规则丢失"的根因与修复依据。
> 最后更新：2026-08-31，钉点 `FWX_COMMIT=75d011a`（fanchmwrt-25.12.4）。

## 背景

LeenWrt 直接复用 fanchmwrt 的 fwx 四组件（`fwx` 内核模块 / `fwxd` 守护进程 / `libfwx_common` / `luci-theme-fanchmwrt`），
但**运行在 immortalwrt 自带的 6.12 内核上**。fanchmwrt 自己的固件跑的是它自带的内核，
该内核为 fwx 适配过 ABI；immortalwrt 内核没有这些适配。因此 fwx 模块源码在 immortalwrt 上
**不是"有 bug"，而是内核符号 ABI 不兼容**，必须由三道补丁弥合。

补丁应用时机：`scripts/diy.sh` 的 `before` 阶段（`WITH_FWX=1` 时），`_apply_fwx_src_patch` 已改为 **fail-fast**
（补丁上下文不符直接 `error_exit` 中断构建，不再静默跳过）。CI `LeenWrtBuilder.yml` 用 `sync-fwx.sh` 按
`FWX_COMMIT` **钉死 SHA** 拉取源码，避免上游改 `fwx_main.c` 后上下文漂移。

## 三处差异与补丁对照

| # | 差异点 | fanchmwrt 侧（源码/内核自带） | immortalwrt 6.12 侧 | 后果（不修） | 补丁 | 实测 apply |
|---|--------|------------------------------|---------------------|-------------|------|-----------|
| 1 | `nf_send_reset` 调用签名（**已推翻**） | 早期误判：6.12 仅导出 3 参，需 `kmod-nf_send_reset-6.12.patch` 改 3 参 | **实测推翻(2026-08-31)**：6.12 主线原生即 4 参 `(net,sk,oldskb,hook)`（5.11+ 起），fwx `>5.10.197` 分支 4 参调用**本就正确**、无需补丁 | 旧 3 参补丁方向错误（改 3 参→`sk` 取错→panic），**已废弃删除** | — | — |
| 2 | DPI `read_skb` L4 解析边界 | `parse_flow_proto` 未钳制，靠上游内核保护未暴露 | 6.12 + FORTIFY：`kmalloc(len)` 的 `len` 由发送方 `tot_len/udph->len/doff` 派生，未钳到 skb 尾部 → **FORTIFY memcpy BUG → panic** | `fwx-match-feature-crash.patch`（skb 尾部钳制 + `tcph->doff<5` / `udp_len<8` 守卫） | ✅ 钉点 clean apply |
| 3 | `struct nf_conn` 扩展字段 `fwx_data` | fanchmwrt 内核自带（`nf_conn` 含 `fwx_data`） | immortalwrt 内核无此字段，模块访问 `ct->fwx_data` 越界 | 内存损坏 / 规则无法关联 conntrack | `950-fwx-nf-conn-struct-user-hook.patch`（注入 `target/linux/generic/hack-6.12/`） | ✅ 逐字节一致，dry-run 通过 |

## 审计结论（2026-08-31 实测）

下载钉点 `75d011a` 的 `package/fcm/fwx` 源码，对打补丁后的 `src/fwx_main.c` 复核：

- `nf_send_reset`：6.12 内核**原生导出 4 参** `(net,sk,oldskb,hook)`（5.11+ 起）；fwx 源码 `>5.10.197` 分支的 `extern` @127 与三处调用 @2054/2406/2426 均为 4 参，**与内核签名一致、不会 panic**。早期"6.12 只导出 3 参"的误判已推翻；据此写的 `kmod-nf_send_reset-6.12.patch`（改 3 参）方向错误、会令 RST 时 `sk` 取错寄存器→panic，**已废弃删除、不再应用**。真正致 panic 的是下方 DPI `read_skb` 越界（#2），非 `nf_send_reset`。
- DPI 钳制：未打补丁 `parse_flow_proto` @1190 对 `l4_data/l4_len` 不钳 skb 尾部，`read_skb` 调用 @2179/2370 越界读 → FORTIFY BUG；`fwx-match-feature-crash.patch` 注入 `skb_tail_pointer` 钳制 + `tcph->doff`/`udph->len` 守卫。
- `fwx_data` 在 `fwx_main.c` 中大量引用（匹配分支 @2396/2401/2421），证明模块依赖 950 注入的 `struct nf_conn` 扩展字段——950 必须随 `WITH_FWX=1` 注入 `hack-6.12`。

**结论：三道补丁全部就位且对当前钉点干净 apply，源码树编译进 immortalwrt 6.12 后 ABI 自洽。无需再与 fanchmwrt 源码做大范围 diff——差异即上述三处内核适配。**

---

## 深度追加（2026-08-30 续查："新建规则重启 + 未保存"）

用户质疑"是不是补丁的事"，并指向"新建过滤规则后导致重启且未保存"。逐行核实 fwx 内核模块与 `rule_manager.lua`/`fwxd` 守护后，结论如下。

### 1. 用户规则真实下发路径（与早前 netlink 推断不同）

- **用户规则**：UI → luci-app → **UCI**（`/etc/config/appfilter`、`/etc/config/macfilter`、`/etc/config/fwx`，overlay 持久）→ `rule_manager.lua` 守护（轮询 `CHECK_INTERVAL=10`）读 UCI → 以 JSON `{"api":"add_app_filter_rule","data":{"rule_id":N}}` **写入字符设备 `/dev/fwx`**（`write_to_dev_fwx()`，`io.open("/dev/fwx","w")`）。
- 内核侧：`fwx_cdev_release` → `fwx_config_handle` → `cJSON_Parse`（受 `file->buf[256<<10]` 保护，`copy_from_user` 累积、`size+count>sizeof(buf)` 直接 `-EINVAL`，畸形 JSON 安全返回）→ 按 `api` 查 `k_request_api_list[]` 分发 → `fwx_api_add_app_filter_rule` → `fwx_add_app_filter_rule`（`kmalloc`+`list_add` 挂链表，**仅此而已，不碰 skb、不调 `nf_send_reset`、不做 DPI**）。
- **netlink 路径仅用于加载分类特征库，不是用户规则**：`fwxd` 守护 `fwx_load_feature_to_kernel` 读 `/tmp/feature.cfg`（由 `fwx.init:25` 软链到 `/etc/fwxd/feature.cfg`，overlay 持久）经 netlink `FWX_NL_MSG_ADD_FEATURE` 下发内核。该文件是 **app_id→名称 / `#class` 分组的特征库**（由 `gen_class.sh /tmp/feature.cfg` 生成），用于界面显示与 DPI 分类，**与用户过滤规则无关**。早期"netlink 接收越界读"假设只影响启动加载特征库，非"新建规则"路径，已排除。

> 全仓（含钉点源码）核实：对 `feature.cfg` 的所有打开均为 `O_RDONLY`/`"r"`（内核 `load_feature_buf_from_file`、fwxd `main.c:100`/`fwx_config.c:34`/`fwx_ubus.c:686`），**无任何写操作**——特征库是构建期/首次生成后只读加载，用户规则从不经此文件。

### 2. panic 真正触发点 = 包钩子匹配流量（所以"新建规则才崩"）

`fwx_ops[]` 注册于 `NF_INET_PRE_ROUTING`（`fwx_main.c:2502`，`nf_register_net_hooks` @2732），**每个包都过 fwx 钩子**。rule-add 只是把规则挂进链表"武装"过滤器；**规则生效后第一个匹配到的流量**才会走到崩溃代码：

- **`nf_send_reset` 4 参（6.12 实际兼容）**：`send_reset_packet`（:2049）被匹配分支调用，6.12 走 `#if LINUX_VERSION_CODE > KERNEL_VERSION(5,10,197)` 分支：
  ```c
  nf_send_reset(&init_net, skb->sk, skb, NF_INET_PRE_ROUTING);   // 4 参，:2054 / :2406 / :2426
  ```
  6.12 内核**原生导出 4 参** `nf_send_reset(net, sk, oldskb, hook)`（5.11+ 起），与 fwx 调用**签名一致、不会 panic**。早期"6.12 仅导出 3 参"的误判已推翻；据此写的 3 参改写补丁（`kmod-nf_send_reset-6.12.patch`）方向错误、**已废弃删除**。本路径不再是 panic 来源——真正致 panic 的是下方 DPI `read_skb` 越界（#2）。
- **DPI `read_skb` 未钳制**：`parse_flow_proto`（:1190）对 TCP/UDP **完全不校验 `l4_data`/`l4_len` 是否落在 skb 内**：
  ```c
  // TCP: l4_len = ipp_len - tcph->doff*4; l4_data = ipp + tcph->doff*4;  (doff 来自报文)
  // UDP: l4_len = ntohs(udph->len)-8;     l4_data = ipp + 8;            (udph->len 来自报文)
  ```
  这两个值直接喂给 `read_skb(skb, flow.l4_data - skb->data, flow.l4_len)`（:2179 / :2370）与 `dpi_https_proto` 的 `memcpy(&url_len, p+i+OFFSET, 2)`（:1297），**只按 `data_len` 自校验、不按 skb 尾部校验** → 越界读 → **FORTIFY memcpy BUG → panic**。

**即：实际补丁（DPI 钳制 #2 + 950 struct #3）正是修这条包钩子路径；"新建规则导致重启"的根因就是未打补丁的包钩子，只是崩溃发生在匹配流量上，而非保存动作本身。**

### 3. "未保存"真相 = 重启循环，不是持久化 bug

- 用户规则在 **UCI / overlay**，构建期与运行期均持久；`rule_manager` 只读 UCI、不写 UCI（写盘由 luci-app 完成并 `uci commit`）。
- 未打补丁时：每次启动 `rule_manager` 重新把 UCI 里的规则应用到内核 → 匹配流量 → 包钩子 panic → 重启 → 再应用 → 再 panic，形成**重启循环**。用户感知为"规则丢失/没保存"，实则是规则一直在 UCI 里、只是设备来不及稳定就被打崩。
- `feature.cfg` 经 `fwx.init:25` 软链到 `/etc/fwxd/feature.cfg`（overlay），同样持久；即便缺失也只是应用名显示异常，不影响规则持久化。
- **补丁就位（且真正编进 fwx.ko）后**，包钩子不再 panic → 规则正常生效且跨重启留存，"未保存"现象消失。

### 4. 为何"确认三补丁 apply 仍 panic" = 构建复用旧 .o（非补丁无效）

fwx 内核模块 `Makefile` **无 `PKG_RELEASE`**，`Build/Prepare` 仅按 Makefile 时间戳判断是否需要重新 prepare/编译。`diy.sh` 改了 `feeds/fwx/fwx/src/*.c`（打补丁）但 `Makefile` 时间戳未变 → 构建系统**复用 `build_dir` 里旧的 `.o`** → 静默产出**未打补丁的 `fwx.ko`** 进固件。CI 无 build_dir 缓存故 CI 直出正确；本地增量构建 / 旧 diy.sh（WARN 静默跳过补丁）易中招。

修复（`scripts/diy.sh` `before` 段，已加）：
1. **自检闸门**：DPI 补丁应用后 `grep -q skb_tail_pointer` 确认钳制已落入 `fwx_main.c`，否则 `error_exit` 中断构建——杜绝"补丁未真落模块"仍产出固件（`nf_send_reset` 4 参调用本就正确，无需自校验其缺失）。
2. `touch feeds/fwx/fwx/Makefile` 强制构建系统重新 prepare/编译 fwx，避免复用旧 `.o`。

> 上述 diy.sh 改动当前**工作树已改、未提交**（与 fwx 三补丁 fail-fast、密码 `-1`、`fwxd` 联网补丁等一并待提交推送）。

## 已知注意点

- `fwx-match-feature-crash.patch` 文件本身为 CRLF；GNU `patch`（构建宿主机）会自动剥离 CR 并 clean apply（已实测），无需处理。
- 950 仅针对 6.12 系列（`FWX_KERNEL_BASELINE=6.12`，系列内任意子版本放行，跨系列 fail-fast）。

## 修复行动

1. 用**当前仓库**（含 fail-fast diy.sh + 钉点 75d011a）重新触发构建，`with_fwx=true`。
2. 构建日志应出现 `applied fwx DPI bounds` / `applied fwxd internet check` / `injected fwx kernel patch`。
3. 刷入后：行为管理添加拦截规则不再 panic；非 panic 的正常重启后规则应保留（fanchmwrt 设计有持久化）。
4. 若仍 panic，先查 `[diy]` 构建日志是否 error_exit（补丁未中即中断，不会产出未修复固件）——说明钉点或内核基线已变，需重新对齐补丁/钉点。
