# 0.6.1 Telegram 直选圆环与焦点恢复验证记录

日期：2026-10-10。本文记录实现边界、验证证据与未覆盖的真机条件。测试环境为 Android 15 / API 35 临时模拟器，Telegram 宿主由明确标注的独立合成应用提供，无账户、无真实聊天数据。尚未在用户的 vivo X200s / V2458A、Android 16 / API 36、官方 Telegram 12.10.6 上验证本版。

## 用户报告与修改原因

用户在 0.6.0 手机上已经看到“复制并弹出”助手；点击后 Telegram 选文菜单消失，但没有圆环。2026-10-10T06:24:14.117Z 的本机诊断显示服务启用、已连接，阶段停在：

```text
telegram_copy_stage=LAUNCH_REQUESTED
telegram_recent_stages=HELPER_SHOWN>HELPER_TAPPED>LAUNCH_REQUESTED>HELPER_SHOWN>HELPER_TAPPED>LAUNCH_REQUESTED
```

这说明助手收到点击并发出了后续窗口请求，没有记录到旧 `ClipboardHaloActivity` 获得焦点。它不能区分 Activity 启动被拦截、窗口焦点竞争或其他系统行为。用户提供的顶部“翻译”提示截图也不足以证明该提示就是失败原因。

0.6.1 把用户要求的“选中文字就显示圆环”放到已能出现的无障碍浮层中；用户选择圆环操作后，使用可见、可聚焦的无障碍操作窗口取得文字，避免这条路径依赖旧 Activity 启动成功。保留 GTA 圆环外观和已有操作配置。

## 当前交互与文字边界

1. 仅在前台官方 Telegram 的真实选文菜单中识别 Copy 控件，不根据聊天正文猜测选区。首次发现需确认 Telegram 前台；圆环显示后跟踪同一宿主和同一菜单窗口。
2. 直接显示 `TYPE_ACCESSIBILITY_OVERLAY` GTA 圆环，使用 `FLAG_NOT_FOCUSABLE`，让 Telegram 保留自己的精确选区。显示圆环本身不会复制或读取剪贴板。
3. 用户选定操作后重新核验 Copy 控件，调用一次真实 `ACTION_CLICK`，记录调用前后的时间，并传递原宿主窗口 ID。取消圆环不触发复制；随后出现的原生 Copy 事件通过已消费窗口记录去重。
4. 使用独立可聚焦的 `ClipboardHaloOverlay` 等待真实窗口焦点。只有 `hasWindowFocus()` 成立时才尝试一次剪贴板读取；不监听剪贴板、不计时轮询、不读取 URI 内容。
5. 仅接受单条有效文字。新的辅助复制路径要求系统剪贴板时间戳落在本次 Copy 调用开始到结束的闭区间内，且该调用区间不超过 4 秒。Copy 没有写入、只留下此前文字时必须拒绝；等待焦点不会放宽这个时间戳区间。
6. 成功文字只保存为本次内存快照。恢复焦点后复用快照，并在执行前重新检查窗口、开关、操作仍启用及期限。先置提交标记，再执行一次所选操作。`ACTION_DISPATCHED` 仅表示已提交调用，不代表外部应用已完成搜索或分享。

具体实现见 [TelegramCopyAssistant](../app/src/main/java/com/actionhalo/android/TelegramCopyAssistant.kt)、[ClipboardHaloOverlay](../app/src/main/java/com/actionhalo/android/ClipboardHaloOverlay.kt) 与 [TelegramCopyPolicy](../app/src/main/java/com/actionhalo/android/TelegramCopyPolicy.kt)。

## 临时失焦、取消和旧入口

临时小窗口或对话框取得焦点时，只要原宿主和选文菜单仍有效，保留直选圆环。已选择的操作则保留在可见等待界面，提供“继续”和“取消”。每一代真实焦点最多自动读一次，自动读取总计最多两次；显式“继续”可在当前期限内重试。已经成功取得的文字不会因新的焦点变化而重新读取。

新操作窗口会话最长等待 30 秒。恢复前始终核验原宿主：原宿主消失且最高层应用窗口完整覆盖可用屏幕时，以 `SOURCE_CLOSED` 明确提示并取消；小模态对话框或系统窗口暂时遮挡来源时等待恢复，不根据缺少焦点回调或暂时缺失窗口 ID 直接丢弃请求。关闭功能、锁屏、服务中断、配置变化、用户取消或新请求替换旧请求会清理待执行内容。过期后提示请求失效，不在另一应用中继续旧操作。

首页“使用已复制文字”、快捷设置磁贴和旧原生 Copy 事件入口仍由 `ClipboardHaloActivity` 处理，也补齐了临时失焦恢复：

- 读取返回 null 时保留“继续 / 取消”，不再立即结束。URI、多条或无效文字仍拒绝。
- 自动 Copy 请求在创建时核验是否于 4 秒内到达；已接受的请求可等待最多 30 秒恢复焦点，读取时仍以原 Copy / 菜单时间验证文字。旧原生事件的时间规则没有放宽为任意新剪贴板。
- 一旦成功显示圆环，停止读取期限计时，保留原文字和原圆环；不会在 30 秒后自动关闭已经可用的圆环。
- `attemptedRead` 的保存状态防护继续存在：读取过的旧请求不能在 Activity 重建后悄悄消费另一份剪贴板。

普通自动选文圆环与 Telegram 复制前的圆环也沿用该窗口判断：小对话框遮挡时保留界面；此时选择动作会暂存，来源恢复后重新核对有效选区或原 Copy 控件，再执行。普通选文还在点击前刷新节点、范围及文字，防止继续使用已经取消的选区。

Telegram 圆环先核验原宿主，再核验原选文菜单。即使无障碍窗口 ID 仍在，菜单节点树也可能已暂时不可读；这时重新核验来源并短时等待，不能把 `findTarget()` 返回 null 直接当作菜单取消。只有实际恢复有效 Copy 控件后才结束等待；已有 `pendingAction` 时，刷新和再次取节点失败不会重置 30 秒期限。菜单缺失先等待既有的 260 ms 稳定刷新，再确认是否收起圆环，避免弹窗关闭时先发布宿主、后发布原菜单造成误取消。

这些策略针对应用内可观察的窗口状态，不保证所有 OEM 窗口或系统拦截均能恢复。无障碍权限本身被系统关闭属于另一问题，本次修改不声称已修复它。

## 当前已取得的验证证据

| 检查 | 当前结果 | 本机证据 |
| --- | --- | --- |
| 直选 GTA 圆环，动画比例 1，合成 `animator-copy` 菜单 | 已完成一次端到端往返；Copy 调用一次、宿主写入一次，返回验证 `exact_selected_fragment=true`、`actionhalo_label=true` | [事件](../build/diagnostics/telegram-copy-0.6.1/direct-scale1/events.log)、[原文与 ActionHalo 标签核对](../build/diagnostics/telegram-copy-0.6.1/direct-scale1/verification.log)、[操作前截图](../build/diagnostics/telegram-copy-0.6.1/direct-scale1/screen-before.png)、[窗口状态](../build/diagnostics/telegram-copy-0.6.1/direct-scale1/windows-after.txt) |
| 直选圆环遇到真实 Dialog，修正后端到端往返 | 已通过：Dialog 期间保留待执行操作且没有 Copy；Dialog 关闭后 `copy_calls=1`、`writes=1`，精确 Unicode 选文及 ActionHalo 标签均匹配 | [等待期间事件](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-fixed/events-waiting-dialog.log)、[完整事件](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-fixed/events.log)、[精确文字核对](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-fixed/verification.log)、[Dialog 期间窗口](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-fixed/windows-waiting-dialog.txt) |
| Android 框架可聚焦窗口对照 | 两项通过：非聚焦浮层读不到独立 UID 宿主剪贴板；真实聚焦浮层可读取固定 Unicode 文字，后续失焦 / 恢复不重复读取 | [框架对照记录](../build/diagnostics/telegram-copy-0.6.1/focused-window-framework.txt) |
| 历史首轮生产浮层测试 | 10 项中 9 项通过、1 项失败；快照竞争测试改为受控调度后已纳入后续全套通过记录，首轮失败保留 | [保留的首轮原始记录](../build/diagnostics/telegram-copy-0.6.1/focused-overlay-production.txt) |
| 一轮完整设备回归 | `OK (50 tests)`：44 项实际通过、6 项需另行启用的选文诊断跳过。分项为权限导航 6、剪贴板入口 10、豆瓣 3、聚焦浮层 13、GTA 圆环 7、集成 5；这次结果早于最新 Dialog 元数据修正，不能替代最终重跑 | [完整设备记录](../build/diagnostics/telegram-copy-0.6.1/all-instrumentation.txt) |
| 新增第 14 项后的聚焦测试首轮 | 14 项中 12 项通过、2 项失败；来源关闭后露出后台残留的小 Dialog，窗口被归为 `OBSCURED`，没有在测试等待时间内立即取消。详见下述边界；清理已知合成宿主后最终重跑通过 | [首次 14 项记录](../build/diagnostics/telegram-copy-0.6.1/focused-final.txt) |
| 最终构建焦点回归 | 14 项通过、0 失败、0 跳过，包含普通选文显示前被打断、显示后暂存动作和服务解绑 | [交付 APK 焦点记录](../build/diagnostics/telegram-copy-0.6.1/focused-release.txt) |
| JVM 单元测试 | 最终构建 42 项通过、0 失败、0 跳过 | [构建记录](../build/diagnostics/telegram-copy-0.6.1/build-checks.txt)、[汇总](../build/diagnostics/telegram-copy-0.6.1/final-artifact.json) |
| Android Lint | 最终构建 0 错误、5 项原有警告 | [Lint 报告](../app/build/reports/lint-results-debug.txt) |

首轮快照测试通过创建窗口来尝试插入“读取完成、执行尚未发生”的时隙，但真实窗口焦点回调与帧调度先后不固定：动作可能已提交，测试才观察到抢焦。已把这一测试改为受控的 `postAction` 执行调度，仍使用真实窗口焦点和真实 Binder 剪贴板读取，先确认焦点已丢失再放行待执行动作；生产默认调度仍为 `postOnAnimation`。该调整使目标竞争条件可重复触发，不把首轮失败直接算作通过，也不以模拟焦点回调代替窗口验证。后续全套通过记录包含这一用例，核对失焦不执行、恢复后只执行一次、剪贴板被替换后仍使用第一次快照。

新增旧 Activity 回归覆盖空剪贴板显式重试，以及真实 Dialog 抢焦超过 4 秒后恢复原复制文字；已有成功圆环失焦后保留快照、旧任务替换、过期 / 未授权 / 旧剪贴板拒绝等用例继续保留。这些旧入口回归已包含在上述完整设备记录中；最终构建另重跑 14 项焦点回归。

## 进一步回归发现

连续切换授权并解绑服务的设备测试复现了 `TelegramCopyAssistant.setEnabled()` 读取空 `serviceInfo` 后崩溃。现已在服务断开时清理并返回，新增真实解绑回归。见 [崩溃记录](../build/diagnostics/telegram-copy-0.6.1/service-disconnect-regression.txt)。这不能直接解释用户 vivo 关闭权限的来源。

普通应用小 Dialog 的测试还证明：即使原页面没有关闭，模态窗口也可能令它暂时离开无障碍窗口列表。首轮全套测试因此失败，见 [原始记录](../build/diagnostics/telegram-copy-0.6.1/modal-source-regression.txt)。现统一以 `SourceWindowState` 区分原窗口可用、小窗口遮挡和完整应用替换；小窗口期间不读取或执行，原窗口恢复后才重新核验。真实小 Dialog 保留及期间选 Copy 的回归覆盖这一边界。窗口几何不能识别所有 OEM 或分屏意图；未知遮挡只短时等待，不放宽选文检查。

独立 Telegram fixture 的真实 Dialog 探针仍两次重现直选圆环被清除，分别保留于 [direct-dialog 窗口](../build/diagnostics/telegram-copy-0.6.1/direct-dialog/windows-dialog.txt)和 [direct-dialog-final 窗口](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-final/windows-dialog.txt)。进一步临时诊断得到同一刷新过程先报告 `state=PRESENT host=PRESENT`，90 毫秒后却出现 `target=false`，见 [窗口转换日志](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-trace/window-transition.log)。这确认无障碍窗口元数据与可读取节点树异步变化，先前“ID 存在，目标为 null 就关闭”的处理仍有竞争条件。

修正后改为宿主优先；目标暂不可读时再次核验来源并等待，只有实际有效目标恢复才取消等待计时。待执行动作期间不因两次节点查询之间再次失效而重置 30 秒期限。临时 `AHFocusProbe` 日志已从生产代码删除。随后 [direct-dialog-fixed](../build/diagnostics/telegram-copy-0.6.1/direct-dialog-fixed/verification.log) 端到端探针通过：Dialog 期间未调用 Copy，关闭后仅一次 Copy / 一次宿主写入，最终选文与 ActionHalo 标签均正确。这是合成宿主上的实证，不是用户 vivo 顶部翻译提示的复现。

新增第 14 项后的测试首轮还暴露了窗口分类的明确边界：源 Activity 关闭后，若露出来的仍是另一处后台残留的小 Dialog，`SourceWindowState` 无法只凭窗口几何确定源已关闭，会归为 `OBSCURED` 并等到 30 秒期限，而不会立即清理。等待期间原来源未恢复，禁止读取或执行旧操作。不能把这个条件描述成“所有来源关闭都会立即取消”；恢复为完整应用窗口才可明确判断替换，未知小窗口只能限时等待。首次两个取消断言失败按原样保留。清理本任务的合成 Telegram 宿主并返回 HOME，建立明确的全屏返回目标后，最终 14 项全部通过；这并不消除上述未知小窗口边界。

额外的可聚焦 PopupWindow 对照 `--mode partial` 未通过初始圆环检查。框架只暴露聚焦 popup，`hasParent=false`，宿主不在可访问窗口列表中；因此本版无法验证同源子菜单，不显示圆环，探针没有发送触摸。该模式不同于所检查 Telegram FloatingToolbar 的默认非聚焦路径。保留 [失败窗口记录](../build/diagnostics/telegram-copy-0.6.1/direct-partial/windows-before.txt)，不能据此宣称所有客户端和菜单均支持。

最终打包复测还曾发现 Dialog 关闭后原圆环被重新创建、待执行动作丢失，见 [失败窗口](../build/diagnostics/telegram-copy-0.6.1/final-direct-dialog/windows-after.txt)。原宿主和原菜单最终都恢复，但发布时间不同；现沿用既有 60 / 260 ms 两阶段刷新，早期缺失先保留，稳定刷新后再确认取消。等待期间仍须有效原 Copy 控件才能执行。

## 最终交付核对

- APK：[ActionHalo-0.6.1-debug.apk](../build/ActionHalo-0.6.1-debug.apk)，版本 0.6.1 / code 9，1,109,495 字节。
- SHA-256：`7655c206f07c309245a411c6e4780b169c019ea0e75c02941693f3682ebcb9c2`。
- 签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与本机 0.6.0 APK 一致，可覆盖安装。仍为开发用 debug 签名。
- 最终构建成功，42 项 JVM 测试与 14 项真实窗口焦点测试通过。完整设备回归早先通过 44 项、跳过 6 项单独启用的诊断；之后新增一项并重跑焦点类，不能把跳过算成实际通过。
- 直选圆环合成往返通过：动画比例 0（[核对](../build/diagnostics/telegram-copy-0.6.1/direct-scale0/verification.log)）、非聚焦菜单并发原生 Copy 事件（[事件](../build/diagnostics/telegram-copy-0.6.1/direct-nonfocusable/events.log)）、不写入新剪贴板（[拒绝旧内容](../build/diagnostics/telegram-copy-0.6.1/direct-no-write/verification.log)）、菜单出现后但操作前的旧内容（[拒绝旧内容](../build/diagnostics/telegram-copy-0.6.1/direct-menu-stale/verification.log)）、圆环中心取消（[零复制事件](../build/diagnostics/telegram-copy-0.6.1/direct-cancel/events.log)）。
- 最终 APK 重跑通过：真实 Dialog 连续三次（[第 1 次](../build/diagnostics/telegram-copy-0.6.1/final-dialog-repeat-1/verification.log)、[第 2 次](../build/diagnostics/telegram-copy-0.6.1/final-dialog-repeat-2/verification.log)、[第 3 次](../build/diagnostics/telegram-copy-0.6.1/final-dialog-repeat-3/verification.log)），每次均只有一个 Copy / 一次宿主写入，ActionHalo 精确文字往返成功；[取消](../build/diagnostics/telegram-copy-0.6.1/final-direct-cancel/events.log)零 Copy，[旧剪贴板](../build/diagnostics/telegram-copy-0.6.1/final-direct-menu-stale/verification.log)仍正确拒绝。
- 用户 vivo / 真实 Telegram 回测：未进行。顶部翻译提示是否实际持有输入焦点：未确定。模拟器为 API 35，未以它替代 API 36 真机结果。

`build/` 下证据与 APK 为本机生成文件，不保证随源码分发。此前版本证据保留在 [0.6.0 记录](telegram-copy-0.6.0.md)，兼容性范围见 [Telegram 兼容性核对](telegram-compatibility.md)。
