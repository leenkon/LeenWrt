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

VERSION="" PHASE="" PROFILE_TYPE="" FEEDS_SRC="" FILES_DIR_NAME="files"
NO_ADGH=0 WITH_FWX=0
CUSTOM_IP="" CUSTOM_GATEWAY="" BYPASS_IP="" BYPASS_IP6="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

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
        --bypass-ip6) BYPASS_IP6="$2"; shift 2 ;;
        --no-adgh)   NO_ADGH=1; shift ;;
        --with-fwx)  WITH_FWX=1; shift ;;
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
    echo "[diy] before: $VERSION"
    if [ -n "$FEEDS_SRC" ]; then
        FEED_CONF_SRC="$FEEDS_SRC"
    else
        FEED_CONF_SRC="$PROJECT_ROOT/feeds/$VERSION.conf"
    fi
    [ -f "$FEED_CONF_SRC" ] || error_exit "缺失feed配置: $FEED_CONF_SRC"
    rm -f feeds.conf
    cp "$FEED_CONF_SRC" feeds.conf
    # src-link 用项目根相对路径，但 feeds update 在 openwrt TOPDIR 解析，改写为绝对路径以定位 vendored 目录
    sed -i "s#\./feeds/fwx#$PROJECT_ROOT/feeds/fwx#g" feeds.conf

    # kmod-fwx 硬依赖 fanchmwrt fork 内核补丁(给 struct nf_conn 加 fwx_data，原版 6.12 内核无)，注入 6.12 hack 目录。仅 --with-fwx。
    if [ "$WITH_FWX" = "1" ]; then
        FWX_KERN_PATCH="$PROJECT_ROOT/patches/fwx/950-fwx-nf-conn-struct-user-hook.patch"
        if [ -f "$FWX_KERN_PATCH" ]; then
            FWX_HACK_DIR="target/linux/generic/hack-6.12"
            mkdir -p "$FWX_HACK_DIR"
            cp -f "$FWX_KERN_PATCH" "$FWX_HACK_DIR/"
            echo "[diy] injected fwx kernel patch -> $FWX_HACK_DIR/$(basename "$FWX_KERN_PATCH")"
        else
            echo "[diy] WARN: 未找到 fwx 内核补丁 $FWX_KERN_PATCH (kmod-fwx 可能因缺 fwx_data 编译失败)" >&2
        fi

        # kmod-fwx 6.12 兼容：上游 fwx_main.c 把 nf_send_reset 写成 4 参数，6.12 实为 3 参数，此处对源码树打补丁。
        FWX_KMOD_PATCH="$PROJECT_ROOT/patches/fwx/kmod-nf_send_reset-6.12.patch"
        if [ -f "$FWX_KMOD_PATCH" ]; then
            if patch -p1 --dry-run -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$FWX_KMOD_PATCH" >/dev/null 2>&1; then
                patch -p1 --forward -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$FWX_KMOD_PATCH"
                echo "[diy] applied fwx kmod 6.12 patch -> feeds/fwx/fwx/src/fwx_main.c"
            else
                echo "[diy] fwx kmod patch 已应用或上下文不符，跳过(详见 $FWX_KMOD_PATCH)"
            fi
        else
            echo "[diy] WARN: 未找到 fwx kmod 补丁 $FWX_KMOD_PATCH (kmod-fwx 可能编译失败)" >&2
        fi
    fi

    # 覆盖 fanchmwrt 主题硬编码标题为 LuCI 动态标题（主题由 build.sh 3.6 拉取）
    _THEME_HEADER="$PROJECT_ROOT/feeds/fwx/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut"
    if [ -f "$_THEME_HEADER" ]; then
        python3 - "$_THEME_HEADER" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
new = "<title>{{ striptags(`${boardinfo.hostname ?? '?'}${node ? ` - ${node.title}` : ''}`) }} - LuCI</title>"
m = re.sub(r'<title>.*?</title>', new, s, count=1, flags=re.S)
if m != s:
    open(p, 'w', encoding='utf-8').write(m)
    print("[diy] 主题标题已覆盖为 LuCI 动态标题")
else:
    print("[diy] 未在 header.ut 找到 <title> 标签，跳过")
PY
    fi

    # 删除 fanchmwrt 主题整个 <footer> 区域（保留 #modemenu 挂载点，否则 menu-fanchmwrt.js 的 renderModeMenu 找不到 #modemenu 直接 return，顶部菜单失效）
    _THEME_FOOTER="$PROJECT_ROOT/feeds/fwx/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/footer.ut"
    if [ -f "$_THEME_FOOTER" ]; then
        python3 - "$_THEME_FOOTER" <<'PY'
import sys, re
p = sys.argv[1]
s0 = open(p, encoding='utf-8').read()
s = re.sub(r'<span>.*?</span>\s*', '', s0, flags=re.S)
s = re.sub(r'</?footer>', '', s)
s = re.sub(r'\n[ \t]*\n[ \t]*\n', '\n\n', s)
if s != s0:
    open(p, 'w', encoding='utf-8').write(s)
    print("[diy] 已删除主题 footer 区域（保留 #modemenu 与菜单脚本）")
else:
    print("[diy] footer.ut 未变化，跳过")
PY
    fi
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
    # IP 转发开关：所有 profile 统一开启
    IP_FORWARD_LN='grep -q '\''net.ipv4.ip_forward=1'\'' /etc/sysctl.conf || echo '\''net.ipv4.ip_forward=1'\'' >> /etc/sysctl.conf'

    # full/main 共用：LAN 静态地址（lan6 删除、ip6assign、proto、ipaddr、netmask）
    LAN_WAN_COMMON_BLK=$(cat <<EOF
uci -q delete network.lan6
uci set network.lan.ip6assign='64'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci commit network
EOF
)

    # bypass/full 共用：OpenClash meta/redir-host 配置
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

    # 带 ADGH 时启用二进制 AdGuardHome（init.d 经 files/ 注入；Procd 脚本需 enable 才开机自启）
    ADGH_ENABLE_BLK=$(cat <<'EOF'
chmod 755 /etc/init.d/adguardhome
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start
EOF
)

    # full/main 共用：LAN 区 forward + lan->wan forwarding 重置
    LAN_FORWARD_BLK=$(cat <<'EOF'
LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && uci set ${LAN_FW}.forward='ACCEPT'
WAN_FW=$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
# PPPoE MTU 1492，缺 MSS 钳制会导致大包被 PMTUD 黑洞丢弃(已连接但打不开网页)，显式钳制。
[ -n "$WAN_FW" ] && uci set ${WAN_FW}.mtu_fix='1'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'
EOF
)

    # full/main 共用：dns-hijack + firewall include（放在最后，避免上游未就绪时形成黑洞）
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

    # full/main 共用：启用 UPnP/IGD 并绑 lan->wan（miniupnpd 已编入镜像）
    UPNP_BLK=$(cat <<'EOF'
uci -q get upnpd.config >/dev/null || uci set upnpd.config=upnpd
uci set upnpd.config.enabled='1'
uci set upnpd.config.internal_iface='lan'
uci set upnpd.config.external_iface='wan'
uci set upnpd.config.secure='1'
uci commit upnpd
/etc/init.d/miniupnpd enable
/etc/init.d/miniupnpd restart
EOF
)

    # full/main 共用：DHCP 公共段（范围、RA、下发单 DNS 等）
    DHCP_COMMON_BLK=$(cat <<EOF
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,$ip_esc'
uci set dhcp.lan.start='11'
uci set dhcp.lan.limit='149'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
# 通告本机为 IPv6 默认网关（否则客户端有地址无路由）
uci set dhcp.lan.ra_default='1'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].sequential_ip='1'
EOF
)

    # WAN 段(PPPoE/DHCP)提前生成避免重复；WAN 设备不写死，由 board.d 首启探测(eth1 存在则作 WAN)。
    if [ "$PROFILE_TYPE" = "full" ] || [ "$PROFILE_TYPE" = "main" ]; then
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME"); p=$(_escape_uci "$PPPOE_PASSWORD")
            WAN_BLK=$(cat <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
            uci set network.wan.ipv6='auto'
            uci set network.wan.peerdns='1'
            uci -q delete network.wan6
EOT
)
        else
            WAN_BLK=$(cat <<EOT
            uci set network.wan.proto='dhcp'
            uci set network.wan.peerdns='1'
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
# 旁路由 dnsmasq 仅作 ADGH 兜底(:5453)，须配上游；noresolv=1 不读空 resolv.conf。
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].noresolv='1'
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
            # noadgh：dnsmasq 占 :53，上游指向 OC redir-host(:7874)+阿里云兜底，OC 停时仍解析。
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
            # 带 ADGH：dnsmasq 让出 :53(port 5453)，AdGuardHome 占 :53，纯阿里云兜底。
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

$UPNP_BLK

$OC_CONFIG_BLK
EOT
        if [ "$NO_ADGH" != "1" ]; then
            cat >> "$OUT" <<EOT
$ADGH_ENABLE_BLK
EOT
            cat >> "$OUT" <<EOT
$DNS_HIJACK_BLK
EOT
        fi
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

$UPNP_BLK

# 显式声明旁路 IP,供 dns-hijack 直接读取(取代 dhcp 反查,避免主路由模式 DNS 环路)
uci -q delete dns_hijack.settings
uci set dns_hijack.settings=settings
uci set dns_hijack.settings.bypass_ip='$BYPASS_IP'
[ -n '$BYPASS_IP6' ] && uci set dns_hijack.settings.bypass_ip6='$BYPASS_IP6'
uci commit dns_hijack
$DNS_HIJACK_BLK
EOT
    fi

    # fwx 应用过滤(DPI 内核模块)依赖 conntrack，与流卸载冲突会导致连接不稳/应用过滤失效，故开启 fwx 时关闭流卸载
    if [ "$WITH_FWX" = "1" ]; then
        FLOFF=0; FLOFF_HW=0
    else
        FLOFF=1; FLOFF_HW=1
    fi
    cat >> "$OUT" <<EOT
uci set firewall.@defaults[0].flow_offloading='$FLOFF'
uci set firewall.@defaults[0].flow_offloading_hw='$FLOFF_HW'
uci commit firewall

uci set system.@system[0].hostname='LeenWrt'
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

# 首启离线安装 apps/ 的 .apk：仅 enable，由 rc.d(S99) 启动后期执行(避免早期 apk 库未就绪)
/etc/init.d/firstboot-pkgs enable

# 主题默认浅色（99-custom 字典序后于 100_fwx，覆盖 fwx 出厂 theme_mode=1）
if uci -q get fwx.global >/dev/null 2>&1; then
    uci set fwx.global.theme_mode='0'
    uci commit fwx
fi

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
