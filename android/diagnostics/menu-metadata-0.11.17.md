# Android 0.11.17 菜单标签暂缺导致圆环闪现

用户提供 vivo / SDK 36 / 0.11.16 新报告：两次 `MENU_MATCHED → HALO_ATTACHED` 后分别约 71 ms、83 ms 出现 `MENU_NO_COPY → MENU_MISSING → HALO_WAITING_MENU`。没有选区范围，也没有上一版隐藏后连续外部触摸的记录。用户确认微信聊天首次选字的圆环仍一闪而过。

## 复现

复用不同 UID 的真实聊天菜单夹具。先识别菜单并显示圆环，再让同一菜单窗口停止公开按钮标签，实际控件、窗口标识和菜单触摸保持不变。两条用例在修改生产代码前均因圆环消失失败，7.305 秒：`/private/tmp/actionhalo-menu-flash-red.log`。补充同一菜单窗口仍存在的断言后，再次在同一可见性断言处失败，3.426 秒：`/private/tmp/actionhalo-menu-flash-confirm-red.log`。

```sh
adb -s emulator-5580 shell am instrument -w -r \
  -e focused_clipboard_overlay true \
  -e class 'com.actionhalo.android.FocusedClipboardOverlayTest#unreadableChatMenuKeepsTheHaloVisibleAndReceivesPhysicalCopy' \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

原判断在本次查找未取得复制目标时，只要来源窗口存在就调用 `updateSelectionMenu(false)`。因此即使原菜单仍在，只是节点标签或树暂时不可读，也会立即隐藏圆环。已有的来源等待逻辑虽然没有移除窗口，却无法使隐藏的圆环继续显示。

第一次 46 项回归中，45 项通过，等待复制的用例失败。进一步把标签恢复延后到窗口变化事件之后，并只发送普通内容变化事件，稳定复现了第二个问题：物理触摸已经请求复制，真实菜单标签已经恢复，但服务缓存的子节点标签仍为空；在失败点主动刷新节点后能读到当前“复制”。这与 [AOSP 的无障碍缓存处理](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/view/accessibility/AccessibilityCache.java) 一致：没有子树变化标记的内容事件只刷新事件来源节点，不保证清掉子节点缓存。此实验不能证明真实微信发送了相同事件。

## 修改

生产改动集中在 `TelegramCopyAssistant`。每次菜单检查重新确认原有的菜单窗口标识、父来源窗口与包名关系；只有同一已确认菜单仍在，且检查结果为 `MENU_NO_COPY` 或 `MENU_UNREADABLE`、没有明确节点拒绝时，保留圆环当前的可见性。

这不会主动恢复因手柄拖动而隐藏的圆环。菜单实际移除、来源不匹配、控件明确被拒绝、授权撤回等路径仍按原规则隐藏或清理。首次菜单仍必须完整通过原有识别，未放宽普通复制按钮或不完整菜单的触发条件。

动作执行继续调用原有的新鲜菜单核对。用户点击圆环复制而标签仍缺失时，使用既有等待逻辑；标签恢复后才执行当前可用目标。等待期间关闭原菜单会取消待执行动作并移除圆环，不读取旧剪贴板或直接调用先前缓存的按钮。

对已经确认的同一菜单窗口，读取到可点击控件或其标签子节点的空标签时，主动刷新该节点，并再次核对来源包名、窗口、启用状态、可见性、密码、可编辑和敏感标记。只有刷新后的当前标签与既有菜单规则匹配才执行。遍历深度和节点数量上限保持不变；首次菜单发现不使用这条恢复路径。

没有增加配置、权限、依赖、触发延迟或持续轮询。0.11.16 的菜单触摸保护、较高菜单布局和隐藏状态事件保护保持不变，重新定位继续可用。

## 验证

修复后 6 项定向模拟器测试全部通过，36.389 秒：`/private/tmp/actionhalo-menu-flash-green.log`。覆盖标签缺失时持续可见、直接点击原菜单、圆环复制等待标签恢复、菜单真正关闭，以及原生／标准菜单／仅菜单入口真实手柄按住隐藏和松手恢复。

关闭菜单用例进一步要求：取消已经请求但尚未执行的复制，实际移除圆环窗口，剪贴板保持原样。标签恢复用例延后 400 ms 发送普通内容变化事件，避免由窗口变化碰巧清空缓存而漏测。

延迟恢复回归在缓存修复前稳定失败：`/private/tmp/actionhalo-menu-flash-delayed-probe.log`。修复后，标签恢复、原菜单物理复制、关闭菜单取消等待、复制可用性复核和不支持控件拒绝共 5 项通过，25.331 秒：`/private/tmp/actionhalo-menu-flash-cache-green.log`。

移除临时测试探针后，SDK 36 模拟器最终 46 项回归全部通过，无跳过，275.378 秒：`/private/tmp/actionhalo-menu-flash-final-regression.log`。覆盖上述场景，以及首次选文、原生／菜单／WebView 重选与手柄拖动、选区周边触摸保护、重新定位、较高聊天菜单两排物理点击、快速复制不改变背景和位置、授权撤回与菜单识别边界。构建和 61 项 JVM 测试通过；Lint 0 错误、6 项警告：`/private/tmp/actionhalo-menu-flash-release-build.log`。没有保留临时探针或增加生产日志。

## 安装包与边界

`ActionHalo-0.11.17-debug.apk`：versionCode 53，minSdk 26，targetSdk 36，1,598,374 字节。SHA-256：`e105b6971b4079fc3dbd0b30a82f314bd37604981938aa113bb5f153714d5ffa`。

ZIP 完整性与签名校验通过，证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与之前安装包一致。导出文件与模拟器已测试的构建产物逐字节相同。

尚未在用户的 vivo 真机、真实微信、原子笔记或 Codex App 中验证，也未重跑其他 Android 版本和全部应用测试。复现证明了报告中这条隐藏路径有问题，不能证明微信为什么停止公开菜单数据。若微信持续不提供可用复制目标，圆环动作仍会等待或超时；不会绕过验证执行旧控件。未提交、推送或发布远程版本。
