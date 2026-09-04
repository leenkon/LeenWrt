# appfilter-assets

应用过滤（OAF / fwx）构建期注入的图标资源目录。

## oaf-icons（应用图标）

图标文件名即应用 ID（LuCI 按 `<appId>.png` 拼路径，缺失时退化为首字母色块）。

本目录是**已提交的静态图标缓存**，由 `LeenWrtBuilder.yml` 在构建期复制到两处 LuCI：
- OAF 模式 → `luci-app-oaf` 的 `resources/oaf/app_icons/`
- fwx 模式 → `luci-app-fwx-appfilter` 的 `resources/app_icons/`

## 特征库（`feature.bin`）更新策略

特征库**不在构建期从官方 API 拉取**（CI 访问 api.openappfilter.com 不稳且易 403）。
改为设备**首启自动更新**：`diy.sh` 在 `rc.local` 注入一段一次性脚本，启动末步经 OAF 自带
在线更新客户端（`ubus call fwx common`，UA 正确）拉取官方最新**免费版**（free=1）覆盖
`/etc/fwxd/feature.bin`，成功后写 `/etc/oaf-feature-autoupdate.done` 守护（失败则下次启动重试）。

> 构建期不再手动拉取/固化特征库（相关脚本已移除）；最新免费库由设备首启自动获取。

图标与特征库版本可能不同步属正常；缺失图标时 LuCI 退化为首字母色块，不影响过滤功能。
如需更新图标，手动替换本目录内容并重新提交即可。
