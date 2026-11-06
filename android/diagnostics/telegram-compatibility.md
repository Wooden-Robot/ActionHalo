# Telegram Android 选文兼容性核对

核对日期：2026-10-10。当前版本为 0.6.1，Telegram 交互已改为选文后直接显示圆环、用户选动作后才复制读取并执行。模拟器证据及验证边界见 [0.6.1 记录](telegram-copy-0.6.1.md)。用户已报告 0.6.0 在 vivo 上的失败现象，详见下一节；尚未验证 0.6.1 在该手机上的结果。本文其余版本记录分别描述当时的源码结论和合成宿主结果，不代表真实 Telegram 已通过。没有登录用户 Telegram 或读取聊天。

源码基线是官方仓库 [DrKLO/Telegram 的固定提交 `f2908b14133bbffbf7ab04f641ecb5bfaf533242`](https://github.com/DrKLO/Telegram/commit/f2908b14133bbffbf7ab04f641ecb5bfaf533242)，提交说明为 `update to 12.10.6 (7112)`，提交时间为 2026-09-30。用户随后提供的本机报告确认 `org.telegram.messenger=12.10.6`；版本一致仍不能把源码或合成宿主的结果直接视为该手机的运行结果。

## 0.6.1：直接圆环与待执行动作

用户使用 0.6.0 后报告：点击助手后 Telegram 菜单消失，但圆环没有出现。服务仍为已连接，诊断多次记录 `HELPER_SHOWN → HELPER_TAPPED → LAUNCH_REQUESTED`，没有后续 `FOCUSED`。这些记录证明已经走到请求启动界面，但不能区分系统拒绝启动、窗口未取得焦点或其他尚未记录的情况。截图顶部摄像头附近有系统翻译胶囊，不能仅根据同时出现就认定它抢占焦点是根因。

0.6.1 的流程：

1. 继续限定识别前台官方 Telegram 的同包部分选文菜单；找到有效 Copy 控件后，直接显示不取得焦点的 GTA 圆环。显示本身不复制、不读取剪贴板。
2. 用户在圆环中选定动作后，重新核对菜单并执行真实 Copy `ACTION_CLICK`，记录复制操作起止时间。
3. 用可见、可取得焦点的无障碍浮层承接已选动作。实际取得焦点后读取并核对本次剪贴板；确认准确内容后直接执行动作。此路径不再启动新 Activity 打开圆环。
4. 临时失焦最多保留待执行操作 30 秒，提供可见的继续/取消入口。已有有效文字快照时保持快照，恢复焦点不再读取；首次读取为空时，仅允许在真实恢复焦点时重试一次，总读取次数最多两次，不做计时轮询。
5. 时间戳不属于本次复制的旧内容直接拒绝，不用旧剪贴板填补空结果。切换到其他应用、关闭权限、锁屏、取消或到期都清理待执行操作，不能在以后恢复出意外动作。

标题改为“Telegram 选文圆环”，沿用原偏好；新安装默认关闭，旧版已开启则升级保持开启。磁贴仍作为无需无障碍的手动备用入口；0.5.2 的设置导航行为及 vivo 总列表关闭的未解决边界保持不变。原生 Copy 按钮可能不发布点击事件的事实也没有改变。

### 当前验证状态

Android 15 / API 35 临时模拟器已实际运行两项框架对照，输出为 `OK (2 tests)`，见 [focused-window-framework.txt](../build/diagnostics/telegram-copy-0.6.1/focused-window-framework.txt)：

- 不取得焦点的无障碍浮层不能读取另一个应用写入的剪贴板。
- 可取得焦点的无障碍浮层在焦点回调后能读取准确 Unicode 文字一次。

这两项只验证框架读取条件。完整选文圆环、失焦恢复和端到端结果见 [0.6.1 记录](telegram-copy-0.6.1.md)；以下 0.6.0 历史结果不能替代新版或真机验证。

## 三种操作需要分开判断

| 操作 | 源码中的实现 | 对 ActionHalo 的意义 |
| --- | --- | --- |
| 长按消息，出现消息菜单或选中整条消息 | `ChatActivity` 创建消息菜单、选择消息行或开始多选；消息节点可带有 `selected` 标志 | 整条消息选择不等于文字字符范围选择，不能据此认定用户选中了某一段文字 |
| 在消息正文中选择部分文字、拖动手柄 | Telegram 的 `TextSelectionHelper` 自己保存起止偏移、绘制选区及处理菜单 | 受审查的实现没有将该选区桥接为标准无障碍文字选区事件或节点字符范围，当前自动触发链缺少精确选区输入 |
| 在消息输入框中选择已经输入的文字 | 输入框继承 Android `EditText`，保留父类选区回调和无障碍节点初始化 | 源码上保留标准选区通路，应单独检查事件计数和数字范围，不能套用消息正文的限制 |

## 消息长按与消息节点

- [ChatActivity.java:1692–1720](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L1692-L1720)：消息长按回调进入 `createMenu()` / `processRowSelect()`，随后可能调用 `startMultiselect()`。
- [ChatMessageCell.java:27085–27185](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/ChatMessageCell.java#L27085-L27185)：自定义 `AccessibilityNodeProvider` 为消息宿主节点拼接朗读文本，其中可包含作者、转发信息、正文等。
- [ChatMessageCell.java:27341–27345](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/ChatMessageCell.java#L27341-L27345)：Android 7 及以上通过 `info.setText(accessibilityText)` 提供拼接文本。能读取整条节点文本，不代表能读取用户选中的子串。
- [ChatMessageCell.java:27485–27486](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/ChatMessageCell.java#L27485-L27486)：选择背景对应 `info.setSelected(true)`。该标志不是 `textSelectionStart` / `textSelectionEnd`；受审查的消息节点提供器没有调用 `setTextSelection()`。

因此，不能用消息节点的整段 `text` 或 `isSelected` 替代精确选文，也不能将正文内部偏移直接套用到包含额外信息的朗读文本上。

## 正文部分选文的动态链

以下链接均指向同一固定提交的 `ui/Cells/TextSelectionHelper.java`：

1. [102–103](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L102-L103)：`selectionStart`、`selectionEnd` 是 helper 自有的整数字段，初始值为 `-1`。
2. [236–237](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L236-L237)：长按开始时直接写入两个字段。
3. [1057–1065](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1057-L1065)：拖动手柄直接改变字段并请求重绘。
4. [1516–1518](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1516-L1518)：基类 `onOffsetChanged()` 为空；聊天列表 helper 没有覆写它。
5. [1800–1805](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1800-L1805)：`getSelectedText()` 用内部起止值调用 `text.subSequence()`。
6. [2121–2140](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L2121-L2140)：`ChatListTextSelectionHelper.select()` 也直接设置这些字段并更新界面。

这一选区实现没有使用 Android `Selection` span 维护选区，也没有显式发送 `TYPE_VIEW_TEXT_SELECTION_CHANGED` 或调用无障碍节点的 `setTextSelection()`。为避免只依据一个文件中缺少符号下结论，还核对了上层：

- [ChatActivity.java:3450–3562](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L3450-L3562)：聊天页子类覆写的是主题、复制条件和引用处理，没有增加选区事件桥接。
- [ChatActivity.java:8678–8704](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L8678-L8704)：helper 回调更新界面状态、显示复制提示，没有发布文字选区事件。

这个判断限于上述聊天正文选区链。界面仍可能产生其他无障碍事件；源码审查不能证明某台设备实际收到的全部事件。

## 正文菜单不保证有外部入口

- [TextSelectionHelper.java:1545–1552](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1545-L1552)：自定义菜单添加复制、引用、翻译、剪切、粘贴、全选。
- [TextSelectionHelper.java:1621–1666](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1621-L1666)：菜单动作由 Telegram 内部处理；这条路径没有建立 `ACTION_PROCESS_TEXT` 或 `ACTION_SEND`。
- [TextSelectionHelper.java:1733–1747](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java#L1733-L1747)：复制调用 `getSelectedText()`，再调用 `AndroidUtilities.addToClipboard()`。

因此不能承诺消息正文选词菜单里有 ActionHalo 或系统分享。复制是否允许还受 Telegram 自身消息或会话限制影响，例如 [ChatActivity.java:3506–3513](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L3506-L3513) 中的 `canCopy()` 判断。

## 输入框保留标准选区通路

输入框继承链为 `ChatActivityEditTextCaption → EditTextCaption → EditTextBoldCursor → EditTextEffects → android.widget.EditText`。

- [ChatActivityEnterView.java:5492–5498](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Components/ChatActivityEnterView.java#L5492-L5498)：`onSelectionChanged()` 首先调用父类。
- [EditTextEffects.java:98–109](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Components/EditTextEffects.java#L98-L109)：继续调用父类选区回调。
- [EditTextBoldCursor.java:1265–1274](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Components/EditTextBoldCursor.java#L1265-L1274)：无障碍节点初始化调用父类，并补充 EditText 类名及提示文字。
- Android 15 的 [TextView.java:12638–12641](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/widget/TextView.java#L12638-L12641) 在父类选区回调中发送 `TYPE_VIEW_TEXT_SELECTION_CHANGED`；[14102–14105](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/widget/TextView.java#L14102-L14105) 填写事件起止位置；[15919–15943](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/widget/TextView.java#L15919-L15943) 将无障碍选区 getter 对应到输入框真实选区。

因此输入框是合理的独立验证入口，但实际是否触发仍取决于用户版本、系统及服务状态，尚不能声明 vivo 真机已验证成功。

## 0.5 的复制桥接与验证边界

0.5 增加独立授权的“Telegram 复制后弹出”：在系统实际发送可识别的复制点击事件时，服务核对包名、按钮类、完整复制标题及菜单窗口时间；前台 Activity 获得焦点后读取一次刚复制的文字，再显示圆环。它没有从消息朗读文本猜测子串，也没有后台监听或读取剪贴板。这条路径不能保证真实 Telegram 的每次 Copy 都会产生所需事件。

按钮结构方面，[FloatingToolbar.java:1412–1427](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/FloatingToolbar.java#L1412-L1427) 使用普通 LinearLayout 和被设为 `IMPORTANT_FOR_ACCESSIBILITY_NO` 的子 TextView；Android 的[可见子 View 事件填充](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/view/ViewGroup.java#L3534-L3558)仍能带出标题。但 [View.performClick()](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-15.0.0_r1/core/java/android/view/View.java#L8019-L8034) 在 listener 返回后才发送点击事件，按钮若已被销毁，就不能假定事件仍会发送。详情及可复刻源码见 [Telegram Copy fixture](telegram-copy-fixture/README.md)。

模拟器中，合成宿主使用允许的包名 `org.telegram.messenger`，但显示名明确为 **Telegram copy fixture**，没有账号或网络权限。旧版 0.4 对同一 Copy 点击不弹出；0.5 的真实无障碍服务在原自动选文关闭、复制授权开启时自动显示圆环，保留完整 Unicode 子串，关闭后返回宿主。翻译、不写入新内容的 Copy、关闭复制授权都不会显示圆环。复刻结构还验证了普通 FrameLayout 菜单和中文复制标题，不代表完整复刻了真实 Telegram 所有菜单。

快速旧剪贴板测试发现并修复了一个边界：只检查点击附近的时间，会接受菜单打开前写入、距 Copy 点击仅 895 ms 的旧内容；加入“剪贴板晚于当前菜单窗口首次出现”的校验后，同一负例在写入到点击间隔 858 ms 时被拒绝，正常 Copy 仍成功。实际事件的 popup windowId 与宿主 windowId 不同，系统无障碍窗口列表也提供该 popup 的 ID。时间匹配仍不是剪贴板来源证明。

手动备用入口是快捷设置中的“已复制文字圆环”：复制后点击磁贴，圆环直接显示在原应用上方，关闭后返回。正式磁贴经过系统添加对话框和真实点击验证，在无障碍服务关闭时仍可使用。原首页粘贴入口也保留。

用户现已确认：失败时系统无障碍开关仍开启，操作是先选中正文的部分文字，再点复制。浏览器是否恢复仍未知。原测试只证明延迟销毁工具条的链路，不能写成真实 Telegram 或 vivo X200s 已验证。

## 0.5.1 调查发现的事件丢失边界

固定版本中，`TextSelectionHelper.copyText()` 同步写入剪贴板，接着依次调用 `hideActions()`、`clear(true)`。后者将选区设为无效并再次调用 `hideActions()`，继而 `actionMode.finish()`。`FloatingActionMode.reset()` 调用工具条的 `dismiss()`；`FloatingToolbarPopup.dismiss()` 先 `mHideAnimation.cancel()`，而 hide 动画的 `onAnimationEnd()` 不区分取消与自然结束，调用 `NotificationCenter.doOnIdle()` 销毁 PopupWindow。该方法在没有其他应用动画时直接运行传入代码。因此销毁可能发生在 Copy listener 返回之前。

对应源码：[TextSelectionHelper.copyText / clear / hideActions](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/Cells/TextSelectionHelper.java)、[FloatingActionMode.reset](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/FloatingActionMode.java)、[FloatingToolbar 动画回调及 dismiss](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ActionBar/FloatingToolbar.java)、[NotificationCenter.doOnIdle](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/messenger/NotificationCenter.java)。

补齐这一链的 `animator-copy` 合成模式，在 Android 15 与当前 0.5.1 上重复得到：复制已写入；hide 动画 end 先执行；listener 返回时 `attached=false`；没有 `TYPE_VIEW_CLICKED`，圆环不弹。系统动画比例 1 和 0 均复现。只执行一次 hide/dismiss 动画，以及原 partial 模式，仍会先发出点击事件并成功弹出。因此关键是完整的 hide→cancel→dismiss 顺序，不能归因于用户关闭了动画。

部分选文的 `onTextCopied()` 只调用 `UndoView.ACTION_TEXT_COPIED`；该路径在 API 32 及以上被 `shouldShowClipboardToast()` 提前跳过，没有可依赖的 Telegram 自身提示事件。旧版本的提示是 `TYPE_ANNOUNCEMENT`，也不能据此保证当前手机可用。

这证明原事件方案存在真实框架边界，但仍不能确定用户 vivo 的失败正是这一原因。0.5.1 增加分阶段诊断以区分事件未到达、事件过滤、窗口缺失、前台启动/焦点与剪贴板时效失败，没有通过猜测菜单关闭或扫描聊天来补触发。0.6.0 在此基础上新增下面的明确点击路径，未改变原复制按钮可能缺少事件的事实。

## 0.6.0 历史记录：Telegram 复制助手

首页功能更名为“Telegram 复制助手”，新安装默认关闭，沿用 `telegram_copy_popup_enabled` 偏好。升级前已启用原复制功能的用户，升级后助手保持开启；不清除旧开关，也不要求重新进入系统设置授权。无障碍设置导航保留 [0.5.2 的行为与边界](accessibility-lifecycle.md)：已授权同意功能时留在首页，显式设置按钮先显示状态框；这不修复用户手动进入 vivo 总列表后关闭的问题。

新增路径为：选中 Telegram 消息中的部分文字 → 在识别出的菜单旁显示“复制并弹出” → **用户点击新按钮** → 对 Telegram 真实 Copy 控件执行 `ACTION_CLICK` → 前台窗口获得焦点后读取一次本次剪贴板 → 显示现有 GTA 圆环。出现选文菜单或助手本身不会执行复制。

检测范围和操作约束：

- 仅检查当前前台官方包 `org.telegram.messenger` 或 `org.telegram.messenger.web` 的同包子应用窗口菜单。主聊天树只用于读取前台窗口包名，不遍历消息正文；不使用消息朗读文本推测选文。
- 助手开启时增加 `FLAG_INCLUDE_NOT_IMPORTANT_VIEWS`，用于获得 Telegram 工具条中 `IMPORTANT_FOR_ACCESSIBILITY_NO` 的复制标题；关闭助手时移除该标志与额外的内容变化订阅。
- 复制标题按完整文字匹配系统标题和支持的中英文标题。候选须可见、启用、非密码、非可编辑、非系统标记的敏感节点，并存在真实 `ACTION_CLICK`；多个候选、超出受限菜单遍历范围或无法确认菜单时不显示助手。
- 点击“复制并弹出”后重新核对当前菜单及控件，仅在确认后执行复制。菜单已变化或 Copy 操作失败时提示重新选择；用户也可关闭本次助手。
- 无障碍服务不读取剪贴板。前台窗口只读一次，剪贴板时间戳必须落在本次 Copy 调用开始到结束的区间内；不能确认本次内容时拒绝弹出，不能退回之前的剪贴板。时间匹配本身仍不是剪贴板来源的绝对证明。
- 保留旧原生 Copy 点击事件路径，但助手发起操作产生的点击事件会去重，避免重复圆环。原按钮因工具条销毁而不发事件时仍可能无反应；新增助手不能称为修复了原按钮。

Android 15 / API 35 临时模拟器的合成宿主检查已通过：完整 `animator-copy` 销毁链在动画比例 1、0 下都只执行一次 Copy、写入一次并显示稳定圆环；仍发送原生点击事件的 `nonfocusable` 对照保持助手请求，没有被旧事件路径覆盖。不写入新剪贴板、菜单出现后已有旧内容两个负例均未写入、没有圆环并返回宿主。Translate、外部取消、“×”收起、同一窗口保持收起、新菜单重新出现、切换应用和未知复制标题的检查通过。早前手动 GTA Copy 往返验证记录 `exact_selected_fragment=true`。

0.6.0 负例测试曾发现，仅使用 `NEW_TASK` 启动内部圆环可能复用旧任务，显示旧请求内容。当时统一 `ClipboardHaloActivity` 的内部请求为 `NEW_TASK | CLEAR_TASK`，创建新的请求界面；重新运行上述两个负例后均正确拒绝旧内容。证据和结果详见 [0.6.0 复制助手验证记录](telegram-copy-0.6.0.md)。该轮 42 项 JVM 单元测试通过，Lint 0 错误、5 项原有警告。这些是旧版结果，不能作为 0.6.1 浮层路径的验证。

这些合成宿主检查未覆盖用户 vivo X200s 的窗口行为，后续用户已报告本节开头所述的 0.6.0 失败。菜单结构、语言包、受限消息、系统窗口暴露或后台启动限制都可能影响功能；本应用不绕过 Telegram 不允许复制的限制。无障碍未连接或圆环没有出现时，继续使用正常复制后点击“复制后圆环”快捷磁贴的备用路径；GTA 圆环和磁贴功能保留。
