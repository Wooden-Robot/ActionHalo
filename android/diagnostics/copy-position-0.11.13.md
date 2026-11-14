# Android 0.11.13 复制后圆环位置继承

## 复现

用户报告快速点复制时，圆环短暂漂移再回原位。针对按下、窗口展开、复制执行和保留圆环分别检查屏幕坐标，使用 SDK 36 无账号模拟器和真实跨 UID 文本控件。

- 普通复制后关闭圆环：原生、菜单兼容两个入口的逐帧位置检查均通过，未在此场景复现漂移。记录：`/private/tmp/actionhalo-copy-anchor-frames.log`，2 项，11.774 秒。
- 开启复制后保留圆环：原生入口通过；菜单兼容入口失败，复制前为 `Rect(22, 626 - 1058, 1662)`，复制后为 `Rect(22, 652 - 1058, 1688)`，纵向偏移 26 像素。记录：`/private/tmp/actionhalo-copy-anchor-keep-red.log`。
- 将原圆环的逐帧断言移到窗口交接断言之前，单独重跑兼容用例，仍在新窗口位置断言失败，原窗口所有检查帧位置不变。记录：`/private/tmp/actionhalo-copy-anchor-handoff-red.log`，1 项失败，5.552 秒。定位为复制后新窗口按默认位置重新布局，没有继承用户看到的圆环位置。

最小复现命令（修改前运行失败，修改后通过）：

```sh
adb -s emulator-5580 shell am instrument -w -r \
  -e focused_clipboard_overlay true \
  -e class com.actionhalo.android.FocusedClipboardOverlayTest#quickMenuCopyKeepsTheWheelAtTheSamePosition \
  com.actionhalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

## 修改

`TelegramCopyAssistant` 在移除旧圆环前读取其实际屏幕矩形，通过现有复制回调与 `SelectionAccessibilityService` 传递给 `ClipboardHaloOverlay`。快照窗口保留圆环或显示失败恢复菜单时，沿用这个位置和尺寸，包括用户重新定位产生的位移。

复用 `HaloSafeArea.bindInitialPlacement`，仅在带有原圆环矩形时按该矩形定位；默认的手动分享、选文处理和剪贴板入口仍走原有初始位置逻辑。交接窗口的布局未匹配目标坐标前跳过绘制，避免先显示默认位置，再在下一帧移动。用户开始操作后，仍由原有触摸逻辑控制重新定位。

没有改动 `SelectionHaloWindow` 的触摸展开、防误触区域、背景时机或普通复制关闭逻辑；保留聚焦读取、选文快照、权限及新鲜度校验。屏幕矩形只存在于当前复制会话，不增加设置或持久化记录。

## 验证

- 第一轮 5 项定向测试全部通过，24.906 秒：`/private/tmp/actionhalo-copy-anchor-green.log`。覆盖两入口的普通复制、两入口的保留圆环，以及保留窗口从第一帧起使用原矩形。
- 最终位置检查使用 `OnDrawListener` 记录实际绘制的帧；被布局保护取消的预绘制帧不计入。保留窗口用例同时检查位置与尺寸，复制用例通过独立聚焦窗口验证精确复制内容。
- 0.11.13 构建和 61 项 JVM 测试通过，Lint 0 错误、6 项警告：`/private/tmp/actionhalo-copy-anchor-final-build.log`。
- 首轮相关回归 26 项中 25 项通过、1 项失败，无跳过：`/private/tmp/actionhalo-copy-anchor-regression.log`。失败的是新增的重新定位后复制用例。坐标探针显示测试缓存的复制按钮为 `Rect(461, 1131 - 593, 1263)`，而实际控件左上角已为 `(439, 505)`，没有点到移动后的按钮。测试现等待输入帧完成，并刷新无障碍节点后读取坐标；保留实际按钮位置和复制前后矩形的断言。探针记录：`/private/tmp/actionhalo-copy-anchor-reposition-probe.log`。
- 修正测试坐标读取后，最终 8 项位置与重新定位测试全部通过，41.221 秒：`/private/tmp/actionhalo-copy-anchor-final-position.log`。覆盖普通复制、保留圆环、已重新定位的圆环、第一帧位置及两入口的滑动重新定位。生产 APK 未再修改；最终测试构建与 lint 通过，`git diff --check` 通过。未重复运行已通过的其余相关用例。

## 安装包

- `ActionHalo-0.11.13-debug.apk`：versionCode 49，minSdk 26，targetSdk 36，1,270,035 字节。
- SHA-256：`8dcb49509cf6c268330ef4c1c72cf847204ebab86ef82fc6ee2cefb40a6461b7`，另存 `ActionHalo-0.11.13-SHA256SUMS.txt`。
- ZIP 完整性及 APK v2 签名验证通过。证书 SHA-256 为 `58b29de06a5f9010b876d073df1b9ea459e3d356ba395d3a8032066f31540d83`，与之前交付包一致，可覆盖安装。交付文件与回归使用的生产 APK 字节相同。

本次复现并修复的是菜单兼容模式下复制后保留圆环的位置偏移；未连接用户 vivo 真机，不能保证覆盖厂商系统上其他瞬时位移路径。未运行完整 Android 测试集，未提交、推送或远程发布。
