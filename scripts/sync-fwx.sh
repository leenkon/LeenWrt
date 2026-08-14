#!/usr/bin/env bash
# sync-fwx.sh — 从 fanchmwrt 同步 fwx 组件到 LeenWrt（升级 fork 的 fwx）
# 用法: scripts/sync-fwx.sh [branch]   默认 fanchmwrt-25.12.4
# 升级后请审阅 git diff，确认无误再提交推送。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${1:-fanchmwrt-25.12.4}"
SRC_PATH="package/fcm/fwx"
RAW="https://raw.githubusercontent.com/fanchmwrt/fanchmwrt/$BRANCH"
API="https://api.github.com/repos/fanchmwrt/fanchmwrt/git/trees/$BRANCH?recursive=1"
LOCAL_FWX="$ROOT/feeds/fwx/fwx"
FWX_PATCH_DIR="$ROOT/patches/fwx"
KMOD_PATCH="$FWX_PATCH_DIR/kmod-nf_send_reset-6.12.patch"
README="$ROOT/feeds/fwx/README.md"

echo "== sync-fwx: 从 fanchmwrt@$BRANCH 同步 fwx 组件 =="

# 1) 取版本锚点（commit + date）
read -r SHA DATE < <(curl -fsSL "https://api.github.com/repos/fanchmwrt/fanchmwrt/commits?sha=$BRANCH&per_page=1" \
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
trap 'rm -rf "$TMPFX"' EXIT
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

# 4) 同步 950 内核补丁（hack-6.12 下含 fwx 的补丁）
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

# 5) 重放 kmod 6.12 补丁
if [ -f "$KMOD_PATCH" ]; then
  if patch -p1 --dry-run -d "$LOCAL_FWX" < "$KMOD_PATCH" >/dev/null 2>&1; then
    patch -p1 --forward -d "$LOCAL_FWX" < "$KMOD_PATCH"
    echo "kmod 6.12 补丁已重放到新源码"
  else
    echo "WARN: kmod 6.12 补丁无法应用到新源码（上游可能已修 6.12，或代码变动）。"
    echo "      请手工核查 $KMOD_PATCH 是否仍需要，必要时删除或更新该补丁。"
  fi
else
  echo "(无 kmod 补丁，跳过)"
fi

# 6) 刷新 README 版本锚点
if [ -f "$README" ]; then
  sed -i -E "s#^- 上游分支：.*#- 上游分支：$BRANCH#" "$README"
  sed -i -E "s#^- 锚点 commit：.*#- 锚点 commit：$SHA  ($DATE)#" "$README"
  echo "已刷新 README 版本锚点 -> $BRANCH @ $SHA ($DATE)"
fi

echo "== sync-fwx 完成。请审阅 git diff，确认无误后: git add -A && git commit && git push =="
