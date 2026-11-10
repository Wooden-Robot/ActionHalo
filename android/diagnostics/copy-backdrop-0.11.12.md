# Android 0.11.12 复制时的背景明暗闪动

## 用户现象与版本边界

用户确认闪动发生在整个页面或背景，而非按钮图标。2026-10-31 的新诊断仍报告 App 0.11.9、SDK 36、vivo V2458A，服务已连接且两个选文开关已启用。记录中一次菜单匹配并添加圆环，随后出现外部触摸、等待菜单、菜单消失和移除圆环；另一段长按记录为来源不可见，没有有效选区范围。

这份报告不能代表 0.11.10–0.11.11 的表现：这些版本已分别加入空间不足时的局部触摸穿透、整段选文及周边保护。本次安装包包含这两项已有修正。当前没有真机证据证明所有应用的不弹问题已解决，因此没有继续放宽菜单来源、密码或敏感节点检查，也没有改变首次选区与调整选区的触发规则。

## 复现与修改

SDK 36 无账号模拟器中，先在真实文本控件选字、调整范围并弹出生产圆环，再注入复制按钮的 DOWN/UP。修改前：

1. 原生选文入口与菜单兼容入口均在 DOWN 时立即设置 `FLAG_DIM_BEHIND` 并添加 GTA 背景，快速 UP 复制后立刻移除，形成明暗闪动。
2. 兼容入口点击原应用的复制菜单后，再打开全屏剪贴板处理窗口、读取新剪贴板并重复执行复制，即使用户只要普通复制也会短暂打开该窗口。

三个失败断言分别检查两个入口的 DIM 标志，以及兼容复制的 `OVERLAY_REQUESTED` 阶段。修改前日志 `/private/tmp/actionhalo-copy-flash-red.log`：3 项测试全部失败，23.741 秒。重现命令：

```sh
adb -s emulator-5580 shell am instrument -w -r \
  -e focused_clipboard_overlay true \
  -e class 'com.actionhalo.android.FocusedClipboardOverlayTest#quickNativeCopyDoesNotFlashThePageBackdrop,com.actionhalo.android.FocusedClipboardOverlayTest#quickMenuCopyDoesNotFlashThePageBackdrop,com.actionhalo.android.FocusedClipboardOverlayTest#standardSelectionToolbarCopiesOnlyTheSelectedFragmentThroughTheRealHalo' \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

`SelectionHaloWindow` 仍在按下时展开输入区域，保持首次点击位置和重新定位逻辑；背景效果延迟到系统长按阈值，或手指移动超过系统触摸阈值时才启用。松手、取消、多指切换、隐藏或移除窗口时取消待执行回调。辅助按钮或诊断入口主动打开的圆环保留原有背景。

`TelegramCopyAssistant.copyFromMenu` 在重新确认动作可用于来源应用、复制菜单仍有效后，点击原应用的复制操作。普通复制且未开启「复制后保留圆环」时，到此完成，不读取剪贴板、不再次写入，也不打开处理窗口。其他动作及保留圆环继续走原有的聚焦读取、时效和来源校验。保留原应用的剪贴板标签属于预期变化，相关测试继续检查精确选文内容；自定义菜单夹具还检查标签仍为 `Custom menu fixture`。

## 验证

- 第一轮定向验证 10 项全部通过，56.365 秒：`/private/tmp/actionhalo-copy-flash-targeted.log`。包括三个原失败用例、长按及拖动背景、点击前禁用复制、实际兼容入口保留快照、快照复用、网页翻译、原生复制失败重试以及首次点击位置。
- 0.11.12 构建、61 项 JVM 测试通过；Lint 0 错误、6 项警告。记录：`/private/tmp/actionhalo-copy-flash-final-build.log`。
- 三个相关测试类的首轮回归共 91 项，87 通过、2 失败、2 跳过，456.729 秒：`/private/tmp/actionhalo-copy-flash-regression.log`。未安装专用 Telegram 夹具和 Via，两个对应测试跳过。手柄保护、重定位、自定义聊天菜单及厂商菜单、键盘和服务恢复等已通过。
- 两项失败发生在圆环创建前。原生新长按用例的真实事件记录显示第二次长按为 `35:35` 的收起选区，并没有选中另一个单词；测试原先只判断起点不同，未确认非空。现按系统返回的字符坐标长按，并验证选区包含指定字符。日志：`/private/tmp/actionhalo-copy-flash-trigger-probe.log`。
- 另一项菜单翻译用例在定向检查通过、整组回归中未出现圆环。检查发现共用夹具只向右扩选，初始单词在文本末尾时可能重复设置原范围。夹具现向两端扩选并断言范围确实改变，失败时附带既有诊断；生产触发规则未改。两项用例连同前序长按/拖动、快照焦点切换场景连续三轮通过，每轮 4 项：`/private/tmp/actionhalo-copy-flash-fixture-recheck-1.log` 至 `-3.log`。该结果不能证明手机上所有不弹问题的原因。
- 最后只重建并验证了测试 APK，生产 APK 字节未变；未再次运行整组 91 项。最终测试代码 lint 及 `git diff --check` 通过，记录：`/private/tmp/actionhalo-copy-flash-final-lint.log`。

## 安装包

- `ActionHalo-0.11.12-debug.apk`：versionCode 48，minSdk 26，targetSdk 36；1,268,619 字节。
- SHA-256：`6c17fab1745b73cb39c09c2dbb000a481ef598b84cd74f978e456478959535be`，另存 `ActionHalo-0.11.12-SHA256SUMS.txt`。
- ZIP 完整性及 APK v2 签名校验通过。签名证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与之前交付的开发包相同；覆盖安装保留现有设置。交付文件与相关回归使用的生产 APK 字节一致。

本次真实窗口测试使用 Android 16 / API 36 模拟器和固定夹具文字，未连接用户 vivo 真机，未实测真实微信或原子笔记。未提交、推送或远程发布。
