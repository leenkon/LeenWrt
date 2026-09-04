#!/usr/bin/env bash
# 构建期把 OAF 特征库刷新为官方免费最新版（token=0 即可，无需订阅 key）。
# oafd 启动即解密 /etc/fwxd/feature.bin；本脚本用官方免费包覆盖 OAF 包内 48 条样板，
# 并解包同一压缩包内的图标刷新本地图标库。网络/校验失败则保留现状、返回 0，不阻断离线构建。
# 用法：OAF 克隆之后、make 之前调用。环境变量：FEATURE_PY / OAF_FEATURE_BIN / OAF_ICONS_DIR
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { command -v cygpath >/dev/null 2>&1 && cygpath -w "$(pwd)" || pwd -P; })"
FEATURE_PY="${FEATURE_PY:-$ROOT/scripts/feature-tool.py}"
OAF_FEATURE_BIN="${OAF_FEATURE_BIN:-package/OpenAppFilter/open-app-filter/files/feature.bin}"
# 与 fwx 共用同一图标源（扁平 <appId>.png），随 feature.bin 在线刷新
OAF_ICONS_DIR="${OAF_ICONS_DIR:-$ROOT/appfilter-assets/oaf-icons}"

PY="$(command -v python3 || command -v python || true)"
[ -x "$FEATURE_PY" ] || { echo "[feature] ERR: 缺 $FEATURE_PY"; exit 1; }
[ -n "$PY" ] || { echo "[feature] ERR: 未找到 python3"; exit 1; }

# 非 OAF 构建（未克隆）→ 跳过
[ -f "$OAF_FEATURE_BIN" ] || { echo "[feature] WARN: 未找到 $OAF_FEATURE_BIN（OAF 未克隆？），跳过"; exit 0; }

BIN="$(mktemp -t feature.XXXXXX.bin)"
trap 'rm -f "$BIN"' EXIT

echo "[feature] 拉取官方免费特征库（token=0，free=1 包，含 feature.bin + app_icons/）…"
"$PY" "$FEATURE_PY" fetch -o "$BIN" --icons "$OAF_ICONS_DIR" 2>&1 || { echo "[feature] WARN: 拉取/校验失败，保留 OAF 包内 feature.bin 与图标库（离线降级）"; exit 0; }

cp -f "$BIN" "$OAF_FEATURE_BIN"
echo "[feature] 已注入最新 feature.bin → $OAF_FEATURE_BIN"
# 审计：把烧进镜像的库版本+应用数打到构建日志，便于核对是否真带最新免费库
"$PY" "$FEATURE_PY" verify "$OAF_FEATURE_BIN" 2>&1 | sed 's/^/[feature] 审计: /'
[ -d "$OAF_ICONS_DIR" ] && echo "[feature] 审计: 图标库已刷新 → $OAF_ICONS_DIR ($(ls -1 "$OAF_ICONS_DIR" 2>/dev/null | wc -l) 个)"
exit 0
