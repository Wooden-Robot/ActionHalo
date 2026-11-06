# Android 0.8.4：按 PC 实现调整 GTA 外观

验证日期：2026-10-12。版本 `0.8.4` / `27`，最低 Android 8.0（API 26），目标 API 36，继续只提供通用 APK。

## PC 源码对照

对照 [RadialMenuView.swift](../../Sources/App/UI/RadialMenuView.swift) 的颜色、图标阴影、编号、中心文字、间隙与即时选中处理，以及 [RadialMenuWindow.swift](../../Sources/App/UI/RadialMenuWindow.swift) 的渐变背景、暗角和 `NSVisualEffectView`。本轮没有修改 PC 代码。

| 效果 | PC 实现 | Android 0.8.4 |
| --- | --- | --- |
| 分区 | 黑色 `0.05 / 0.74`，选中亮白 `0.88 / 0.96` | 对应灰度和透明度；禁用分区继续降低透明度 |
| 图标 | 白色，黑色阴影半径 5、透明度 0.9 | 缓存矢量图标的模糊透明度蒙版，按实际图标缩放绘制黑色柔影 |
| 选中 | 关闭隐式动画，图标立即放大到 1.22，白色柔光与亮边 | 保持即时高亮和 1.22 放大，用缓存路径的三层描边近似柔光 |
| 中心 HUD | 15 点重字标题、10 点等宽副标题、黑色文字阴影 | 15 sp 重字标题、10 sp 等宽副标题、8 dp 黑色阴影；显示当前动作及槽位 |
| 编号与间隙 | 10 点等宽粗体；6/8/12+ 项间隙为 0.04/0.025/0.015 弧度 | 编号改为 10 sp，对应数量采用相同间隙角度 |
| 背景 | 上下加深的纵向渐变、径向暗角、轮盘内的 macOS HUD 材质 | 在原有系统遮罩上叠加纵向渐变与径向暗角，继续响应用户保存的背景深度 |

手机仍保留较宽的环带，并分别为图标和编号分配径向位置；没有直接套用 PC 的内外径比例。这样可以在 6/8/12/16 项及较大字体下保留图标尺寸，避免图标和序号重叠。

Android 使用原生渐变和缓存阴影近似 macOS 的材质层次，未实现 `NSVisualEffectView` 的实时磨砂效果。没有截取其他应用的画面、逐帧模糊或增加依赖。阴影在图标尺寸变化时重建，窗口移除时释放；拖动期间复用已有蒙版和分区路径。

共用绘制入口继续覆盖手动选文、分享、原生无障碍选区、Telegram 和通用复制菜单。首次定位、直接点选、圆环外 32 dp 选择上限、中心关闭、分页及设置保存规则保持原有行为。

## 验证

JDK 17 / SDK 36 下，`assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest` 和 `lintDebug` 全部通过。**54 项 JVM 测试通过，无失败、错误或跳过**，包括各数量的 GTA 间隙和两种模式的触摸边界。

Android 15 / API 35 ARM64 模拟器：**38 项设备测试通过**，用时 117.885 秒。

- `GtaRadialMenuTest`：25 项，新增亮白分区上图标黑色柔影与重复绘制稳定性检查，回归 6/8/12/16 项编号间距、较大字体、点选、按住滑动、首次定位、距离上限、取消、分页及无障碍按钮。
- `HaloIntegrationTest`：7 项，覆盖手动选文、分享、复制、首页和动作管理。
- `SettingsPagesTest`：3 项，新增 0% 背景深度下所有背景层完全透明、默认深度下上下比中心更暗的实际像素检查。
- `FocusedClipboardOverlayTest`：3 项，以固定合成选文验证真实服务和窗口中的准确复制及外部首次定位。

Android 8.0 / API 26 ARM64 模拟器：**5 项针对性检查通过**，用时 11.445 秒，覆盖白色图标柔影、320 dp 和较大字体布局、两种模式下首次点选与长按、滑出选择范围后恢复、外观设置及渐变像素。

API 26 首次运行中，4 项通过，首个手势被输入法窗口拒绝注入。系统 `InputDispatcher` 日志明确指向 `InputMethod` 窗口。保留首轮失败日志，关闭模拟器键盘并确认 `mInputShown=false` 后，同一组 5 项全部通过；没有为此修改应用交互或输入注入权限。

日志与截图保存在 `android/build/diagnostics/`：

- `gta-pc-0.8.4-build.txt`、`gta-pc-0.8.4-api35-tests.txt`、`gta-pc-0.8.4-api26-tests.txt`。
- `gta-pc-0.8.4-api26-first-attempt.txt`、`gta-pc-0.8.4-api26-input-denial.txt`。
- [0.8.3 静止截图](../build/diagnostics/gta-pc-0.8.4-before-idle.png)、[0.8.3 选中截图](../build/diagnostics/gta-pc-0.8.4-before-selected.png)。
- [0.8.4 静止截图](../build/diagnostics/gta-pc-0.8.4-after-idle.png)、[0.8.4 选中截图](../build/diagnostics/gta-pc-0.8.4-after-selected.png)。

截图来自 API 35 中实际运行的窗口，选中截图通过真实触摸按下取得，已人工查看。背景是模拟器桌面和固定测试文字，不含用户消息。

## 安装包

文件 `ActionHalo-0.8.4-debug.apk`：**1,209,373 字节，约 1.21 MB**。仓库根目录和 `android/build/` 各保存一份及校验文件，均与构建产物相同。仅一个无 ABI 过滤的通用 APK，无原生架构库。

SHA-256：`db21ee87a51cd8f0cb39925ac4c1309e054d2d96f2321bc8fe3236a17e4ea8fa`。

签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.8.3 相同，可覆盖安装。元数据见 `android/build/diagnostics/gta-pc-0.8.4-artifact.json`。

## 验证边界

本轮未在 vivo 或其他品牌真机、真实 Telegram/X 或其他 CPU 架构运行；API 26 仅执行上述 5 项检查。PC 对照基于源码，未运行 PC 端截图对照。Android 背景和柔光是平台适配，不能视为像素级复刻。未提交、推送或发布 GitHub Release。
