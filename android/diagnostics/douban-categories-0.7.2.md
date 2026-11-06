# Android 0.7.2：恢复豆瓣分类网址

2026-10-10；versionCode 12。

## 原因与改动

0.7.1 的豆瓣综合、读书、电影三个动作共用原生综合搜索路由。此前官方豆瓣 7.135.1 模拟器实测也仅返回综合结果，不能自动选中电影或书籍分类，见 [0.7.1 记录](menu-settings-0.7.1.md)。用户反馈分类不生效，并明确允许恢复网址；本次没有继续猜测原生分类参数。

- 豆瓣读书直接启动 `https://search.douban.com/book/subject_search?search_text=…`。
- 豆瓣电影直接启动 `https://search.douban.com/movie/subject_search?search_text=…`。
- 两项复用现有 `DoubanSearch.webUrl`，不先尝试原生综合搜索。豆瓣综合搜索仍优先启动 App，找不到或被拒绝时回退官方综合网页。
- 保留现有操作 ID、类型、启用状态与顺序；不修改圆环、分页、无障碍服务或 Telegram。选文编码与启动失败提示沿用原实现，无新增权限或依赖。

## 验证

- 新回归用例使用真实 `ActionStore` 目录动作，在修复前失败：期望隐式分类网址，实际 Intent 包名为 `com.douban.frodo`。修复后通过。
- `assembleDebug`、`assembleDebugAndroidTest`、`testDebugUnitTest`、`lintDebug` 离线构建成功；47 项 JVM 测试通过，Lint 无错误、5 条原有提示。
- Android 15 / API 35 ARM64 任务模拟器上，`DoubanActionTest` 4 项、`SearchActionTest` 6 项共 10 项通过。分类动作在模拟原生可用、不可用、拒绝启动三种条件下均只发出一次 HTTPS 分类 Intent；中文、emoji、`&`、`#`、`+`、百分号保留为查询内容。综合搜索原生启动和两种网页回退分支仍通过。
- 此次设备测试检查真实执行入口发出的 Intent，由测试 Context 截获第三方启动；没有把 Intent 断言当作豆瓣网页加载成功。未在用户 vivo / Android 16 真机复测。

构建与测试日志保存在 `android/build/diagnostics/douban-categories-0.7.2/`（构建产物，不入版本库）。

## 安装包

- `android/build/ActionHalo-0.7.2-debug.apk`，versionCode 12，1,009,450 字节。
- SHA-256：`f6704a18150cf2aaf5600038c391cbac3284bf1a28635033e864e74b24c54021`。
- `apksigner verify --print-certs` 通过；证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与前版一致，可覆盖安装保留配置。
