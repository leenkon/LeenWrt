#!/bin/sh
# 下载并注入官方预编译 AdGuardHome 静态二进制（linux/amd64）
#
# 取代 feeds 编译方案：免 Go 工具链、免 Makefile hash 打补丁、保证最新版、
# 25.12 完全通用。二进制经 files/<core>/ 注入固件（如 files/leenwrt/usr/bin/AdGuardHome），
# 由 files/leenwrt/etc/init.d/adguardhome 启动，配置复用 files/leenwrt/etc/adguardhome/adguardhome.yaml。
#
set -e

# 用法: upgrade-adgh-binary.sh [项目根目录] [--files-dir <核专属files目录>] [--version latest|<版本号>]
#   --files-dir: 注入目标目录（如 files/leenwrt）；缺省回退到 <root>/files/leenwrt
#   ADGH 仅 leenwrt 使用，其 FILES_DIR 即 files/leenwrt，须把二进制注入该目录才能进固件
PROJECT_ROOT="$(pwd -P)"
FILES_DEST=""
VERSION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --files-dir) FILES_DEST="$2"; shift 2 ;;
    --version)   VERSION_ARG="$2"; shift 2 ;;
    -*) shift ;;
    *) PROJECT_ROOT="$(cd "$1" && pwd -P)"; shift ;;
  esac
done
FILES_DEST="${FILES_DEST:-$PROJECT_ROOT/files/leenwrt}"
ADGH_VER="${VERSION_ARG:-${ADGH_VER:-latest}}"

BIN_DIR="$FILES_DEST/usr/bin"
BIN="$BIN_DIR/AdGuardHome"
if [ "$ADGH_VER" = "latest" ]; then
  ADGH_VER=$(curl -s --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  [ -z "$ADGH_VER" ] && { echo "[ADGH-BIN][ERROR] 获取最新版本失败（GitHub API 受限？）"; exit 1; }
fi

# 已存在且版本匹配则跳过（幂等，便于本地重复构建）
if [ -x "$BIN" ]; then
  cur=$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ "$cur" = "$ADGH_VER" ] && { echo "[ADGH-BIN][SKIP] 已是最新: v$cur"; exit 0; }
fi

ASSET="AdGuardHome_linux_amd64.tar.gz"
BASE="https://github.com/AdguardTeam/AdGuardHome/releases/download/v${ADGH_VER}"
SHA_URL="$BASE/checksums.txt"
# 主源 + ghproxy 回退
URLS="
$BASE/$ASSET
https://ghproxy.net/https://github.com/AdguardTeam/AdGuardHome/releases/download/v${ADGH_VER}/$ASSET
"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 下载官方 checksums.txt 并提取本架构的 sha256（内容形如 "<hash>  ./AdGuardHome_linux_amd64.tar.gz"）
SHA=""
for u in "$SHA_URL" "https://ghproxy.net/$SHA_URL"; do
  SHA=$(curl -sL --connect-timeout 20 "$u" 2>/dev/null | grep "AdGuardHome_linux_amd64.tar.gz" | grep -oE '^[0-9a-f]{64}' | head -1)
  [ -n "$SHA" ] && break
done

ARCHIVE="$TMP/$ASSET"
GOT=""
for u in $URLS; do
  if curl -sL --connect-timeout 60 -o "$ARCHIVE" "$u" 2>/dev/null && [ -s "$ARCHIVE" ]; then
    magic=$(head -c2 "$ARCHIVE" | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "1f8b" ] && { GOT="$u"; break; }
  fi
done
[ -z "$GOT" ] && { echo "[ADGH-BIN][ERROR] 下载 AdGuardHome 二进制失败"; exit 1; }
echo "[ADGH-BIN] 下载成功: $GOT"

if [ -n "$SHA" ]; then
  got_sha=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
  if [ "$got_sha" != "$SHA" ]; then
    echo "[ADGH-BIN][ERROR] checksum 不匹配: $got_sha != $SHA"; exit 1
  fi
  echo "[ADGH-BIN] checksum 校验通过"
else
  echo "[ADGH-BIN][WARN] 未取得官方 checksum，跳过校验（仅校验 gzip 魔数）"
fi

tar -xzf "$ARCHIVE" -C "$TMP"
SRC="$TMP/AdGuardHome/AdGuardHome"
[ -x "$SRC" ] || { echo "[ADGH-BIN][ERROR] 归档内未找到 AdGuardHome 二进制"; exit 1; }
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC" "$BIN"
echo "[ADGH-BIN][DONE] 已安装 AdGuardHome v$ADGH_VER -> $BIN"
