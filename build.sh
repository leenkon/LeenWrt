#!/bin/bash
# LeenWrt 本地编译脚本（Debian/Ubuntu）
# 单核心由 cores/<core>.conf 驱动：leenwrt(fork 自 immortalwrt 上游, OC/ADGH 全功能, 可选 fwx 应用过滤)。
# 用法: chmod +x build.sh && ./build.sh

set -e

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
error_exit() { echo -e "${RED}错误：$1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }

# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
DEF_GATEWAY="10.10.10.1"
ROOT_PASSWORD="password"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_CONF_DIR="$SCRIPT_DIR/cores"

# ========== 1. 核心选择 ==========
echo "========================================"
echo "    路由固件本地编译脚本"
echo "========================================"
echo -e "\n请选择核心（编译源）："
echo "  1) leenwrt (默认, fork 自 immortalwrt 上游)"
read -p "请输入选择 [1，默认 1]: " c
c=${c:-1}
case "$c" in 1) CORE="leenwrt";; *) error_exit "无效选择";; esac

# source 核心描述文件
CORE_CONF="$CORE_CONF_DIR/$CORE.conf"
[ -f "$CORE_CONF" ] || error_exit "缺失核心描述: $CORE_CONF"
# shellcheck disable=SC1090
source "$CORE_CONF"
success "核心: $CORE ($REPO_URL)"

# ========== 2. 版本选择（来自核心描述 VERSION_OPTIONS） ==========
echo -e "\n请选择 $CORE 版本："
i=1
for v in $VERSION_OPTIONS; do echo "  $i) $v"; i=$((i+1)); done
read -p "请输入选择 [1-$(($i-1))，默认 1]: " vsel
vsel=${vsel:-1}
VERSION=$(echo $VERSION_OPTIONS | awk -v n="$vsel" '{print $n}')
[ -n "$VERSION" ] || error_exit "无效选择"
success "版本: $VERSION"

# ========== 3. 配置选择 ==========
echo -e "\n请选择编译配置："
echo "  1) Main (主路由)  2) Mini (旁路由)  3) Full (完整路由)  4) Full-noadgh (完整路由无ADGH)"
read -p "请输入选择 [1-4，默认 1]: " p
p=${p:-1}
case "$p" in 1) PROFILE="Main";; 2) PROFILE="Mini";; 3) PROFILE="Full";; 4) PROFILE="Full-noadgh";; *) error_exit "无效选择";; esac

# 解析配置（显式映射，避免按 '-' 拆分带来的歧义）
case "$PROFILE" in
  Main)        CFG_PREFIX=default; RUN_TYPE=main;;
  Mini)        CFG_PREFIX=mini;    RUN_TYPE=bypass;;
  Full)        CFG_PREFIX=full;    RUN_TYPE=full;;
  Full-noadgh) CFG_PREFIX=full;    RUN_TYPE=full; NO_ADGH="true";;
  *) error_exit "无效配置: $PROFILE";;
esac
NO_ADGH=${NO_ADGH:-false}
MAIN_VER=${VERSION%.*}

# 自定义IP
echo -e "\n[LAN IP]"
[[ "$RUN_TYPE" == "bypass" ]] && DEF_IP="$DEF_BYPASS_IP" || DEF_IP="$DEF_MAIN_IP"
read -p "自定义LAN IP [默认: $DEF_IP，回车跳过]: " custom_ip
ROUTER_IP="${custom_ip:-$DEF_IP}"
success "LAN IP: $ROUTER_IP"

# 网关(仅旁路由)
GATEWAY_IP=""
[[ "$RUN_TYPE" == "bypass" ]] && { read -p "网关IP [默认: $DEF_GATEWAY]: " gw; GATEWAY_IP="${gw:-$DEF_GATEWAY}"; success "网关: $GATEWAY_IP"; }

# PPPoE (主路由/完整路由)
PPPOE_USER="" PPPOE_PASS=""
[[ "$RUN_TYPE" == "main" || "$RUN_TYPE" == "full" ]] && { read -p "配置PPPoE? [y/N]: " pp; [[ "$pp" =~ ^[Yy]$ ]] && { read -p "用户名: " PPPOE_USER; read -p "密码: " PPPOE_PASS; success "PPPoE已配置"; } || success "使用DHCP"; }

# OC / ADGH：leenwrt 全功能（OAF 已由 fwx 应用过滤栈取代，不再单独安装）
WITH_OC="false"; WITH_ADGH="false"
if [ "$CORE" = "leenwrt" ]; then
  [[ "$RUN_TYPE" == "bypass" || "$RUN_TYPE" == "full" ]] && WITH_OC=true
  [[ "$RUN_TYPE" == "bypass" || ("$RUN_TYPE" == "full" && "$NO_ADGH" != "true") ]] && WITH_ADGH=true
fi

# fwx 应用过滤（可选，默认开启）：kmod-fwx/fwxd + 15 个 luci-app-fwx-* 编入镜像
WITH_FWX="true"
read -p "包含 fwx 应用过滤? [Y/n]: " fwx; [[ "$fwx" =~ ^[Nn]$ ]] && WITH_FWX="false"
[ "$WITH_FWX" = "true" ] && success "将包含 fwx 应用过滤"

# 旁路 IP (仅 leenwrt 主路由，用于 DNS 劫持排除规则和 DHCP DNS 选项)
BYPASS_IP=""
if [[ "$RUN_TYPE" == "main" && "$CORE" = "leenwrt" ]]; then
  read -p "旁路路由IP [默认: $DEF_BYPASS_IP，回车跳过]: " bip
  BYPASS_IP="${bip:-$DEF_BYPASS_IP}"
  success "旁路IP: $BYPASS_IP"
fi

# Root密码
read -p "Root密码 [默认: password]: " rp
ROOT_PWD="${rp:-$ROOT_PASSWORD}"
success "密码已设置"

# 确认
echo -e "\n========================================  准备编译  ========================================"
echo "  核心: $CORE | 版本: $VERSION | 配置: $PROFILE | IP: $ROUTER_IP | 类型: $RUN_TYPE"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
[[ -n "$BYPASS_IP" ]] && echo "  旁路IP: $BYPASS_IP"
echo "==================================================================================="
read -p "确认开始? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0

# ========== 编译 ==========
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY="$SCRIPT_DIR/scripts/diy.sh"
FEEDS_FILE_ABS="$SCRIPT_DIR/$FEEDS_FILE"
FILES_DIR_ABS="$SCRIPT_DIR/$FILES_DIR"

# 1. 换行符（路由器 ash 不兼容 CRLF）：统一修复 scripts/ 与 files/ 下所有脚本、YAML 及 init.d
echo -e "\n${YELLOW}[1/7] 检查换行符和权限...${NC}"
find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/$FILES_DIR" -type f \
  \( -name "*.sh" -o -name "*.yaml" -o -name "dns-hijack" -o -name "99-adgh-filters" -o -path "*/init.d/*" \) \
  -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$DIY" "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
success "完成"

# 2. 依赖
echo -e "\n${YELLOW}[2/7] 安装依赖...${NC}"
sudo apt update -y
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
libglib2.0-dev libgmp-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
ninja-build p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig uglifyjs \
upx-ucl unzip vim wget xmlto xxd zlib1g-dev
success "完成"

# 3. 源码
echo -e "\n${YELLOW}[3/7] 拉取源码...${NC}"
# 取源引用：leenwrt 用上游 tag（v${VERSION}）克隆检出
SRC_REF="${REF_PREFIX}${VERSION}"
if [[ -d "$OPENWRT_DIR" ]]; then
    read -p "删除现有目录? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] && rm -rf "$OPENWRT_DIR" || { error_exit "请先删除 $OPENWRT_DIR"; }
fi
if [[ ! -d "$OPENWRT_DIR" ]]; then
    # 直接按 SRC_REF（tag/分支）克隆检出，避免浅克隆 fetch 后无本地 ref 致 checkout 失败
    git clone --depth 1 --single-branch --branch "$SRC_REF" "$REPO_URL" "$OPENWRT_DIR" || error_exit "源码克隆失败"
fi
success "完成（取源引用: $SRC_REF）"

# 4. 配置
echo -e "\n${YELLOW}[4/7] 准备配置...${NC}"
cd "$OPENWRT_DIR"
"$DIY" -v "$MAIN_VER" -p before -t "$RUN_TYPE" --feeds "$FEEDS_FILE_ABS" ${WITH_FWX:+"--with-fwx"}
./scripts/feeds update -a

# OpenClash LuCI 替换（仅 leenwrt 旁路由 / 完整路由）
if [[ "$WITH_OC" == "true" ]]; then
  chmod +x "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
  "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh" "$OPENWRT_DIR"
fi

# AdGuardHome LuCI 壳去除对引擎包(adguardhome)的硬依赖（仅 leenwrt 25.12；引擎走二进制注入）
if [[ "$CORE" = "leenwrt" && "$MAIN_VER" = "25.12" ]]; then
  ADGH_LUCI_MK="$OPENWRT_DIR/feeds/luci/applications/luci-app-adguardhome/Makefile"
  if [ -f "$ADGH_LUCI_MK" ]; then
    sed -i -e 's/+adguardhome //g' -e '/LUCI_EXTRA_DEPENDS:=adguardhome/d' "$ADGH_LUCI_MK"
    echo "[build] 已去除 luci-app-adguardhome 对 adguardhome 的硬依赖（引擎走二进制注入）"
  else
    echo "[build] 警告: 未找到 luci-app-adguardhome Makefile，跳过依赖去除"
  fi
fi

./scripts/feeds install -a -f

# leenwrt：直接套用本地 .config 种子（configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config）
cp "$SCRIPT_DIR/configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config" .config || error_exit "配置文件不存在: configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config"
sed -i 's/\r$//' .config
# Full-noadgh：本 profile 不注入 ADGH 引擎，移除 LuCI 壳避免“有菜单无服务”
if [[ "$RUN_TYPE" = "full" && "$NO_ADGH" = "true" ]]; then
  sed -i 's/^CONFIG_PACKAGE_luci-app-adguardhome=y/# &/' .config
  sed -i 's/^CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y/# &/' .config
  echo "[build] Full-noadgh: 已禁用 luci-app-adguardhome（无引擎）"
fi

# fwx 应用过滤（可选）：kmod-fwx/fwxd + 15 个 luci-app-fwx-* 编入镜像
if [[ "$WITH_FWX" = "true" ]]; then
  {
    echo ""
    echo "# ===== fwx 应用过滤栈（可选：kmod-fwx/fwxd/libfwx_common vendored in feeds/fwx + 15 个 luci-app-fwx-* 来自 src-git fanchmwrt-packages）====="
    echo "CONFIG_PACKAGE_kmod-fwx=y"
    echo "CONFIG_PACKAGE_fwxd=y"
    echo "CONFIG_PACKAGE_libfwx_common=y"
    echo "CONFIG_PACKAGE_libmosquitto=y"
    echo "CONFIG_PACKAGE_libsqlite3=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-app-center=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-appfilter=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-dashboard=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-dashboard-setting=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-feature=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-mac-blacklist=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-macfilter=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-network=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-record=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-record-whitelist=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-resources=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-session-stat=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-system=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-user=y"
    echo "CONFIG_PACKAGE_luci-app-fwx-user-record=y"
  } >> .config
  echo "[build] 已追加 fwx 应用过滤栈 CONFIG（kmod-fwx/fwxd/libfwx_common vendored + 15 个 luci-app-fwx-* 来自 src-git fanchmwrt-packages）"
fi
success "完成"

# 5. 网络配置
echo -e "\n${YELLOW}[5/7] 生成网络配置...${NC}"
# --no-adgh 仅在 NO_ADGH=true 时传入（leenwrt Full-noadgh）
NOADGH_ARG=""
[ "$NO_ADGH" = "true" ] && NOADGH_ARG="--no-adgh"
"$DIY" -v "$MAIN_VER" -p after -t "$RUN_TYPE" --files-dir "$FILES_DIR_ABS" \
  ${ROUTER_IP:+--ip "$ROUTER_IP"} \
  ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
  ${BYPASS_IP:+--bypass-ip "$BYPASS_IP"} \
  ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
  ${NOADGH_ARG:+"$NOADGH_ARG"} \
  ${WITH_FWX:+"--with-fwx"} \
  --root-pass "$ROOT_PWD"
success "完成"

# 6. 预装核心 + 打包 files
echo -e "\n${YELLOW}[6/7] 预装核心与打包文件...${NC}"
# OpenClash Meta 核心预装（仅 leenwrt 旁路由 + 完整路由）
if [[ "$WITH_OC" == "true" ]]; then
    chmod +x "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh"
    "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
# AdGuardHome 官方预编译二进制注入（仅 leenwrt 旁路由 + 完整路由；Full-noadgh 不注入）
if [[ "$WITH_ADGH" == "true" ]]; then
    chmod +x "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh"
    "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
[[ -d "$FILES_DIR_ABS" ]] && { rm -rf "$OPENWRT_DIR/files"; cp -rf "$FILES_DIR_ABS" "$OPENWRT_DIR/files"; }

# 离线 .apk：拷入镜像首启安装目录 /etc/firstboot-pkgs/apps/（由 firstboot-pkgs 用 --allow-untrusted 安装）
mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps"
cp -f "$SCRIPT_DIR/apps/"*.apk "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps/" 2>/dev/null || true

# 文件清理：按 profile 删除不需要的静态文件（在 openwrt 副本上操作，不修改源树）
if [[ "$CORE" = "leenwrt" ]]; then
case "$RUN_TYPE" in
  main)
    rm -rf "$OPENWRT_DIR/files/etc/adguardhome"
    rm -rf "$OPENWRT_DIR/files/etc/openclash"
    rm -f "$OPENWRT_DIR/files/usr/bin/AdGuardHome"
    rm -f "$OPENWRT_DIR/files/etc/init.d/adguardhome"
    rm -f "$OPENWRT_DIR/files/etc/config/adguardhome"
    ;;
  bypass)
    rm -f "$OPENWRT_DIR/files/usr/sbin/dns-hijack"
    ;;
  full)
    if [ "$NO_ADGH" = "true" ]; then
      rm -rf "$OPENWRT_DIR/files/etc/adguardhome"
      rm -f "$OPENWRT_DIR/files/usr/bin/AdGuardHome"
      rm -f "$OPENWRT_DIR/files/etc/init.d/adguardhome"
      rm -f "$OPENWRT_DIR/files/etc/config/adguardhome"
    fi
    ;;
esac
fi
# 确保脚本可执行（Windows 无 Unix x 位，按路径/扩展名匹配）
find "$OPENWRT_DIR/files" -type f \( -path "*/sbin/*" -o -path "*/init.d/*" -o -path "*/hotplug.d/*" -o -path "*/uci-defaults/*" -o -name "*.sh" \) -exec chmod 755 {} + 2>/dev/null || true
make defconfig && make download && make clean
success "完成"

# 7. 编译
echo -e "\n${YELLOW}[7/7] 编译固件...${NC}"
make -j$(nproc) || make -j1 V=s

echo -e "\n${GREEN}========================================  编译完成!  ========================================${NC}"
echo "固件位置: $OPENWRT_DIR/bin/targets/x86/64/"
ls -la "$OPENWRT_DIR/bin/targets/x86/64/"*combined*.img.gz 2>/dev/null || true
