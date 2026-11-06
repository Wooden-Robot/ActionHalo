# 进入无障碍总列表后服务关闭：证据与诊断边界

核对日期：2026-10-10。用户设备为 vivo X200s（V2458A，Android 16 / SDK 36）。早期反馈是锁屏或放置后关闭；经过对照，用户最新明确：前台、后台对照均正常，打开系统无障碍**总列表**就会实际关闭 ActionHalo 服务。当前应以这一更具体的触发条件为准，不再将后台回收作为已确认原因。尚未连接该手机获取系统日志，不能认定某个 Android 标准行为就是这台手机的实际原因。

## 已核对的 Android 行为

以下源码链接固定到 AOSP `android-15.0.0_r1`，不使用随时变化的主分支。它们说明参考系统的行为，不能替代 OriginOS 的实现或真机记录。

| 情况 | 参考系统行为 | 能得出的结论 |
| --- | --- | --- |
| 普通进程死亡、服务 Binder 断开 | `binderDied()` 标记服务为 crashed；`serviceDisconnectedLocked()` 移除已绑定连接并加入 crashed 集合，没有在这条路径删除启用名单 | 服务不可用与授权关闭是两种状态；仅凭进程死亡不能推断系统开关一定变成关闭 |
| 包被强制停止（force-stop） | 从 enabled、binding、crashed 集合移除对应服务，再写回 `ENABLED_ACCESSIBILITY_SERVICES` | 这条路径确实会撤下启用状态；进程退出记录仍需确定是否发生了它 |
| 服务调用 `disableSelf()` | 从 enabled 集合移除自身并持久化设置 | 应用可以主动关闭自己；ActionHalo 0.5.0 生产代码没有调用该方法，也没有写入系统无障碍启用名单 |

原始源码：

- [AccessibilityServiceConnection.java:452：Binder 死亡处理](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityServiceConnection.java#452)。
- [AccessibilityUserState.java:287：断开连接后加入 crashed 集合](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityUserState.java#287)。
- [AccessibilityManagerService.java:818：强制停止后移除并保存启用状态](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityManagerService.java#818)。
- [AccessibilityServiceConnection.java:201：disableSelf](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityServiceConnection.java#201)。

早期“锁屏后真 OFF”的描述曾引出强制停止或厂商回收启用状态的假设，但没有确认其中任何一种；最新对照已将实际触发条件定位为进入系统无障碍总列表。崩溃、内存回收、用户关闭、后台限制和安装更新也不能仅凭一个“未连接”状态区分。

## vivo 官方指导

[vivo 官方无障碍问答](https://www.vivo.com/qa/en/support/questionList?categoryId=54313) 中有两条相关问答：

- FAQ 77611，`Why is the accessibility switch of the app always turned off automatically?`
- FAQ 77596，`Accessibility is automatically disabled`

已核对这两条的完整正文。它们将应用兼容性及耗电列为可能原因，建议允许应用后台高耗电、允许自启动，并加入一键加速白名单。官方页面的公开内容接口为 `POST /qa/en/support/questionById`，参数分别为 `id=77611`、`id=77596`；这里只读取问答，没有发送反馈或用户资料。

给 X200s 的最小操作指引是：在系统设置搜索“后台耗电管理”或“后台高耗电”，找到 ActionHalo 并选择允许；再检查“自启动”以及“一键加速”白名单。国际站说明中的菜单名称不保证与当前 OriginOS 完全相同，应用不能把打开某个设置页当作用户已经完成设置，也不能把 Android 电池优化豁免状态当作 vivo 三项设置的状态。

这些是早期后台假设下的官方排查建议，不是 ActionHalo 在此机型上的修复证明。最新触发条件已转向进入系统无障碍总列表，不再要求用户重复后台设置对照。不要为排查而让用户关闭整机安全保护、授予隐藏权限或恢复出厂设置。

## 0.5.1：设置入口和最小诊断

0.5.1 补齐了后台设置指引和可供用户查看的生命周期、进程退出诊断。没有新增空前台服务、定时唤醒、隐藏悬浮窗或自动写入无障碍启用名单的逻辑。

设置入口使用公开 API，并处理目标页面不存在的情况：

- `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` 打开系统电池优化列表。
- `ACTION_APPLICATION_DETAILS_SETTINGS` 配合自身 `package:` URI 打开应用信息。
- `ACTION_ACCESSIBILITY_SETTINGS` 打开无障碍设置。

这些入口的定义见 [Android Settings API](https://developer.android.com/reference/android/provider/Settings)。vivo 的自启动、高耗电和清理白名单没有在本次调研中找到稳定的公开专用跳转契约，因此不硬编码未经真机验证的厂商 Activity。

诊断应分别表示“系统启用名单中是否有自身服务”“本进程中的服务是否已经连接”，保留有限的生命周期时间和状态。进程被杀时不保证收到 `onDestroy()` 或其他回调；再次打开应用时需要结合 Android 11/API 30 及以上的自身进程退出历史，而不能只读旧的 connected 布尔值。

[ApplicationExitInfo 官方 API](https://developer.android.com/reference/android/app/ApplicationExitInfo) 提供退出时间、原因码、信号或退出状态、进程重要性等信息，解释时必须保留以下限制：

- `REASON_USER_REQUESTED` 覆盖强制停止、移出最近任务等情况，旧系统还可能用于包更新；不能据此声称是用户亲手关闭了权限。
- `REASON_SIGNALED` 和 `SIGKILL` 不能独立证明低内存；部分设备没有专门的低内存退出上报。
- `getDescription()` 可能为空，格式不跨设备或版本稳定；不把其中字符串当作可靠分类规则。
- 系统没有提供明确原因时显示未知，不用“省电杀后台”补全缺失证据。

最小诊断无需读取或保存选中文字、聊天正文、剪贴板、其他应用列表、浏览历史或完整堆栈。可见结果应说明这是系统报告或本应用观察到的状态，不能将时间相邻直接写成因果关系。

## 为什么本轮不直接加“保活服务”

AOSP 的无障碍绑定包含 `BIND_FOREGROUND_SERVICE_WHILE_AWAKE`，见 [AccessibilityServiceConnection.java:157](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityServiceConnection.java#157)。该标志只在设备唤醒时提供相应进程状态待遇。常驻前台服务能够影响进程重要性，但不代表一定改变 OriginOS 的后台清理策略，更不能恢复已经关闭的授权。参考 [Android 进程生命周期](https://developer.android.com/guide/components/activities/process-lifecycle)。

[Android Doze 指引](https://developer.android.com/training/monitoring-device-state/doze-standby) 明确要求不要仅为避免应用进入空闲状态而启动前台服务。`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 也只申请部分 Doze/App Standby 豁免，不等同于厂商后台白名单或无障碍授权；当前尚未证明标准 Doze 破坏 ActionHalo 的亮屏选文功能，所以本版不直接新增该申请权限。

若后续真机证据支持持续前台执行的需要，应设计用户明确启动、能停止、带真实状态通知的功能，并据用途声明 [specialUse 类型](https://developer.android.com/develop/background-work/services/fgs/service-types#special-use) 及 subtype。该类型不是无限保活豁免，发布审核另有要求。[Android 允许用户停止正在执行的前台服务应用](https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping)，停止时还可能没有应用回调。

## 验证边界

模拟器可以验证启用状态和连接状态的区分、生命周期记录、自身进程退出历史读取、设置跳转和强制停止的参考行为。即使这些检查全部通过，也不能宣布 vivo 进入无障碍总列表后权限关闭已经修复。

真机后续验证应围绕已确认的总列表入口，比较进入前后启用名单、服务连接与生命周期记录。重新开启前先保留诊断，避免丢失状态差异。无需用户提供聊天内容或账户信息。若有 ADB 环境，可进一步核对自身组件是否仍在 `enabled_accessibility_services`、是否绑定，以及对应进程退出记录；不要通过写入该设置来掩盖故障或绕过用户授权。


### 0.5.1 实际验证

Android 15/API 35 专用模拟器上验证：首次读取为关闭；开启服务后连接记录与启用名单均为开启；短暂锁屏记录 SCREEN_OFF，授权保持开启；对测试应用执行 force-stop 后系统移除启用项，再打开首页能读取之前的记录并新增观察到关闭的时间。没有将短暂锁屏误报为权限回收。此检查不等同于 vivo 长时间待机测试。

39 项 JVM 单元测试通过；设备回归 19 项通过、6 项需要显式启用的选文诊断跳过；新增首页复制报告测试确认报告不包含原剪贴板中的合成私密标记。Lint 0 错误、5 项原有警告。证据存于本机 android/build/diagnostics/service-health-0.5.1/。


## vivo Android 16 用户报告：手动反复重开后的解绑

0.5.1 真机报告显示 vivo V2458A、SDK 36，系统启用名单关闭、服务列表未列出、当前未连接，Android 电池优化已豁免。最近退出记录为更早的 PACKAGE_UPDATED，没有本轮对应的崩溃退出记录。约半分钟内有四组 CONNECTED → UNBOUND → DESTROYED，连接至解绑间隔约 1.3–13.7 秒。用户明确说明每次连接均来自自己手动重新打开，不能把这组记录解释为服务自主重连。所保留的这几组记录中没有 SCREEN_OFF。

这些证据支持先排查启用状态被撤销及正常解绑，不能认定是普通后台进程回收。PACKAGE_UPDATED 是升级退出类别，不能作为本轮崩溃的证据。Telegram 计数在每次服务连接时会重置，报告中的零仅针对最近一次连接，不能证明此前复制按钮一直没有事件。

补查 [AOSP Android 16 管理服务](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityManagerService.java)、[连接管理](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityServiceConnection.java) 与[安全策略](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilitySecurityPolicy.java)：普通 binderDied 不删除 enabled 集；系统设置写入、disableSelf、force-stop、DPM 禁止、安装服务列表失去组件等可走不同的关闭路径。BIND_ACCESSIBILITY_SERVICE AppOp 拒绝可导致服务不被纳入已安装列表；ACCESS_ACCESSIBILITY 拒绝主要挡数据访问，两者不可混同。没有证据能把本报告具体归因于其中某一条或 vivo 的未公开实现。

用户目前只能在手机上操作。连续两份报告显示，最后一次 CONNECTED 到后一次检查相隔约 74 秒，期间保持首页前台，授权与连接均开启，没有新增解绑记录。用户随后确认前后台对照都正常，进一步确认触发动作是打开系统无障碍总列表，并非仅打开 ActionHalo 服务详情页。此项最新证据替代此前“待后台对照”的排查安排；后台保活方向搁置。

### 已核对的 Android 16 设置页面行为

以下源码固定到 AOSP `android-16.0.0_r1`：

- [AccessibilitySettings.java](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/tags/android-16.0.0_r1/src/com/android/settings/accessibility/AccessibilitySettings.java)：总列表 `onResume()` 刷新偏好显示，没有因为进入页面而临时解绑或删除服务启用项的流程。
- [ToggleAccessibilityServicePreferenceFragment.java](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/tags/android-16.0.0_r1/src/com/android/settings/accessibility/ToggleAccessibilityServicePreferenceFragment.java)：详情页从实际启用名单刷新开关，`onCheckedChanged()` 会与实际状态比较；程序刷新为相同状态不会自行关闭服务。关闭服务通过确认操作调用 `onPreferenceToggled()`，再写服务状态。
- [ToggleFeaturePreferenceFragment.java](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/tags/android-16.0.0_r1/src/com/android/settings/accessibility/ToggleFeaturePreferenceFragment.java)：初始化、恢复开关显示与快捷方式选项不能混同于用户授权服务。

因此，不能将用户遇到的实际关闭描述为 Android 进入设置页面时正常的临时解绑。AOSP 参考实现也不能证明 vivo 使用相同逻辑，更不足以确定 OriginOS 的具体关闭机制或设置写入者。

对 ActionHalo 生产代码的只读复核未发现 `disableSelf()`、组件启停、系统启用名单写入、动态修改 `serviceInfo/packageNames` 或向系统界面注入点击。MainActivity 返回前台只刷新状态；选文服务在窗口变化时清理旧圆环；`onUnbind()` / `onDestroy()` 在系统解绑后记录状态并释放本地资源。未发现“进入总列表 → 应用主动撤销授权”的路径。0.5.1 两处同意对话框在服务已启用时仍无条件跳转总列表，是可以确定修正的多余导航。

## 0.5.2 限定方案：避免重复进入总列表

本轮只调整应用发起的导航，不声称修复用户手动进入 vivo 无障碍总列表后的关闭：

1. 首次同意自动选文、同意 Telegram 复制模式后，先读取本应用无障碍授权状态；已开启时留在首页，不再无条件打开系统设置。
2. 用户点击设置按钮时，若系统授权已开启，先显示“权限已开启”状态框并留在首页；只有用户另行点击打开系统设置，才调用公开的 `ACTION_ACCESSIBILITY_SETTINGS` 进入总列表。
3. 系统授权未开启时，仍正常打开公开的无障碍总列表供用户授权。最终生产实现不使用隐藏详情入口，也不尝试申请其受限权限。

该方案减少已授权用户从 ActionHalo 重复进入设置的机会，不绕开系统无障碍总列表，也不能阻止用户手动进入列表后发生的实际关闭。

### 已放弃的隐藏详情入口及实际失败证据

实现过程中曾尝试隐藏 action `android.settings.ACCESSIBILITY_DETAILS_SETTINGS` 配合 `Intent.EXTRA_COMPONENT_NAME` 的 flattened String，期望直接导航到自身服务详情页。Android 15 / API 35 专用模拟器上实际点击后，该 intent 能解析到 `com.android.settings/.Settings$AccessibilityDetailsSettingsActivity`，但启动抛出 `SecurityException`，系统日志明确要求 `android.permission.OPEN_ACCESSIBILITY_DETAILS_SETTINGS`。这不是“找不到页面”，`resolveActivity()` 成功也不代表调用方能启动该组件。

补查固定 AOSP Manifest 后确认：Android 15 与 16 的该权限均为 `signature|installer`，注释明确不供第三方应用使用；两版 Settings 详情 Activity 都在组件上要求此权限。普通 ActionHalo 不能仅靠声明 `uses-permission` 获得它，不应绕过检查。

- [Android 15 framework 权限定义](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/core/res/AndroidManifest.xml#5190)与 [Settings Activity 权限要求](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/tags/android-15.0.0_r1/AndroidManifest.xml#2352)。
- [Android 16 framework 权限定义](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/res/AndroidManifest.xml#5606)与 [Settings Activity 权限要求](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/tags/android-16.0.0_r1/AndroidManifest.xml#2540)。

此前仅核对 action 定义、参数与入口 Fragment，遗漏了组件启动权限；现据实际点击和 Manifest 契约放弃此路径。截获 intent 的导航测试只能证明应用发出的参数，不能证明系统页面实际可打开。

0.5.2 最终方案重新构建并验证：39 项 JVM 测试通过；Android 15/API 35 模拟器设备回归 25 项通过，另 6 项选文诊断按默认参数跳过。六项新导航测试均通过，覆盖真实服务已绑定时两种同意流程不导航、未授权时两种公开设置请求、已授权时权限管理的确认和取消。修复前两种已授权同意流程的“不应导航”断言均实际失败，修复后通过。Lint 0 错误、5 项原有警告；APK 签名验证通过，与 0.5.1 使用同一签名。证据位于 android/build/diagnostics/settings-navigation-0.5.2/，最终设备记录为 final-device-tests.txt。

当前没有 vivo 真机修复证据；本节方案不解决 Telegram 部分选文复制事件缺失，也不自动恢复已关闭的系统授权。

### 可选的只读 ADB 状态探针

将来有设备连接时可用 `collect-service-state.py`，不要求当前手机用户执行。只采样 ActionHalo 的启用/连接列表状态、匿名化的进程代次、三个相关 AppOps 的前后模式，以及少数固定类别的系统日志信号；不写权限、不安装或停止应用，不导出原始服务列表、日志正文、序列号、剪贴板或无障碍树。设备 serial 必须显式指定。

```sh
python3 android/diagnostics/collect-service-state.py --self-test
python3 android/diagnostics/collect-service-state.py --serial DEVICE_SERIAL --seconds 30 --output /tmp/actionhalo-service-state.json
```

本轮只实际运行了探针解析与隐私过滤自测，通过；没有连接真机运行采集。缺失或不完整的系统输出保留未知，日志信号可能早于采样且不保证能指出系统设置的写入者。


### 前台服务候选已搁置

此前曾为“仅后台关闭”的待验证假设评估同一 SelectionAccessibilityService 作为 started + bound 的 specialUse 前台服务；该候选从未实现。用户最新确认前后台均正常、进入无障碍总列表才实际关闭后，本轮不再需要沿此方向增加保活、常驻通知或 FGS 权限。前台服务不能恢复撤销的授权，也没有证据表明它能改变进入系统菜单这一触发条件。
