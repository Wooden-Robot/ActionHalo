# Android 0.11.14 首次选字直接弹出

用户反馈原子笔记中首次选中文字不弹圆环，拖动选区手柄后才弹。现有实现及测试仍保留 0.8.7 引入的初选静默规则：原生路径只记录第一次范围；菜单路径在收到选区事件时要求范围已经改变。这个规则与当前期望冲突。

## 复现与修改

在 SDK 36 隔离模拟器、不同 UID 的真实 EditText 和系统 FloatingToolbar 上，将断言改为首次选字后出现圆环，不进行范围调整。两条用例修改生产代码前均失败，原生报告为 `selection_result=INITIAL_SELECTION`。日志：`/private/tmp/actionhalo-initial-selection-red.log`。

```sh
adb -s emulator-5580 shell am instrument -w -r \
  -e focused_clipboard_overlay true -e selection_diagnostics true \
  -e class 'com.actionhalo.android.SelectionTriggerDiagnosticTest#initialSelectionOpensTheHaloAndDuplicateEventsKeepItsWindow,com.actionhalo.android.FocusedClipboardOverlayTest#initialStandardSelectionOpensTheHaloWithoutCopying' \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

`SelectionAccessibilityService` 让首次有效选区事件进入原有显示流程，保留 250 ms 事件合并。同范围的长按提示不能取消已经待显示或已显示的圆环；先到达长按提示、后到达相同范围的选区事件时也能显示。只有长按提示而缺少选区事件时，继续让菜单兼容处理，诊断名称改为 `LONG_PRESS_ONLY`，避免再提示用户必须先拖动手柄。

`TelegramCopyAssistant` 在自动模式下识别到经过核对的复制菜单后直接显示，删除用于初选静默的范围调整状态。保留范围元数据和选文保护区域更新。按钮模式、关闭、暂停、来源窗口、密码与敏感节点、菜单归属和复制授权检查继续生效。

同步中英文说明和诊断建议、现有测试及选文夹具。没有修改圆环触摸定位、手柄保护、背景时机或复制后窗口位置继承的生产实现，也没有新增权限、设置或依赖。

## 验证

- 修复后原始两条复现用例通过，8.038 秒：`/private/tmp/actionhalo-initial-selection-green.log`。
- 构建及 61 项 JVM 测试通过；Lint 0 错误、6 项警告：`/private/tmp/actionhalo-initial-selection-final-build.log`。
- 首轮完整选区与复制回归 85 项，77 通过、6 失败、2 条件跳过，401.961 秒：`/private/tmp/actionhalo-initial-selection-regression.log`。两个跳过项需要额外的 Via 测试站点与 Telegram 合成宿主，不能记为通过。
- 六项失败涉及：一项仍断言重新选字保持静默；两项向已经为 `0:9` 的控件再次请求 `0:9`，Android 返回未改变；一项用程序化重选与无障碍长按代替真实第二次长按；两项快速复制使用了过期的无障碍窗口坐标。探针确认复制按钮返回范围为 `Rect(593, 535 - 725, 667)`，实际控件左上角为 `(593, 623)`，高 132，原注入点落在真实图标外侧。增加等待两帧也未修正该缓存坐标。记录：`/private/tmp/actionhalo-initial-selection-probe.log`、`/private/tmp/actionhalo-initial-selection-calibrated.log`。
- 测试现在直接验证首次选字；每次范围调整均实际改变范围；取消后的第二次选字使用真实触摸长按；快速复制使用实际可见图标坐标，仍检查每个绘制帧的位置、背景及精确复制内容。夹具校准后的 11 项检查中 9 项通过，剩余 2 项在按钮坐标前提检查处失败。生产 APK 在校准期间未修改。
- 最终 8 项全部通过，46.372 秒：`/private/tmp/actionhalo-initial-selection-final.log`。包括原生与菜单快速复制、两入口复制后保留位置、已重新定位后的复制、保留窗口第一帧、首次标准菜单选字以及长按提示后相同范围的首次事件。原先 6 项失败均已通过定向复验，未再次运行完整 85 项。最终测试构建和 Lint 通过，`git diff --check` 通过。
- 初选后真实拖动手柄、整段选文及周边防误触、重新定位、初选事件顺序、重复事件、按钮模式、暂停、权限撤回和自定义工具栏均纳入上述回归。没有将模拟器夹具当作原子笔记或 vivo 实测。

## 安装包

`ActionHalo-0.11.14-debug.apk`：versionCode 50，minSdk 26，targetSdk 36，1,268,935 字节。

SHA-256：`3a97081b2b860c697a1d23146225010f6ef5255c97ef3b0dffff50645bbac8e6`，另存 `ActionHalo-0.11.14-SHA256SUMS.txt`。ZIP 完整性及签名校验通过，证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与之前交付包一致，可以覆盖安装。交付包与回归使用的生产 APK 字节一致。

未连接用户 vivo 真机，未在真实原子笔记、微信或 Telegram 中验证；未重跑其他 Android 版本及全部应用测试。未提交、推送或发布远程版本。
