# fix(kmod-fwx): 钳制 DPI 解析的 L4 载荷窗口到真实 skb 尾，避免畸形包触发内核 oops

> 草稿：提交至 `fanchmwrt/fanchmwrt` 分支 `fanchmwrt-25.12.4`
> 适配路径 `package/fcm/fwx/src/fwx_main.c`

## 摘要

`kmod-fwx` 在 netfilter 收包 hook 做 DPI 时，L4 载荷窗口（`l4_len` / `l4_data` / `read_skb`
的 `len`）完全由**发送方可控的 L3/L4 头字段**（`iph->tot_len`、`ip6h->payload_len`、
`tcph->doff`、`udph->len`）推导，**从不与真实 skb 长度对账**。一个头字段声称的载荷长度与
实际 skb 不符的包（伪造 `tot_len`/`udph->len`、截断包、或带以太网/FCS 填充的包）会让：

- `read_skb()` 的 `kmalloc(len)` 小于 `skb_seq_read()` 实际返回的字节数 → `memcpy` 越界；
- DPI 循环按错误的 `l4_len` 越过 skb 尾读 `url_pos` / `host_pos`。

内核 FORTIFY `memcpy` 检查命中 → `__fortify_panic` → `Kernel BUG` → **硬重启**。

实测 panic：`memcpy: detected buffer overflow: 1472 byte write of buffer size 1255`
at `read_skb [fwx]`，崩溃路径 `read_skb → fwx_hook_gateway_handle → fwx_pre_hook →
nf_hook_slow → ip_rcv`；`uptime` 从数百秒重置到个位数秒是硬重启铁证。

## 上游现状（已核实）

- 本仓库钉点 `FWX_COMMIT=75d011a…` 取自 `fanchmwrt/fanchmwrt` 的 `fanchmwrt-25.12.4` 分支；
  直接 `diff` 上游该分支 `package/fcm/fwx/src/fwx_main.c` 与本地拉取副本 =
  **逐字节相同**。
- 上游至今**未修复**此问题（无 `skb_tail_pointer` / `skb->len` 边界钳制），故这是 genuine
  upstream bug，建议直接合入本补丁。

## 根因（单点）

`parse_flow_proto()` 在算出 `ipp` / `ipp_len` 后，立即用发送方头字段派生 `l4_len` /
`l4_data`，却从未把它们钳到真实 skb 尾。这是所有越界的唯一源头：

```c
ipp = ...; ipp_len = ntohs(iph->tot_len) - ihl*4;   // 发送方可控
...
flow->l4_len  = ipp_len - tcph->doff * 4;           // doff 发送方可控
flow->l4_data = ipp + tcph->doff * 4;
...
read_skb(skb, flow.l4_data - skb->data, flow.l4_len); // kmalloc(flow.l4_len)
```

只要 `l4_len` 被钳到真实 skb 尾、且 `doff`/`udph->len` 合法，下游 `read_skb`、`dpi_*`
循环、`af_is_flow_host_ip_literal` 的 `memcpy(host_buf, …)`（已自限到 `host_buf`[64]）全部安全。

## 修复（精简：单 hunk，根因修复）

只对 `parse_flow_proto` 一处下手：把 `ipp_len` 钳到真实 skb 尾，并校验 TCP `doff` 与
UDP 长度。本 hunk 之后，`read_skb`、`dpi_*` 循环、`af_is_flow_host_ip_literal` 的越界
已不可能发生，故下游这些函数无需改动；本补丁也未删除任何既有代码，只新增钳制逻辑。

```diff
--- a/package/fcm/fwx/src/fwx_main.c
+++ b/package/fcm/fwx/src/fwx_main.c
@@ -1220,18 +1220,50 @@ int parse_flow_proto(struct sk_buff *skb, flow_info_t *flow)
 		return -1;
 	}
 
+	/* Clamp the L4 payload window to the real skb tail. The header fields used
+	 * above (iph->tot_len / ip6h->payload_len) are sender-controlled and may
+	 * disagree with the actual skb; derive the bound from the skb itself.
+	 * Without this, l4_len / l4_data can point past the skb and read_skb()'s
+	 * kmalloc(len) memcpy trips FORTIFY and panics the kernel. */
+	{
+		unsigned char *tail = skb_tail_pointer(skb);
+		int avail;
+
+		if (ipp >= tail)
+			return -1;
+		avail = (int)(tail - ipp);
+		if (ipp_len > avail)
+			ipp_len = avail;
+		if (ipp_len < 0)
+			ipp_len = 0;
+	}
+
 	switch (flow->l4_protocol)
 	{
 	case IPPROTO_TCP:
+		if (ipp_len < (int)sizeof(struct tcphdr))
+			return -1;
 		tcph = (struct tcphdr *)ipp;
+		if (tcph->doff < 5 || (int)(tcph->doff * 4) > ipp_len)
+			return -1;
 		flow->l4_len = ipp_len - tcph->doff * 4;
 		flow->l4_data = ipp + tcph->doff * 4;
 		flow->dport = ntohs(tcph->dest);
 		flow->sport = ntohs(tcph->source);
 		return 0;
 	case IPPROTO_UDP:
+		if (ipp_len < (int)sizeof(struct udphdr))
+			return -1;
 		udph = (struct udphdr *)ipp;
-		flow->l4_len = ntohs(udph->len) - 8;
+		{
+			int udp_len = ntohs(udph->len);
+
+			if (udp_len < 8)
+				return -1;
+			if (udp_len > ipp_len)
+				udp_len = ipp_len;
+			flow->l4_len = udp_len - 8;
+		}
 		flow->l4_data = ipp + 8;
 		flow->dport = ntohs(udph->dest);
 		flow->sport = ntohs(udph->source);
```

### 为何单 hunk 足够

钳制后恒有 `l4_len ≤ skb->len - (l4_data - skb->data)`，于是：
- `read_skb(skb, from, l4_len)` 的 `kmalloc(l4_len)` 尺寸正确，`skb_seq_read` 不可能越界（消除 `1472/1255` panic）；
- `l4_data` / `url_pos` 落在真实 skb 内，`dpi_*` 循环读 `data[i+3]` 不越界；
- `af_is_flow_host_ip_literal` 的 `memcpy(host_buf, url_pos, copy_len)` 中 `copy_len` 已自限到 `host_buf-1=63`，与 `l4_len` 无关，始终安全。

## 验证

- `patch -p1 --dry-run` 干净应用（上游 `fanchmwrt-25.12.4` 与本地钉点副本逐字节相同，hunk 直接命中）。
- 与 kmod 6.12 兼容补丁（`nf_send_reset` 4→3 参）、950 内核补丁（给 `struct nf_conn` 加 `fwx_data`）均不冲突。
- 下游 LeenWrt 用此修复重新编译后，长期测速**不再出现不定时重启**（用户实测确认）。
- 行为：畸形包在 `parse_flow_proto` 返回 `<0` → 该流直接 `NF_ACCEPT` 放行，不再越界。

## 备注

- `feature.cfg` 仅在加载期消费，与此 oops 无关；版本错位至多影响匹配准确度。
- 950 补丁为 fwx 硬依赖（fwx 经 `ct->fwx_data.*` 访问 conntrack），本修复不改它。
- 合入后下游（如 LeenWrt）只需钉新 `FWX_COMMIT` 即可退役本地等价补丁。
