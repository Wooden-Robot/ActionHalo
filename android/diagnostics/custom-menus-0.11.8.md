# Android 0.11.8 自定义选文与消息菜单

用户截图分别展示了带「小 V 写作、剪切、复制」的厂商工具栏，以及带「复制、转发、收藏」的消息菜单。截图能确认按钮组合，不能证明实际控件 ID、窗口归属或无障碍层级；本次未连接用户手机。

后续真机反馈（2026-10-24）：用户试用后仍表示圆环不会弹出，问题未解决。下述合成测试仅证明已构造的菜单结构能够触发，不能作为微信或原子笔记兼容成功的依据。当前未连接 Android 设备，已请求用户在微信复现后提供「诊断 → 复制故障诊断」文本，以核对真实服务状态、选文事件和处理阶段；收到证据前不认定根因，也不继续按截图猜测窗口结构。

随后收到的报告确认服务连接、权限和开关正常，记录过 `DIRECT_HALO_SHOWN`，但缺少该阶段的时间和隐藏／删除原因；`FILTERED` 也没有具体类别。用户进一步说明为「微信一闪而过，原子笔记不出现」。后续最小复现、修正及增强诊断见 [0.11.9 记录](menu-lifecycle-0.11.9.md)，仍需真机确认。

旧识别器要求同包子窗口提供 Android 标准菜单标识，只有已授权的 Telegram 路径允许非标准菜单。本次在「通用选文菜单兼容」下增加组合识别：真实可点的复制控件，加上剪切／全选，或者同时具有转发和收藏。沿用同包、子窗口、前台来源、控件可点击、可见、非密码和非敏感校验；仍不扫描主页面或聊天正文。

只有选择圆环动作后才点击复制并读取本次新剪贴板。普通复制按钮、不完整菜单及歧义复制目标不触发。Telegram 自定义菜单继续使用其独立授权。重新定位与选文手柄保护逻辑未撤回。

## 验证

- 修改前，两种无标准 ID 的真实 Android 子窗口夹具都失败于「菜单存在，但圆环未出现」。日志：`/private/tmp/actionhalo-custom-menu-red.log`。
- 修改后，两种菜单首次触发、动作前剪贴板不变、动作后准确复制，以及普通复制按钮、不完整菜单排除共四项通过。日志：`/private/tmp/actionhalo-custom-menu-targeted.log`。
- 首次完整回归报告 79 项：76 通过、2 条件跳过、1 失败。失败为 `standardMenuCancellationResetsReadinessForTheNextInitialSelection`，未等到范围调整后的圆环。不能将这轮写为全部通过。日志：`/private/tmp/actionhalo-custom-menu-final-regression.log`。
- 该项独立复验通过；新增的嵌套文字标签与可点击容器菜单也通过。随后按失败前五项用例组合复验，六项均通过。未更改生产代码或放宽断言来消除失败；超时原因尚未确定。日志：`/private/tmp/actionhalo-custom-menu-readiness-nested.log`、`/private/tmp/actionhalo-custom-menu-readiness-sequence.log`。
- 59 项 JVM 测试通过；Lint 0 错误、6 项警告。日志：`/private/tmp/actionhalo-custom-menu-verified-build.log`、`/private/tmp/actionhalo-custom-menu-nested-build.log`。
- 未执行的两项依赖另外安装的 Telegram 合成宿主及 Via 浏览器测试条件。这些合成回归不等同于真实微信、原子笔记或 OriginOS 验证。

## 安装包

`ActionHalo-0.11.8-debug.apk`，versionCode 44，minSdk 26，targetSdk 36。交付包与已测试生产包字节一致，ZIP 完整性和签名校验通过；与前版使用相同签名，可以覆盖安装。

主窗口内绘制、未公开可点击控件、跨包或无法核对来源的菜单仍可能不被识别。故障报告已补充选区事件及固定结果分类，不包含正文或剪贴板内容。未提交、推送或发布远程版本。
