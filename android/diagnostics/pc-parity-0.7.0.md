# Android 0.7.0：PC 功能对齐与选文菜单兼容

记录日期：2026-10-10。目标版本为 `0.7.0` / `versionCode 10`。本文区分仓库代码与官方路由证据、设备验证结果和未实现能力，不把启动请求成功等同于外部应用已经显示搜索结果。

## 功能对照

本仓库的 PC 实现是 macOS 版。Android 保留原有复制、Google 搜索、翻译、打开链接、分享、百度与豆瓣综合搜索，新增下列六个可选搜索。六项均默认关闭，用户可在首页分别启用。

| 功能 | PC 代码中的行为 | Android 0.7.0 | 代码依据 |
| --- | --- | --- | --- |
| 豆瓣读书 | 官方图书分类网页搜索 | 新增，同一网页分类路由 | [PC 配置](../../Plugins/DoubanBook.actionhaloext/Config.json)、[Android 配置](../app/src/main/java/com/actionhalo/android/ActionStore.kt) |
| 豆瓣电影 | 官方电影分类网页搜索 | 新增，同一网页分类路由 | [PC 配置](../../Plugins/DoubanMovie.actionhaloext/Config.json)、[Android 配置](../app/src/main/java/com/actionhalo/android/ActionStore.kt) |
| NeoDB 书影音 | 综合搜索；目录虽叫 `NeoDBBook`，实际未限定书籍 | 新增综合搜索，对齐 PC 当前行为 | [PC 配置](../../Plugins/NeoDBBook.actionhaloext/Config.json)、[Android 配置](../app/src/main/java/com/actionhalo/android/ActionStore.kt) |
| NeoDB 书籍 | 当前 PC 配置没有单独书籍过滤项 | 新增 `c=book` 书籍过滤，独立于综合项 | [Android 配置](../app/src/main/java/com/actionhalo/android/ActionStore.kt)、下文官方证据 |
| GitHub 搜索 | `https://github.com/search?q=…` | 新增，同一网页搜索 | [PC 配置](../../Plugins/GitHubSearch.actionhaloext/Config.json)、[Android 配置](../app/src/main/java/com/actionhalo/android/ActionStore.kt) |
| Telegram 搜索 | 原生命令打开搜索并校验、输入关键词 | 新增，使用 Android 官方客户端支持的带词深链 | [PC 配置](../../Plugins/Search%20Telegram.actionhaloext/Config.json)、[Android 路由](../app/src/main/java/com/actionhalo/android/TelegramSearch.kt)、[执行器](../app/src/main/java/com/actionhalo/android/ActionExecutor.kt) |

新增搜索不改变旧操作的 `enabled_*` 开关，也不重写 `custom_actions`。原有豆瓣综合入口保持原生优先：显式指定 `com.douban.frodo`，打开 `douban://douban.com/search/result?q=…`，不可启动时回退官方综合网页。豆瓣读书、电影两个新增分类项走网页，不以未经核实的原生分类参数代替。所有选文均作为编码后的单个查询值，不允许选文改变目的域名或注入新参数；自定义网址仍仅接受 HTTP(S)。

## 搜索路由证据与边界

豆瓣官方[读书首页](https://book.douban.com/)与[电影首页](https://movie.douban.com/)的搜索表单分别使用：

```text
https://search.douban.com/book/subject_search?search_text={text}
https://search.douban.com/movie/subject_search?search_text={text}
```

这与 PC 插件配置一致。官方 APK 可见 `douban://douban.com/search/result?t=%s&q=%s` 模板字符串，但没有充分证据确定 `t` 对应书籍和电影的值，因此本版没有猜测该参数。综合原生搜索路由的来源是[豆瓣官方热搜接口](https://m.douban.com/rexxar/api/v2/chart/hot_search_board)。外部网页的登录、验证与可访问性仍由豆瓣决定。

NeoDB 使用下列两个独立入口：

```text
https://neodb.social/search/?q={text}
https://neodb.social/search/?q={text}&c=book
```

NeoDB 官方仓库固定提交 [`b5cb29296c51cb9946b2d5cf23852d822b8e48d8`](https://github.com/neodb-social/neodb/commit/b5cb29296c51cb9946b2d5cf23852d822b8e48d8)的[分类模板](https://github.com/neodb-social/neodb/blob/b5cb29296c51cb9946b2d5cf23852d822b8e48d8/neodb/catalog/templates/search_header.html#L17-L24)以 `c=book` 生成书籍链接，[搜索处理](https://github.com/neodb-social/neodb/blob/b5cb29296c51cb9946b2d5cf23852d822b8e48d8/neodb/catalog/views/search.py#L261-L269)将该参数转为分类过滤条件。`/search/` 保留查询参数重定向 `/search`；这里核实的是源码路由，不能据此宣称某次在线请求已返回结果。

Telegram 使用 `ACTION_VIEW` 和 `tg://search?query=<编码关键词>`，依次明确指定 `org.telegram.messenger`、`org.telegram.messenger.web`。依据是官方 12.10.6 固定提交 [`f2908b14133bbffbf7ab04f641ecb5bfaf533242`](https://github.com/DrKLO/Telegram/commit/f2908b14133bbffbf7ab04f641ecb5bfaf533242)的 [LaunchActivity 处理分支](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/LaunchActivity.java#L2631)，详见 [Telegram 搜索入口核验](telegram-search.md)。第一个官方包不可用或被系统拒绝时尝试第二个；两者均失败则提示不可用，不发送消息，也不把关键词改投其他网站。未登录、锁定状态、第三方客户端和未来版本需要各自验证。

## 配置与圆环交互

[ActionStore](../app/src/main/java/com/actionhalo/android/ActionStore.kt)取消总启用数量为 8 的限制；[RadialMenuView](../app/src/main/java/com/actionhalo/android/RadialMenuView.kt)每页最多显示 8 项，通过下方箭头翻页，提供真实按钮供无障碍操作。新自定义网址默认启用，超出第一页的项目进入后续页面。早期版本已保存的豆瓣关闭状态及其他操作设置继续保留。当前仍按内置列表和自定义列表顺序显示，本版没有增加 PC 的自定义排序功能。

[HaloAppearance](../app/src/main/java/com/actionhalo/android/HaloAppearance.kt)将全部入口的菜单上限统一为 `MENU_SIZE_DP = 400`。首页、选文/分享和手动剪贴板入口经 [HaloActivity](../app/src/main/java/com/actionhalo/android/HaloActivity.kt)使用该值；普通自动选区与复制菜单入口分别由 [SelectionAccessibilityService](../app/src/main/java/com/actionhalo/android/SelectionAccessibilityService.kt)和 [TelegramCopyAssistant](../app/src/main/java/com/actionhalo/android/TelegramCopyAssistant.kt)使用。两种外观采用相同圆环几何，按可用短边缩小并保留边距，不再因为关闭 GTA 而改变大小。

[RadialGeometry](../app/src/main/java/com/actionhalo/android/RadialGeometry.kt)在普通与 GTA 模式均使用中心 `16 dp` 死区。按住中心后在圆孔内沿方向移动即可选择动作，不必滑到外圈；超过外圈保留 `60 dp` 松手容错。拖动只更新选择，松手执行一次，回中心取消。GTA 保留分区缝隙、HUD 与暗色遮罩；普通模式仍使用橙色外观。尺寸与触摸区域对齐不表示两个外观的装饰完全相同。

## 通用选文菜单兼容

新增 `standard_selection_menu_enabled` 独立开关，默认 `false`，不会因已有 Telegram 功能开启而自动启用。用户在首页同意专用说明并授予系统无障碍服务后，才识别前台应用的标准选文菜单。设置入口见 [MainActivity](../app/src/main/java/com/actionhalo/android/MainActivity.kt)，识别条件见 [TelegramCopyPolicy](../app/src/main/java/com/actionhalo/android/TelegramCopyPolicy.kt)和 [TelegramCopyAssistant](../app/src/main/java/com/actionhalo/android/TelegramCopyAssistant.kt)。

通用入口首次识别绑定具体前台窗口，避免误用同应用另一窗口的菜单；只检查前台应用同包子菜单窗口中的标准容器 `android:id/floating_popup_container` 与真实 Copy 控件，且必须能确定唯一目标。显示圆环时不复制或读取文字；用户选定操作后才请求宿主复制，在可见且已取得焦点的 [ClipboardHaloOverlay](../app/src/main/java/com/actionhalo/android/ClipboardHaloOverlay.kt)中核对本次剪贴板，再执行所选动作。沿用原来源核验、限时等待、取消和旧剪贴板拒绝。

标准容器和父子窗口依据为 AOSP Android 16 的 [floating_popup_container](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/res/res/layout/floating_popup_container.xml)、[LocalFloatingToolbarPopup](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/com/android/internal/widget/floatingtoolbar/LocalFloatingToolbarPopup.java#1504) 和 [AccessibilityWindowManager](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/accessibility/java/com/android/server/accessibility/AccessibilityWindowManager.java#939)。原生选区和菜单兼容同时开启时，已有原生选区优先；用户取消的同一选区不会经菜单路径重新弹出，选区变化后才允许再次触发。

这一入口不扫描主页面或聊天正文、不截图识字、不监控后台剪贴板，也不保存选中文字。自绘菜单、未公开复制控件、OEM 改造窗口和屏幕识字界面仍可能无法识别。X 实机、真实第三方应用及 vivo 各系统版本尚不能仅凭代码或合成宿主证明可用；失败时保留分享、系统菜单中的 ActionHalo 和手动复制快捷入口。用户已确认 0.6.1 在其原场景可以使用，该反馈不等于已验证本轮新增通用菜单路径或修复了无障碍开关被系统关闭的问题；[0.6.1 历史证据](telegram-copy-0.6.1.md)继续保留。

## 未移植能力

本版没有移植 macOS Shell、AppleScript、终端命令、键盘快捷键注入、文件定位、跨应用剪切/粘贴/删除、系统词典协议、`.actionhaloext` 插件包导入或 PC 操作排序。Android 自定义动作仍是 HTTP(S) 网址模板；处理文本入口不回写宿主选区。没有声称两个平台已完全等价。

普通手机尺寸以外，短边小于 208 dp 的极小分屏可能挤压圆环与分页区域，尚未提供专用紧凑布局。

## 验证与交付

交付 APK：`android/build/ActionHalo-0.7.0-debug.apk`，包名 `com.actionhalo.android`，版本 `0.7.0` / code `10`，minSdk 26、targetSdk 36。

- APK SHA-256：`169e9c8f0aa424f445f30300bb6deda2007958cac756fc7a3dce4e53cc205b89`。
- 签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.6.1 相同，可覆盖安装。
- `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 构建成功；45 项 JVM 测试全部通过。Lint 为 0 errors / 5 warnings（已有 localeConfig、App Bundle 语言切换、Gradle 版本提示和诊断文字拼接）。
- Android 15 / API 35 arm64 模拟器执行全套设备测试，开启真实焦点与无障碍设置诊断：66 项注册测试中 60 项实际通过，6 项需要单独环境的历史选文诊断按条件跳过。包含 19 项真实焦点/菜单测试、10 项 GTA/普通触摸与分页测试、6 项动作配置集成、6 项新搜索路由、6 项权限设置导航、10 项手动剪贴板入口和 3 项豆瓣执行器测试。
- 通用菜单回归使用不同 UID 的真实标准 FloatingToolbar，关闭原生自动选区后验证直接弹圈、准确部分文字复制；另验证仅 Telegram 授权不能扩大范围、撤回通用授权立即消失、普通 Copy 弹窗不会误识别。两条路径同开时只显示一个原生圆环，取消后同选区及临时窗口事件不重弹，新选区可重新触发。
- 另用独立合成 Telegram 宿主验证真实小弹窗取得焦点后恢复：原生选区、Telegram 菜单和通用菜单三个开关均开启；圆环出现前复制调用为零，用户选择操作后临时等待，恢复后宿主只复制一次，ActionHalo 使用准确 Unicode 片段执行一次。此项模拟窗口时序，不冒充登录后的真实 Telegram。
- 在完整回归后调整普通模式大字体排版，并重跑全部 11 项圆环设备测试，全部通过。新增用例在 320 dp / 字号 1.3 下核对两页中文长标题、Unicode 图标的实际末行高度、保持 12 sp 正文及分页按钮互不重叠；拖动时中心展示完整动作名称。最终截图另检查 320/400 dp、字号 1.0/1.3 两种外观的两页布局。

构建与测试日志保存在本地 `android/build/diagnostics/pc-parity-0.7.0/`，该目录由 Git 忽略。
