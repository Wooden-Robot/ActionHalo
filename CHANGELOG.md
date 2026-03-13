# Changelog

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
