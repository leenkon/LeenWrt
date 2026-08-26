#!/bin/sh
# LeenWrt Full 主路由急救/定案脚本（无需重新编译）
# 串口或 failsafe 下运行：/bin/sh /path/recover-lan.sh
# 覆盖假设：A lan 区三态  B 网口(本脚本只诊断)  C uhttpd  D DHCP  E 刷错profile(Mini当Full)  F fwx内核补丁oops
# 末尾给结论，指明下一步。

log(){ echo "### $*"; }

log "[1] 设备自身地址（判断是否刷错 profile）"
echo "lan.ipaddr = $(uci -q get network.lan.ipaddr 2>/dev/null || echo '<空>')"
echo "wan.proto  = $(uci -q get network.wan.proto 2>/dev/null || echo '<无wan: 疑为Mini/旁路由>')"
echo "hostname   = $(uci -q get system.@system[0].hostname 2>/dev/null)"

log "[2] 接口与地址"
ip -brief addr 2>/dev/null || ip addr 2>/dev/null

log "[3] LAN 防火墙区三态（假设 A）"
LAN_FW=$(uci show firewall 2>/dev/null | grep "\.name='lan'" | cut -d. -f1-2)
if [ -z "$LAN_FW" ]; then
  echo "!! 未找到 lan 区"
else
  echo "lan zone: $LAN_FW  input=$(uci get ${LAN_FW}.input 2>/dev/null || echo '<默认>')  output=$(uci get ${LAN_FW}.output 2>/dev/null || echo '<默认>')  forward=$(uci get ${LAN_FW}.forward 2>/dev/null || echo '<默认>')"
  echo ">> 强制三态 ACCEPT"
  uci set ${LAN_FW}.input='ACCEPT'; uci set ${LAN_FW}.output='ACCEPT'; uci set ${LAN_FW}.forward='ACCEPT'
  uci commit firewall
fi

log "[4] fwx 内核模块与内核日志（假设 F）"
echo "lsmod fwx: $(lsmod 2>/dev/null | grep -i fwx || echo '<未加载>')"
echo ">> dmesg 中 fwx/oops/panic 痕迹:"
dmesg 2>/dev/null | grep -iE 'fwx|oops|panic|call trace|general protection|BUG:' | tail -15 || echo "  (无或 dmesg 不可读)"

log "[5] nftables 是否有异常 drop/reject"
nft list ruleset 2>/dev/null | grep -iE 'drop|reject' | head -10 || echo "  (nft 不可读或无匹配)"

log "[6] uhttpd 后台（假设 C）"
/etc/init.d/uhttpd enabled 2>/dev/null || /etc/init.d/uhttpd enable
/etc/init.d/uhttpd restart 2>/dev/null
sleep 1
(netstat -tlnp 2>/dev/null || ss -tlnp 2>/dev/null) | grep -E ':80 |:443 ' || echo "!! 80/443 无监听"

log "[7] lan 口 DHCP（假设 D）"
/etc/init.d/dnsmasq enabled 2>/dev/null || /etc/init.d/dnsmasq enable
/etc/init.d/dnsmasq restart 2>/dev/null
[ "$(uci -q get dhcp.lan.ignore)" = "1" ] && echo "!! lan dhcp 被 ignore" || echo "lan dhcp 正常"

log "[8] 重启网络与防火墙"
/etc/init.d/network restart 2>/dev/null
/etc/init.d/firewall restart 2>/dev/null

echo
echo "==== 结论判定 ===="
LIP=$(uci -q get network.lan.ipaddr 2>/dev/null)
WPRO=$(uci -q get network.wan.proto 2>/dev/null)
if [ "$LIP" != "10.10.10.1" ] || [ -z "$WPRO" ]; then
  echo "[判定 E] lan.ipaddr=$LIP 且/或 无 wan -> 极可能刷成了 Mini(旁路由)。Full 应为 10.10.10.1 + wan=dhcp。请确认构建选的是 Full(profile 1)并重新刷。"
fi
if lsmod 2>/dev/null | grep -qi fwx; then
  echo "[fwx] kmod-fwx 已加载(未直接崩)；若仍双死，看上面 dmesg 有无 oops 残留，或改用 WITH_FWX=false 重建隔离验证。"
else
  echo "[fwx] kmod-fwx 未加载(modprobe 失败) -> 950 补丁在 6.12 未编译/未注入成功。建议 WITH_FWX=false 重建一次确认。"
fi
echo "若上述修复后能进 10.10.10.1 后台 -> 根因 A(lan 区被挡)，已修复。"
echo "若仍双死 -> 贴本脚本完整输出 + 'logread | tail -40' 继续查。"
