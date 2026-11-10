# Android 0.11.15 重选文字后恢复圆环

用户反馈 Android 手机 App 内首次选字能显示圆环，但拖动手柄重选后不再显示。没有连接用户 vivo 真机，也没有真实 Codex App 的本次诊断报告；以下是相同症状的真实 Android 窗口复现，不代表已经确认手机上的全部原因。

## 复现与原因

SDK 36 隔离模拟器中，普通原生控件、WebView、仅菜单入口及快速 WebView 手柄拖动在旧版 0.11.14 均通过，因此不能把这些对照当成故障复现。随后扩展现有测试应用：可选择的 TextView 使用真实系统手柄，同时保留同包子窗口中的可点复制菜单。真实拖动确实扩大选区，菜单始终可用，但旧版圆环不再显示。

同一用例在修改生产代码前连续两次失败。日志为 `/private/tmp/actionhalo-reselection-custom-red.log` 与 `/private/tmp/actionhalo-reselection-custom-probe.log`。探针显示窗口仍附着，`selectionMoving=true`、`waitingForMenuReturn=true`、`menuWasHidden=false`，且 `placementBlocked=false`、`expanded=false`、菜单仍为 `MENU_MATCHED`。圆环卡在等待菜单隐藏的状态，并非被空间不足或来源关闭移除。

```sh
adb -s emulator-5580 shell am instrument -w -r \
  -e focused_clipboard_overlay true -e selection_diagnostics true \
  -e class 'com.actionhalo.android.FocusedClipboardOverlayTest#reselectingWithAVisibleCustomMenuRestoresTheHaloAndCopiesTheNewRange' \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

## 修改

`SelectionHaloWindow.updateSelectionMenu` 保留原来的菜单隐藏／恢复判断，允许经过稳定检查的可用菜单解除等待。`TelegramCopyAssistant` 复用原有 260 ms 稳定复查，在重新核对来源、菜单归属、授权和复制控件后恢复。原生路径复用 250 ms 复查，要求当前选区仍有效、来源存在；已经识别过工具栏时，还要求工具栏当前可用。

直接在每次菜单可用时恢复会过早显示：系统工具栏正在收起时，其无障碍节点可能短暂仍可读取。该方案在真实手柄停留用例中失败，已撤回。保留早期隐藏，使用已有稳定复查恢复，避免放宽窗口与授权校验。

未增加计时器种类、配置、权限、依赖或菜单正文读取。选文及周边保护、触摸穿透、排队触摸防误触、正常重新定位和复制背景／位置规则保持原有实现。测试在圆环视图恢复且无障碍按钮重新发布后点击复制，并核对剪贴板内容等于重选后的真实范围。

## 验证

- 原始复现用例通过，6.865 秒：`/private/tmp/actionhalo-reselection-published.log`。旧版永久隐藏，新版恢复并复制新范围；拖动没有操作圆环或打开背景。
- 稳定检查版本的四项常规手柄用例通过，覆盖首次拖动、多行重抓、原生与菜单入口，以及按住暂停时保持隐藏。首轮同时运行的新增用例已恢复可见，但立即查询无障碍按钮早于系统发布；补齐同时等待可见视图与可用按钮后，上述完整用例通过。未放松恢复或复制内容断言。
- 最终 33 项相关模拟器回归全部通过，无跳过，187.913 秒：`/private/tmp/actionhalo-reselection-regression.log`。覆盖持续显示菜单的真实重选与精确复制、原生／标准菜单／仅菜单的多行手柄、无字符坐标保护、整段选文及周边、拥挤窗口穿透、正常重新定位、快速复制的背景与保留位置、自定义聊天及厂商菜单、首次与重复选区、取消与来源变化、WebView 普通与快速拖动，以及排队触摸。没有重跑完整应用套件。
- 构建及 61 项 JVM 测试通过；Lint 0 错误、6 项警告：`/private/tmp/actionhalo-reselection-verification-build.log`。临时探针已删除。

## 安装包与边界

`ActionHalo-0.11.15-debug.apk`：versionCode 51，minSdk 26，targetSdk 36，1,597,889 字节。SHA-256：`6fce3d24ab0abd42d80677ef4980e4e50864b34f9e0f13adc98bb53b24161f15`。

ZIP 完整性与签名校验通过，证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与上一交付包一致。APK 条目没有增删，仅应用清单和应用代码 dex 改变。导出包与模拟器回归使用的生产 APK 字节一致，校验和另存 `ActionHalo-0.11.15-SHA256SUMS.txt`。

未验证真实 Codex App、原子笔记、微信和 vivo 真机，也未重跑其他 Android 版本或全部应用测试。应用不提供真实松手信号且菜单持续可用时，恢复时机仍依赖既有稳定检查，无法保证识别手指停留的每个瞬间；选区周边防误触保护继续生效。没有提交、推送或发布远程版本。
