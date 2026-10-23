# Android 0.7.3：对齐 PC 图标

2026-10-11；versionCode 13。

## 改动

PC 圆环通过 `RadialMenuView.swift` 绘制 SF Symbols，Android 原先用文字字符代替。本次根据 PC 内置动作和 `Plugins/*/Config.json` 的语义制作 Android 矢量图形，不提取 Apple 的符号文件，也不新增依赖。

| 动作 | 图形 |
| --- | --- |
| 复制 | 重叠纸张 |
| Google、翻译 | 经纬地球 |
| 百度、豆瓣综合 | 放大镜 |
| 豆瓣读书 | 打开的实心书 |
| 豆瓣电影 | 胶片 |
| NeoDB、NeoDB 书籍 | 竖排书籍 |
| GitHub | 地球与大陆 |
| Telegram | 轮廓纸飞机 |
| 打开链接、自定义网址 | 链环 |
| 分享 | 方框向上箭头 |

- 圆环和首页动作列表共用 `ActionIcons` 资源映射。圆环仍由实际 Button 提供点击、键盘和 TalkBack，只将文字图标替换为居中矢量绘制；完整动作名称和选中时的中心预览保留。
- 图标沿用 PC 的数量尺寸规则：至多 6、8、12、16 项分别为 32、30、26、22 dp；按按钮可用宽高等比缩小，不受系统字号影响。保留现有普通/GTA 模式的高亮颜色与 GTA 放大反馈，着色后显式重绘。
- Android 应用图标复用 `Assets/ActionHaloIcon.svg` 的八扇区路径、旋转和右上高亮偏移，替代橙色闪电。保留 Android 深色背景，VectorDrawable 不复现 SVG 的模糊滤镜。
- 未修改操作 ID、保存格式、启用状态、排序、分页、权限、复制触发或搜索行为；0.7.2 的豆瓣分类网址继续使用。

## 验证

- `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 离线成功。47 项 JVM 测试通过；Lint 无错误、5 条原有提示。
- Android 15 / API 35 ARM64 任务模拟器运行 `GtaRadialMenuTest` 12 项、`HaloIntegrationTest` 6 项，共 18 项通过。
- 矢量回归使用真实默认目录和隔离自定义网址，覆盖普通/GTA、6/8/12/16、两页、320 dp 圆环及 1.3 倍字号；逐按钮绘制 Bitmap，断言图形非空、四边留白、无文字替代、无障碍完整标题，拖选更新中心且取消不执行。原有一次执行、手势取消、分页、模式保存和旧配置回归通过。
- 已查看默认 GTA 圆环与启用可选搜索后的普通圆环截图，确认图形、位置及首页左上八扇区应用图标。未在 vivo / Android 16 真机或其启动器遮罩上复测。

日志与截图位于 `android/build/diagnostics/pc-icons-0.7.3/`（构建产物，不入版本库）。

## 安装包

- `android/build/ActionHalo-0.7.3-debug.apk`，versionCode 13，1,017,374 字节。
- SHA-256：`c1793079bc5750717369aae5048f71014042567b41c98b550415b46901a97bb8`。
- `apksigner verify --print-certs` 通过；证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与前版一致，可覆盖安装保留配置。
