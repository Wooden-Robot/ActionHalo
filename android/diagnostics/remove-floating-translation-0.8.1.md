# Android 0.8.1：移除浮窗翻译，恢复单一通用包

验证日期：2026-10-12。根据用户要求移除浮窗翻译；移除后没有架构相关原生库，取消分架构打包。版本 `0.8.1` / `24`，最低 Android 8.0（API 26），目标 API 36。

## 实现范围

- 删除翻译浮窗、Activity、无障碍翻译浮层、本机翻译引擎、语言识别、模型下载和来源图片，移除两个 ML Kit 依赖及专用网络状态权限。
- 内置「Google 翻译」恢复为普通网址动作：使用 Google 翻译网页，默认自动识别原文，目标语言随应用语言选择中文或英文。沿用网址校验、选文编码和浏览器启动的错误处理。保留动作 ID、排序、启用状态和图标；配置原本不持久化动作类型，无需改写用户动作数据。
- 手动选文、分享、无障碍原生选区和复制菜单入口共用现有网址执行流程。移除服务中的翻译窗口生命周期分支，保留原生圆环、复制窗口、锁屏和焦点处理。
- 更新中英隐私说明、README 和诊断文档，移除 SDK 数据披露、离线翻译和模型下载入口。联网权限继续供用户主动检查更新使用。
- 升级后首次打开应用，在后台删除旧版的 `no_backup/com.google.mlkit.translate.models`。目录名经过旧版实际模型下载核对；不删除其他文件或改写动作、权限及外观设置。少量旧 SDK 元数据不在此模型目录清理范围内。
- Gradle 和 CI 恢复只输出一个 `app-debug.apk`，交付名为 `ActionHalo-0.8.1-debug.apk`。0.8.0 五个包及记录作为历史产物保留。

## 安装包

文件：`ActionHalo-0.8.1-debug.apk`，1,052,218 字节，约 **1.05 MB / 1.00 MiB**。位于仓库根目录及 `android/build/`。

SHA-256：`290080712b99017e25b3448c5f2fec371546105071e45ebb4b78b3cc058fbfa7`，同时保存为 `ActionHalo-0.8.1-SHA256SUMS.txt`。

签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，延续原有 debug 签名，可覆盖现有版本。

产物不含 `.so` 或 `lib/` 架构目录；DEX 不含 ML Kit 类，清单不含 SDK provider 或 TranslationActivity。相较最后一次 0.8.0 通用包的 36,006,622 字节，体积减少约 97.1%。由于没有原生库需要按 ABI 取舍，分架构打包不再带来库体积收益。

## 验证

构建命令（`android` 目录，JDK 17 / SDK 36）：

```bash
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:lintDebug --offline --no-daemon
```

- 构建与 Lint 通过，54 项 JVM 测试通过。
- 最终 API 35 / Android 15 ARM64 一次性模拟器：21 项设备测试全部通过，耗时 29.634 秒。覆盖动作保存及 URL 编码、设置页面和外观、模型目录清理、手动选文与分享、真实无障碍选区、标准复制菜单翻译和实际复制。
- 三条翻译设备测试覆盖四种入口，使用 ActivityMonitor 捕获浏览器启动，断言网站及还原后的选文、启动次数、圆环和复制窗口关闭；不把固定测试文字发往网站。
- 另行在旧版 0.8.0 实际下载英中模型并成功翻译，随后写入固定的排序、自定义网址、开关和外观配置，覆盖安装 0.8.1。首次打开后，44,380 KiB 的旧模型目录被删除；所有固定设置及目录外的标记文件保持原样。清理后 `no_backup` 为 48 KiB，包含旧 SDK 元数据和测试标记，不是应用总占用。
- 校验仅有一个无 ABI 过滤的 APK，版本、最低 API、签名及交付副本 SHA-256 均正确。

原始结果位于 `android/build/diagnostics/remove-translation-0.8.1-*`：`build` 为构建日志，`api35-tests` 为设备结果，`old-model-setup` 为旧版真实模型准备，`upgrade.json` 为覆盖升级结果，`artifact.json` 为文件大小及校验值。

## 未验证范围

本轮仅运行 Android 15 ARM64 模拟器，未在 vivo 或其他品牌真机、其他 Android 版本或其他 CPU 架构执行。Android 8 及以上的既有回归结果见[兼容回归记录](compatibility-regression.md)，不等同于本轮实测。网页翻译需要可访问相应网站；本轮验证动作分发与选文，不评价第三方网站的翻译质量。未修改 PC 代码，未提交、推送或发布 GitHub Release。
