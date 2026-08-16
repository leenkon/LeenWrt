# fix(kmod-fwx): 钳制 DPI 包解析边界，避免畸形包触发内核 oops

> 草稿：提交至 `fanchmwrt/fanchmwrt` 分支 `fanchmwrt-25.12.4`
> 适配路径 `package/fcm/fwx/src/fwx_main.c`（fwx 源码最后改动 `bb1460e`，2026-06-12）

## 摘要

`kmod-fwx` 在 netfilter 收包 hook 做 DPI 时，对从 skb payload 解析出的 `url_pos` / `host_pos`
指针**全程未做边界校验**。遇到畸形 / 截断包会让指针越过 skb 尾，`af_is_flow_host_ip_literal`
的 `memcpy` 与 AC 自动机扫描读到非法地址 → page fault → 内核 oops。由于崩溃发生在收包路径，
表现为**硬重启**（网卡 down→up，体感与"断流"无法区分）。

本补丁在解析链各关节加长度 / NULL 守卫，把 L4 载荷长度钳到真实 skb 尾；畸形包直接返回
`NF_ACCEPT` 放行，不再越界。

## 影响 / 复现

- 触发：桥接 / 转发特定畸形包（截断 TCP、异常 TLS ClientHello、畸形 QUIC / DNS）经 fwx gateway hook。
- 现象：栈顶 `fwx_match_feature+0xee/0x670 [fwx]`，RIP 落在模块内部；崩溃路径
  `read_skb → fwx_hook_gateway_handle → fwx_pre_hook → nf_hook_slow → ip_rcv`。
- 范围：fwx 源码自 `bb1460e` 起即存在（25.12.x 全系同源），**与内核版本无关**
  （模块对本机 6.12 内核编译，`vermagic` 与符号 CRC 对齐，能干净加载）。
- 与 `feature.cfg` 无关：该文件仅在加载期被读入内存 AC / 正则表，收包路径只读 skb + 内存表。

## 根因（调用链）

1. `read_skb()`（原版 ~L1159）不校验 `from + len ≤ skb->len`，直接 `kmalloc` + `skb_prepare_seq_read`。
2. `parse_flow_proto()` 用包内 `iph->tot_len` / `tcph->doff` / `udph->len` 算 `l4_len`，
   畸形值可得负值或越界，后续 `dpi_*` 按此长度读 skb。
3. `dpi_https_proto()` / `dpi_http_proto()` 循环内 `data[i+1..i+3]` 不校验 `i+3 < data_len`。
4. `af_is_flow_host_ip_literal()`（~L259）直接 `memcpy(host_buf, url_pos, copy_len)`，
   `url_pos` 来自上述未校验指针 → OOB 读。

## 修复

把 L4 载荷长度钳到 `skb_tail_pointer`，TCP 校验 `doff>=5` 且不越界、UDP 校验 `udp_len>=8`
且钳到 `ipp_len`；`read_skb` 加 skb / 长度边界检查；http(s) 循环索引加 `i+3 < data_len` 界。

```diff
--- a/package/fcm/fwx/src/fwx_main.c
+++ b/package/fcm/fwx/src/fwx_main.c
@@ -1162,6 +1162,9 @@ static unsigned char *read_skb(struct sk_buff *skb, unsigned int from, unsigned
 	unsigned char *msg_buf = NULL;
 	unsigned int consumed = 0;
 
+	if (!skb || len == 0 || from >= skb->len || len > skb->len - from)
+		return NULL;
+
 	msg_buf = kmalloc(len, GFP_KERNEL);
 	if (!msg_buf)
 		return NULL;
@@ -1220,18 +1223,49 @@ int parse_flow_proto(struct sk_buff *skb, flow_info_t *flow)
 		return -1;
 	}
 
+	/* Bind the L4 payload to the real skb tail so a malformed packet
+	 * (forged iph->tot_len / tcph->doff / udph->len) cannot make the DPI
+	 * parsers read past the skb and oops the kernel (was fwx_match_feature
+	 * -> af_is_flow_host_ip_literal memcpy from an OOB url_pos/host_pos). */
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
@@ -1279,7 +1313,7 @@ int dpi_https_proto(flow_info_t *flow)
 	if (!((p[0] == 0x16 && p[1] == 0x03 && p[5] == 0x01) || flow->client_hello))
 		return -1;
 
-	for (i = 0; i < data_len; i++)
+	for (i = 0; i + 3 < data_len; i++)
 	{
 		if (i + HTTPS_URL_OFFSET >= data_len)
 		{
@@ -1341,7 +1375,7 @@ void dpi_http_proto(flow_info_t *flow)
 		return;
 	}
 
-	for (i = 0; i < data_len; i++)
+	for (i = 0; i + 3 < data_len; i++)
 	{
 		if (data[i] == 0x0d && data[i + 1] == 0x0a)
 		{
```

## 验证

- `patch -p1 --dry-run` 干净应用，无 fuzz / 偏移。
- 与 kmod 6.12 兼容补丁（`nf_send_reset` 4→3 参）顺序应用验证通过（kmod 先打，本补丁自动消化 +1 行偏移）。
- 950 内核补丁（给 `struct nf_conn` 加 `fwx_data`）与本修复无交集，不受影响。
- 行为：畸形包现在 `parse_flow_proto<0 → return NF_ACCEPT` 直接放行，不再越界。

## 备注

- `feature.cfg` 仅在加载期消费，与此 oops 无关；版本错位至多影响匹配准确度。
- 950 补丁为 fwx 硬依赖（fwx 经 `ct->fwx_data.*` 访问），本修复不改它。
- 建议：合入后下游（如 LeenWrt）钉新 `FWX_COMMIT` 即可退役本地等价补丁。
