#!/bin/bash
# OpenClash Meta 核心预装脚本
# 下载最新 mihomo 核心二进制放入 files/<core>/etc/openclash/core/（如 files/leenwrt），跳过首次启动时的在线下载
#
# 用法: upgrade-openclash-core.sh [项目根目录] [--files-dir <核专属files目录>] [--arch linux-amd64]
#   --files-dir: 注入目标目录（如 files/leenwrt）；缺省回退到 <root>/files/leenwrt
#   --arch:      默认 linux-amd64 (x86_64)
#   仅 leenwrt 旁路由/完整路由构建时调用；执行时机: diy.sh after 之后、files/ 复制到 openwrt 之前

set -e

PROJECT_ROOT="$(pwd -P)"
FILES_DEST=""
CORE_ARCH="linux-amd64"
RELEASE_BRANCH="master"
while [ $# -gt 0 ]; do
  case "$1" in
    --files-dir) FILES_DEST="$2"; shift 2 ;;
    --arch)      CORE_ARCH="$2"; shift 2 ;;
    -*) shift ;;
    *) PROJECT_ROOT="$(cd "$1" && pwd -P)"; shift ;;
  esac
done
FILES_DEST="${FILES_DEST:-$PROJECT_ROOT/files/leenwrt}"

CORE_DIR="$FILES_DEST/etc/openclash/core"
CORE_BIN="$CORE_DIR/clash_meta"

# 获取最新版本号
CORE_VERSION=$(curl -s --connect-timeout 10 \
    "https://raw.githubusercontent.com/vernesong/OpenClash/core/${RELEASE_BRANCH}/core_version" \
    | sed -n '1p')
if [ -z "$CORE_VERSION" ]; then
    echo "[ERROR] 无法获取核心版本（GitHub 可能不可达）"
    exit 1
fi
echo "  最新版本: $CORE_VERSION"

# 已有核心且版本相同则跳过
if [ -x "$CORE_BIN" ]; then
    CURRENT_V=$("$CORE_BIN" -v 2>/dev/null | awk -F ' ' '{print $3}' | head -1)
    if [ "$CURRENT_V" = "$CORE_VERSION" ]; then
        echo "[SKIP] 核心已是最新版本: $CORE_VERSION"
        exit 0
    fi
fi

# 下载核心二进制
echo "[CORE] 下载 Meta 核心 (clash-${CORE_ARCH})..."
mkdir -p "$CORE_DIR"
TMP_TAR="/tmp/clash-${CORE_ARCH}.tar.gz"

curl -sL --connect-timeout 30 --output "$TMP_TAR" \
    "https://raw.githubusercontent.com/vernesong/OpenClash/core/${RELEASE_BRANCH}/meta/clash-${CORE_ARCH}.tar.gz"

if [ ! -s "$TMP_TAR" ]; then
    echo "[ERROR] 核心二进制下载失败"
    rm -f "$TMP_TAR"
    exit 1
fi

# 解压（tar.gz 内含 clash 二进制）
tar zxf "$TMP_TAR" -C /tmp clash >/dev/null 2>&1 || {
    echo "[ERROR] 核心解压失败"
    rm -f "$TMP_TAR" /tmp/clash
    exit 1
}

mv /tmp/clash "$CORE_BIN"
rm -f "$TMP_TAR"

# 设置权限（与 openclash_core.sh 一致: 4755）
chmod 4755 "$CORE_BIN"

# 验证二进制
CORE_V=$("$CORE_BIN" -v 2>/dev/null | awk -F ' ' '{print $3}' | head -1)
if [ -z "$CORE_V" ]; then
    echo "[WARN] 核心版本验证失败（可能在非 x86_64 平台运行），文件已保存但不保证可用"
else
    echo "[DONE] OpenClash Meta 核心已预装: v${CORE_V} → $CORE_BIN"
fi
