# Android 0.8.0：分架构与通用安装包

> 历史记录：0.8.1 已移除浮窗翻译和模型依赖，并恢复单一通用 APK。当前行为及文件见 [0.8.1 记录](remove-floating-translation-0.8.1.md)。

验证日期：2026-10-12。五个包均为独立可安装的 debug APK，包名 `com.actionhalo.android`、版本 `0.8.0` / `23`，最低 Android 8.0（API 26），目标 API 36。每台设备安装一个匹配包即可。

## 打包与文件

使用 Android Gradle Plugin 的 ABI splits 一次生成 ARMv7、ARM64、x86、x86_64 和通用版。所有包共用代码、资源、版本与签名，只有原生库架构范围不同。CI 上传路径已同步为 `app-*-debug.apk`。vivo X200s 选择 ARM64；不确定设备架构时选择通用版。

交付文件位于仓库根目录和 `android/build/`。以下为当前文件；此前同名 0.8.0 通用包已由本次构建替换。

| 文件 | 字节数 | MiB | 架构 |
| --- | ---: | ---: | --- |
| `ActionHalo-0.8.0-debug.apk` | 36,006,622 | 34.34 | 四种架构 |
| `ActionHalo-0.8.0-arm64-v8a-debug.apk` | 12,535,104 | 11.95 | ARM64 |
| `ActionHalo-0.8.0-armeabi-v7a-debug.apk` | 11,483,444 | 10.95 | ARMv7 |
| `ActionHalo-0.8.0-x86-debug.apk` | 13,399,024 | 12.78 | x86 |
| `ActionHalo-0.8.0-x86_64-debug.apk` | 13,160,034 | 12.55 | x86_64 |

SHA-256 同步保存为 `ActionHalo-0.8.0-SHA256SUMS.txt`：

```text
2e7ee2086d3bc226e81c392f245a465036d656621351816d78b33f5321541155  ActionHalo-0.8.0-debug.apk
102424e7f085e585f871443287231cb0419ebfbef509109958b5c2149b35af9a  ActionHalo-0.8.0-arm64-v8a-debug.apk
28fa7db6fb3f57855a5ad1b9862be9629598cb7f6b9e29be1404f2c06973e949  ActionHalo-0.8.0-armeabi-v7a-debug.apk
16adb3fe458b111c4a9ade7a392d434a588faf04a5c13b8519db4d6c404ff791  ActionHalo-0.8.0-x86-debug.apk
92d438db55bd0d18d4499732f53d0b9a154304ac05bb0056466635e27ace1362  ActionHalo-0.8.0-x86_64-debug.apk
```

签名证书 SHA-256：`58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，延续原有 debug 签名。在匹配架构的设备上可与通用版覆盖安装。

## 覆盖安装中发现的离线翻译问题

全新安装 ARM64 包、下载英中模型并成功翻译后，立即断网覆盖为通用包，旧代码会停在 `Translating`。原测试等待 180 秒仍未完成；将离线测试时限缩短为 15 秒后再次复现。临时阶段日志确认 `modelsReady=true`，随后调用 `downloadModelIfNeeded`，其成功回调没有执行，尚未进入 `translate`。仅重试曾通过，不能代替完整安装过程的验证。

共享 `LocalTranslator` 现在对已下载的源/目标模型直接调用 `translate`；缺少模型时仍须用户选择下载，并保留 Wi-Fi 条件、错误处理、结果长度检查及关闭逻辑。这与 [Google 官方模型管理与翻译接口](https://developers.google.com/ml-kit/language/translation/android) 的用法一致。临时探针已从源码移除。

## 验证结果

最终构建命令（在 `android` 目录，JDK 17、SDK 36）：

```bash
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:lintDebug --offline --no-daemon
```

- 构建及 Lint 通过；54 项 JVM 测试重新运行，全部通过。
- 五个包签名校验通过；清单的包名、版本及 API 范围一致。
- 五个包的 DEX、清单、资源及 assets 内容完全一致。四个独立包各含本架构的两份 `.so`，通用包包含八份；每份库与通用包中对应库逐字节一致，并检查 ELF 位数和机器类型。
- 原生库继续压缩存放、安装时解压。ARM64 和 x86_64 的 ELF `PT_LOAD` 对齐均至少 16 KiB；这是静态检查，不代表在 16 KiB 系统完成运行测试。
- 最终 API 35 / Android 15 ARM64 一次性模拟器：全新安装 ARM64，下载公开模型并实际识别英文、翻译为中文，通过（8.546 秒）。
- 关闭 Wi-Fi、移动数据并断言无活动网络后，ARM64 → 通用包覆盖安装成功，实际离线翻译通过（0.227 秒）；随后通用包 → ARM64 覆盖成功，再次离线翻译通过（0.335 秒）。均未清除应用数据或重新下载模型。
- 翻译界面的显式下载、Wi-Fi 选项、失败重试、译文复制和目标语言回退，3 项测试通过。
- 交付副本与构建产物逐字节一致，SHA-256 已生成。测试后恢复模拟器网络、卸载测试应用与模型，并关闭临时模拟器。

日志和机器可读结果位于 `android/build/diagnostics/abi-packaging-0.8.0-*`。其中 `before-fix-offline`、`probe-fresh-overwrite-offline` 保留修复前失败证据；`final-build`、`arm64-native`、`universal-overwrite-offline`、`arm64-overwrite-offline`、`translation-panel` 对应最终验证。

## 安装后的占用

在同一个 ARM64 模拟器，通用包保留的 `base.apk` 为 36,006,622 字节，ARM64 包为 12,535,104 字节，少约 22.38 MiB。两者实际解压的原生库均为 16,996 KiB，`no_backup` 中模型及 SDK 数据均为 44,420 KiB。分包同时减少下载文件和安装后保留 APK 的占用；已下载模型及本机实际使用的原生库占用相同。系统显示的应用总占用还包括编译产物、数据和缓存，此处没有测量该总值。

## 范围与未验证项

本轮未运行 ARMv7、x86、x86_64 模拟器，未连接 vivo 或其他品牌真机；这些架构只完成产物静态检查。跨 Android 版本及自动选文的已有结果见[兼容回归记录](compatibility-regression.md)。应用内更新继续选择原有文件名的通用 APK，未新增按架构更新筛选。未修改 PC 代码，未提交、推送或发布 GitHub Release。
