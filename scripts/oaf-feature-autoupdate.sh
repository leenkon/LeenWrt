#!/bin/sh
# LeenWrt OAF 首启特征库更新：成功后自清 rc.local（仅跑一次、不留痕）。
# 由 /etc/rc.local 后台调用；下载在 oafd 内异步完成，本脚本轮询状态直到成功/失败。
DONE_FLAG=/etc/oaf-feature-autoupdate.done
RC_LOCAL=/etc/rc.local
[ -f "$DONE_FLAG" ] && exit 0

# 等网络就绪（最多 ~60s）
for i in $(seq 1 30); do
    ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && break
    sleep 2
done
ubus list fwx >/dev/null 2>&1 || exit 0

# 取列表：仅服务器返回 code=2000 才继续；free=1 取 count 最大的包
list=$(ubus call fwx common '{"api":"get_feature_online_list","data":{"refresh":1,"lang":"cn"}}' 2>/dev/null)
[ "$(echo "$list" | jsonfilter -e '@.code' 2>/dev/null)" = "2000" ] || exit 0
ids=$(echo "$list" | jsonfilter -e '@.data.files[@.free=1].id' 2>/dev/null)
cnts=$(echo "$list" | jsonfilter -e '@.data.files[@.free=1].count' 2>/dev/null)
[ -n "$ids" ] || exit 0
tmp=$(mktemp -d)
printf '%s\n' "$ids" > "$tmp/ids"
printf '%s\n' "$cnts" > "$tmp/cnts"
best=$(paste -d' ' "$tmp/ids" "$tmp/cnts" 2>/dev/null | sort -k2 -n | tail -1 | awk '{print $1}')
rm -rf "$tmp"
[ -n "$best" ] || exit 0

# 触发更新（oafd 异步下载，立即返回 code=2000=已接受）
resp=$(ubus call fwx common "{\"api\":\"start_feature_online_update\",\"data\":{\"id\":\"$best\",\"lang\":\"cn\"}}" 2>/dev/null)
[ "$(echo "$resp" | jsonfilter -e '@.code' 2>/dev/null)" = "2000" ] || exit 0

# 轮询直到成功/失败（最多 ~5min）；成功才自清，失败保留 rc.local 下次重试
ok=0
for i in $(seq 1 30); do
    st=$(ubus call fwx common '{"api":"get_feature_online_update_status"}' 2>/dev/null)
    case "$(echo "$st" | jsonfilter -e '@.data.state' 2>/dev/null)" in
        success) ok=1; break ;;
        failed)  break ;;
    esac
    sleep 10
done
[ "$ok" = "1" ] || exit 0

# 成功：写 flag + 自清 rc.local 的 OAF 段（含本脚本调用），仅跑一次且不留痕
touch "$DONE_FLAG"
sed -i '/# >>> LeenWrt OAF START/,/# <<< LeenWrt OAF END/d' "$RC_LOCAL" 2>/dev/null
exit 0
