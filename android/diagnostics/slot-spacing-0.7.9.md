# Android 0.7.9：分开 GTA 序号和图标

2026-10-11；versionCode 19。

## 改动

- GTA 序号靠内、图标靠外，按实际字体高度和图标选中后 1.22 倍的最大投影范围预留间距。空间不足时缩小图标，编号与图标使用独立画笔。
- GTA 内半径调整为外半径的一半，扩大分区内部的可用空间；圆环外径不变。普通模式的几何布局保持原样。
- 分页、图标点击、屏幕任意位置按下同步圆环中心及既有取消交互继续使用共用路径，没有新增设置或存储变更。

## 验证

- 离线 `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 成功。52 项 JVM 测试通过；Lint 0 错误、5 条原有提示。
- Android 15 / API 35 ARM64，1080×2400 / 420 dpi 专用模拟器：`GtaRadialMenuTest` 18 项、`HaloIntegrationTest` 6 项，共 24 项全部通过。
- 像素检查覆盖每页 6、8、12、16 项、320 dp 菜单、1.3 倍系统字号、第一页与最后一页。测量实际绘制的旋转编号与矢量图标，包含选中后 1.22 倍缩放，确认二者可视像素分离至少 2 dp 且位于圆环分区内。
- 既有普通/GTA、分页、链接禁用、按下点同步中心、滑动松手执行与取消测试通过。另查看完整 GTA 界面截图，默认字号下中心文字与分区显示正常。
- APK 版本、签名与修改文件空白检查通过。

构建和设备日志位于 `android/build/diagnostics/slot-spacing-0.7.9/`，包含 `build.txt`、`instrumentation.txt` 和 `halo.png`。

## 验证边界

尚未在 vivo / Android 16 真机复测。极小分屏及超大字号下中心长标题的完整可读性未纳入此次验证。

## 安装包

- `android/build/ActionHalo-0.7.9-debug.apk`，versionCode 19，1,031,918 字节。
- SHA-256：`708aaf34de5580ce1a23158d034ce3d2995db6292e7c714ff301caca814b33c4`。
- 证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.7.8 一致，可覆盖安装保留设置。
