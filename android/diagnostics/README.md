# 自动选文诊断（仅限模拟器）

`SelectionTriggerDiagnosticTest` 共 11 项，覆盖真实长按、选区事件竞态、通用菜单、键盘、锁屏恢复和服务重连。默认设备测试跳过这些项目；必须显式传入 `selection_diagnostics=true`，并通过模拟器硬件与型号检查。兼容较旧镜像的 `Android SDK built for…` 和新镜像的 `sdk_gphone…` 型号。测试暂时开启自动模式及无障碍服务，结束后恢复原设置。不要在个人手机运行这些诊断。跨版本结果与 CI 命令见[兼容回归记录](compatibility-regression.md)。

先构建并安装 debug 应用和测试 APK（命令在 `android` 目录执行）：

```bash
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
adb -s emulator-5580 install -r app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5580 install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
```

原生输入框、只读 TextView、WebView 使用测试 APK 内的独立宿主 Activity。例如检查 WebView：

```bash
adb -s emulator-5580 shell am instrument -w \
  -e selection_diagnostics true \
  -e class com.actionhalo.android.SelectionTriggerDiagnosticTest#webLongPressAutomaticallyOpensHalo \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

其他方法名为 `editableLongPressAutomaticallyOpensHalo` 和 `readOnlyLongPressAutomaticallyOpensHalo`。

检查真实 Via 时，在模拟器中安装[官方 APK](https://github.com/tuyafeng/Via)，手动完成浏览器首次启动。启动固定测试网页服务器（仅监听本机）：

```bash
python3 -m http.server 8800 --bind 127.0.0.1 --directory diagnostics
```

在另一个终端执行：

```bash
adb -s emulator-5580 reverse tcp:8800 tcp:8800
adb -s emulator-5580 shell am instrument -w \
  -e selection_diagnostics true \
  -e diagnostic_browser_url http://127.0.0.1:8800/fixture.html \
  -e class com.actionhalo.android.SelectionTriggerDiagnosticTest#viaLongPressAutomaticallyOpensHalo \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

预期结果为 `OK (1 test)`，截图保存到应用缓存 `trigger-via.png`。测试使用 `FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`，否则 UI 自动化本身会停用待测服务。仅测试包会记录事件类型、控件类型、范围、文字长度、测试宿主包名及窗口活动状态；不记录文字正文：

```bash
adb -s emulator-5580 logcat -d -s ActionHaloTriggerProbe:I '*:S'
adb -s emulator-5580 reverse --remove tcp:8800
```

停止服务器以完成清理。生产 APK 不包含测试 Activity 或这些日志。「故障诊断」页面的诊断仅保留当前进程内的事件计数、最近非空范围数字及结果类别。

2026-10-10 对照结果：Android 15 / API 35 上四个场景均通过。Via 7.3.3 与 WebView 提供事件选区 `0:9`，节点选区为 `-1:-1`；现有代码使用事件选区成功显示圆环。系统选文菜单同时存在，未夺走网页活动窗口。这次测试未复现用户报告的 vivo X200s 故障，不能据此认定原因或宣称修复。

## 迟到事件对照

外部测试宿主通过真实无障碍框架发送迟到事件，测试先独立确认事件范围与刷新后的节点范围不同，再断言圆环状态。它模拟可验证的竞态，不冒充 vivo 的实际事件记录。

```bash
adb -s emulator-5580 shell am instrument -w \
  -e selection_diagnostics true \
  -e class com.actionhalo.android.SelectionTriggerDiagnosticTest#freshNonemptySourceSurvivesDelayedCollapsedEvent,com.actionhalo.android.SelectionTriggerDiagnosticTest#freshCollapsedSourceRejectsDelayedNonemptyEvent \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

- A：节点实际保持 `0:9`，约 80 ms 后收到 `1:1` 的旧事件，圆环应显示。0.3.0 会错误取消，修复前已观察到此断言失败。
- B：节点实际变为 `1:1`，随后收到 `0:9` 的旧事件，圆环不得显示。修复前已通过，用于防止恢复已取消的旧选择。

0.4.0 修复后，同一组 A/B 测试均通过，WebView 和官方 Via 的真实长按对照也继续通过。仍需用户的 vivo X200s 验证是否覆盖其实际故障。

## 无障碍设置导航回归

`AccessibilitySettingsNavigationTest` 同样仅限 `sdk_gphone` 模拟器，默认跳过，需要单独开启参数。六项检查覆盖已授权的两种同意流程、未授权的两种公开设置请求，以及已授权时点击权限管理需要再次点击才能进入总列表、取消后留在首页。使用真实服务绑定和同意对话框，导航决策由 ActivityMonitor 捕获；测试结束恢复系统设置与应用偏好。它不模拟 vivo 进入总列表后撤销授权的原因。

```bash
adb -s emulator-5580 shell am instrument -w \
  -e accessibility_settings_diagnostics true \
  -e class com.actionhalo.android.AccessibilitySettingsNavigationTest \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

UiAutomation 的命令直接执行，不进行 shell 引号解析；恢复 secure 设置时只允许组件/数值字符并直接传入，避免把字面引号写进服务名单。

## 网页翻译、升级清理与更新验证

0.8.1 移除浮窗翻译和真实模型下载诊断，翻译恢复为网址动作。`HaloIntegrationTest#processTextAndShareOpenWebTranslationWithTheExactSelection` 验证手动选文与分享；以下两个可选诊断验证真实无障碍和复制菜单生产链路：

```bash
adb -s emulator-5580 shell am instrument -w \
  -e selection_diagnostics true \
  -e focused_clipboard_overlay true \
  -e class com.actionhalo.android.SelectionTriggerDiagnosticTest#nativeSelectionOpensWebTranslationAndClosesTheHalo,com.actionhalo.android.FocusedClipboardOverlayTest#standardToolbarOpensWebTranslationWithOnlyTheCopiedFragment \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

浏览器启动由 ActivityMonitor 捕获，断言网址、编码后还原的选文和圆环关闭，不把测试文字发往网站。`SettingsPagesTest#openingTheAppRemovesOnlyObsoleteModelsAndPreservesSettings` 验证只清理废弃模型目录，并保留其他文件和设置。旧版实际下载模型后覆盖升级的结果见 [0.8.1 记录](remove-floating-translation-0.8.1.md)。

更新的真实 HTTPS 检查使用 `android_updates_network=true` 和 `AndroidReleaseCatalogTest#liveUpdateCheckCompletesUsingThePublicRepository`，同样仅限一次性模拟器。0.8.0 的历史模型诊断见[原验证记录](settings-translation-updates-0.8.0.md)。
