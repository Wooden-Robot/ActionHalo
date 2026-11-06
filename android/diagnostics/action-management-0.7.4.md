# Android 0.7.4：操作排序与编辑

2026-10-11；versionCode 14。

## 功能

- 首页每行的「⋮」菜单提供上移、下移。全部操作都可排序，包含未启用项；首尾边界禁用。圆环各入口按保存顺序读取已启用操作。
- Google、百度、豆瓣读书、豆瓣电影、NeoDB、NeoDB 书籍、GitHub 及自定义网站操作，可编辑名称、HTTP(S) 网址模板与图标。模板必须含 `{text}`，选文继续由共用 URL 构造器编码；拒绝协议、主机等位置的非法模板。
- 图标从现有 10 个矢量资源中选择。首页和圆环共用映射，不引入依赖。新增操作与编辑操作复用同一表单；表单支持滚动。
- 复制、打开链接、分享、翻译、豆瓣综合 App 搜索、Telegram 原生搜索维持固定行为，仍可排序和切换启用状态；对应 PC 对核心操作的编辑限制。
- 编辑保留 ID、位置和启用状态。取消或校验失败不写入；自定义操作可从「⋮」菜单确认删除。

## 配置兼容

保留 `halo_actions` 中原有启用键与 `custom_actions` JSON 数组，图标是可选字段。新增 `action_order` ID 数组与 `builtin_edits` 覆盖项数组。旧配置缺少新字段时按原顺序、默认图标显示；未知、重复或已删除的排序 ID 被跳过，后来新增的操作追加在末尾。

内置网站覆盖按原 ID 合并，避免修改启用状态和排序。未编辑的豆瓣读书、电影继续使用原分类搜索网址；编辑后按用户保存的 HTTP(S) 模板执行。GTA、每页数量及权限设置沿用现有配置。

## 验证

- 最终离线 `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 成功；47 项 JVM 测试通过。Lint 0 错误、5 条原有提示。
- Android 15 / API 35 ARM64 专用模拟器运行 25 项测试全部通过：`ActionManagementTest` 5 项、`ActionManagementUiTest` 3 项、`HaloIntegrationTest` 6 项、`DoubanActionTest` 4 项、`SearchActionTest` 6 项，以及矢量圆环布局 1 项。
- 配置回归覆盖跨内置/自定义及关闭项排序、边界、重建存储、旧 JSON、重复/失效 ID、新增与删除；编辑后实际执行新网址，Unicode 正确编码；非法名称、网址、图标及固定操作编辑不改变原配置。
- 真实设置 UI 回归覆盖「⋮」菜单、上移/下移、名称/网址/图标保存、关闭状态保留、重建界面、非法网址保持编辑器打开，以及下次真实圆环使用保存后的顺序。
- 矢量回归覆盖普通/GTA、6/8/12/16 项、分页、320 dp 和较大字号，检查图形绘制、边界、完整无障碍标题及中心拖选预览。已查看管理菜单与编辑器截图。
- 初次 UI 回归的两次失败来自测试连接 UiAutomation 的时机及原生取消按钮的大写文本定位，已修正测试并在最终完整运行中通过；没有绕过保存或校验断言。

日志与截图位于 `android/build/diagnostics/action-management-0.7.4/`（构建产物）。模拟器结果不能替代 vivo / Android 16 真机复测；本次不改变无障碍或 Telegram 复制触发链。

## 安装包

- `android/build/ActionHalo-0.7.4-debug.apk`，versionCode 14，1,161,080 字节。
- SHA-256：`cd1328d6f97ec801765b6a05ee42ea5df6a6fa6a096375320cb17cccf7d88fa3`。
- `apksigner verify --print-certs` 通过；证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与 0.7.3 一致，可覆盖安装保留配置。
