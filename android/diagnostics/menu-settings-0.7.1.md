# Android 0.7.1：图标圆环、每页数量与豆瓣 App 搜索

2026-10-10；versionCode 11。

- 普通圆环移除图标下方的名称，只显示操作图标；中心滑动提示、TalkBack 名称、点击与松手执行保留。删除原来的两行文字与图标高度补偿，按图标实际宽高缩放字号，避免 16 项与大字体下特殊符号变成省略号。
- 首页「圆环氛围」增加「每页显示数量」：6、8、12、16，与 PC `StatusBarController.swift` 的选项一致。Android 默认保留 8 项以延续旧版布局，PC 默认 12。选项持久化，非法配置回退 8。
- 每个 RadialMenuView 都通过 HaloAppearance 读取配置，覆盖首页、选文／分享、手动剪贴板、普通自动圆环及 Telegram／通用菜单圆环；服务中修改数量会关闭旧圆环，下次显示使用新设置。
- 分页不改变已启用操作及其顺序；旧豆瓣升级迁移仍使用固定历史上限 8，与新的每页数量无关。
- 豆瓣读书、电影改为原生 App 优先，与豆瓣综合搜索共用显式包名 `com.douban.frodo` 的带词深链。启动不可用或被系统拒绝时，分别回退读书／电影官方分类网页；原操作 ID、启用状态和自定义 URL 限制不变。

## 豆瓣分类边界

官方 APK 7.135.1 / 364 来自[豆瓣官方下载页](https://www.douban.com/doubanapp/)及[官方分发入口](https://andariel.douban.com/d/com.douban.frodo/douban/)，SHA-256 为 `f840c998aae08bdaf4de28d9def79ff4a9e58e302556530dae9cb1952ec60aa3`。使用 Android 15 模拟器、不登录的浏览模式，以公开测试词“三体”核查。APK 字符串含 `search/result?t=%s&q=%s`，但实验 `t=book`、`movie`、`1001`、`1002` 均返回混合的综合结果，不能把“能打开页面”当作分类成功。

交付使用[豆瓣官方热搜接口](https://m.douban.com/rexxar/api/v2/chart/hot_search_board)公开的 `douban://douban.com/search/result?q=…` 综合路由，App 内可能仍需手动切换分类；分类网页兜底保持原路径。这次没有添加自动点击豆瓣页面、额外无障碍权限或未经证实的分类参数。首次安装豆瓣需先完成自身启动流程。

## 验证

- `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 离线构建成功；47 项 JVM 测试通过。Lint 无错误，5 条现有提示（localeConfig/API、App Bundle 语言、Gradle 版本与两条诊断文字拼接）。
- 设备回归 30 项全部通过：`GtaRadialMenuTest` 12、`HaloPageSizeTest` 3、`HaloIntegrationTest` 6、`DoubanActionTest` 3、`SearchActionTest` 6。覆盖四种数量、两种样式、分页顺序与全局编号、图标不省略／裁切、中心名称、一次执行、设置保存／非法值回退／重建、旧配置升级及三种豆瓣动作的原生成功／不可用／拒绝启动分支。
- 已检查普通 8 项、普通/GTA 16 项两页截图，以及 320dp 圆环、1.3 倍字号下的图标；首页原生数量选择器包含 6/8/12/16 且显示当前选项。
- 在官方豆瓣 7.135.1 的浏览模式实际点击 0.7.1 圆环中的「豆瓣读书」「豆瓣电影」，两个入口均进入原生搜索，搜索框均保留测试词“三体”。实际页面是综合结果；未把分类实验或 Intent 接受等同于分类成功。
- 回归中的极快上下 MOVE 注入曾被 Android 重采样从预期屏幕 Y=1417 外推至 Y=1591，进入页码区域，导致瞬时标题断言失败。通过实际坐标记录定位后，新增数量组合在真实 View 上分发 MotionEvent，验证中心提示、分页索引与松手执行；翻页及原有 11 项圆环测试仍保留系统输入路径。不改变产品的分页保护或命中规则；临时反射和事件日志已删除。
- 仅在任务专用 Android 15 / API 35 ARM64 模拟器验证；未在 vivo 真机复测，不据此宣称所有 OEM 或豆瓣版本均相同。

测试日志与截图保存在 `android/build/diagnostics/menu-settings-0.7.1/`（构建产物，不入版本库）。

## 安装包

- `android/build/ActionHalo-0.7.1-debug.apk`，versionCode 11，1,169,107 字节。
- SHA-256：`796223a656b5d27b068951d0ea91f5b4b9b06049dc05595164831ce195842766`。
- `apksigner verify --print-certs` 通过；沿用前版调试签名，证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`。可覆盖前版同签名 APK；不会清除用户配置。
