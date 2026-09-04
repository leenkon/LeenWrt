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

# fwx 源码树补丁：DPI 边界守卫 + fwxd 联网检查；上下文不符即 fail-fast（静默跳过曾致 fwx 过滤 panic）
_apply_fwx_src_patch() {
    local name="$1" patch="$2" target="${3:-$PROJECT_ROOT/feeds/fwx/fwx}"
    [ -f "$patch" ] || error_exit "未找到 $name 补丁: $patch"
    [ -d "$target" ] || error_exit "未找到 $name 目标目录: $target（feeds/fwx 未就绪？）"
    if patch -p1 --reverse --dry-run -d "$target" < "$patch" >/dev/null 2>&1; then
        echo "[diy] $name 已应用，跳过"
    elif patch -p1 --dry-run -d "$target" < "$patch" >/dev/null 2>&1; then
        patch -p1 -d "$target" < "$patch"
        echo "[diy] applied $name -> $target"
    else
        error_exit "$name 补丁上下文不符，未应用（详见 $patch）；fwx 版本漂移需重新钉点"
    fi
}

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
SUBNET_MASK="255.255.255.0"
DNS_MAIN="223.5.5.5"
DNS_BACKUP="223.6.6.6"

VERSION="" PHASE="" PROFILE_TYPE="" FEEDS_SRC="" FILES_DIR_NAME="files"
NO_ADGH=0 WITH_FWX=0 WITH_OC=0 WITH_OAF=0 WITH_DNS_HIJACK=1
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
        --with-oaf)  WITH_OAF=1; shift ;;
        --with-oc)   WITH_OC=1; shift ;;
        --feeds)     FEEDS_SRC="$2"; shift 2 ;;
        --files-dir) FILES_DIR_NAME="$2"; shift 2 ;;
        *) error_exit "未知参数 $1" ;;
    esac
done

[ -n "$VERSION" ] && [ -n "$PHASE" ] || error_exit "必填 --version / --phase"
[ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ] && error_exit "after阶段必须指定 --type full/bypass"
case "$PROFILE_TYPE" in ""|bypass|full) ;; *) error_exit "--type 仅支持 bypass / full" ;; esac

# OAF 与 fwx 互斥：同为 conntrack 级 DPI，共用 /etc/config/fwx、/usr/bin/rule_manager、/etc/fwxd/feature.*，
# 并存会互相覆盖文件与抢钩子。OAF 优先（与 workflow 的判定一致，此处兜底防止手工调用漏掉互斥）
if [ "$WITH_OAF" = "1" ] && [ "$WITH_FWX" = "1" ]; then
    echo "[diy] OAF 已勾选 → 强制关闭 fwx" >&2
    WITH_FWX=0
fi

if [ "$PROFILE_TYPE" = "bypass" ]; then
    # 旁路由：--ip=本机LAN IP(默认10.10.10.2)，--gateway=上游主路由(默认10.10.10.1)
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
    # src-link 相对路径在 openwrt TOPDIR 解析失败，改写为绝对路径以定位 feeds/fwx
    sed -i "s#\./feeds/fwx#$PROJECT_ROOT/feeds/fwx#g" feeds.conf

    # 未勾选 fwx（含 OAF 优先互斥）时移除 fwx/fwxluci feed 注册，构建面彻底不含 fwx 包
    if [ "$WITH_FWX" != "1" ]; then
        sed -i '/^[[:space:]]*src-link[[:space:]]\+fwx/d' feeds.conf
        sed -i '/^[[:space:]]*src-git[[:space:]]\+fwxluci/d' feeds.conf
        echo "[diy] fwx/fwxluci feed 已移除（未勾选 fwx）"
    fi

    # fwx 内核改动(kmod-fwx 硬依赖)整体受 --with-fwx 门控：不勾选时零 fwx 内核补丁，连 950 都不注入。
    if [ "$WITH_FWX" = "1" ]; then
        FWX_KERN_PATCH="$PROJECT_ROOT/patches/fwx/950-fwx-nf-conn-struct-user-hook.patch"
        if [ -f "$FWX_KERN_PATCH" ]; then
            # 950 针对 6.12 系列(系列内任意子版本均可尝试)；版本取自 target/linux/generic/kernel-6.12 的 LINUX_KERNEL_HASH-6.12.xx
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

        # 6.12 主线 nf_send_reset 原生 4 参 (net,sk,oldskb,hook)（5.11+ 起），fwx 源码 >5.10.197 分支已正确调用 4 参；改 3 参(旧补丁方向)会令 RST 发送时 sk 取错寄存器 → 内核 panic，故 fwx 源码保持 4 参调用、不应用任何 3 参改写补丁
        _apply_fwx_src_patch "fwx DPI bounds" "$PROJECT_ROOT/patches/fwx/fwx-match-feature-crash.patch"
        _apply_fwx_src_patch "fwxd internet check" "$PROJECT_ROOT/patches/fwx/fwxd-internet-check-dns-agnostic.patch" "$PROJECT_ROOT/feeds/fwx/fwxd"

        # 自检闸门：DPI 钳制须真实落入 fwx_main.c（fwx 6.12 的 nf_send_reset 已是 4 参 (net,sk,oldskb,hook)，勿改 3 参）。fwx Makefile 无 PKG_RELEASE，须 touch 强制重编，否则复用旧 build_dir .o 静默产出未打补丁 fwx.ko
        FWX_MAIN_C="$PROJECT_ROOT/feeds/fwx/fwx/src/fwx_main.c"
        [ -f "$FWX_MAIN_C" ] || error_exit "fwx 源码缺失: $FWX_MAIN_C（sync-fwx 未拉取？）"
        if ! grep -q "skb_tail_pointer" "$FWX_MAIN_C"; then
            error_exit "DPI 补丁未生效：fwx_main.c 缺少 skb_tail_pointer 钳制 → 行为管理将内核 panic"
        fi
        # 强制 OpenWrt 重新 prepare/编译 fwx（Makefile 无 PKG_RELEASE，避免复用旧 build_dir 对象）
        touch "$PROJECT_ROOT/feeds/fwx/fwx/Makefile" 2>/dev/null || true
        echo "[diy] fwx 补丁自检通过(src 已含 DPI 钳制)，已 touch Makefile 强制重编"
    fi

    ;;

ruby)
    # ruby YJIT 解耦：分支头 lang/ruby 默认拉起 rust/host（rustc LLVM 404 致构建挂）；OpenClash 依赖 ruby 不可选，仅 WITH_OC 时调用
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
    # 须在 feeds update -a 后运行（argon/bootstrap 在 src-git feeds/luci，update 后落地）
    # 所有主题统一处理：
    #  1) 标题：.ut 即 ucode，用 {{ }}（旧 Lua <%= %> 属损坏，重构建自愈）。
    #  2) footer：隐藏不删除，保 #modemenu DOM 防 menu-argon.js 抛错致侧边栏不渲染。
    echo "[diy] themes: 处理 fanchmwrt/argon/bootstrap 主题标题与 footer"
    OPENWRT_DIR="$PROJECT_ROOT/openwrt"
    _FWX_THEME="$PROJECT_ROOT/feeds/fwx/luci-theme-fanchmwrt"
    _LUCIF_DIR="$OPENWRT_DIR/feeds/luci"
    python3 - "$_FWX_THEME" "$_LUCIF_DIR" <<'PY'
import sys, os, re, glob
fwm_root, luci_dir = sys.argv[1], sys.argv[2]

# .ut 即 ucode 模板；Lua <%= %> 分支仅遗留兼容。
# boardinfo.hostname / node.title / striptags 为模板上下文变量。
TITLE_UCODE = "<title>{{ striptags((boardinfo.hostname or '?') .. (node and ' - ' .. node.title or '')) }} - LuCI</title>"
TITLE_LUA  = "<title><%= striptags((boardinfo.hostname or '?') .. (node and ' - ' .. node.title or '')) %> - LuCI</title>"
# 隐藏 footer 但保留 DOM，整串用于重复构建去重。
HIDE_CSS = '<style id="leenwrt-hide-footer">footer{display:none!important}</style>'

def fix_header(path):
    s0 = open(path, encoding='utf-8').read()
    s = s0
    # .ut 即 ucode（LuCI 约定）；旧 Lua <%= %> 按损坏自愈重注入。
    is_ucode = path.endswith('.ut')
    TITLE_NEW = TITLE_UCODE if is_ucode else TITLE_LUA
    # 替换 <title>，容忍 <title ...> 属性
    s, n = re.subn(r'<title[^>]*>.*?</title>', TITLE_NEW, s, count=1, flags=re.S)
    if n and HIDE_CSS not in s:
        # 紧跟 </title> 注入，不依赖 </head> 是否存在
        s = s.replace(TITLE_NEW, TITLE_NEW + "\n    " + HIDE_CSS, 1)
    if s != s0:
        open(path, 'w', encoding='utf-8').write(s)
        print("[diy] 标题+footer隐藏已应用: " + path)
    elif n:
        print("[diy] 标题已替换，footer CSS 已存在(无变更): " + path)
    else:
        print("[diy] 未在 header.ut 找到 <title>: " + path)

theme_dirs = set()
# glob 不会匹配基础目录自身，须把 fwm_root 直接加入；argon/bootstrap 在 luci_dir/themes 下递归。
if os.path.isdir(fwm_root):
    theme_dirs.add(fwm_root)
for p in glob.glob(os.path.join(luci_dir, 'themes', '**', 'luci-theme-*'), recursive=True):
    if os.path.isdir(p):
        theme_dirs.add(p)

for d in sorted(theme_dirs):
    for h in glob.glob(os.path.join(d, '**', 'header.ut'), recursive=True):
        fix_header(h)
PY
    ;;

config)
    # .config 主题注入：seed 仅含基础主题(argon/bootstrap)；按 WITH_FWX 追加 fanchmwrt(开)与默认主题(开=fanchmwrt/关=argon)
    echo "[diy] config: 注入默认主题(CONFIG_LUCI_DEFAULT_THEME，按 WITH_FWX)"
    CONFIG_FILE=".config"
    [ -f "$CONFIG_FILE" ] || error_exit "缺失 $CONFIG_FILE（config 阶段须在 .config 复制后调用）"
    # 确保末尾有换行（seed .config 末行可能无换行，避免追加内容粘连上一行）
    [ -n "$(tail -c1 "$CONFIG_FILE" 2>/dev/null)" ] && printf '\n' >> "$CONFIG_FILE"
    # 去重：移除任何已存在的默认主题行（seed 不再含此行，此处兜底）
    sed -i '/^CONFIG_LUCI_DEFAULT_THEME=/d' "$CONFIG_FILE"
    if [ "$WITH_FWX" = "1" ]; then
        grep -q '^CONFIG_PACKAGE_luci-theme-fanchmwrt=' "$CONFIG_FILE" || echo 'CONFIG_PACKAGE_luci-theme-fanchmwrt=y' >> "$CONFIG_FILE"
        echo 'CONFIG_LUCI_DEFAULT_THEME="fanchmwrt"' >> "$CONFIG_FILE"
        echo "[diy] 已追加 luci-theme-fanchmwrt（默认 fanchmwrt）"
    else
        echo 'CONFIG_LUCI_DEFAULT_THEME="argon"' >> "$CONFIG_FILE"
        echo "[diy] 已设默认主题 argon（关 fwx，不引入 fanchmwrt）"
    fi
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

    # ADGH 仅 enable：真正 start 由 init.d 的 interface-up trigger 驱动（uci-defaults 阶段接口未 up，勿 early 调 procd）
    ADGH_ENABLE_BLK=$(cat <<'EOF'
chmod 755 /etc/init.d/adguardhome
/etc/init.d/adguardhome enable
EOF
)
    # dns-balance 常驻自愈合：ADGH 或 OC 任一存在即启用（上游/劫持表全权管理）
    DNS_BALANCE_ENABLE_BLK=$(cat <<'EOF'
chmod 755 /etc/init.d/dns-balance
/etc/init.d/dns-balance enable
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

    # full 共用：LAN 三态 ACCEPT + lan->wan 转发 + wan mtu_fix（不依赖上游默认 firewall，避免 lan input=REJECT 挡 LuCI 或无转发）
    LAN_FORWARD_BLK=$(cat <<'EOF'
LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && {
    uci set ${LAN_FW}.input='ACCEPT'
    uci set ${LAN_FW}.output='ACCEPT'
    uci set ${LAN_FW}.forward='ACCEPT'
}
WAN_FW=$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "$WAN_FW" ] && uci set ${WAN_FW}.mtu_fix='1'
_i=0; while [ $_i -lt 16 ] && uci -q delete firewall.@forwarding[0]; do _i=$((_i+1)); done
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

    # 主路由端口：WAN 锁 eth1（本机物理前口映射为 eth1，非 eth0）；其余 eth* 桥 br-lan
    if [ "$PROFILE_TYPE" = "full" ]; then
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME"); p=$(_escape_uci "$PPPOE_PASSWORD")
            WAN_BLK=$(cat <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'
uci set network.wan.peerdns='1'
uci set network.wan.device='eth1'
# PPPoE MTU 1492，缺 MSS 钳制会导致大包被 PMTU 黑洞丢弃(已连接但打不开网页)
uci set network.wan.mtu_fix='1'
uci -q delete network.wan6
EOT
)
        else
            WAN_BLK=$(cat <<EOT
uci set network.wan.proto='dhcp'
uci set network.wan.device='eth1'
uci set network.wan.peerdns='1'
uci set network.wan.mtu_fix='1'
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
EOT
)
        fi
        # 端口：eth1=WAN 不进桥；其余 eth* 桥接 br-lan 作 LAN（避免 lan/wan 争 eth1）
        PORT_BLK=$(cat <<'EOT'
# 先删既有 br-lan device（默认配置含匿名段，不删会并存两个同名桥 → 端口双归属、LuCI 解析异常）
for _d in $(uci show network 2>/dev/null | sed -n "s/^\(network\.[^.]*\)\.name='br-lan'$/\1/p"); do
  uci -q delete "$_d"
done
_lan_eth=$(ls /sys/class/net 2>/dev/null | grep -E '^eth[0-9]+$' | grep -v '^eth1$' | sort -V)
uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci -q delete network.br_lan.ports
for _e in $_lan_eth; do uci add_list network.br_lan.ports="$_e"; done
uci set network.lan.device='br-lan'
uci -q delete network.lan.type
uci -q delete network.lan.ports
uci -q delete network.lan.ifname
uci commit network
EOT
)
    fi

    echo '#!/bin/sh' > "$OUT"
    echo "logger -t uci-defaults \"开始应用${PROFILE_TYPE}配置\"" >> "$OUT"

    if [ "$PROFILE_TYPE" = "bypass" ]; then
        gw_esc=$(_escape_uci "$CUSTOM_GATEWAY")
        # OC/ADGH 按编译开关独立注入（上游/劫持表由 dns-balance 全权管理）
        BYPASS_OC_ADGH_BLK=""
        if [ "$WITH_OC" = "1" ]; then
            BYPASS_OC_ADGH_BLK="${BYPASS_OC_ADGH_BLK}${OC_CONFIG_BLK}
"
        fi
        if [ "$NO_ADGH" != "1" ]; then
            BYPASS_OC_ADGH_BLK="${BYPASS_OC_ADGH_BLK}${ADGH_ENABLE_BLK}
uci -q delete adguardhome.config.dns_hijack
uci set adguardhome.config.dns_hijack='$WITH_DNS_HIJACK'
$BYPASS_IP_UCI_BLK
uci commit adguardhome
"
        fi
        # dns-balance 启用：ADGH 或 OC 任一存在即启用一次
        if [ "$WITH_OC" = "1" ] || [ "$NO_ADGH" != "1" ]; then
            BYPASS_OC_ADGH_BLK="${BYPASS_OC_ADGH_BLK}${DNS_BALANCE_ENABLE_BLK}
"
        fi
        # 无 ADGH 且无 OC：dns-balance 不接管，静态兜底公网 DNS（防 dnsmasq 无上游）
        if [ "$WITH_OC" != "1" ] && [ "$NO_ADGH" = "1" ]; then
            BYPASS_OC_ADGH_BLK="${BYPASS_OC_ADGH_BLK}uci -q delete dhcp.@dnsmasq[0].port
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci commit dhcp
"
        fi
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

# 旁路由：所有网口桥接为 LAN，重建 br-lan（与 LeenWrt2 对齐；全口 LAN 可插任意口）
_fw_all=\$(ls /sys/class/net 2>/dev/null | grep -E '^eth[0-9]+\$' | sort -V)
if [ -n "\$_fw_all" ]; then
  for _d in \$(uci show network 2>/dev/null | sed -n "s/^\(network\.[^.]*\)\.name='br-lan'\$/\1/p"); do
    uci -q delete "\$_d"
  done
  uci set network.br_lan=device
  uci set network.br_lan.name='br-lan'
  uci set network.br_lan.type='bridge'
  uci -q delete network.br_lan.ports
  for _e in \$_fw_all; do
    uci add_list network.br_lan.ports="\$_e"
  done
  uci set network.lan.device='br-lan'
  uci -q delete network.lan.type
  uci -q delete network.lan.ports
  uci -q delete network.lan.ifname
  uci commit network
fi

        uci set dhcp.lan.ignore='1'
        uci set dhcp.lan6.ignore='1'
        uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
        # dnsmasq 上游/劫持表由 dns-balance 管理，此处不写
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
_i=0; while [ \$_i -lt 16 ] && uci -q delete firewall.@forwarding[0]; do _i=\$((\$_i+1)); done
uci commit firewall

$BYPASS_OC_ADGH_BLK
EOT
    elif [ "$PROFILE_TYPE" = "full" ]; then
        cat >> "$OUT" <<EOT
$WAN_BLK
$PORT_BLK
$LAN_WAN_COMMON_BLK

$IP_FORWARD_LN

$DHCP_COMMON_BLK
$LAN_FORWARD_BLK
$UPNP_BLK
EOT
        # OC/ADGH 配置按编译开关注入
        if [ "$WITH_OC" = "1" ]; then
            cat >> "$OUT" <<EOT
$OC_CONFIG_BLK
EOT
        fi
        if [ "$NO_ADGH" != "1" ]; then
            cat >> "$OUT" <<EOT
$ADGH_ENABLE_BLK
EOT
            # dns_hijack 写 uci；劫持表由 dns-balance 常驻按 ADGH 监听态布/清，=0 时改用 REJECT 强制走路由器 DNS
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
        # dns-balance 启用：ADGH 或 OC 任一存在即启用一次
        if [ "$WITH_OC" = "1" ] || [ "$NO_ADGH" != "1" ]; then
            cat >> "$OUT" <<EOT
$DNS_BALANCE_ENABLE_BLK
EOT
        fi
        # 无 ADGH 且无 OC：dns-balance 不接管，静态兜底公网 DNS（防 dnsmasq 无上游）
        if [ "$WITH_OC" != "1" ] && [ "$NO_ADGH" = "1" ]; then
            cat >> "$OUT" <<EOT
uci -q delete dhcp.@dnsmasq[0].port
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci commit dhcp
EOT
        fi
    fi

    # fwx / OAF 应用过滤(DPI 内核模块)依赖 conntrack，与流卸载冲突会导致连接不稳/应用过滤失效，故开启任一后端时关闭流卸载
    if [ "$WITH_FWX" = "1" ] || [ "$WITH_OAF" = "1" ]; then
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

# 首启装 apps/ 的 .apk：本次由 rc.local 在系统就绪后触发；enable 备下次启动兜底(rcS glob 已展开)
chmod 755 /etc/init.d/firstboot-pkgs
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

    # OAF 设置与特征库首启自动更新放 rc.local：appfilter.init(START=96) 首启才生成 /etc/config/fwx，
    # uci-defaults 早于它，抢建会丢默认段落；rc.local 为启动末步，ubus/网络已就绪。
    if [ "$WITH_OAF" = "1" ]; then
        RC_LOCAL="$FB_DIR/etc/rc.local"
        mkdir -p "$(dirname "$RC_LOCAL")"
        [ -f "$RC_LOCAL" ] || printf 'exit 0\n' > "$RC_LOCAL"
        if ! grep -q "LeenWrt OAF" "$RC_LOCAL"; then
            OAF_RC_BLK=$(cat <<'EOF'
# LeenWrt OAF：出厂配置覆盖（浅色/网关模式/启用过滤）
[ -f /etc/config/fwx ] && {
    OAF_CHANGED=""
    [ "$(uci -q get fwx.global.theme_mode)" != "0" ] && { uci set fwx.global.theme_mode='0'; OAF_CHANGED=1; }
    [ "$(uci -q get fwx.network.work_mode)" != "0" ] && { uci set fwx.network.work_mode='0'; OAF_CHANGED=1; }
    [ "$(uci -q get fwx.appfilter.enable)" != "1" ] && { uci set fwx.appfilter.enable='1'; OAF_CHANGED=1; }
    [ -n "$OAF_CHANGED" ] && { uci commit fwx; logger -t oaf "已应用 LeenWrt 设置(浅色/网关模式/启用过滤)"; }
}
# LeenWrt OAF：首启经自带在线客户端(ubus fwx, UA 正确)拉官方最新免费特征库；写 flag 仅跑一次，失败下次重试
if [ ! -f /etc/oaf-feature-autoupdate.done ]; then
  (
    for i in $(seq 1 30); do ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && break; sleep 2; done
    ubus list fwx >/dev/null 2>&1 || exit 0
    list=$(ubus call fwx common '{"api":"get_feature_online_list","data":{"refresh":1,"lang":"cn"}}' 2>/dev/null)
    [ -n "$list" ] || exit 0
    ids=$(echo "$list" | jsonfilter -e '@.data.files[@.free=1].id' 2>/dev/null)
    cnts=$(echo "$list" | jsonfilter -e '@.data.files[@.free=1].count' 2>/dev/null)
    [ -n "$ids" ] || exit 0
    tmp=$(mktemp -d)
    printf '%s\n' "$ids" > "$tmp/ids"
    printf '%s\n' "$cnts" > "$tmp/cnts"
    best=$(paste -d' ' "$tmp/ids" "$tmp/cnts" 2>/dev/null | sort -k2 -n | tail -1 | awk '{print $1}')
    rm -rf "$tmp"
    if [ -n "$best" ] && ubus call fwx common "{\"api\":\"start_feature_online_update\",\"data\":{\"id\":\"$best\",\"lang\":\"cn\"}}" >/dev/null 2>&1; then
      touch /etc/oaf-feature-autoupdate.done
    fi
  ) >/tmp/oaf-feature-autoupdate.log 2>&1 &
fi
EOF
)
            # 置于首行：rc.local 末尾还有 firstboot-pkgs(apk 安装耗时较久)，先落地 OAF 设置
            { printf '%s\n' "$OAF_RC_BLK"; grep -v '^exit 0$' "$RC_LOCAL" 2>/dev/null; echo 'exit 0'; } > "$RC_LOCAL.new" \
                && mv "$RC_LOCAL.new" "$RC_LOCAL"
            chmod 755 "$RC_LOCAL" 2>/dev/null || true
            echo "[diy] 输出: $RC_LOCAL（已追加 OAF 设置 + 特征库首启自动更新）"
        fi
    fi

    if [ -n "$ROOT_PASSWORD" ]; then
        command -v openssl >/dev/null 2>&1 || error_exit "缺失依赖: openssl (用于 root 密码哈希)"
        # musl crypt 仅认 DES/MD5($1$)，dropbear 才支持 SHA-512；用 -1 保证 SSH 与网页登录一致
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -1 -stdin) || error_exit "openssl密码加密失败"
        echo "root:$crypt:0:0:99999:7:::" > "$SHADOW"
        chmod 600 "$SHADOW" 2>/dev/null || true
    fi
    ;;
*) error_exit "PHASE仅支持 before / config / themes / ruby / after" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
