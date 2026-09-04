#!/usr/bin/env bash
# sync-fwx.sh — 从 fanchmwrt 同步 fwx 组件与 fanchmwrt 系统主题到 LeenWrt（升级 fork 的 fwx / 主题）
# 用法: scripts/sync-fwx.sh [branch|pinned-SHA]   默认 fanchmwrt-25.12.4；传 40 位 commit SHA 则钉死模式(按该 SHA 拉取四组件, 不追分支头/不改写钉点/950/README, 供 CI 构建)
# 升级后请审阅 git diff，确认无误再提交推送。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 复用 leenwrt.conf 的上游钉点作为单一来源（FWX_UPSTREAM_REPO / FWX_UPSTREAM_PATH / FWX_UPSTREAM_BRANCH）
# shellcheck disable=SC1090
source "$ROOT/cores/leenwrt.conf" 2>/dev/null || true
BRANCH="${1:-${FWX_UPSTREAM_BRANCH:-fanchmwrt-25.12.4}}"
SRC_PATH="${FWX_UPSTREAM_PATH:-package/fcm/fwx}"
FWX_REPO="${FWX_UPSTREAM_REPO:-fanchmwrt/fanchmwrt}"
# 钉死模式：若第一个参数是完整 commit SHA(40位hex)，按该 SHA 拉取四组件，不追分支头、
# 不改写 FWX_COMMIT/THEME_COMMIT/950/README（供 CI 构建，避免 DPI 补丁上下文不符被静默跳过）
PINNED=0
if [[ "$BRANCH" =~ ^[0-9a-f]{40}$ ]]; then
  PINNED=1
  echo "[sync-fwx] 钉死模式: 按 FWX_COMMIT=$BRANCH 拉取, 不追分支头"
fi
RAW="https://raw.githubusercontent.com/$FWX_REPO/$BRANCH"
API="https://api.github.com/repos/$FWX_REPO/git/trees/$BRANCH?recursive=1"
LOCAL_FWX="$ROOT/feeds/fwx/fwx"
FWX_PATCH_DIR="$ROOT/patches/fwx"
README="$ROOT/feeds/fwx/README.md"

echo "== sync-fwx: 从 fanchmwrt@$BRANCH 同步 fwx 组件 =="

# 通用组件同步：package/fcm/<name> -> feeds/fwx/<name>
# fwxd / libfwx_common 均为 luci-app-fwx-* 必需依赖，缺一不可（否则 apk: no such package）
_sync_component() {
  local name="$1"
  local src="package/fcm/$name"
  local local_dir="$ROOT/feeds/fwx/$name"
  local tmp
  tmp="$(mktemp -d)"
  mapfile -t cf < <(curl -fsSL "$API" | python3 -c "
import sys,json
for t in json.load(sys.stdin).get('tree',[]):
    p=t['path']
    if p.startswith('$src/') and t['type']=='blob':
        print(p)
")
  if [ "${#cf[@]}" -eq 0 ]; then
    echo "WARN: 未拉取到组件 $name 源文件，跳过"
    rm -rf "$tmp"
    return 0
  fi
  for f in "${cf[@]}"; do
    rel="${f#$src/}"; dst="$tmp/$rel"
    mkdir -p "$(dirname "$dst")"
    curl -fsSL "$RAW/$f" -o "$dst"
  done
  rm -rf "$local_dir"; mkdir -p "$local_dir"; cp -a "$tmp/." "$local_dir/"
  echo "已刷新 feeds/fwx/$name/ (${#cf[@]} 文件)"
  rm -rf "$tmp"
}

# 1) 取版本锚点（commit + date）
read -r SHA DATE < <(curl -fsSL "https://api.github.com/repos/$FWX_REPO/commits?sha=$BRANCH&per_page=1" \
  | python3 -c "import sys,json;d=json.load(sys.stdin)[0];print(d['sha'], d['commit']['committer']['date'][:10])")
echo "源 commit: $SHA ($DATE)"

# 2) 列出 fwx 源文件（递归 tree，仅 blob，路径前缀 package/fcm/fwx/）
mapfile -t FILES < <(curl -fsSL "$API" | python3 -c "
import sys,json
for t in json.load(sys.stdin).get('tree',[]):
    p=t['path']
    if p.startswith('$SRC_PATH/') and t['type']=='blob':
        print(p)
")
echo "发现 ${#FILES[@]} 个 fwx 源文件"
[ "${#FILES[@]}" -gt 0 ] || { echo "ERR: 未拉取到 fwx 源文件，请检查分支 $BRANCH"; exit 1; }

# 3) 先下载到临时区，成功后再替换本地（避免网络失败破坏工作树）
TMPFX="$(mktemp -d)"
trap 'rm -rf "$TMPFX" "${TMP_THEME:-}" 2>/dev/null' EXIT
for f in "${FILES[@]}"; do
  rel="${f#$SRC_PATH/}"
  dst="$TMPFX/$rel"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$RAW/$f" -o "$dst"
done
rm -rf "$LOCAL_FWX"
mkdir -p "$LOCAL_FWX"
cp -a "$TMPFX/." "$LOCAL_FWX/"
echo "已刷新 feeds/fwx/fwx/ (${#FILES[@]} 文件)"

# 3b) 同步 fanchmwrt 系统主题（与 fwx 核心同源 package/fcm，仅路径不同：package/fcm/luci-theme-fanchmwrt）
THEME_SRC_PATH="${THEME_UPSTREAM_PATH:-package/fcm/luci-theme-fanchmwrt}"
LOCAL_THEME="$ROOT/feeds/fwx/luci-theme-fanchmwrt"
mapfile -t THEME_FILES < <(curl -fsSL "$API" | python3 -c "
import sys,json
for t in json.load(sys.stdin).get('tree',[]):
    p=t['path']
    if p.startswith('$THEME_SRC_PATH/') and t['type']=='blob':
        print(p)
")
echo "发现 ${#THEME_FILES[@]} 个主题源文件"
if [ "${#THEME_FILES[@]}" -gt 0 ]; then
  TMP_THEME="$(mktemp -d)"
  for f in "${THEME_FILES[@]}"; do
    rel="${f#$THEME_SRC_PATH/}"
    dst="$TMP_THEME/$rel"
    mkdir -p "$(dirname "$dst")"
    curl -fsSL "$RAW/$f" -o "$dst"
  done
  rm -rf "$LOCAL_THEME"
  mkdir -p "$LOCAL_THEME"
  cp -a "$TMP_THEME/." "$LOCAL_THEME/"
  echo "已刷新 feeds/fwx/luci-theme-fanchmwrt/ (${#THEME_FILES[@]} 文件)"
else
  echo "WARN: 未拉取到主题源文件，跳过主题同步"
fi

# 3c) 同步其余 fwx 核心组件（fwxd + libfwx_common）
_sync_component fwxd
_sync_component libfwx_common

# 4) 同步 950 内核补丁（hack-6.12 下含 fwx 的补丁）；钉死模式跳过，保留本地钉点补丁
if [ "$PINNED" != "1" ]; then
  mapfile -t KPATCHES < <(curl -fsSL "$API" | python3 -c "
import sys,json
for t in json.load(sys.stdin).get('tree',[]):
    p=t['path']
    if p.startswith('target/linux/generic/hack-6.12/') and 'fwx' in p and t['type']=='blob':
        print(p)
")
  for kp in "${KPATCHES[@]}"; do
    curl -fsSL "$RAW/$kp" -o "$FWX_PATCH_DIR/$(basename "$kp")"
    echo "  已更新补丁 $(basename "$kp")"
  done
fi

# 5) 刷新 README 版本锚点（钉死模式跳过，保留钉点注释）
if [ "$PINNED" != "1" ] && [ -f "$README" ]; then
  sed -i -E "s#^- 上游分支：.*#- 上游分支：$BRANCH#" "$README"
  sed -i -E "s#^- 锚点 commit：.*#- 锚点 commit：$SHA  ($DATE)#" "$README"
  echo "已刷新 README 版本锚点 -> $BRANCH @ $SHA ($DATE)"
fi

# 6) 刷新 cores/leenwrt.conf 的 FWX_COMMIT / THEME_COMMIT（钉死模式跳过，保持钉点单一来源）
CONF="$ROOT/cores/leenwrt.conf"
if [ "$PINNED" != "1" ] && [ -f "$CONF" ]; then
  sed -i -E "s#^FWX_COMMIT=.*#FWX_COMMIT=\"$SHA\"#" "$CONF"
  sed -i -E "s#^THEME_COMMIT=.*#THEME_COMMIT=\"$SHA\"#" "$CONF"
  echo "已刷新 cores/leenwrt.conf FWX_COMMIT / THEME_COMMIT -> $SHA"
fi

# 升级模式：校验 DPI bounds 补丁仍可干净应用到新源码，否则阻断（防静默产出 panic 固件）
if [ "$PINNED" != "1" ] && [ -f "$FWX_PATCH_DIR/fwx-match-feature-crash.patch" ]; then
  if ! patch -p1 --dry-run -d "$LOCAL_FWX" < "$FWX_PATCH_DIR/fwx-match-feature-crash.patch" >/dev/null 2>&1; then
    echo "ERR: fwx-match-feature-crash.patch 无法应用到升级后的 fwx 源码, 上游可能已改 fwx_main.c; 请同步更新该补丁后再升级, 或重新钉 FWX_COMMIT。" >&2
    exit 1
  fi
fi
echo "== sync-fwx 完成。请审阅 git diff，确认无误后: git add -A && git commit && git push =="
