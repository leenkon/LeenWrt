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

# ========== 核心描述（单核 leenwrt） ==========
echo "========================================"
echo "    路由固件本地编译脚本"
echo "========================================"
CORE="leenwrt"
CORE_CONF="$CORE_CONF_DIR/$CORE.conf"
[ -f "$CORE_CONF" ] || error_exit "缺失核心描述: $CORE_CONF"
# shellcheck disable=SC1090
source "$CORE_CONF"
success "核心: $CORE ($REPO_URL)"

# ========== 版本选择（来自核心描述 VERSION_OPTIONS） ==========
echo -e "\n请选择 $CORE 版本："
i=1
for v in $VERSION_OPTIONS; do echo "  $i) $v"; i=$((i+1)); done
read -p "请输入选择 [1-$(($i-1))，默认 1]: " vsel
vsel=${vsel:-1}
VERSION=$(echo $VERSION_OPTIONS | awk -v n="$vsel" '{print $n}')
[ -n "$VERSION" ] || error_exit "无效选择"
success "版本: $VERSION"

# ========== 配置选择 ==========
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

# OC / ADGH：leenwrt 全功能（旁路由/完整路由启用）
WITH_OC="false"; WITH_ADGH="false"
[[ "$RUN_TYPE" == "bypass" || "$RUN_TYPE" == "full" ]] && WITH_OC=true
[[ "$RUN_TYPE" == "bypass" || ("$RUN_TYPE" == "full" && "$NO_ADGH" != "true") ]] && WITH_ADGH=true

# fwx 应用过滤（可选，默认开启）：包清单见 feeds/fwx/fwx-packages.list
WITH_FWX="true"
read -p "包含 fwx 应用过滤? [Y/n]: " fwx; [[ "$fwx" =~ ^[Nn]$ ]] && WITH_FWX="false"
[ "$WITH_FWX" = "true" ] && success "将包含 fwx 应用过滤"

# 旁路 IP (主路由，用于 DNS 劫持排除规则和 DHCP DNS 选项)
BYPASS_IP=""
if [[ "$RUN_TYPE" == "main" ]]; then
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

# 按钉死 SHA 从 fanchmwrt/package/fcm 动态拉取包；SHA 不变则跳过(.MARKER 缓存)，失败降级/报错
pull_fcm_package() {
  local fcm_path="$1" local_dir="$2" marker="$3" commit="$4" label="$5"
  if [[ -z "$commit" ]]; then
    echo "[build] 警告: 未设置 ${label} 的 COMMIT，跳过动态拉取（使用本地缓存副本）"
    return 0
  fi
  if [[ -f "$marker" && "$(cat "$marker" 2>/dev/null)" = "$commit" ]]; then
    echo "[build] ${label} 已缓存 @ $commit，跳过拉取"
    return 0
  fi
  echo -e "\n${YELLOW}[build] 动态拉取 ${label} (${fcm_path} @ ${commit})...${NC}"
  local tmp="$(mktemp -d)" files=()
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(
    curl -fsSL "https://api.github.com/repos/${FWX_UPSTREAM_REPO}/git/trees/${commit}?recursive=1" 2>/dev/null \
    | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in d.get('tree',[]):
    p=t['path']
    if p.startswith('${fcm_path}/') and t['type']=='blob': print(p)" 2>/dev/null
  )
  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ -d "$local_dir" && -n "$(ls -A "$local_dir" 2>/dev/null | grep -v "^$(basename "$marker")\$")" ]]; then
      echo "[build] 警告: 无法从 GitHub 拉取 ${label}，使用本地缓存副本（非钉死 SHA 版本）" >&2
    else
      rm -rf "$tmp"; error_exit "${label} 拉取失败且无可本地缓存：请检查网络 / ${label} COMMIT($commit)"
    fi
  else
    for f in "${files[@]}"; do
      rel="${f#${fcm_path}/}"; dst="$tmp/$rel"
      mkdir -p "$(dirname "$dst")"
      if ! curl -fsSL "https://raw.githubusercontent.com/${FWX_UPSTREAM_REPO}/${commit}/$f" -o "$dst" 2>/dev/null; then
        rm -rf "$tmp"; error_exit "${label} 文件下载失败: $f"
      fi
    done
    rm -rf "$local_dir"; mkdir -p "$local_dir"; cp -a "$tmp/." "$local_dir/"
    echo "$commit" > "$marker"
    echo "[build] 已拉取 ${label} (${#files[@]} 文件) @ $commit"
  fi
  rm -rf "$tmp" 2>/dev/null || true
}

# 3.5 fwx 核心动态拉取（仅 --with-fwx），950/kmod 补丁不受影响
if [[ "$WITH_FWX" = "true" ]]; then
  pull_fcm_package "$FWX_UPSTREAM_PATH" "$SCRIPT_DIR/feeds/fwx/fwx" "$SCRIPT_DIR/feeds/fwx/fwx/.fwx_commit" "$FWX_COMMIT" "fwx 核心"
fi

# 3.6 fanchmwrt 系统主题动态拉取（默认主题 fanchmwrt，bootstrap 作基础）
pull_fcm_package "$THEME_UPSTREAM_PATH" "$SCRIPT_DIR/feeds/fwx/luci-theme-fanchmwrt" "$SCRIPT_DIR/feeds/fwx/luci-theme-fanchmwrt/.theme_commit" "$THEME_COMMIT" "luci-theme-fanchmwrt"

# 4. 配置
echo -e "\n${YELLOW}[4/7] 准备配置...${NC}"
cd "$OPENWRT_DIR"
"$DIY" -v "$MAIN_VER" -p before -t "$RUN_TYPE" --feeds "$FEEDS_FILE_ABS" ${WITH_FWX:+"--with-fwx"}
./scripts/feeds update -a

# OpenClash LuCI 替换（仅 leenwrt 旁路由 / 完整路由）
if [[ "$WITH_OC" == "true" ]]; then
  "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh" "$OPENWRT_DIR"
fi

# AdGuardHome LuCI 壳去除对引擎包(adguardhome)的硬依赖（leenwrt 25.12；引擎走二进制注入）
if [[ "$MAIN_VER" = "25.12" ]]; then
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

# fwx 应用过滤（可选）：包清单见 feeds/fwx/fwx-packages.list
if [[ "$WITH_FWX" = "true" ]]; then
  FWX_LIST="$SCRIPT_DIR/feeds/fwx/fwx-packages.list"
  if [[ -f "$FWX_LIST" ]]; then
    {
      echo ""
      echo "# ===== fwx 应用过滤栈（kmod-fwx 构建期按 SHA 动态拉取 + luci-app-fwx-* via src-git fwxluci；fwxd/libfwx_common vendored）====="
      while read -r pkg; do
        [[ -n "$pkg" && "$pkg" != \#* ]] && echo "CONFIG_PACKAGE_${pkg}=y"
      done < "$FWX_LIST"
    } >> .config
    echo "[build] 已追加 fwx 应用过滤栈 CONFIG（来自 $FWX_LIST）"
  else
    echo "[build] 警告: 未找到 fwx 包清单 $FWX_LIST，跳过 fwx CONFIG 注入"
  fi
fi

# fwx/fwxluci 为本地 feed，不作设备端远程 apk 仓库(官方镜像无 packages.adb，否则 apk update 404)；设 m 即注释保留。
for _f in fwx fwxluci; do
  if ! grep -q "^CONFIG_FEED_${_f}=" .config; then
    printf 'CONFIG_FEED_%s=m\n' "$_f" >> .config
  else
    sed -i "s/^CONFIG_FEED_${_f}=y/CONFIG_FEED_${_f}=m/" .config
  fi
done
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
    "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
# AdGuardHome 官方预编译二进制注入（仅 leenwrt 旁路由 + 完整路由；Full-noadgh 不注入）
if [[ "$WITH_ADGH" == "true" ]]; then
    "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
[[ -d "$FILES_DIR_ABS" ]] && { rm -rf "$OPENWRT_DIR/files"; cp -rf "$FILES_DIR_ABS" "$OPENWRT_DIR/files"; }

# 离线 .apk：拷入镜像首启安装目录 /etc/firstboot-pkgs/apps/（由 firstboot-pkgs 用 --allow-untrusted 安装）
mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps"
shopt -s nullglob
_copied=0
for _apk in "$SCRIPT_DIR/apps/"*.apk; do
  cp -f "$_apk" "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps/"
  _copied=$((_copied + 1))
done
shopt -u nullglob
if [ "$_copied" -gt 0 ]; then
  success "已拷贝 $_copied 个离线 .apk 到镜像首启安装目录"
else
  echo "[build] 警告: apps/ 下无 .apk，自定义离线包将不会随固件安装"
fi

# 文件清理：按 profile 删除不需要的静态文件（在 openwrt 副本上操作，不修改源树）
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
      # full-noadgh 不劫持 DNS(dnsmasq :53 + OC 兜底),dns-hijack 无人调用,移除
      rm -f "$OPENWRT_DIR/files/usr/sbin/dns-hijack"
    fi
    ;;
esac
# 确保脚本可执行（Windows 无 Unix x 位，按路径/扩展名匹配）
find "$OPENWRT_DIR/files" -type f \( -path "*/sbin/*" -o -path "*/init.d/*" -o -path "*/hotplug.d/*" -o -path "*/uci-defaults/*" -o -name "*.sh" \) -exec chmod 755 {} + 2>/dev/null || true
make defconfig && make download && make clean
success "完成"

# 7. 编译
echo -e "\n${YELLOW}[7/7] 编译固件...${NC}"
make -j$(nproc) || make -j1 V=s

# 构建结束：仅回退 fwx kmod 6.12 补丁(不影响 feeds/fwx/fwx 其它本地改动)
FWX_KMOD_PATCH="$SCRIPT_DIR/patches/fwx/kmod-nf_send_reset-6.12.patch"
if [ -f "$FWX_KMOD_PATCH" ]; then
    if patch -p1 -R --dry-run -d "$SCRIPT_DIR/feeds/fwx/fwx" < "$FWX_KMOD_PATCH" >/dev/null 2>&1; then
        patch -p1 -R -d "$SCRIPT_DIR/feeds/fwx/fwx" < "$FWX_KMOD_PATCH"
        echo "[build] 已回退 fwx kmod 6.12 兼容补丁(仅补丁本身,不影响其他本地改动)"
    else
        echo "[build] fwx kmod 补丁未应用或已回退,跳过清理"
    fi
else
    echo "[build] 警告: 未找到 fwx kmod 补丁 $FWX_KMOD_PATCH,跳过回退"
fi

echo -e "\n${GREEN}========================================  编译完成!  ========================================${NC}"
echo "固件位置: $OPENWRT_DIR/bin/targets/x86/64/"
ls -la "$OPENWRT_DIR/bin/targets/x86/64/"*combined*.img.gz 2>/dev/null || true
