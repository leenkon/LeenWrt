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
NO_ADGH=0 WITH_FWX=0 WITH_OC=0
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD="" LOG_SERVER=""

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
        --no-adgh)   NO_ADGH=1; shift ;;
        --with-fwx)  WITH_FWX=1; shift ;;
        --with-oc)   WITH_OC=1; shift ;;
        --log-server) LOG_SERVER="$2"; shift 2 ;;
        --feeds)     FEEDS_SRC="$2"; shift 2 ;;
        --files-dir) FILES_DIR_NAME="$2"; shift 2 ;;
        *) error_exit "未知参数 $1" ;;
    esac
done

[ -n "$VERSION" ] && [ -n "$PHASE" ] || error_exit "必填 --version / --phase"
[ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ] && error_exit "after阶段必须指定 --type full/bypass"
case "$PROFILE_TYPE" in ""|bypass|full) ;; *) error_exit "--type 仅支持 bypass / full" ;; esac

if [ "$PROFILE_TYPE" = "bypass" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_BYPASS_IP"
    [ -z "$CUSTOM_GATEWAY" ] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
    [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ] && error_exit "旁路由不支持PPPoE，请使用 --type full"
elif [ "$PROFILE_TYPE" = "full" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法路由IP: $CUSTOM_IP"
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
    # src-link 改写为绝对路径定位 vendored 目录
    sed -i "s#\./feeds/fwx#$PROJECT_ROOT/feeds/fwx#g" feeds.conf

    # kmod‑fwx 内核补丁，注入 hack‑6.12
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

        # kmod‑fwx 6.12 nf_send_reset 参数适配补丁
        FWX_KMOD_PATCH="$PROJECT_ROOT/patches/fwx/kmod-nf_send_reset-6.12.patch"
        if [ -f "$FWX_KMOD_PATCH" ]; then
            if patch -p1 --dry-run -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$FWX_KMOD_PATCH" >/dev/null 2>&1; then
                patch -p1 --forward -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$FWX_KMOD_PATCH" || true
                echo "[diy] applied fwx kmod 6.12 patch -> feeds/fwx/fwx/src/fwx_main.c"
            else
                echo "[diy] fwx kmod patch 已应用或上下文不符，跳过(详见 $FWX_KMOD_PATCH)"
            fi
        else
            echo "[diy] WARN: 未找到 fwx kmod 补丁 $FWX_KMOD_PATCH (kmod-fwx 可能编译失败)" >&2
        fi

        # kmod‑fwx DPI越界读Oops修复补丁
        FWX_CRASH_PATCH="$PROJECT_ROOT/patches/fwx/fwx-match-feature-crash.patch"
        if [ -f "$FWX_CRASH_PATCH" ]; then
            if patch -p1 --dry-run -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$FWX_CRASH_PATCH" >/dev/null 2>&1; then
                patch -p1 --forward -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$FWX_CRASH_PATCH" || true
                echo "[diy] applied fwx DPI bounds patch -> feeds/fwx/fwx/src/fwx_main.c"
            else
                echo "[diy] fwx DPI bounds patch 已应用或上下文不符，跳过(详见 $FWX_CRASH_PATCH)"
            fi
        else
            echo "[diy] WARN: 未找到 fwx DPI 边界守卫补丁 $FWX_CRASH_PATCH" >&2
        fi
    fi

    # fanchmwrt主题：替换硬编码title为LuCI动态标题
    _THEME_HEADER="$PROJECT_ROOT/feeds/fwx/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut"
    if [ -f "$_THEME_HEADER" ] && command -v python3 >/dev/null 2>&1; then
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

    # fanchmwrt主题删除footer文字，保留#modemenu节点
    _THEME_FOOTER="$PROJECT_ROOT/feeds/fwx/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/footer.ut"
    if [ -f "$_THEME_FOOTER" ] && command -v python3 >/dev/null 2>&1; then
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

ruby)
    # 必须在 ./scripts/feeds update -a 之后调用：feeds/packages 此时才被拉取到本地。
    # ruby 的 YJIT 默认开启会拉起 rust/host，其预编译 LLVM 在 25.12 上游已 404；
    # 解耦后 ruby 走 --disable-yjit，OpenClash 运行期 ruby -ryaml 校验不受影响。
    echo "[diy] ruby: 解耦 YJIT 与 rust/host"
    _RUBY_DIR="$PROJECT_ROOT/feeds/packages/lang/ruby"
    [ -d "$_RUBY_DIR" ] || error_exit "缺失 ruby 源码目录（请确认已执行 feeds update -a）: $_RUBY_DIR"
    sed -i 's/^PKG_BUILD_DEPENDS:=ruby\/host RUBY_ENABLE_YJIT:rust\/host/PKG_BUILD_DEPENDS:=ruby\/host/' "$_RUBY_DIR/Makefile"
    sed -i '/default y if x86_64/d' "$_RUBY_DIR/Config.in"
    echo "[diy] 已解耦 ruby YJIT 与 rust/host（避免 rustc 1.94.0 LLVM 下载 404）"
    ;;

after)
    echo "[diy] after: $PROFILE_TYPE"
    # bypass强制ADGH启用，无论外部传入--no-adgh
    if [ "$PROFILE_TYPE" = "bypass" ]; then
        NO_ADGH=0
    fi
    case "$FILES_DIR_NAME" in
      /*) FB_DIR="$FILES_DIR_NAME" ;;
      *)  FB_DIR="$PROJECT_ROOT/$FILES_DIR_NAME" ;;
    esac
    OUT="$FB_DIR/etc/uci-defaults/99-custom.sh"
    SHADOW="$FB_DIR/etc/shadow"
    mkdir -p "$(dirname "$OUT")"
    mkdir -p "$(dirname "$SHADOW")"
    rm -f "$OUT" "$SHADOW"

    ip_esc=$(_escape_uci "$CUSTOM_IP")
    log_server_esc=$(_escape_uci "$LOG_SERVER")

    # ====================== 公共配置块 ======================
    IP_FORWARD_LN='grep -q '\''net.ipv4.ip_forward=1'\'' /etc/sysctl.conf || echo '\''net.ipv4.ip_forward=1'\'' >> /etc/sysctl.conf'

    LAN_WAN_COMMON_BLK=$(cat <<EOF
uci -q delete network.lan6
uci set network.lan.ip6assign='64'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci commit network
EOF
)

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

    # 修复：uci‑defaults只enable，不在此处start
    ADGH_ENABLE_BLK=$(cat <<'EOF'
chmod 755 /etc/init.d/adguardhome
/etc/init.d/adguardhome enable
EOF
)

    LAN_FORWARD_BLK=$(cat <<'EOF'
LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && uci set ${LAN_FW}.forward='ACCEPT'
WAN_FW=$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "$WAN_FW" ] && uci set ${WAN_FW}.mtu_fix='1'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'
EOF
)

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

    UPNP_BLK=$(cat <<'EOF'
uci -q get upnpd.config >/dev/null || uci set upnpd.config=upnpd
uci set upnpd.config.enabled='1'
uci set upnpd.config.internal_iface='lan'
uci set upnpd.config.external_iface='wan'
uci set upnpd.config.secure='0'
uci commit upnpd
/etc/init.d/miniupnpd enable
/etc/init.d/miniupnpd restart
EOF
)

    REMOTE_SYSLOG_BLK=""
    if [ -n "$LOG_SERVER" ]; then
        REMOTE_SYSLOG_BLK=$(cat <<EOF
uci set system.@system[0].log_ip='$log_server_esc'
uci set system.@system[0].log_port='514'
uci set system.@system[0].log_proto='udp'
uci set system.@system[0].log_remote='1'
EOF
)
    fi

    DHCP_COMMON_BLK=$(cat <<EOF
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='6,$ip_esc'
uci set dhcp.lan.start='11'
uci set dhcp.lan.limit='149'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_default='1'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].sequential_ip='1'
EOF
)

    WAN_BLK=""
    if [ "$PROFILE_TYPE" = "full" ]; then
        if [ -n "$PPPOE_USERNAME" ]; then
            # 修复：转义，账号密码变量写入脚本，路由器运行时执行_escape_uci
            WAN_BLK=$(cat <<'EOT'
_u() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
uci set network.wan.proto='pppoe'
uci set network.wan.username="$(_u "$PPPOE_USERNAME")"
uci set network.wan.password="$(_u "$PPPOE_PASSWORD")"
uci set network.wan.ipv6='auto'
uci set network.wan.peerdns='1'
uci -q delete network.wan6
uci set network.wan6=@network.wan
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
EOT
)
            # 注入原始变量到输出脚本环境
            WAN_BLK="PPPOE_USERNAME='$PPPOE_USERNAME';PPPOE_PASSWORD='$PPPOE_PASSWORD';"$WAN_BLK
        else
            WAN_BLK=$(cat <<'EOT'
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
# 旁路由不清删wan/wan6，清空接口，保留防火墙zone避免日志报错，增加‑q抑制不存在警告
uci -q set network.wan.ifname=''
uci -q set network.wan6.ifname=''
uci commit network

uci set dhcp.lan.ignore='1'
uci -q set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].port='5453'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp

${LAN_FORWARD_BLK}

[ -n "\$LAN_FW" ] && {
    uci set \${LAN_FW}.input='ACCEPT'
    uci set \${LAN_FW}.output='ACCEPT'
    uci set \${LAN_FW}.forward='ACCEPT'
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
            if [ "$WITH_OC" = "1" ]; then
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
                cat >> "$OUT" <<EOT
uci -q delete dhcp.@dnsmasq[0].port
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp
EOT
            fi
        else
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
EOT
        if [ "$WITH_OC" = "1" ]; then
            cat >> "$OUT" <<EOT
$OC_CONFIG_BLK
EOT
        fi
        if [ "$NO_ADGH" != "1" ]; then
            cat >> "$OUT" <<EOT
$ADGH_ENABLE_BLK

$DNS_HIJACK_BLK
EOT
        fi
    fi

    # fwx开启关闭流卸载
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

$REMOTE_SYSLOG_BLK
uci commit system
/etc/init.d/log restart

# 虚拟机无cpufreq目录不执行调频
if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
    /etc/init.d/cpufreq-perf enable
    /etc/init.d/cpufreq-perf start
fi

/etc/init.d/firstboot-pkgs enable

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
*) error_exit "PHASE仅支持 before / ruby / after" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
