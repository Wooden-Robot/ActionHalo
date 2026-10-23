# Telegram Copy 事件复刻 fixture

这是独立的合成测试应用，显示名为 **Telegram copy fixture**，不包含 Telegram、账号、网络权限或聊天数据。包名使用 `org.telegram.messenger` 以测试 ActionHalo 的受限来源匹配；**只允许安装到确认没有真实 Telegram 的临时模拟器**，不得安装到用户手机或覆盖已有应用。目录没有加入正式 APK 的 source set。

## 它复刻什么

- 普通 `LinearLayout` 菜单项，子 `TextView` 设置 `IMPORTANT_FOR_ACCESSIBILITY_NO`、不可获取焦点。
- 菜单项没有 ID、contentDescription、AccessibilityDelegate 或人工发送的无障碍事件。
- `Copy` listener 同步写入合成 Unicode 子串，然后在 150 ms 动画结束后销毁 `PopupWindow`。
- 此处复刻“动画结束才销毁”的顺序，不声称动画实现完全相同；官方 hide 使用 100 ms AnimatorSet，dismiss 另有 150 ms 开始延迟。
- `Translate` 不写剪贴板；`Copy without write` 保留之前的旧剪贴板，用于验证拒绝旧内容。
- `FrameLayout` Copy 项用于覆盖整条消息菜单常见容器类别，只是通用结构试验，不声称完整复刻 Telegram 的整条消息菜单。
- 上层 panel 旁观并原样转交已经生成的事件，仅记录固定按钮标签与事件元数据；不记录剪贴板或选中文字。

合成正文包含前后缀；部分选文只写 `中文 🚀 café — selected fragment`。进入 ActionHalo 后选择复制，再返回 fixture 按“Verify clipboard equals selected fragment”，可验证传入内容确实为子串。

## 离线构建

```sh
bash android/diagnostics/telegram-copy-fixture/build.sh
```

默认使用本机 Android SDK 36 build tools、platform 36 和 OpenJDK 17；可通过 `ANDROID_SDK_ROOT`、`JAVA_HOME` 指定。默认 APK 为 `/private/tmp/actionhalo-telegram-copy-fixture/telegram-copy-fixture.apk`，临时签名密钥也只放在该目录。脚本不安装应用，不调用 Gradle。

## 设备验证步骤

1. 与其他测试协调模拟器使用；确认设备为临时模拟器，且 `pm path org.telegram.messenger` 没有已有应用。
2. 安装 ActionHalo 当前调试 APK 与此 fixture。在 ActionHalo 首页明确开启 Telegram 复制后弹出授权及无障碍服务。
3. 打开 fixture 的部分选文 toolbar，点击 Copy。检查只弹出一次圆环，片段无前后缀；确认事件日志为 `TYPE_VIEW_CLICKED` 的正常容器类、Copy 文本，且 `descriptionNull=true`、`viewHasId=false`。
4. 在圆环选择复制，返回 fixture 验证 exact selected fragment 为 true。
5. 点击 Translate：不应弹出圆环。测试 复制、複製、拷貝 与系统 `android.R.string.copy` 标签。
6. 点击 Seed stale clipboard，等待至少 3 秒，再打开 Copy without write 并点 Copy：不得用旧内容显示圆环。
7. 测试 FrameLayout whole-message 菜单、关闭授权后 Copy 不弹出，以及关闭圆环返回原 fixture。
8. 完成后卸载此 fixture，恢复共享模拟器的原有服务设置。保存结论和合成截图，不将模拟器结果写成 vivo / 真实 Telegram 已验证。

也可通过启动参数快速进入：`fixture_mode=partial`、`nonfocusable`、`frame`、`seed`、`stale`、`fresh-stale`、`verify`；`fixture_label` 可指定固定 Copy 标签。`nonfocusable` 与 `partial` 仅改变 PopupWindow 是否获取焦点，用于检查官方默认非焦点工具条是否被窗口跟踪遗漏。`fresh-stale` 在显示菜单之前立即写入 A，但 Copy 按钮不写入，专门检查“两秒内的旧剪贴板”边界。日志 tag 为 `TelegramCopyFixture`，包含 popup/宿主 windowId 及 `sinceSeedMs`，不包含剪贴板内容。

确认临时模拟器为空后，示例命令如下；不得省略前置设备和已有包检查：

```sh
adb -s emulator-5580 shell getprop ro.kernel.qemu
adb -s emulator-5580 shell pm path org.telegram.messenger
adb -s emulator-5580 install /private/tmp/actionhalo-telegram-copy-fixture/telegram-copy-fixture.apk
adb -s emulator-5580 shell am start -W -S -n org.telegram.messenger/.CopyFixtureActivity --es fixture_mode partial
adb -s emulator-5580 shell logcat -d -s TelegramCopyFixture:I '*:S'
adb -s emulator-5580 uninstall org.telegram.messenger
```

截图定位按钮后使用真实屏幕点击，不能用直接启动 `ClipboardHaloActivity` 代替自动触发验证。不要用会压制真实无障碍服务的 UiAutomation 会话。快速旧内容试验需在 `fresh-stale` 显示后两秒内点 Copy，并从日志确认实际间隔。

## 固定源码依据与边界

Telegram 基线为 [`f2908b14133bbffbf7ab04f641ecb5bfaf533242`](https://github.com/DrKLO/Telegram/commit/f2908b14133bbffbf7ab04f641ecb5bfaf533242)：

- [TextSelectionHelper.java:1545–1551](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1545-L1551) 的部分选文菜单使用 `android.R.string.copy`；[1733–1747](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1733-L1747) 用内部选区取得子串并写剪贴板。
- [FloatingToolbar.java:1412–1427](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/FloatingToolbar.java#L1412-L1427) 的普通 LinearLayout 包含排除于节点树的 TextView；[1465–1484](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/FloatingToolbar.java#L1465-L1484) 设置标题，而 contentDescription 代码处于注释中。[488–494](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/FloatingToolbar.java#L488-L494) 在动画结束后才 dismiss。
- Android 15 [View.performClick():8019–8034](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/view/View.java#L8019-L8034) 先调用 listener，再发送点击事件。[ViewGroup:3534–3558](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/view/ViewGroup.java#L3534-L3558) 遍历可见子 View 填充事件，列表[没有按 importance 过滤](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/view/ViewGroup.java#L9120-L9126)；[TextView:13806–13819](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/widget/TextView.java#L13806-L13819) 可将按钮文字填入事件。因此 `IMPORTANT_FOR_ACCESSIBILITY_NO` 不能单独证明 Copy 标签不会进入点击事件。

复制提示不是更可靠的替代信号：[AndroidUtilities:3598–3599](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/messenger/AndroidUtilities.java#L3598-L3599) 在 API 32 及以上禁用自己的 clipboard toast；[UndoView:1012–1015](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Components/UndoView.java#L1012-L1015) 提前返回。旧版提示的[发送实现](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/messenger/AndroidUtilities.java#L4997-L5005) 是 `TYPE_ANNOUNCEMENT`，不是 `TYPE_NOTIFICATION_STATE_CHANGED`。系统复制提示也不能作为具有 Telegram 来源与精确选区保证的信号。

该方案依赖明确 Copy 点击，不能实现“仅长按或拖动正文就自动取得选区”。Android 10 以上[剪贴板读取要求当前 app 获得焦点或是默认输入法](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)，因此服务应只识别事件，前台 Activity 获取焦点后读取。新鲜时间戳可排除旧剪贴板，但不是剪贴板来源证明；未知客户端/标签、没有点击事件、复制受限、系统拦截前台启动时应保留手动磁贴路径。

## 本次验证记录

2026-10-10，Android 15 / API 35 模拟器 `emulator-5580`。离线编译、打包、签名校验通过。真实无障碍服务运行，未使用 UiAutomation。复制自动路径测试配置为 `telegram_copy_popup_enabled=true`、`auto_popup_enabled=false`。

| 用例 | 观察结果 |
| --- | --- |
| 0.4 相同 Copy 点击对照 | 停留宿主，不显示圆环 |
| 0.5 LinearLayout Copy | 自动前台为 ClipboardHaloActivity；事件文本只有 Copy，description=null、View 没有 ID |
| 精确 Unicode 子串与返回 | 圆环执行复制后，宿主比较结果为 true；无原消息前后缀，返回原宿主 |
| Translate | 确认产生 Translate 点击事件；不弹出 |
| 旧内容超过 4.5 秒，Copy 不写 | 拒绝旧内容，返回宿主，不显示圆环 |
| 窗口出现前的快速旧内容 | 原实现 seed 后 895 ms 误弹（RED）；菜单时间校验修复后 858 ms 被拒绝（GREEN）；正常 Copy 再测仍成功 |
| FrameLayout Copy、复制/複製/拷貝 | 均显示圆环，Back 返回宿主；FrameLayout 仅通用结构试验 |
| 首页关闭复制授权后 Copy | 偏好实际保存 false；新 Copy 不弹出 |
| 正式快捷磁贴，无障碍关闭 | 从正式首页完成系统 Add tile 对话框，真实点击 QS 磁贴后显示圆环；Back 返回宿主；当时 Bound/Enabled services 均为空 |

窗口对照实例：popup `windowId=210`、宿主 `209`；同一菜单在 `dumpsys accessibility` 中是 `Popup Window / id=210 / TYPE_APPLICATION / focused=true`。最终菜单时间修复只重测快速旧内容与正常 Copy；其他成功用例在同轮较早的 0.5 候选构建上完成。

合成截图、按钮事件日志及窗口结构记录保存在本机 `/private/tmp/actionhalo-telegram-copy-fixture/`：`final-normal-copy-halo.png`、`0.5-exact-substring-return.png`、`red-fast-stale.png`、`green-fast-stale.png`、`0.5-official-tile-service-off-halo.png`、`all-events.log`、`accessibility-popup-windows.txt`。测试后 fixture 已卸载，原应用偏好、QS 列表和无障碍服务状态已恢复；模拟器交还主测试流程。

以上是独立合成宿主的真实 Android 框架/服务链验证，不是真实 Telegram 或 vivo X200s 实测；没有使用账号或聊天数据。

## 0.5.1 诊断调查：复制无反应

2026-10-10 用户进一步确认：实际失败时系统无障碍开关仍打开，操作是先选中 Telegram 正文的一部分再点复制。这一情况不能用“整条消息菜单不同”解释。

重新核对固定版本：`FloatingToolbar.createPopupWindow` 默认不获取焦点，而原 fixture 的 `partial` 模式获取焦点。新增 `nonfocusable` 对照后，**未修改的 0.5.0 APK 两种模式都能自动弹出**。Android 15 模拟器中非焦点 popup 为 `TYPE_APPLICATION` 子窗口（实例 id=11、宿主 id=10），仍出现在 `AccessibilityService.windows`。真实点击事件仍是 `android.widget.LinearLayout`，文本仅为 Copy。由 ActivityTaskManager 记录确认由无障碍服务启动 `ClipboardHaloActivity`，随后前台读取剪贴板。这个差异不是该模拟器上的失败原因，因此没有据此放宽生产来源或标签匹配。

测试判断必须等待异步 Activity 切换。Copy 后立即截图可能仍是原宿主，不能据此判失败；应在限定时间内轮询 `dumpsys activity activities` 的 `topResumedActivity` 是否为 `ClipboardHaloActivity`，再截图。此次证据位于 `/private/tmp/actionhalo-copy-repro-06/nonfocusable-ready-window.txt`、`nonfocusable-complete.log`、`nonfocusable-halo.png` 与 `focused-halo.png`。

固定版本 `TextSelectionHelper.copyText()` 同步调用 `AndroidUtilities.addToClipboard()` 后才隐藏工具条，后者的普通文字、Spanned 与 HTML 分支都直接调用 `ClipboardManager.setPrimaryClip()`。没有找到需要延迟或重复读取剪贴板的异步复制代码。Overflow 菜单也由 `AdapterView.performItemClick()` 对菜单 child 发送点击事件，不是把 ListView 当作 Copy 控件；无需额外扩大类别白名单。

随后发现原 fixture 漏了部分 Copy 的完整销毁链，详见下节。真实 vivo 上仍未实测，设备内复制诊断需要区分：事件是否到达、来源/标签是否匹配、菜单窗口是否已记录、前台入口是否启动与获得焦点、剪贴板时效是否通过。诊断不能记录消息、选中文字或剪贴板内容。

## 完整复制动画链的红色复现

`animator-copy` 按官方 `copyText → hideActions → clear(true) → finish → dismiss` 顺序复刻：启动 100 ms hide AnimatorSet，随后 cancel，再启动带 150 ms 延迟的 100 ms dismiss AnimatorSet。hide 的 end listener 在取消时同样执行 `PopupWindow.dismiss()`；这是 `NotificationCenter.doOnIdle` 没有其他动画时的同步分支。`animator-hide`、`animator-dismiss` 仅执行单次对应动画，作为对照。

2026-10-10，Android 15 / API 35 / 0.5.1 结果：

| 模式 | 系统 animator_duration_scale | 结果 |
| --- | --- | --- |
| animator-copy | 1 | listener 返回时 attached=false；复制已写入；没有框架点击事件；不弹圆环，重复确认 |
| animator-copy | 0 | 同上 |
| partial（旧模式） | 1 | listener 返回时 attached=true；随后 Copy 点击事件；圆环弹出 |
| animator-hide | 0 | 点击事件存在；圆环弹出 |
| animator-dismiss | 0 | 点击事件存在；圆环弹出 |

因此这里的关键是 hide→cancel→dismiss 链，而不是禁用动画本身。原 fixture 仅做单次延迟销毁，未覆盖这个实际源码分支；原先的成功结果不能证明真实 Telegram 复制自动弹出稳定可用。

确认临时模拟器已安装本 fixture 与 ActionHalo、明确启用复制授权和测试无障碍服务后，可重复运行：

```sh
python3 android/diagnostics/telegram-copy-fixture/probe.py --serial emulator-5580 --mode animator-copy --scale 1 --expect detached --output /private/tmp/actionhalo-copy-repro-06/probe-copy
python3 android/diagnostics/telegram-copy-fixture/probe.py --serial emulator-5580 --mode partial --scale 1 --expect halo --output /private/tmp/actionhalo-copy-repro-06/probe-control
```

两条命令均实际运行通过断言：第一条锁定“已分离、没有点击、没有圆环”的已知失败边界，第二条锁定正常弹出对照。探针会拒绝非模拟器设备，按当前 popup 边界真实触摸 Copy，等待前台结果，按 fixture 进程 ID 保存日志，并恢复运行前的系统动画比例。它不安装应用，不改 ActionHalo 偏好，不读聊天或剪贴板正文。

`ChatActivity.onTextCopied()` 的 `UndoView.ACTION_TEXT_COPIED` 在 API 32 及以上提前返回，因此该分支没有 Telegram 自身 Toast/Bulletin/announcement 可替代丢失的点击事件。完整源码推导、证据和限制另见 [兼容性核对](../telegram-compatibility.md)。

## 明确按钮路径的验证协议

新版探针保留原 Copy 控件，不增加 ID、contentDescription 或无障碍 delegate，也不改变子 TextView 的 importance。`--trigger helper` 仅从 `dumpsys accessibility` 定位标题严格为 `ActionHalo Telegram copy` 的辅助窗口，真实触摸窗口左侧三分之一处；右侧关闭按钮不在触摸目标内。它不直接调用内部 Activity 或 Copy listener。

fixture 新增两种负例，均保留完整 hide→cancel→dismiss 销毁链：

- `animator-copy-no-write`：先写入合成旧剪贴板，再打开菜单；Copy listener 被调用，但不写入。
- `animator-copy-menu-stale`：先打开菜单，100 ms 后写入合成旧剪贴板；探针等待 `seed_after_menu=true`，再等 200 ms 才按辅助按钮；Copy 不写入。此场景专门检查“菜单打开后已有剪贴板”不能被当作辅助按钮刚复制的结果。

固定日志 `counters copy_calls=N writes=N translations=N` 记录 Copy listener 调用、由 Copy 写入的次数和 Translate 次数。`writes` 不包括为负例准备的旧内容。`verify exact_selected_fragment=true/false` 仅记录与固定合成 Unicode 子串的比较结果，不输出正文。原 Copy 和 Translate 节点的可访问性结构未改。

准备好明确授权的临时模拟器后，可依次运行：

```sh
# RED：旧 0.5.2 的原 Copy 路径仍可复现“复制完成但无点击事件”。
python3 android/diagnostics/telegram-copy-fixture/probe.py --serial emulator-5580 --mode animator-copy --trigger native --expect detached --output /private/tmp/actionhalo-copy-helper/red

# GREEN：候选新版，点可见辅助按钮，通过原 Copy 的真实 ACTION_CLICK 完成复制。
python3 android/diagnostics/telegram-copy-fixture/probe.py --serial emulator-5580 --mode animator-copy --trigger helper --expect halo --output /private/tmp/actionhalo-copy-helper/green

# 同一个 Copy listener 不写内容时，不能误用菜单出现前的旧内容。
python3 android/diagnostics/telegram-copy-fixture/probe.py --serial emulator-5580 --mode animator-copy-no-write --trigger helper --expect rejected --output /private/tmp/actionhalo-copy-helper/no-write

# 不能误用菜单出现之后、按辅助按钮之前已有的内容。
python3 android/diagnostics/telegram-copy-fixture/probe.py --serial emulator-5580 --mode animator-copy-menu-stale --trigger helper --expect rejected --output /private/tmp/actionhalo-copy-helper/menu-stale
```

以上为验证协议，不能代替实际运行记录。探针要求 Copy listener 恰好调用一次，Translate 为零；正例要求写入一次且 `ClipboardHaloActivity` 连续位于前台至少 600 ms，避免把随即拒绝并退出的 Activity 闪现算作圆环成功。负例观察完整约四秒，要求没有稳定圆环、Copy 写入零次并返回 fixture。完整动画辅助路径还必须仍显示 `attached=false` 且没有框架点击事件，以证明没有回避既知失败条件。每次保存固定事件日志、前后窗口状态、最终 Activity 状态和合成截图；最后恢复系统动画比例。

**稳定显示仍不足以证明圆环取得的文字正确。** 成功后须真实点击圆环里的 Copy 操作，再返回 fixture 执行“Verify clipboard equals selected fragment”（也可用 `fixture_mode=verify` 进入前台比较），确认固定日志 `verify exact_selected_fragment=true`。只有完成这个往返，才能声称精确 Unicode 子串验证通过。不要用会抑制服务的默认 UiAutomation 读取圆环按钮，也不能通过直接启动 `ClipboardHaloActivity` 代替辅助按钮触发。

还需单独真实操作以下负例：点原 Translate、按 Back 取消菜单、点辅助窗口关闭按钮、离开 Telegram；均应没有圆环且辅助按钮及时消失。关闭功能授权或断开服务后，应不出现辅助按钮。将正例至少再以 `--scale 0` 运行一次，确认没有依赖动画延迟。所有模拟器结果仅代表合成宿主上的框架与服务链，不能写成 vivo 或官方 Telegram 已实测。


## 0.6.1 直接圆环探针

`direct_probe.py` 只用于安装了本合成宿主的临时模拟器，启动前校验 fixture 版本、服务连接、GTA 模式和七项默认操作。它在读取并稳定窗口几何后才发送一次真实触摸；新 Activity 对固定 Unicode 片段和 ActionHalo 剪贴板标签同时核对，不能把宿主自身已经复制成功误算为 ActionHalo 已执行。

```sh
python3 direct_probe.py --serial emulator-5580 --mode animator-copy --dialog --output /tmp/actionhalo-direct-dialog
```

`--dialog` 在圆环出现后加入真实聚焦小 Dialog；选动作时必须没有 Copy，Back 关闭 Dialog 后才继续且仅执行一次。`--cancel` 要求零 Copy；`--scale 0` 覆盖动画关闭；`animator-copy-no-write`、`animator-copy-menu-stale` 要求拒绝旧剪贴板。开启功能和默认操作属于探针前置条件，脚本不会静默修改应用配置。完整结果（含可聚焦 `partial` 对照未支持的窗口结构）见 [0.6.1 验证记录](../telegram-copy-0.6.1.md)。
