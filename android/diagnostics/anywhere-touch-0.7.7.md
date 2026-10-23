# Android 0.7.7：屏幕任意位置方向选择

2026-10-11；versionCode 17。

## 改动

- 共用 `RadialGeometry.hitTest` 去掉外圈距离限制，按实际圆环中心与触点的夹角选择操作。保留 16 dp 中心死区、GTA 扇区间隙及非有限坐标校验。
- `RadialMenuView.bindTouchSurface` 将宿主触摸事件换算为圆环本地坐标，保留完整指针、取消事件和既有的松手执行逻辑。圆环外按下、移动、松手也可选择；不再点击外部关闭。
- 首页体验、系统选文菜单、分享、手动剪贴板、普通选区无障碍浮层及 Telegram/通用选文菜单圆环共用这条路径。普通选区浮层扩大到可用屏幕，圆环仍在原选区附近；GTA 背景、圆环大小、分页和动作配置不变。
- 普通/GTA 模式均支持点中心或移回中心松手取消。禁用的打开链接、多指中断、系统取消及 GTA 间隙仍不执行；执行一次后仍拦截重复事件。关闭浮层时清除触摸监听。

## 验证

- 离线 `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 成功；52 项 JVM 测试通过。新增远距离方向、1–16 个操作、密度/死区、空动作、非有限坐标及 GTA 间隙验证。Lint 0 错误、5 条原有提示。
- Android 15 / API 35 ARM64 专用模拟器：`GtaRadialMenuTest` 16 项及 `HaloIntegrationTest` 6 项全部通过。新增普通/GTA 圆环矩形之外的真实触摸注入，验证预览、换项、松手单次执行、禁用链接、系统取消、多指中断、移回中心取消和随后重新操作。
- 首轮新增测试的注入点落入系统栏；测试现按可见窗口与系统栏/刘海 Insets 裁切可用范围，并断言触点在应用内、圆环矩形外。最终 22 项运行全部通过，未绕过系统输入路由。
- 另外 4 项 `FocusedClipboardOverlayTest` 通过真实无障碍服务验证：标准选文菜单复制精确片段、原生菜单选区归属、来源弹窗暂时遮挡后恢复、普通模式延迟复制直到弹窗关闭。两个普通选区测试显式关闭 GTA，覆盖本次扩大的普通浮层。
- APK 版本与签名验证通过，改动文件空白检查通过。

日志位于 `android/build/diagnostics/anywhere-touch-0.7.7/`（构建产物）：`build.txt`、`final-test-build.txt`、`final-instrumentation.txt`、`service-instrumentation.txt`。

## 使用边界

“任意位置”指应用可用屏幕，系统状态栏、导航栏和系统手势仍由 Android 处理。圆环显示期间，原先可穿透的普通模式外部区域用于方向选择；点中心关闭后恢复来源应用操作。分页按钮仍保留原生点击行为。

无障碍浮层仍为非焦点窗口，以保留来源选区；系统返回键可能交给来源应用，取消圆环请用中心。设备验证使用模拟器及测试宿主，尚未在 vivo / Android 16 / 真实 Telegram、X 上复测。

## 安装包

- `android/build/ActionHalo-0.7.7-debug.apk`，versionCode 17，1,030,698 字节。
- SHA-256：`0bebe2124c6a2a408f55d69f34aebb675cd2f7eec6d268a8fccc1c362e050285`。
- 证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.7.6 一致，可覆盖安装保留设置。
