# Changelog

## v0.3.1
- 修复多屏场景下的 Accessibility 坐标换算，降低副屏和非主屏上的文本命中误判。
- 为插件目录热重载加入防抖，减少连续文件变更时的重复扫描和预热卡顿。
- 改进全局热键注册失败处理，遇到重复快捷键或系统冲突时直接提示，而不是静默失效。
- 为脚本插件建立执行信任模型：安装时提示风险、首次运行前确认、脚本内容变化后自动重新要求信任，并支持在插件管理里查看或撤销信任。
- 修复 GTA 氛围模式下脚本插件信任弹窗无法点击的问题，改为先收起菜单再弹确认框。
- 优化插件管理和编辑器界面：调整操作按钮布局，增强信任徽章视觉状态，修复长提示文案遮挡，并显著增大执行内容输入区高度。
- 新增诊断窗口，可查看当前前台应用、焦点元素、选中文本状态、最近一次文本获取来源与失败原因，以及每个插件当前为何可见或不可用。
- 持久化 OpenFire 全局启用状态，并新增“当前应用插件管理”窗口，支持按应用禁用特定插件且在重启后保留。
- 补充并扩展单元测试，覆盖多屏坐标换算、脚本插件信任、按应用插件覆盖和诊断相关行为。

- Fixed Accessibility coordinate conversion across multiple displays to reduce false hits on secondary and non-primary screens.
- Added debounce to plugin directory hot reloads to avoid repeated rescans and prewarm stalls during bursts of file changes.
- Improved global hotkey registration failure handling so duplicate shortcuts and system conflicts surface clear alerts instead of failing silently.
- Added an execution trust model for script plugins, including install-time warnings, first-run confirmation, automatic re-approval after plugin changes, and trust inspection or revocation from plugin management.
- Fixed script-plugin trust prompts being unclickable in GTA mode by dismissing the menu before presenting the confirmation dialog.
- Refined plugin management and editor UI by reworking action button layout, strengthening trust badge states, fixing clipped long warnings, and giving action-content editors much more vertical space.
- Added a diagnostics window that shows the current frontmost app, focused element, selected-text status, latest text acquisition source and failure reason, and why each plugin is currently visible or unavailable.
- Persisted the global OpenFire enabled state and added a “manage plugins in current app” window so app-specific plugin disables survive relaunches.
- Expanded unit test coverage for multi-display coordinates, script-plugin trust, per-app plugin overrides, and diagnostics-related behavior.

## v0.2.2
- 新增“打开文件位置”内置插件：当选中文本是文件路径时，可直接在 Finder 中打开对应位置，支持 `/`、`~`、带引号路径和 `file://` 路径。
- 调整插件菜单策略：只要插件处于启用状态，就始终保留占位；条件不满足时改为灰态不可执行，同时恢复多页分页行为。
- 改进插件合并与升级策略：更新后尽量不影响已有插件的启用/禁用状态；遇到重复插件时优先保留旧版本插件。
- 重做空输入框下的 `Paste / Clear` 浮层，改为更紧凑的不透明工具条样式，并将左右半边分别作为完整的 `Paste` / `Clear` 触发区域。
- 为 `Paste / Clear` 浮层加入整半区 hover 反馈，避免内层小椭圆式高亮。
- 优化 GTA 氛围下的功能触发退出节奏：缩短菜单淡出时间，并让动作执行与菜单退出并行，减少选中后的卡顿感。
- 补充并扩展单元测试，覆盖路径解析、分页、插件合并、按钮状态与 hover 行为。

- Added a built-in "Reveal in Finder" plugin that appears for file-path selections and opens the matching location in Finder, supporting `/`, `~`, quoted paths, and `file://` URLs.
- Changed plugin menu behavior so every enabled plugin keeps a slot; non-matching actions now stay visible but disabled, while multi-page pagination continues to work.
- Improved plugin merge and upgrade behavior to avoid disturbing existing enabled/disabled states and to prefer older plugin copies when duplicates exist.
- Rebuilt the empty-input `Paste / Clear` popup as a tighter opaque toolbar, with the left and right halves acting as full `Paste` and `Clear` hit regions.
- Added whole-segment hover feedback to the `Paste / Clear` popup without bringing back inner pill highlights.
- Tightened GTA-mode action exit timing by shortening the fade-out and running action execution in parallel with menu dismissal.
- Expanded unit test coverage for path parsing, pagination, plugin merging, button states, and hover behavior.

## v0.2.1
- 菜单栏图标支持右键直接切换 OpenFire 的启用状态。
- 新增默认关闭的 “Run in iTerm2 / 在 iTerm2 中执行” 插件，可将选中文本作为 shell 命令发送到 iTerm2 执行。
- 更新中英文 README，明确产品灵感同时来自 GTA V 和 PopClip。
- 修正文档中的 Script Extensions 示例，补充推荐的外部脚本文件写法与内联脚本说明。

- Added right-click toggling on the menu bar icon to enable or disable OpenFire directly.
- Added a default-disabled "Run in iTerm2" plugin that sends selected text to iTerm2 as a shell command.
- Updated both READMEs to clarify that OpenFire draws inspiration from both GTA V and PopClip.
- Fixed the Script Extensions docs to show the recommended bundled script-file layout alongside inline scripts.

## v0.2.0
- 修复插件过滤未在管理层生效，避免不匹配插件占用菜单名额。
- 修复 Accessibility 权限恢复后重复注册通知的问题。
- 修复停止监听时未清理挂起观察器/任务的问题。
- 改进复制兜底逻辑，完整恢复原有剪贴板内容。

- Fix plugin filtering so non-matching plugins no longer consume menu slots.
- Fix duplicate notification registration after Accessibility permission recovery.
- Fix pending observer/task cleanup when stopping selection monitoring.
- Preserve full clipboard contents when using the copy-based selection fallback.

## v0.1.2
- 调整 Telegram 搜索插件图标为纸飞机。

- Update Telegram search plugin icon to a paper plane.

## v0.1.1
- 修复更新检查请求指向错误仓库导致的解析失败问题。
- 当服务器响应非 200 时给出更明确的错误提示。

- Fix update check failing due to incorrect repository owner.
- Show clearer error when server response is not 200.

## v0.1.0
- 新增 GitHub Releases 更新检测，发现新版本弹窗提示并提供下载/跳转。
- 菜单新增“检查更新…”与“自动检查更新”开关（默认开启）。
- 手动检查支持“已是最新版本”和更友好的网络错误提示，失败可重试。
- 新增 UpdateChecker 相关测试。

- Added GitHub Releases update checking with prompts and download/open link.
- Added “Check for Updates...” and “Auto Check Updates” toggle in the menu (default on).
- Manual checks show “Up to date” and friendlier network error messages with retry.
- Added UpdateChecker tests.
