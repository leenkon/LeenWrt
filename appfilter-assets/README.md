# appfilter-assets

应用过滤（OAF / fwx）构建期注入的图标资源目录。

## oaf-icons（应用图标）

图标文件名即应用 ID（LuCI 按 `<appId>.png` 拼路径，缺失时退化为首字母色块）。

本目录是**已提交的静态图标缓存**，由 `LeenWrtBuilder.yml` 在构建期复制到两处 LuCI：
- OAF 模式 → `luci-app-oaf` 的 `resources/oaf/app_icons/`
- fwx 模式 → `luci-app-fwx-appfilter` 的 `resources/app_icons/`

特征库（`feature.bin`）由 `scripts/update-feature.sh` 单独在构建期从官方免费 API 刷新，
**不**经本目录中转——故图标与特征库版本可能不同步。缺失图标时 LuCI 退化为首字母色块，
不影响过滤功能。如需更新图标，手动替换本目录内容并重新提交即可。
