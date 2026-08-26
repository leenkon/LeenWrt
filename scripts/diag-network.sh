#!/bin/sh
# 设备端网络/后台诊断脚本：无法上网 + 无法进后台时串口/failsafe 跑一次即可定位。
# 输出覆盖 lo 接口、network 配置、overlay 挂载、服务监听、防火墙、关键日志。

log_h() { echo "\n===== $1 ====="; }

log_h "基础状态"
echo "时间: $(date)"
echo "uptime: $(uptime)"
echo "hostname: $(cat /proc/sys/kernel/hostname 2>/dev/null)"

log_h "IP 地址"
ip addr 2>/dev/null || ifconfig -a 2>/dev/null

log_h "路由表"
ip route 2>/dev/null || route -n 2>/dev/null

log_h "network 配置 (uci)"
uci show network 2>/dev/null

log_h "loopback 是否 UP"
ip link show lo 2>/dev/null || echo "WARN: 无法查看 lo"

log_h "overlay / 挂载状态"
mount 2>/dev/null | grep -E 'overlay|squashfs|ext4|/dev/sd|/dev/nvme|/dev/mmc|/dev/vd'

log_h "磁盘空间"
df -h 2>/dev/null | grep -E 'Filesystem|overlay|tmpfs|/dev/'

log_h "关键进程"
ps w 2>/dev/null | grep -E 'uhttpd|adguardhome|AdGuardHome|dnsmasq|openclash|firewall|nftables' | grep -v grep

log_h "监听端口 (53/80/443/5353/7874/9090)"
if command -v ss >/dev/null 2>&1; then
    ss -lun 2>/dev/null | grep -E ':53 |:80 |:443 |:5353 |:7874 |:9090 |:8030'
elif command -v netstat >/dev/null 2>&1; then
    netstat -lun 2>/dev/null | grep -E ':53 |:80 |:443 |:5353 |:7874 |:9090 |:8030'
else
    echo "无 ss/netstat"
fi

log_h "防火墙 zone"
uci show firewall 2>/dev/null | grep -E 'name=|input=|output=|forward=|masq='

log_h "nftables 规则"
nft list ruleset 2>/dev/null | head -100

log_h "DHCP 租约 / 接口状态"
uci show dhcp 2>/dev/null | head -40
ls /tmp/dhcp.leases 2>/dev/null && cat /tmp/dhcp.leases 2>/dev/null

log_h "关键日志 (logread)"
logread 2>/dev/null | grep -iE 'network unreachable|loopback|lo:|adguardhome|dns-hijack|uhttpd|ubus|firewall|kernel.*oops|panic|squashfs|blockdev' | tail -80

log_h "overlay 根文件是否可写"
touch /tmp/.diag_test 2>/dev/null && rm -f /tmp/.diag_test && echo "/tmp 可写" || echo "/tmp 不可写"
touch /etc/.diag_test 2>/dev/null && rm -f /etc/.diag_test && echo "/etc 可写(overlay 正常)" || echo "/etc 不可写(可能 initramfs/overlay 未挂载)"
