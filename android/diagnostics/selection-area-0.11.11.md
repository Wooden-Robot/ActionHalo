# Android 0.11.11 整段选文周边防误触

## 范围

用户明确要求：拖动选中文字及周边区域时不触发圆环触摸重新定位，保留其他位置的重新定位。0.11.10 已能让触摸穿透手柄区域，但几何计算只取选区首尾字符，两个端点之间仍存在未保护的空隙。

`HaloSafeArea.selectionProtectionBounds` 合并选中范围内系统返回的可见字符矩形，再向左右各扩 32dp、上下各扩 40dp。这样单行中间、多行中间和相邻空白均受到保护，不依赖首尾字符落在同一行。仅请求字符位置，不读取或保存正文；保留非有限坐标过滤与来源边界裁剪。按 Android [字符位置接口](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_MAX_LENGTH)的单次 20,000 字符上限分批；沿用现有 32,768 字符选区上限。

没有字符坐标时，将已知手柄窗口的保护矩形合并为一个包围区域，补上两个手柄之间的空隙。此回退只能估计范围；完全不公开字符及手柄几何的应用仍无法准确定位选文，不以整个编辑器或屏幕代替选区。

原生选文与菜单兼容入口同时改用此计算，原有 `handles` 字段更名为 `protectedAreas`。`SelectionHaloWindow` 的局部触摸穿透、窗口尺寸、展开规则和重新定位实现未改。Android 8–12L 的整体避让回退继续沿用，空间不足时仍可能隐藏圆环。

## 验证

- 修改前，真实 Android 文本控件的三项测试均失败：单行选文中间、多行中间、缺少字符坐标时的手柄间文字。保护区内的触摸使窗口宽度从 1036 变为全屏 `MATCH_PARENT`，重现误启动圆环操作。日志：`/private/tmp/actionhalo-selection-area-red.log`，12.274 秒。
- 测试同时检查选文上方缓冲区拒绝重新定位、保护范围外仍可重新定位，并保持剪贴板不变。使用真实来源节点几何与窗口触摸分发；实际输入穿透和手柄拖动由既有真实浮窗用例覆盖。
- 第一轮修复后六项测试中五项通过，一项回退测试失败。坐标探针确认它读到调整前的手柄位置：文字右侧已到 812，旧手柄保护区右侧仍为 414。测试现等待原生手柄确实跟随新选区后再验证，没有更改防误触或范围外重定位断言。记录：`/private/tmp/actionhalo-selection-area-green.log`、`/private/tmp/actionhalo-selection-area-fallback-probe.log`。
- 最终六项定向测试通过，36.255 秒：`/private/tmp/actionhalo-selection-area-final-targeted.log`。
- 最终 32 项相关交互回归全部通过，164.514 秒，无跳过。覆盖手柄拖动、原生及菜单入口重定位、无字符坐标回退、聊天及厂商菜单夹具、键盘和服务重连：`/private/tmp/actionhalo-selection-area-regression.log`。
- 61 项 JVM 测试通过；Lint 0 错误、6 项警告。最终构建：`/private/tmp/actionhalo-selection-area-final-build.log`；`git diff --check` 通过。本次未重跑整个 Android 测试集。

## 交付

- `ActionHalo-0.11.11-debug.apk`：versionCode 47，minSdk 26，targetSdk 36；1,267,523 字节。
- SHA-256：`3f14c5f26ceae601e21add4d8e82c7755528cbdc929720bc2a0e2c4b8857f5cd`，另存于 `ActionHalo-0.11.11-SHA256SUMS.txt`。
- ZIP 完整性及 APK v2 签名校验通过，签名与 0.11.10 相同，可覆盖安装。交付字节与本次回归使用的生产 APK 一致。

本次使用 API 35 无账号模拟器和固定测试文字。未连接用户 vivo 真机；真实微信、原子笔记及 SDK 36 的效果未实测。未提交、推送或远程发布。
