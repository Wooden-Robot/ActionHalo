# Android 0.11.16 聊天菜单触摸冲突

用户反馈微信长按消息后，圆环不显示，微信操作菜单也无法点击。随后提供的 vivo / SDK 36 / 0.11.15 报告显示：圆环创建约 79 ms 后出现 `MENU_NO_COPY → MENU_MISSING → HALO_WAITING_MENU`，隐藏后仍多次出现 `HALO_OUTSIDE_TOUCH` 与 `MENU_HOST_REPLACED`，最后才移除。服务一直连接，报告不能解释为什么微信暂时不再公开复制控件，也不能证明每次失去响应都由同一个原因造成。

## 可复现的问题

原有聊天菜单测试通过无障碍 `ACTION_CLICK` 执行动作，没有覆盖真实触摸。新增测试使用不同 UID 的现有合成聊天菜单，按钮坐标来自控件实际绘制位置，通过无障碍 extras 传给测试；不改变菜单标签，不使用无障碍点击代替手指。

- 较矮菜单的复制和第二排操作在旧实现均通过。较高菜单中，真实点击第二排「翻译」进入圆环。初次失败记录：`/private/tmp/actionhalo-wechat-touch-tall.log`；再次失败与临时探针：`/private/tmp/actionhalo-wechat-touch-probe.log`。原按钮触点 `(540, 1324)` 落在圆环窗口 `Rect(22, 1150 - 1058, 2186)` 内，圆环当时可见。保护区仅包含选文和手柄，明确排除了原菜单窗口。
- 仅加入菜单触摸保护后，原菜单可点击，但新补的圆环真实复制测试失败：圆环复制按钮仍落在原菜单上，点击交给了原菜单。记录：`/private/tmp/actionhalo-wechat-touch-both.log`。较高菜单原先只按其复制按钮位置布局；改为完整菜单位置后，两边真实点击均通过，7 项定向测试耗时 27.305 秒：`/private/tmp/actionhalo-wechat-touch-placement.log`。
- 按真机报告的顺序回放「隐藏 → 外部触摸 → 外部触摸」，隐藏状态仍调用两次菜单检查回调。旧代码在隐藏状态检查之前处理了外部触摸，记录：`/private/tmp/actionhalo-wechat-hidden-queue-red.log`，断言为期望 0 次、实际 2 次。

最小触摸复现命令：

```sh
adb -s emulator-5580 shell am instrument -w -r \
  -e focused_clipboard_overlay true \
  -e class 'com.actionhalo.android.FocusedClipboardOverlayTest#tallChatMenuSecondRowRemainsPhysicallyClickableBesideTheHalo' \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

## 修改范围

`HaloSafeArea.selectionControlBounds` 将经过核对、属于当前来源窗口的菜单矩形纳入保护，与手柄之间的选文区域分开保存，避免把两者之间的空白也一并保护。原生与菜单兼容入口共用这项修改。继续使用既有的整体避让和 API 33 以上局部触摸穿透；未改变授权、来源归属和菜单识别要求。

`TelegramCopyAssistant` 使用完整菜单位置初始化圆环。`SelectionHaloWindow` 在处理外部触摸之前检查隐藏状态，忽略隐藏后排队到达的事件；首次有效外部触摸、正常重新定位和松手恢复规则保留。没有新增配置、权限、依赖或消息正文读取。

## 隐藏状态与验证边界

另有真实窗口测试让菜单继续显示、但停止公开动作标签，触发 `MENU_NO_COPY` 和圆环隐藏，再直接点击原菜单复制；同时启用测试按钮的遮挡触摸过滤。该用例通过，实际 `MotionEvent` 遮挡标记为 0。记录：`/private/tmp/actionhalo-wechat-hidden-metadata.log`。因此模拟器没有复现圆环隐藏后微信菜单仍完全无法点击，不能把真机问题直接归因为 Android 的遮挡过滤。

Android 文档将无障碍浮窗列为允许穿透的可信窗口，这与上述模拟器结果一致；它不保证 vivo 或微信的每项行为：[WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE](https://developer.android.com/reference/android/view/WindowManager.LayoutParams#FLAG_NOT_TOUCHABLE)。没有为未复现的原因修改窗口权限或绕过应用校验。

最终 39 项相关模拟器回归全部通过，无跳过，211.28 秒：`/private/tmp/actionhalo-wechat-regression.log`。包含高低聊天菜单与圆环两侧真实点击、菜单标签暂时不可读、隐藏后排队触摸、原生及兼容入口手柄防误触、整段选文保护、重新定位、快速复制的背景和位置、首次及重选、WebView 等。上述隐藏事件回放的失败用例在最终版本通过。

构建及 61 项 JVM 测试通过；Lint 0 错误、6 项警告：`/private/tmp/actionhalo-wechat-final-build.log`。临时探针已删除，`git diff --check` 通过。没有重跑全部应用套件或其他 Android 版本；API 26–32 继续沿用空间不足时隐藏圆环的既有回退。菜单占用的区域优先交给原应用处理。

## 安装包

`ActionHalo-0.11.16-debug.apk`：versionCode 52，minSdk 26，targetSdk 36，1,268,871 字节。SHA-256：`15ac770eeea348173064fbb4e8e7a0e3b8a7c6114095092953da8de2360d5568`。

ZIP 完整性和签名校验通过，证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与先前安装包一致。导出包与最终模拟器回归的生产 APK 字节一致，另存 `ActionHalo-0.11.16-SHA256SUMS.txt`。

尚未连接用户 vivo 手机，也未在真实微信、原子笔记或 Codex App 中验证。此版本修复了已复现的菜单触摸冲突与隐藏状态事件处理问题，微信菜单完全无响应是否消失仍需真机确认。未提交、推送或发布远程版本。
