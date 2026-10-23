# Android 0.7.6：仅网址可选择打开链接

2026-10-11；versionCode 16。

## 改动

- 在共用 `RadialMenuView` 中判断 `OPEN_URL` 资格，复用执行时的 `ActionUrls.normalizeOpenUrl`，避免圆环与实际执行使用不同规则。有效 HTTP(S) 网址及可补全的裸域名可用，普通文字、无效协议和未知选文不可用。
- 保留扇区位置和用户排序。不可用时按钮 alpha 为 0.25，同时关闭原生 enabled、clickable 和 focusable；拖动、悬停及执行回调也校验资格。与 PC 保留位置、灰显不可选的行为一致。
- 更新选文和翻页时重新判断；选文在拖动中失去网址资格，会清除高亮和放大状态，松手不执行。无效尝试不消耗本次圆环的执行机会，改成有效网址或选择其他操作仍可执行。
- 兼容翻页后、布局刷新前的旧几何命中索引，使用安全索引访问当前页按钮。`ActionExecutor` 的最终网址校验继续保留。
- 不改变 ActionStore 的启用设置、排序、分页数量、编辑字段、透明应用图标及长按排序。

## 入口及边界

首页体验、系统选文菜单、分享、普通无障碍选区和手动剪贴板入口都把实际选文交给同一圆环，因此共用资格判断。

Telegram/通用选文菜单兼容圆环显示时尚未取得实际选文，`selectedText` 为空；打开链接保持禁用。不会为了判断可用性提前复制或读取剪贴板。其他动作仍按用户选择后复制并执行；手动复制后打开剪贴板入口可获得已知文本并判断网址。

## 验证

- 最终离线 `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 成功；47 项 JVM 测试通过，包含 HTTP(S)/裸域名及非法协议、普通文字等网址边界；Lint 0 错误、5 条原有提示。
- Android 15 / API 35 ARM64 专用模拟器运行 `GtaRadialMenuTest` 14 项、`HaloIntegrationTest` 6 项，共 20 项全部通过。
- 新回归在普通/GTA 模式验证普通文字、空串、javascript/file/data 禁用，按钮变暗且不能聚焦，原生点击及拖动松手均不执行；HTTP、HTTPS、裸域名恢复可用，最终只执行一次。
- 验证网址高亮中切换为普通文字后清除预览、缩放和执行资格，松手不执行；随后恢复有效网址仍可拖动执行。
- 既有分页、6/8/12/16 项、矢量图形、大字号、鼠标悬停、手势取消、模式保存、系统选文/分享与复制回归通过。修改文件空白检查、版本和 APK 签名校验通过。

日志位于 `android/build/diagnostics/open-link-0.7.6/`（构建产物）。尚未在 vivo / Android 16 真机复测。

## 安装包

- `android/build/ActionHalo-0.7.6-debug.apk`，versionCode 16，1,169,339 字节。
- SHA-256：`fafcaa6283b788e4c3028f4b8f45f29ca2950dc28611c1912a16141124a72d1e`。
- `apksigner verify --print-certs` 通过；证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.7.5 一致，可覆盖安装保留设置。
