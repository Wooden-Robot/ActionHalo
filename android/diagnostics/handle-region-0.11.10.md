# Android 0.11.10 空间不足时的手柄穿透

## 真机证据

用户提供的 0.11.9 单次报告明确记录了 `MENU_MATCHED → HALO_NO_SPACE → HALO_ATTACHED`，其中空间不足的隐藏发生在创建窗口之前。用户也反馈微信从一闪而过变为完全不显示。服务连接、授权与菜单匹配均已发生，首帧不可见的直接原因是 `SelectionHaloWindow` 要求整个固定尺寸方形窗口避开全部手柄保护区域，找不到位置就把圆环设为不可见。

## 修复范围

共享窗口同时服务于原生选文和菜单兼容入口。在 API 33 及以上，使用 [AttachedSurfaceControl.setTouchableRegion](https://developer.android.com/reference/android/view/AttachedSurfaceControl#setTouchableRegion(android.graphics.Region))，从窗口触摸区域中减去手柄保护矩形。按实际窗口屏幕坐标转换，并在窗口布局变化后更新。仅在区域变化时更新系统，避免该接口请求布局造成循环；窗口拆卸时解除监听。

能够整体避让时仍采用已有位置选择。无法整体避让时保持圆环尺寸和可见性，由局部触摸穿透保护手柄。手柄按下后的隐藏和松手恢复规则继续生效。用户主动操作圆环、展开操作层时，以实际窗口大小的完整 `Region` 恢复触摸范围，并随布局更新，原来的空白位置重定位和拖动选择继续可用。诊断新增固定类别 `HALO_HANDLE_PASSTHROUGH`。

未增加权限、依赖、触摸注入、后台剪贴板读取或隐藏 API。API 26–32 继续原有整体避让回退，空间不足时仍可能隐藏；这些系统缺少本次使用的公开接口。

## 复现与验证

- 修改前，两项测试稳定失败于圆环不可见，重现真机报告指向的分支：`/private/tmp/actionhalo-touch-region-red.log`，约 4 秒。
- 新增真实框架测试把原生选字手柄放在圆环窗口矩形内部，并让保护条两侧都无法容纳完整圆环。通过真实输入拖动手柄，检查来源选区实际扩展、拖动期间圆环隐藏、尺寸和定位不变、松手恢复，以及首次空白重定位后旧穿透区域重新交由圆环处理。
- 首次穿透测试的目标断言错误地要求选区至少到字符 18；实际控件按词吸附到 17，已从初始 9 扩展。记录于 `/private/tmp/actionhalo-touch-region-probe.log`。测试现按用户行为检查“确实扩展”，生产穿透代码未因此调整。截图等待首帧绘制后采集，已目视确认完整圆环可见。
- 初版定向两项通过，包含完整的真实拖动、恢复与重新定位链路：`/private/tmp/actionhalo-touch-region-targeted.log`。
- 第一轮完整回归在窗口切换时遇到 `WindowManagerService.clearTouchableRegion` 空指针崩溃，单独重跑该用例通过。Android 15 [框架实现](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/android15-release/services/core/java/com/android/server/wm/WindowManagerService.java)的 `null` 重置路径未检查窗口是否已经移除，而设置显式区域的路径会检查。已改为用完整矩形恢复触摸，避免走这条有竞态的清空路径。原失败记录保留于 `/private/tmp/actionhalo-touch-region-regression.log`，单项结果为 `/private/tmp/actionhalo-touch-region-crash-red.log`。
- 改用完整矩形后，三项定向测试通过，覆盖原来的拥挤窗口、真实拖动与重定位，以及完整回归中崩溃的多行选字流程：`/private/tmp/actionhalo-touch-region-safe-targeted.log`，18.125 秒。
- 最终完整相关回归 83 项：81 通过、2 跳过、0 失败，耗时 401.694 秒。包含窗口移除、服务断开重连、菜单识别、选区更新和实际复制。跳过项是未安装的 Telegram 合成夹具和 Via 浏览器。日志：`/private/tmp/actionhalo-touch-region-safe-regression.log`。此前 0.11.9 完整回归中超时的 WebView 用例本次通过。
- 最终构建的 61 项 JVM 测试通过；Lint 0 错误、6 项警告：`/private/tmp/actionhalo-touch-region-safe-build.log`。`git diff --check` 通过。

## 交付

- `ActionHalo-0.11.10-debug.apk`：versionCode 46，minSdk 26，targetSdk 36；1,267,455 字节。
- SHA-256：`34d6759543de126849bb0223e7d2b8e969f6053f8bb4894ab565b4740fc282fd`，另存于 `ActionHalo-0.11.10-SHA256SUMS.txt`。
- ZIP 完整性和 APK v2 签名验证通过，与 0.11.9 使用相同签名。交付文件与上述最终构建、模拟器回归使用的 APK 一致。

本次使用 API 35 无账号模拟器及固定文字。未连接用户手机，不能把模拟器结果视为 vivo / SDK 36 / 真实微信或原子笔记已经通过。未提交、推送或远程发布。
