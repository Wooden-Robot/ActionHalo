# Android 8–16 兼容回归

2026-10-11，交付版本 **0.7.12 / versionCode 22**，minSdk 26、targetSdk 36。

## 本轮修复

Android 8、11 的真实系统选文工具条保留 `android:id/floating_toolbar_menu_item_text`，却没有新版工具条的 `android:id/floating_popup_container`。旧实现及旧测试只认外层容器，无法发现这类工具条。0.7.12 同时识别两种框架标识。

识别仍限定前台来源的同包子窗口、有效父窗口和唯一 Copy 控件。发现圆环时不复制、不读取剪贴板；选择动作后才请求原应用复制。没有系统工具条标识的普通 Copy 弹窗仍被拒绝。没有放宽应用正文扫描、敏感控件或剪贴板时效检查。

Android 8 镜像中的旧 WebView 只提供可读标签，选文事件范围为 `0:0`，节点范围为 `-1:-1`，没有可用的正文文本。它无法通过原生选区监听自动弹出；启用已有的「通用选文菜单兼容」后，本轮新增测试通过真实工具条验证直接弹出。没有把标签推测成选中文字。

## 回归覆盖

- 原生输入框、只读文字、WebView 的真实长按；事件选区与新节点范围不一致的竞态。
- 真正显示输入法窗口后，保留选区并通过圆环复制准确 Unicode 文本。
- `KEYCODE_SLEEP` 让屏幕实际关闭，确认原圆环 View 已脱离窗口；唤醒后旧圆环不复活，新选择可以再次显示。
- 真正解绑无障碍服务后清掉圆环，重新绑定后处理新的真实选文。
- 临时应用弹窗、失焦、来源关闭、授权撤回、陈旧剪贴板拒绝和单次执行。
- 普通/GTA 圆环、首次定位、固定中心、远距离方向、外部点击关闭、分页、图标与序号布局、长按排序及原生拖拽取消。

仅在显式启用且硬件和型号都符合 Google 模拟器的环境修改测试设置；结束恢复原设置。外部宿主使用不同 UID 和固定合成文字，未连接用户手机或读取真实聊天。

## 测试夹具修正

- Android 8 的 `dumpsys accessibility` 在 UI 自动化服务存在时会自行抛异常。服务准备检查改用公开的启用服务列表和真实连接状态。
- 熄屏后的无障碍列表可能保留无内容的旧窗口记录；改为检查旧 View 实际脱离窗口，恢复后也检查没有圆环重新出现。
- 旧系统会对快速注入的移动进行重采样；触摸测试等待两个真实显示帧后再注入下一事件。
- 键盘设置仅在键盘测试内临时开启；生命周期测试先明确折叠再选中，保证产生新事件。
- 拖拽测试在可见列表内部松手，取消使用公开的 `View.cancelDragAndDrop()`。Android 11 的触摸 CANCEL 注入会导致原生 drop，取消后再注入事件也可能因接收器已移除而失败。
- 复制测试等待 `ACTION_DISPATCHED`，避免在原工具条已关闭、执行浮层尚未出现的短暂间隔读取中间剪贴板。

## 本机结果

通过数只计真正执行成功的项目，不把 JUnit 的 assumption 跳过或 SDK 过滤算作通过。

| 系统 | 全量测试 APK | 全量结果 | 0.7.12 修复验证 |
|---|---|---|---|
| Android 8 / API 26 | 0.7.12 | 71 通过、25 跳过；另 6 项 SDK 过滤 | 包含旧 WebView 通用菜单、键盘、锁屏和重连；[全量结果](../build/diagnostics/compatibility/api26-verified.txt) |
| Android 11 / API 30 | 0.7.12 | 100 通过、1 跳过；取消夹具 1 项随后修正 | 取消复测 1 项通过，最终覆盖 101 项通过；[全量](../build/diagnostics/compatibility/api30-final.txt)、[取消复测](../build/diagnostics/compatibility/api30-cancel-verified.txt) |
| Android 13 / API 33 | 0.7.12 | 101 通过、1 跳过 | [全量结果](../build/diagnostics/compatibility/api33-all.txt) |
| Android 15 / API 35 | 0.7.11 + 新回归夹具基线 | 100 通过、1 跳过 | 0.7.12 工具条、误触发、撤回授权、键盘、锁屏、重连 6 项复测通过；[基线](../build/diagnostics/compatibility/api35-all.txt)、[修复复测](../build/diagnostics/compatibility/api35-fix-regression.txt) |
| Android 16 / API 36 | 0.7.11 + 新回归夹具基线 | 101 通过、1 跳过 | 0.7.12 工具条准确复制和普通 Copy 弹窗拒绝 2 项通过；[基线](../build/diagnostics/compatibility/api36-final.txt)、[修复复测](../build/diagnostics/compatibility/api36-fix-regression.txt) |

最终构建、52 项 JVM 测试和 Lint 全部通过，见 [构建日志](../build/diagnostics/compatibility/verified-build.txt)。Android 9、10、12、12L、14 等其余矩阵版本尚未在本机执行。上表区分基线和补丁复测，不把不同 APK 的测试合并成同一份全量通过报告。

## 自动化矩阵

[Android 工作流](../../.github/workflows/android.yml) 日常 push / PR 运行 API **26、30、36**，分别覆盖最低支持版本、旧版选文工具条与受限剪贴板路径、当前目标版本。每周一 **03:23（台北时间，UTC 周日 19:23）**及手动运行覆盖 API **26–36** 全版本。各版使用 Google APIs 模拟器并保存设备测试报告；API 27 使用 x86，其余版本使用 x86_64。独立构建任务继续执行编译、单元测试和 Lint。矩阵最多并行 3 个任务，单个版本失败不取消其他版本。仅 Android 代码、配置或该工作流变更触发 push / PR 检查，纯 Markdown 文档修改不触发。

使用 [Android Emulator Runner 官方配置](https://github.com/ReactiveCircus/android-emulator-runner) 启动一次性模拟器；不依赖厂商私有 API。配置的版本不能列为已通过，执行结果以对应 CI 报告为准。

本地同等命令（只连接一次性模拟器时运行）：

```bash
cd android
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.selection_diagnostics=true \
  -Pandroid.testInstrumentationRunnerArguments.focused_clipboard_overlay=true \
  -Pandroid.testInstrumentationRunnerArguments.accessibility_settings_diagnostics=true
```

`FocusedClipboardOverlayTest` 的 22 项针对 Android 10+ 的跨 UID 剪贴板限制，较旧系统跳过；`ActionManagementUiTest` 的 6 项依赖 API 29 的 `WindowInspector`，较旧系统不发现这些测试。Android 8、8.1 另跳过 `clearPrimaryClip` 测试。旧 WebView 不公开文本时跳过原生选区测试，并单独执行通用菜单正例。真实 Via 需要显式提供本地固定网页和已安装浏览器，本轮未执行，不把跳过算作通过。

## 品牌真机边界

本机使用 Apple Silicon 上的官方 ARM64 模拟器，不代表 vivo、OPPO、华为/荣耀、小米、三星等品牌真机验证。尤其无法用 AOSP 的锁屏测试证明厂商不会撤销无障碍授权，也未在本轮重新验证真实 Telegram、X 或豆瓣的最新版本。

真机需继续核对：首次授权与覆盖升级；目标应用选文；键盘及翻译提示打断；锁屏等待后重新选文；切换应用与外部点击退出；字体/显示缩放和横屏。不能由模拟器型号伪装得出品牌兼容结论。

## 安装包

通用 debug APK：`ActionHalo-0.7.12-debug.apk`，**1,032,562 bytes**。未包含 ABI 原生库，无需按 32/64 位拆包。签名验证通过，与 0.7.11 相同，覆盖安装保留配置。

- APK SHA-256：`9e560b2bf0372ea0f62dcac66260325e1439b57409882a79b133a237f2cc5a93`
- 签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`

原始构建及设备结果保存在 `android/build/diagnostics/compatibility/`；该目录不进入版本控制。
