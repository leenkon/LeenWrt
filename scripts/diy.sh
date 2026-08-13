#!/bin/bash
set -e

error_exit() { echo "ERR: $1" >&2; exit 1; }

_escape_uci() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

is_valid_ipv4() {
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$1"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$o" -le 255 ] || return 1
    done
    case "$o1" in 0|127) return 1 ;; 169) [ "$o2" = "254" ] && return 1 ;; esac
    { [ "$o4" -eq 0 ] || [ "$o4" -eq 255 ]; } && return 1
    return 0
}

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
SUBNET_MASK="255.255.255.0"
DNS_MAIN="223.5.5.5"
DNS_BACKUP="223.6.6.6"

VERSION="" PHASE="" PROFILE_TYPE="" CORE="leenwrt" FEEDS_SRC="" FILES_DIR_NAME="files"
NO_ADGH=0 WITH_FWX=0
CUSTOM_IP="" CUSTOM_GATEWAY="" BYPASS_IP="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase)   PHASE="$2"; shift 2 ;;
        -t|--type)    PROFILE_TYPE="$2"; shift 2 ;;
        --ip)         CUSTOM_IP="$2"; shift 2 ;;
        --gateway)    CUSTOM_GATEWAY="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --root-pass)  ROOT_PASSWORD="$2"; shift 2 ;;
        --bypass-ip) BYPASS_IP="$2"; shift 2 ;;
        --no-adgh)   NO_ADGH=1; shift ;;
        --with-fwx)  WITH_FWX=1; shift ;;
        --core)      CORE="$2"; shift 2 ;;
        --feeds)     FEEDS_SRC="$2"; shift 2 ;;
        --files-dir) FILES_DIR_NAME="$2"; shift 2 ;;
        *) error_exit "未知参数 $1" ;;
    esac
done

[ -n "$VERSION" ] && [ -n "$PHASE" ] || error_exit "必填 --version / --phase"
[ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ] && error_exit "after阶段必须指定 --type main/bypass/full"
case "$PROFILE_TYPE" in ""|main|bypass|full) ;; *) error_exit "--type 仅支持 main / bypass / full" ;; esac

if [ "$PROFILE_TYPE" = "bypass" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_BYPASS_IP"
    [ -z "$CUSTOM_GATEWAY" ] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
    [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ] && error_exit "旁路由不支持PPPoE，请使用 --type main/full"
    [ -z "$BYPASS_IP" ] && BYPASS_IP="$CUSTOM_IP"
elif [ "$PROFILE_TYPE" = "full" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法路由IP: $CUSTOM_IP"
else
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法主路由IP: $CUSTOM_IP"
    [ -z "$BYPASS_IP" ] && BYPASS_IP="$DEF_BYPASS_IP"
    is_valid_ipv4 "$BYPASS_IP" || error_exit "非法旁路路由IP: $BYPASS_IP"
fi

if [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ]; then
    [ -z "$PPPOE_USERNAME" ] || [ -z "$PPPOE_PASSWORD" ] && error_exit "PPPoE账号密码必须成对传入"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
[ -d "$PROJECT_ROOT" ] || error_exit "无法定位项目根目录: $PROJECT_ROOT"

case "$PHASE" in
before)
    echo "[diy] before: $VERSION (core=$CORE)"
    if [ -n "$FEEDS_SRC" ]; then
        FEED_CONF_SRC="$FEEDS_SRC"
    else
        FEED_CONF_SRC="$PROJECT_ROOT/feeds/$VERSION.conf"
    fi
    [ -f "$FEED_CONF_SRC" ] || error_exit "缺失feed配置: $FEED_CONF_SRC"
    rm -f feeds.conf
    cp "$FEED_CONF_SRC" feeds.conf
    ;;

after)
    echo "[diy] after: $PROFILE_TYPE"
    # NO_ADGH 仅 full 模式有意义；main/bypass 强制 NO_ADGH=0（均带 ADGH，bypass 即 ADGH+OC 旁路由）
    [ "$PROFILE_TYPE" != "full" ] && NO_ADGH=0
    case "$FILES_DIR_NAME" in
      /*) FB_DIR="$FILES_DIR_NAME" ;;
      *)  FB_DIR="$PROJECT_ROOT/$FILES_DIR_NAME" ;;
    esac
    OUT="$FB_DIR/etc/uci-defaults/99-custom.sh"
    SHADOW="$FB_DIR/etc/shadow"
    mkdir -p "$(dirname "$OUT")"
    rm -f "$OUT" "$SHADOW"

    ip_esc=$(_escape_uci "$CUSTOM_IP")

        # ===== 公共配置块（各 profile 按需引用） =====
    # 1) IP 转发开关：所有 profile 统一开启
    IP_FORWARD_LN='grep -q '\''net.ipv4.ip_forward=1'\'' /etc/sysctl.conf || echo '\''net.ipv4.ip_forward=1'\'' >> /etc/sysctl.conf'

    # 2) full/main 共用：LAN 静态地址（lan6 删除、ip6assign、proto、ipaddr、netmask）
    LAN_WAN_COMMON_BLK=$(cat <<EOF
uci -q delete network.lan6
uci set network.lan.ip6assign='64'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci commit network
EOF
)

    # 3) bypass/full 共用：OpenClash meta/redir-host 配置
    OC_CONFIG_BLK=$(cat <<'EOF'
uci -q get openclash.config.core_type >/dev/null || uci set openclash.config=openclash
uci set openclash.config.core_type='Meta'
uci set openclash.config.core_version='linux-amd64'
uci set openclash.config.enable_redirect_dns='0'
uci set openclash.config.en_mode='redir-host'
uci set openclash.config.operation_mode='redir-host'
uci set openclash.config.enable_custom_overwrite='1'
uci commit openclash
EOF
)

    # 3b) 带 ADGH 时启用二进制 AdGuardHome（init.d 经 files/ 注入；Procd 脚本需 enable 才开机自启）
    ADGH_ENABLE_BLK=$(cat <<'EOF'
chmod 755 /etc/init.d/adguardhome
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start
EOF
)

    # 4) full/main 共用：LAN 区 forward + lan->wan forwarding 重置
    LAN_FORWARD_BLK=$(cat <<'EOF'
LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && uci set ${LAN_FW}.forward='ACCEPT'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'
EOF
)

    # 5) full/main 共用：dns-hijack + firewall include（放在最后，避免上游未就绪时形成黑洞）
    DNS_HIJACK_BLK=$(cat <<'EOF'
chmod 755 /usr/sbin/dns-hijack
/usr/sbin/dns-hijack
uci -q delete firewall.dns_hijack_include
uci set firewall.dns_hijack_include=include
uci set firewall.dns_hijack_include.path='/usr/sbin/dns-hijack'
uci set firewall.dns_hijack_include.enabled='1'
uci commit firewall
EOF
)

    # 6) full/main 共用：DHCP 公共段（范围、RA、下发单 DNS 等）
    DHCP_COMMON_BLK=$(cat <<EOF
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,$ip_esc'
uci set dhcp.lan.start='7'
uci set dhcp.lan.limit='149'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].sequential_ip='1'
EOF
)

    # 7) full/main 共用：WAN 段（PPPoE / DHCP）提前生成，避免两个分支重复
    if [ "$PROFILE_TYPE" = "full" ] || [ "$PROFILE_TYPE" = "main" ]; then
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME"); p=$(_escape_uci "$PPPOE_PASSWORD")
            WAN_BLK=$(cat <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
            uci set network.wan.ipv6='auto'
            uci set network.wan.peerdns='1'
            uci set network.wan.device='eth0'
            uci -q delete network.wan6
EOT
)
        else
            WAN_BLK=$(cat <<EOT
            uci set network.wan.proto='dhcp'
            uci set network.wan.peerdns='1'
            uci set network.wan.device='eth0'
            uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
EOT
)
        fi
    fi

    echo '#!/bin/sh' > "$OUT"
    echo "logger -t uci-defaults \"开始应用${PROFILE_TYPE}配置\"" >> "$OUT"

    if [ "$PROFILE_TYPE" = "bypass" ]; then
        gw_esc=$(_escape_uci "$CUSTOM_GATEWAY")
        cat >> "$OUT" <<EOT
$IP_FORWARD_LN
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.lan.gateway='$gw_esc'
uci -q delete network.lan.dns
uci add_list network.lan.dns='$DNS_MAIN'
uci add_list network.lan.dns='$DNS_BACKUP'
uci -q delete network.lan6
uci -q delete network.wan
uci -q delete network.wan6
uci commit network

uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].port='5453'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp

LAN_FW=\$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
WAN_FW=\$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "\$LAN_FW" ] && {
    uci set \${LAN_FW}.input='ACCEPT'
    uci set \${LAN_FW}.output='ACCEPT'
    uci set \${LAN_FW}.forward='ACCEPT'
    uci set \${LAN_FW}.masq='1'
    uci set \${LAN_FW}.mtu_fix='1'
}
[ -n "\$WAN_FW" ] && {
    uci set \${WAN_FW}.network=''
    uci set \${WAN_FW}.masq='0'
}
while uci -q delete firewall.@forwarding[0]; do :; done
uci commit firewall

$OC_CONFIG_BLK
$ADGH_ENABLE_BLK
EOT
    elif [ "$PROFILE_TYPE" = "full" ]; then
        cat >> "$OUT" <<EOT
$WAN_BLK
$LAN_WAN_COMMON_BLK

$IP_FORWARD_LN

$DHCP_COMMON_BLK
EOT
        if [ "$NO_ADGH" = "1" ]; then
            # noadgh：dnsmasq 占 :53，上游指向 OpenClash redir-host DNS(:7874) + 纯阿里云兜底；
            # OC 停止时 dnsmasq 直连阿里云兜底，避免 DNS 全断（兼容 OC 停止场景）
            cat >> "$OUT" <<EOT
uci -q delete dhcp.@dnsmasq[0].port
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#7874'
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp
EOT
        else
            # 带 ADGH：dnsmasq 让出 :53（port 5453，仅 DHCP），AdGuardHome 占 :53
            # 纯阿里云 DNS 兜底（明文 223.5.5.5/223.6.6.6），noresolv=1 不读 ISP resolv.conf
            cat >> "$OUT" <<EOT
uci -q set dhcp.@dnsmasq[0].port='5453'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp
EOT
        fi
        cat >> "$OUT" <<EOT
$LAN_FORWARD_BLK
uci add firewall rule
uci set firewall.@rule[-1].name='Block-QUIC'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='443'
uci set firewall.@rule[-1].target='REJECT'
uci commit firewall

$OC_CONFIG_BLK
EOT
        if [ "$NO_ADGH" != "1" ]; then
            cat >> "$OUT" <<EOT
$ADGH_ENABLE_BLK
EOT
        fi
        cat >> "$OUT" <<EOT
$DNS_HIJACK_BLK
EOT
    else
        cat >> "$OUT" <<EOT
$WAN_BLK
$LAN_WAN_COMMON_BLK

$IP_FORWARD_LN

$DHCP_COMMON_BLK
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$BYPASS_IP'
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp

$LAN_FORWARD_BLK

$DNS_HIJACK_BLK
EOT
    fi

    # fwx 应用过滤(DPI 内核模块)依赖 conntrack，与流卸载冲突会导致连接不稳/应用过滤失效，故开启 fwx 时关闭流卸载
    FLOFF=1; FLOFF_HW=1
    [ "$WITH_FWX" = "1" ] && FLOFF=0 && FLOFF_HW=0
    cat >> "$OUT" <<EOT
uci set firewall.@defaults[0].flow_offloading='$FLOFF'
uci set firewall.@defaults[0].flow_offloading_hw='$FLOFF_HW'
uci commit firewall

uci set system.@system[0].hostname='LeenWrt-${PROFILE_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system

# 固定 CPU 为 performance，避免降频导致网络抖动
chmod 755 /etc/init.d/cpufreq-perf
/etc/init.d/cpufreq-perf enable
/etc/init.d/cpufreq-perf start

# 首启离线安装 apps/ 中的 .apk（允许未签名，由 firstboot-pkgs 安装后清理）
chmod 755 /etc/init.d/firstboot-pkgs
/etc/init.d/firstboot-pkgs enable
/etc/init.d/firstboot-pkgs start

logger -t uci-defaults "配置应用完成"
EOT
    chmod 755 "$OUT"
    echo "[diy] 输出: $OUT"

    if [ -n "$ROOT_PASSWORD" ]; then
        command -v openssl >/dev/null 2>&1 || error_exit "缺失依赖: openssl (用于 root 密码哈希)"
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl密码加密失败"
        echo "root:$crypt:0:0:99999:7:::" > "$SHADOW"
        chmod 600 "$SHADOW" 2>/dev/null || true
    fi
    ;;
*) error_exit "PHASE仅支持 before / after" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
