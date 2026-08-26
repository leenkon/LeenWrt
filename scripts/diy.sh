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

# fwx 源码树补丁：kmod 6.12 兼容 + DPI 边界守卫（上下文不符时跳过，不阻断构建）
_apply_fwx_src_patch() {
    local name="$1" patch="$2"
    [ -f "$patch" ] || { echo "[diy] WARN: 未找到 $name 补丁 $patch" >&2; return; }
    if patch -p1 --dry-run -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$patch" >/dev/null 2>&1; then
        patch -p1 -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$patch"
        echo "[diy] applied $name -> feeds/fwx/fwx/src/fwx_main.c"
    elif patch -p1 --reverse --dry-run -d "$PROJECT_ROOT/feeds/fwx/fwx" < "$patch" >/dev/null 2>&1; then
        echo "[diy] $name 已应用，跳过"
    else
        echo "[diy] WARN: $name 上下文不符，未应用(详见 $patch)" >&2
    fi
}

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
SUBNET_MASK="255.255.255.0"
DNS_MAIN="223.5.5.5"
DNS_BACKUP="223.6.6.6"

VERSION="" PHASE="" PROFILE_TYPE="" FEEDS_SRC="" FILES_DIR_NAME="files"
NO_ADGH=0 WITH_FWX=0 WITH_OC=0 WITH_DNS_HIJACK=1
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

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
        --no-dns-hijack) WITH_DNS_HIJACK=0; shift ;;
        --with-fwx)  WITH_FWX=1; shift ;;
        --with-oc)   WITH_OC=1; shift ;;
        --feeds)     FEEDS_SRC="$2"; shift 2 ;;
        --files-dir) FILES_DIR_NAME="$2"; shift 2 ;;
        *) error_exit "未知参数 $1" ;;
    esac
done

[ -n "$VERSION" ] && [ -n "$PHASE" ] || error_exit "必填 --version / --phase"
[ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ] && error_exit "after阶段必须指定 --type full/bypass"
case "$PROFILE_TYPE" in ""|bypass|full) ;; *) error_exit "--type 仅支持 bypass / full" ;; esac

if [ "$PROFILE_TYPE" = "bypass" ]; then
    # 旁路由：--ip=本机LAN IP(默认10.10.10.2)，--gateway=上游主路由(默认10.10.10.1)；IP取LAN IP，运行期全量劫持
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_BYPASS_IP"
    [ -z "$CUSTOM_GATEWAY" ] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
    [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ] && error_exit "旁路由不支持PPPoE，请使用 --type full"
elif [ "$PROFILE_TYPE" = "full" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法路由IP: $CUSTOM_IP"
    # 主路由：--gateway 可选，双路由填旁路由 IP，单路由留空
    [ -n "$CUSTOM_GATEWAY" ] && { is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由IP: $CUSTOM_GATEWAY"; }
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
    # src-link 用相对路径，但 feeds update 在 openwrt TOPDIR 解析，改写为绝对路径以定位 feeds/fwx
    # （feeds/fwx 下 fwx / fwxd / libfwx_common / luci-theme-fanchmwrt 四个代码组件均由 build.sh 按 FWX_COMMIT 动态拉取）
    sed -i "s#\./feeds/fwx#$PROJECT_ROOT/feeds/fwx#g" feeds.conf

    # fwx 内核改动(kmod-fwx 硬依赖)整体受 --with-fwx 门控：不勾选时零 fwx 内核补丁，连 950 都不注入。
    if [ "$WITH_FWX" = "1" ]; then
        FWX_KERN_PATCH="$PROJECT_ROOT/patches/fwx/950-fwx-nf-conn-struct-user-hook.patch"
        if [ -f "$FWX_KERN_PATCH" ]; then
            # 950 针对 6.12 系列：早期仅按 FWX_KERNEL_BASELINE 前缀拦截(跨系列如 6.13 才 fail-fast)；
            # 真正能否打入由下方 patch --dry-run 权威判定(干净/ fuzz 告警/ 失败报错)。
            # 版本取自 target/linux/generic/kernel-6.12 的 LINUX_KERNEL_HASH-6.12.xx 行。
            FWX_KERN_VER=$(grep -m1 '^LINUX_KERNEL_HASH-6\.12\.' target/linux/generic/kernel-6.12 2>/dev/null | grep -oE '6\.12\.[0-9]+' 2>/dev/null || true)
            echo "[diy] immortalwrt 内核版本: ${FWX_KERN_VER:-未知} (950 针对 6.12 系列，系列内任意子版本均可尝试打入)"
            FWX_KERNEL_BASELINE=$(grep -m1 '^FWX_KERNEL_BASELINE=' "$PROJECT_ROOT/cores/leenwrt.conf" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
            if [ -n "$FWX_KERNEL_BASELINE" ] && [ -n "$FWX_KERN_VER" ]; then
                FWX_BASE_OK=0
                case "$FWX_KERN_VER" in
                    "${FWX_KERNEL_BASELINE}"*) FWX_BASE_OK=1 ;;
                esac
                if [ "$FWX_BASE_OK" -ne 1 ]; then
                    error_exit "950 补丁针对 ${FWX_KERNEL_BASELINE} 系列内核，当前 ${FWX_KERN_VER} 不匹配。请重新生成 950 或钉死 immortalwrt 内核 tag。"
                fi
            fi
            KERN_TREE=$(ls -d build_dir/linux-x86_64/linux-6.12* 2>/dev/null | head -1)
            if [ -n "$KERN_TREE" ]; then
                if ! patch -p1 --dry-run -d "$KERN_TREE" < "$FWX_KERN_PATCH" >/tmp/fwx950.log 2>&1; then
                    error_exit "950 补丁无法应用到已解压内核树($KERN_TREE)，内核版本可能已更新导致上下文不符"
                elif grep -qi "fuzz" /tmp/fwx950.log; then
                    echo "[diy] WARN: 950 以 fuzz 方式应用，内核版本可能已更新，存在运行时风险" >&2
                fi
            fi
            FWX_HACK_DIR="target/linux/generic/hack-6.12"
            mkdir -p "$FWX_HACK_DIR"
            cp -f "$FWX_KERN_PATCH" "$FWX_HACK_DIR/"
            echo "[diy] injected fwx kernel patch -> $FWX_HACK_DIR/$(basename "$FWX_KERN_PATCH")"
        else
            echo "[diy] WARN: 未找到 fwx 内核补丁 $FWX_KERN_PATCH (kmod-fwx 可能因缺 fwx_data 编译失败)" >&2
        fi

        _apply_fwx_src_patch "fwx kmod 6.12" "$PROJECT_ROOT/patches/fwx/kmod-nf_send_reset-6.12.patch"
        _apply_fwx_src_patch "fwx DPI bounds" "$PROJECT_ROOT/patches/fwx/fwx-match-feature-crash.patch"
    fi

    # 主题标题/footer 处理统一移至 'themes' 阶段（feeds update -a 之后，可覆盖 fanchmwrt/argon/bootstrap 三套）
    ;;

ruby)
    # ruby YJIT 解耦：分支头 lang/ruby 默认 RUBY_ENABLE_YJIT=y -> 拉 rust/host -> rustc LLVM 404 构建挂。
    # OpenClash 依赖 ruby(不可选)，故仅在 WITH_OC 时由 build.sh/workflow 调用。须 feeds update 后、install 前执行。
    echo "[diy] ruby: 解耦 YJIT 与 rust/host（x86_64/aarch64）"
    RUBY_DIR="$PROJECT_ROOT/openwrt/feeds/packages/lang/ruby"
    if [ -d "$RUBY_DIR" ]; then
        # Makefile: 去掉 RUBY_ENABLE_YJIT:rust/host 条件依赖，仅保留 ruby/host（用 # 作分隔符避路径斜杠）
        sed -i -E 's#(PKG_BUILD_DEPENDS:=ruby/host) RUBY_ENABLE_YJIT:rust/host#\1#' "$RUBY_DIR/Makefile"
        # Makefile: 删除 x86_64/aarch64 默认开启 YJIT（让 defconfig 不再翻成 =y）
        sed -i -E '/^[[:space:]]*default y if x86_64\|\|aarch64[[:space:]]*$/d' "$RUBY_DIR/Makefile"
        echo "[diy] ruby: 已解耦 YJIT（Makefile 依赖 + default 均清除）"
    else
        echo "[diy] WARN: 未找到 $RUBY_DIR（feeds update 是否已执行？），跳过 ruby YJIT 解耦" >&2
    fi
    ;;

themes)
    # 主题 footer 移除 + fanchmwrt 标题覆盖。须在 feeds update -a 之后运行：
    # fanchmwrt 是 src-link 本地源（always 可用），argon/bootstrap 在 feeds/luci（src-git，update 后才存在）。
    echo "[diy] themes: 移除各主题 footer（fanchmwrt/argon/bootstrap）"
    OPENWRT_DIR="$PROJECT_ROOT/openwrt"
    _FWX_THEME="$PROJECT_ROOT/feeds/fwx/luci-theme-fanchmwrt"
    _LUCIF_DIR="$OPENWRT_DIR/feeds/luci"
    python3 - "$_FWX_THEME" "$_LUCIF_DIR" <<'PY'
import sys, os, re, glob
fwm_root, luci_dir = sys.argv[1], sys.argv[2]

def strip_footer(path, keep_inner):
    s0 = open(path, encoding='utf-8').read()
    if keep_inner:
        # fanchmwrt：保留 #modemenu 挂载点（顶部菜单脚本依赖），仅剥离 <span> 文案与 footer 标签
        s = re.sub(r'<span>.*?</span>\s*', '', s0, flags=re.S)
        s = re.sub(r'</?footer>', '', s)
    else:
        # argon / bootstrap：移除整个 <footer> 区域
        s = re.sub(r'<footer\b.*?</footer>', '', s0, flags=re.S)
    s = re.sub(r'\n[ \t]*\n[ \t]*\n', '\n\n', s)
    if s != s0:
        open(path, 'w', encoding='utf-8').write(s)
        return True
    return False

# fanchmwrt：标题覆盖为 LuCI 动态标题
for h in glob.glob(os.path.join(fwm_root, '**', 'header.ut'), recursive=True):
    s0 = open(h, encoding='utf-8').read()
    new = "<title>{{ striptags(`${boardinfo.hostname ?? '?'}${node ? ` - ${node.title}` : ''}`) }} - LuCI</title>"
    m = re.sub(r'<title>.*?</title>', new, s0, count=1, flags=re.S)
    if m != s0:
        open(h, 'w', encoding='utf-8').write(m)
        print("[diy] 主题标题已覆盖为 LuCI 动态标题: " + h)
    else:
        print("[diy] 未在 header.ut 找到 <title>: " + h)

# fanchmwrt：移除 footer（保留 #modemenu）
for f in glob.glob(os.path.join(fwm_root, '**', 'footer.ut'), recursive=True):
    if strip_footer(f, keep_inner=True):
        print("[diy] 已移除 fanchmwrt footer（保留 #modemenu）: " + f)
    else:
        print("[diy] fanchmwrt footer 无变化: " + f)

# argon / bootstrap：移除整个 footer
for theme in ('argon', 'bootstrap'):
    found = False
    for f in glob.glob(os.path.join(luci_dir, 'themes', 'luci-theme-' + theme, '**', 'footer.ut'), recursive=True):
        if strip_footer(f, keep_inner=False):
            print("[diy] 已移除 " + theme + " footer: " + f)
        else:
            print("[diy] " + theme + " footer 无变化: " + f)
        found = True
    if not found:
        print("[diy] WARN: 未找到 " + theme + " footer.ut（feeds/luci 是否已 update？）", file=sys.stderr)
PY
    ;;

after)
    echo "[diy] after: $PROFILE_TYPE"
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
    IP_FORWARD_LN='grep -q '\''net.ipv4.ip_forward=1'\'' /etc/sysctl.conf || echo '\''net.ipv4.ip_forward=1'\'' >> /etc/sysctl.conf'

    # full 共用：LAN 静态地址
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

    # 主路由双路由：--gateway=旁路由IP，写入 adguardhome config 供 dns-hijack 排除(防二次劫持)；单路由留空=全量劫持。
    # 旁路由自身不写该项(保持空)：dns-hijack 空值即全量劫持，自动适应旁路由 LAN IP 后期变更，无需固化。
    BYPASS_IP=""
    [ "$PROFILE_TYPE" = "full" ] && BYPASS_IP="$CUSTOM_GATEWAY"
    BYPASS_IP_UCI_BLK=""
    [ -n "$BYPASS_IP" ] && BYPASS_IP_UCI_BLK=$(cat <<EOF
uci -q delete adguardhome.config.dns_hijack_bypass_ip
uci set adguardhome.config.dns_hijack_bypass_ip='$(_escape_uci "$BYPASS_IP")'
EOF
)

    # 不劫持时 REJECT lan->wan :53 强制走路由器 DNS(排除旁路由自身)
    DNS_HIJACK_REJECT_BLK=$(cat <<'EOF'
BYPASS_IP=$(uci -q get adguardhome.config.dns_hijack_bypass_ip 2>/dev/null)
for _z in wan wan6; do
    uci -q get firewall.$_z >/dev/null 2>&1 || continue
    uci -q delete firewall.reject_lan_dns_$_z
    uci set firewall.reject_lan_dns_$_z=rule
    uci set firewall.reject_lan_dns_$_z.name="Reject LAN->$_z :53 (force router DNS)"
    uci set firewall.reject_lan_dns_$_z.src='lan'
    [ -n "$BYPASS_IP" ] && uci set firewall.reject_lan_dns_$_z.src_ip="!$BYPASS_IP"
    uci set firewall.reject_lan_dns_$_z.dest="$_z"
    uci set firewall.reject_lan_dns_$_z.dest_port='53'
    uci set firewall.reject_lan_dns_$_z.proto='udp tcp'
    uci set firewall.reject_lan_dns_$_z.target='REJECT'
done
uci commit firewall
EOF
)

    # full 共用：LAN 区三态 ACCEPT + lan->wan forwarding + wan mtu_fix（与 bypass 分支一致）。
    # 不依赖上游默认 firewall，避免非空配置下 lan input=REJECT 挡掉 LuCI(后台) 且无 lan->wan 转发导致不能上网。
    LAN_FORWARD_BLK=$(cat <<'EOF'
LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && {
    uci set ${LAN_FW}.input='ACCEPT'
    uci set ${LAN_FW}.output='ACCEPT'
    uci set ${LAN_FW}.forward='ACCEPT'
}
WAN_FW=$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "$WAN_FW" ] && uci set ${WAN_FW}.mtu_fix='1'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'
EOF
)

    # full 共用：启用 UPnP/IGD 并绑 lan->wan（miniupnpd 已编入镜像）
    UPNP_BLK=$(cat <<'EOF'
uci -q get upnpd.config >/dev/null || uci set upnpd.config=upnpd
uci set upnpd.config.enabled='1'
uci set upnpd.config.internal_iface='lan'
uci set upnpd.config.external_iface='wan'
# secure=0：放宽 secure_mode，避免老设备 UPnP 映射被丢弃；miniupnpd 仅监听 lan 不外泄
uci set upnpd.config.secure='0'
uci commit upnpd
/etc/init.d/miniupnpd enable
/etc/init.d/miniupnpd restart
EOF
)

    # full 共用：DHCP 公共段（范围、RA、下发单 DNS 等）
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
    if [ "$PROFILE_TYPE" = "full" ]; then
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME"); p=$(_escape_uci "$PPPOE_PASSWORD")
            WAN_BLK=$(cat <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'
uci set network.wan.peerdns='1'
# PPPoE MTU 1492，缺 MSS 钳制会导致大包被 PMTU 黑洞丢弃(已连接但打不开网页)
uci set network.wan.mtu_fix='1'
uci -q delete network.wan6
EOT
)
        else
            WAN_BLK=$(cat <<EOT
uci set network.wan.proto='dhcp'
uci set network.wan.peerdns='1'
uci set network.wan.mtu_fix='1'
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
uci -q delete dhcp.@dnsmasq[0].port
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
# 旁路由 dnsmasq 常驻 :53 兜底(零抖动)；ADGH 改绑 :5353，不再让出 :53。
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp

LAN_FW=\$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
WAN_FW=\$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "\$LAN_FW" ] && {
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
uci -q delete adguardhome.config.dns_hijack
uci set adguardhome.config.dns_hijack='$WITH_DNS_HIJACK'
$BYPASS_IP_UCI_BLK
uci commit adguardhome
EOT
    elif [ "$PROFILE_TYPE" = "full" ]; then
        cat >> "$OUT" <<EOT
$WAN_BLK
$LAN_WAN_COMMON_BLK

$IP_FORWARD_LN

$DHCP_COMMON_BLK
$LAN_FORWARD_BLK
EOT
        # 零抖动 DNS：dnsmasq 常驻 :53 兜底；ADGH(:5353)/OC(:7874) 按需叠加。仅"ADGH关+OC开"时 dnsmasq 上游前置 OC(:7874)
        DNS_SERVERS="$DNS_MAIN $DNS_BACKUP"
        [ "$NO_ADGH" = "1" ] && [ "$WITH_OC" = "1" ] && DNS_SERVERS="127.0.0.1#7874 $DNS_MAIN $DNS_BACKUP"
        {
            echo "uci -q delete dhcp.@dnsmasq[0].port"
            echo "uci -q delete dhcp.@dnsmasq[0].server"
            echo "uci set dhcp.@dnsmasq[0].noresolv='1'"
            echo "uci set dhcp.@dnsmasq[0].dns_redirect='0'"
            for s in $DNS_SERVERS; do
                echo "uci add_list dhcp.@dnsmasq[0].server='$s'"
            done
            echo "uci commit dhcp"
        } >> "$OUT"

        cat >> "$OUT" <<EOT
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
EOT
            # dns_hijack 写入 adguardhome config，由 init.d 监控循环在 ADGH 监听:5353 后布表/停时清表(零抖动)；=0 时改用 REJECT 强制走路由器 DNS
            cat >> "$OUT" <<EOT
uci -q delete adguardhome.config.dns_hijack
uci set adguardhome.config.dns_hijack='$WITH_DNS_HIJACK'
$BYPASS_IP_UCI_BLK
uci commit adguardhome
EOT
            if [ "$WITH_DNS_HIJACK" != "1" ]; then
                printf '%s\n' "$DNS_HIJACK_REJECT_BLK" >> "$OUT"
            fi
        fi
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

# 固定 CPU 为 performance 模式，避免降频抖动
chmod 755 /etc/init.d/cpufreq-perf
/etc/init.d/cpufreq-perf enable
/etc/init.d/cpufreq-perf start

# 首启离线安装 apps/ 的 .apk：仅 enable，由 rc.d(S99) 启动后期执行(避免早期 apk 库未就绪)
/etc/init.d/firstboot-pkgs enable

# 主题默认浅色（覆盖 fwx 出厂 theme_mode=1）
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
*) error_exit "PHASE仅支持 before / themes / ruby / after" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
