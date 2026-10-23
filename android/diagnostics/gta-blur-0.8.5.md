# Android 0.8.5：GTA 背景虚化与执行过渡

验证日期：2026-10-12。版本 `0.8.5` / `28`，最低 Android 8.0（API 26），目标 API 36，继续提供单一通用 APK。

## 实现

GTA 背景由较重的调暗改为原生实时模糊、灰绿薄雾和渐变暗角。原应用画面柔化，圆环、图标和中心文字保持清晰。Android 12+ 使用 `FLAG_BLUR_BEHIND` 和按密度换算的 28 dp 模糊半径；启用时将用户保存的调暗量乘以 0.55，不改写偏好。0% 遮罩取消调暗与雾层，保留原生模糊。

`HaloAppearance.bindBackdrop` 统一处理选文/分享 Activity、原生选区浮层、Telegram/通用复制菜单浮层及执行过渡窗口。模糊监听器随窗口挂载注册，移除时注销；系统运行中关闭模糊则恢复原调暗强度，重新启用时自动恢复虚化。关闭 GTA 不申请模糊。Android 8–11 或系统不支持/禁用模糊时保留薄雾和暗角。

正常选择功能后，带「继续／取消」的执行过渡卡片保持隐藏，不再短暂闪现。只有等待超过 1.5 秒、动作尚未完成时才显示现有处理控件。获得有效文字后取消待显示提示；临时失去焦点仍等待原窗口恢复，保留第一次有效快照，恢复后只执行一次。超时、手动取消、原应用关闭和权限撤回仍取消请求。无障碍读屏可获得等待动作的描述。

没有增加依赖、原生库、截图权限或设置选项，也没有修改圆环定位、选择距离、动作内容或排序。背景模糊由系统合成器处理，应用不截取、读取或保存其他应用画面；测试截图仅由模拟器调试工具生成。

官方 API 与限制：[Window blurs](https://source.android.com/docs/core/display/window-blurs)、[setBlurBehindRadius](https://developer.android.com/reference/android/view/WindowManager.LayoutParams#setBlurBehindRadius(int))、[运行中模糊状态监听](https://developer.android.com/reference/android/view/WindowManager#addCrossWindowBlurEnabledListener(java.util.function.Consumer%3Cjava.lang.Boolean%3E))。Android 12+ 的版本号本身不能保证厂商启用此能力；省电模式等状态也可关闭它。

## 验证

JDK 17 / SDK 36 下，`assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest` 和 `lintDebug` 全部通过。**54 项 JVM 测试通过，无失败、错误或跳过**。

Android 15 / API 35 ARM64：**48 项设备测试全部通过**，用时 140.723 秒。包括 `GtaRadialMenuTest` 25 项、`HaloIntegrationTest` 7 项、`SettingsPagesTest` 4 项，以及 `FocusedClipboardOverlayTest` 的 12 项真实窗口检查。新增检查验证 GTA 与普通模式、系统模糊能力和 0% 遮罩；执行过渡检查确认有效快照已读取时卡片仍隐藏、持续失去焦点后卡片可见，以及恢复焦点后准确执行一次。真实复制、网页翻译、陈旧剪贴板拒绝、权限复核、连续请求和手动取消继续通过。

Android 8.0 / API 26 ARM64：**6 项针对性检查全部通过**，用时 12.315 秒。验证旧系统不启用新模糊接口、两种模式和 0% 遮罩、外观设置保留、图标柔影、较大字体、首次图标点选/长按，以及滑出选择范围后恢复。

API 35 ARM64 模拟器确认系统支持模糊。在同一个实际圆环窗口中，切换系统模糊开关，窗口半径依次为 **73 px → 0 → 73 px**，背景从实时虚化变为较深遮罩，再恢复虚化。已人工查看[模糊开启截图](../build/diagnostics/gta-blur-0.8.5-blur-enabled.png)与[系统禁用后的回退截图](../build/diagnostics/gta-blur-0.8.5-blur-disabled.png)，圆环本身保持清晰。测试后恢复模拟器原系统设置。

首轮设备回归发现延迟提示误用了尚未挂载 View 的 `handler`，在创建过渡窗口时崩溃。修复为明确使用 `ClipboardHaloOverlay` 的主线程队列；首轮日志保留在 `gta-blur-0.8.5-api35-first-attempt.txt`。

构建、设备日志、窗口参数及元数据位于 `android/build/diagnostics/`，文件前缀均为 `gta-blur-0.8.5-`。

## 安装包

`ActionHalo-0.8.5-debug.apk`：**1,214,822 字节，约 1.21 MB**。只有一个无 ABI 过滤的产物，无原生架构库，较 0.8.4 增加 5,449 字节。

SHA-256：`3a74f029fdcf58d6e7518e43d1404f3fdde7d0b1748d75e2d021560132c90d01`。

签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.8.4 相同，可覆盖升级。

## 验证边界

未在 vivo 或其他品牌真机、真实 Telegram/X 或其他 CPU 架构运行；API 26 仅执行上述 6 项检查。系统不提供跨窗口模糊时只能使用回退遮罩，不能据此宣称所有 Android 8+ 设备都有真实虚化。PC 源码未修改，未提交、推送或发布 GitHub Release。
