# Android 0.8.0：设置、外观、浮窗翻译与更新

> 历史记录：0.8.1 已移除浮窗翻译和模型依赖，并恢复单一通用 APK。当前行为及文件见 [0.8.1 记录](remove-floating-translation-0.8.1.md)。

验证日期：2026-10-12。对应用户选择的第 3、4、5、7 项优化。未修改 PC 代码，未提交、推送或发布 GitHub Release。

## 实现范围

- 首页保留服务状态、圆环体验和页面导航。操作管理、圆环外观与触感、触发与权限、故障诊断、关于与更新各自独立；原有排序、编辑、权限同意与诊断复制保留。
- 普通/GTA、手动/无障碍/复制入口共用 320、360、400、440、480 dp 五档大小，仍按可用屏幕缩小。背景遮罩为 0–80%，0% 同时移除 GTA 暗角；两种模式共用轻震开关。恢复默认外观不清除动作或权限。每页数量、首次触摸定位、外部点击关闭保留。
- 内置 Google 翻译改为原生浮窗，支持自动识别和手选语言、复制译文、重试及主动选择的网页入口。源语言/目标语言均使用 SDK 支持列表；地区标签如 `zh-CN` 转换为 `zh`，无效保存值回退到界面语言。
- 无障碍入口直接使用服务窗口，不通过后台 Activity 启动浮窗；原生选区与标准复制菜单两条生产链路均验证。手动选文/分享使用透明 Activity。锁屏、来源被替换、撤回授权或服务停止会清理服务浮窗。
- 缺少模型时先显示下载选择，用户明确选择 Wi-Fi 或当前网络后才请求模型。已缓存模型可离线翻译。关闭后清空本次文字，不增加翻译历史。
- 关于页手动检查本仓库公开 GitHub Releases；忽略 macOS 资产、草稿和预发布，数值比较版本并区分 debug/release APK。显示更新说明，用户点击后由浏览器下载、系统安装。限制响应长度并验证下载域名、仓库和路径。

## 验证结果

| 检查 | 结果与范围 |
| --- | --- |
| 构建、JVM、Lint | 最终构建成功；54 个 JVM 测试全部通过；Android Lint 通过 |
| Android 15 / API 35 全量回归 | 113 项：109 通过、4 个按条件跳过；覆盖原有圆环手势、排序编辑、复制焦点、选区和权限导航 |
| API 35 最终针对性回归 | 12 项：11 通过、1 个离线专用测试跳过；覆盖最后的中文标签转换、来源标识、设置页、真实 HTTPS 更新、实际模型翻译及两条生产浮窗链路 |
| Android 8 / API 26 最终针对性回归 | 10 项：9 通过、1 个离线专用测试跳过；设置、中文标签、译文复制、真实更新检查、实际本机 SDK 翻译通过 |
| 模型下载与实际翻译 | 两个系统版本均实际运行 Google SDK，将固定英文示例翻译为中文；不是模拟译文 |
| 断网翻译 | API 35 同时关闭 Wi-Fi 和移动数据，断言无活动网络，缓存模型翻译通过；随后恢复模拟器网络 |
| 中文视觉检查 | 实际检查首页、外观、关于与更新，以及完整英文选文到中文译文的原生浮窗；译文与官方来源标识正常显示 |
| APK | `minSdk 26` / `targetSdk 36`，四种 ABI，同一调试签名；ARM64 和 x86_64 原生库 `PT_LOAD` 对齐均为 16 KiB |

全量回归先于最后的中文默认语言修正和来源图片补齐；最终构建已对相关代码、UI、真实网络和 SDK 再做针对性验证，未将这些结果冒充为又一次全量运行。测试次数包含重复覆盖，不相加为唯一用例数。

全量中的四个跳过项是：需要单独安装 Via 的应用测试、需要单独授权网络的更新测试，以及下载/断网两个模型测试。更新和模型测试随后按明确参数独立执行。最终针对性测试只跳过单独断网分支。

第一次全量曾发现旧测试仍从首页找诊断按钮，已改为进入诊断页。另有一次 GTA 首次图标短点未执行，单独重跑和后续全量 22 项 GTA 测试均通过；未确认偶发失败原因，未据此改变生产手势语义，断言增加了点击时长信息。API 26 的命令行断网尝试未成功关闭 Wi-Fi，因无网络前置断言失败；改用 API 35 实际断网验证，没有把 API 26 那次当作离线通过。

原始日志位于本机忽略目录 `android/build/diagnostics/`：

- `settings-0.8.0-build-final.txt`
- `settings-0.8.0-api35-final.txt`
- `settings-0.8.0-final-api35-focused.txt`
- `settings-0.8.0-final-api26-focused.txt`
- `settings-0.8.0-offline-api35-final.txt`
- `settings-0.8.0-gta-recheck.txt`

## 网络、数据与来源

0.8.0 使用 [ML Kit 本机翻译](https://developers.google.com/ml-kit/language/translation/android)和[本机语言识别](https://developers.google.com/ml-kit/language/identification/android)。选文不发送到翻译服务器，不保存历史；下载模型通常每种约 30 MB。ML Kit 另收集设备/应用信息、安装标识、性能和使用指标，具体见 [SDK 官方数据说明](https://developers.google.com/ml-kit/android-data-disclosure)。应用关于页已披露，不再沿用旧版“无分析 SDK、无网络权限”的表述。

翻译由 Google Translate 提供，结果旁使用[官方来源图片](https://docs.cloud.google.com/static/translate/images/google-translate-attribution.zip)中的 `png/white-regular@2x.png`，原样保存为 `res/drawable-xhdpi/google_translate_attribution.png`。关于页包含来源、译文保证说明和[翻译服务条款](https://developers.google.com/ml-kit/language/translation/translation-terms)，参照[展示要求](https://docs.cloud.google.com/translate/attribution)。自动翻译可能出错，非英语语言对经过英语转换；本轮只验证英中示例，没有逐个测试全部语言。

更新查询只在点击后读取[公开发布 API](https://docs.github.com/en/rest/releases/releases?apiVersion=latest)，不提交选文或诊断报告。本轮公开仓库没有对应 Android APK；“未找到 Android 发布”是真实网络检查的有效结果。未测试实际线上新版 APK 的下载安装，也未擅自创建 Release。新版发现与地址筛选由固定 JSON 用例覆盖。

## 安装包与边界

首次交付文件：`ActionHalo-0.8.0-debug.apk`，36,312,199 字节（约 34.63 MiB），包含 ARMv7、ARM64、x86、x86_64。原生库压缩存放，系统安装时解压。

SHA-256：`e3d6f6f7b6dca2182c2e3655bb555a9fc3ebbbeddadddccb5374a1e87db500f8`

签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与之前 0.7.12 APK 相同。

随后按架构重新构建了同版本安装包，同名通用包已更新；当前五个包的大小和 SHA-256 以[分架构打包记录](abi-packaging-0.8.0.md)为准，上述校验值仅对应首次交付。

这轮使用临时 Android 8 和 Android 15 模拟器；没有连接用户手机，没有复测 vivo 真机、真实 Telegram/X 或其他品牌。四种 ABI 和 16 KiB ELF 检查不等于已在全部架构、16 KiB 设备或所有 Android 版本执行。已有跨版本结果仍见[兼容回归记录](compatibility-regression.md)。
