#!/bin/bash
# upgrade-openclash.sh — OpenClash 升级统一入口
# 子命令:
#   core [项目根目录] [--files-dir <目录>] [--arch <架构>]
#       预装 Meta 核心二进制到 files/etc/openclash/core/，跳过设备首启在线下载。
#       执行时机: diy.sh after 之后、files/ 复制到 openwrt 之前（仅 OC 勾选时由 LeenWrtBuilder.yml (workflow) 调用）。
#   luci [openwrt目录]
#       用 vernesong/OpenClash 官方最新 master 替换 feeds 中的 luci-app-openclash。
#       执行时机: feeds update -a 之后、feeds install -a 之前（仅 OC 勾选时由 LeenWrtBuilder.yml (workflow) 调用）。
set -e

CMD="${1:-}"; [ $# -gt 0 ] && shift

case "$CMD" in
  core)
    PROJECT_ROOT="$(pwd -P)"
    FILES_DEST=""
    CORE_ARCH="linux-amd64"
    while [ $# -gt 0 ]; do
      case "$1" in
        --files-dir) FILES_DEST="$2"; shift 2 ;;
        --arch)      CORE_ARCH="$2"; shift 2 ;;
        -*) shift ;;
        *) PROJECT_ROOT="$(cd "$1" && pwd -P)"; shift ;;
      esac
    done
    FILES_DEST="${FILES_DEST:-$PROJECT_ROOT/files}"

    CORE_DIR="$FILES_DEST/etc/openclash/core"
    CORE_BIN="$CORE_DIR/clash_meta"
    MARKER="$CORE_DIR/.version"
    VERSION_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/core_version"
    TARBALL_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-${CORE_ARCH}.tar.gz"

    CORE_VERSION=$(curl -s --connect-timeout 10 "$VERSION_URL" | sed -n '1p')
    [ -z "$CORE_VERSION" ] && { echo "[ERROR] 无法获取核心版本（GitHub 可能不可达）"; exit 1; }
    echo "  最新版本: $CORE_VERSION"

    # 已预装且版本一致则跳过（用标记文件比对，避免重复下载大体积二进制）
    if [ -x "$CORE_BIN" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$CORE_VERSION" ]; then
      echo "[SKIP] 核心已是最新版本: $CORE_VERSION"
      exit 0
    fi

    mkdir -p "$CORE_DIR"
    TMP_TAR="/tmp/clash-${CORE_ARCH}.tar.gz"
    echo "[CORE] 下载 Meta 核心 (clash-${CORE_ARCH})..."
    curl -sL --connect-timeout 30 --output "$TMP_TAR" "$TARBALL_URL"
    [ ! -s "$TMP_TAR" ] && { echo "[ERROR] 核心二进制下载失败"; rm -f "$TMP_TAR"; exit 1; }

    tar zxf "$TMP_TAR" -C /tmp clash >/dev/null 2>&1 || {
      echo "[ERROR] 核心解压失败"; rm -f "$TMP_TAR" /tmp/clash; exit 1
    }
    mv /tmp/clash "$CORE_BIN"
    rm -f "$TMP_TAR"
    chmod 4755 "$CORE_BIN"
    echo "$CORE_VERSION" > "$MARKER"

    CORE_V=$("$CORE_BIN" -v 2>/dev/null | awk '{print $3}' | head -1)
    if [ -z "$CORE_V" ]; then
      echo "[WARN] 核心版本校验失败（可能非 x86_64 平台运行），文件已写入但不保证可用"
    else
      echo "[DONE] OpenClash Meta 核心已预装: $CORE_V → $CORE_BIN"
    fi
    ;;

  luci)
    OPENWRT_DIR="${1:-.}"
    echo "[OC-LUCI] 清理 feeds 中的 luci-app-openclash..."
    rm -rf "$OPENWRT_DIR/feeds/luci/applications/luci-app-openclash"
    rm -rf "$OPENWRT_DIR/feeds/packages/net/luci-app-openclash"
    rm -rf "$OPENWRT_DIR/package/feeds/luci/luci-app-openclash"
    rm -rf "$OPENWRT_DIR/package/OpenClash"

    echo "[OC-LUCI] 克隆 vernesong/OpenClash (最新 master)..."
    timeout 120 git clone --depth 1 https://github.com/vernesong/OpenClash "$OPENWRT_DIR/package/OpenClash" || {
      echo "[ERROR] luci-app-openclash 克隆失败"; exit 1
    }
    [ ! -f "$OPENWRT_DIR/package/OpenClash/luci-app-openclash/Makefile" ] && {
      echo "[ERROR] luci-app-openclash Makefile 未找到"; exit 1
    }

    # glob 加固：*.*.lmo -> *.lmo，兼容单/双点命名避免漏装 i18n
    sed -i 's#\$(PKG_BUILD_DIR)/\*\.\*\.lmo#$(PKG_BUILD_DIR)/*.lmo#' \
      "$OPENWRT_DIR/package/OpenClash/luci-app-openclash/Makefile"

    echo "[DONE] OpenClash LuCI 已替换为 GitHub 最新版"
    ;;

  *)
    echo "用法: $0 <core|luci> [参数]"
    echo "  core [项目根目录] [--files-dir <目录>] [--arch <架构>]   预装 Meta 核心二进制"
    echo "  luci [openwrt目录]                                    替换 luci-app-openclash 为官方最新"
    exit 2
    ;;
esac
