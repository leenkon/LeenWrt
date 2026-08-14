#!/bin/bash
# OpenClash LuCI 插件升级脚本
# 从 vernesong/OpenClash GitHub 最新 master 替换 feeds 中的 luci-app-openclash
#
# 执行时机: feeds update -a 之后、feeds install -a 之前
# 原理: 删除 feeds 中的 openclash 源码，克隆官方仓库到 package/

set -e

OPENWRT_DIR="${1:-.}"

echo "[OC-LUCI] 清理 feeds 中的 luci-app-openclash..."
rm -rf "$OPENWRT_DIR/feeds/luci/applications/luci-app-openclash"
rm -rf "$OPENWRT_DIR/feeds/packages/net/luci-app-openclash"
rm -rf "$OPENWRT_DIR/package/feeds/luci/luci-app-openclash"
rm -rf "$OPENWRT_DIR/package/OpenClash"

echo "[OC-LUCI] 克隆 vernesong/OpenClash..."
timeout 120 git clone --depth 1 https://github.com/vernesong/OpenClash "$OPENWRT_DIR/package/OpenClash"

if [ ! -f "$OPENWRT_DIR/package/OpenClash/luci-app-openclash/Makefile" ]; then
    echo "[ERROR] luci-app-openclash Makefile 未找到"
    exit 1
fi

echo "[DONE] OpenClash LuCI 已替换为 GitHub 最新版"
