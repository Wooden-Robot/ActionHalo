# Changelog

## Unreleased

## v0.3.28

- OpenFire 原位升级后的 App 包会在启动服务前排他原子改名为 `ActionHalo.app` 并重新启动；目标冲突、父目录不可写、只读卷、网络卷和 App 包自身为符号链接时均不覆盖、不删除。
- 首次改名由 Finder 双击 `.actionhaloext` 或 `.openfireext` 触发时，会在重启后继续处理原始插件安装请求，不会因迁移丢失。
- Sparkle appcast 会嵌入本版本更新日志，更新窗口可以直接显示发布说明；发布门禁会拒绝缺少说明或说明版本不匹配的 feed。

- App bundles upgraded in place from OpenFire are atomically renamed without replacement to `ActionHalo.app` before services start, then relaunched; conflicts, unwritable parent folders, read-only or network volumes, and app-bundle symlinks remain untouched.
- Finder-launched `.actionhaloext` and `.openfireext` requests are carried through the one-time rename and handled after relaunch instead of being dropped.
- The Sparkle appcast embeds this version's changelog so release notes appear directly in the update window; release gates reject feeds with missing or mismatched notes.

## v0.3.27

- 项目对外品牌、应用/可执行文件、SwiftPM 模块、构建产物、插件格式、界面、文档和 GitHub 发布地址统一更名为 ActionHalo。
- 新插件规范改为 `.actionhaloext`、`com.actionhalo.*` 与 `ACTIONHALO_TEXT(_FILE)`；兼容期内仍可打开、迁移和执行旧 `.openfireext`、`com.openfire.*` 与 `OPENFIRE_TEXT(_FILE)` 插件。
- 保留现有 Bundle ID、Sparkle 公钥、签名密钥账户和插件指纹版本，延续老用户的设置、权限身份、脚本信任与自动更新链。
- 旧用户插件按 ID 一次性复制到 ActionHalo 数据目录，ActionHalo 侧已有插件优先，旧副本不删除且用户删除后的插件不会在重启时复活。

- Renamed the public brand, app/executable, SwiftPM module, build artifacts, plugin format, UI, documentation, and GitHub release URLs to ActionHalo.
- Made `.actionhaloext`, `com.actionhalo.*`, and `ACTIONHALO_TEXT(_FILE)` canonical while continuing to open, migrate, and run legacy `.openfireext`, `com.openfire.*`, and `OPENFIRE_TEXT(_FILE)` plugins during the transition.
- Preserved the existing bundle identifier, Sparkle public key, signing-key account, and plugin fingerprint version so existing settings, permission identity, script trust, and the signed update chain remain intact.
- Added one-time, ID-tracked migration into the ActionHalo plugin directory; current packages win conflicts, rollback copies remain untouched, and deleted migrated plugins do not reappear on restart.

## v0.3.26
- 修复 Telegram、Codex 等应用无法提供辅助功能焦点元素时，选中文字后圆环无法自动出现、全局快捷键也无响应的问题。
- 对精确匹配的兼容应用启用受 PID 绑定的 `Cmd+C` 回退，并将缺失焦点支持贯通选区检测、延迟展示和菜单目标上下文。
- 保持安全输入、受保护文本和非白名单应用的失败关闭策略，同时将重复复制抑制限制在短时间窗口内，避免旧选区长期阻止相同文本再次触发。
- 增加缺失焦点、应用切换、安全输入和重复选区的回归测试。

- Fixed automatic radial-menu presentation and global hotkeys in Telegram, Codex, and other applications that do not expose an Accessibility focused element.
- Added PID-bound `Cmd+C` fallback for exact compatibility matches and carried missing-focus support through selection detection, delayed presentation, and menu target context.
- Preserved fail-closed behavior for secure input, protected text, and non-allowlisted applications while bounding duplicate-copy suppression to a short window so stale selections do not block identical text indefinitely.
- Added regression coverage for missing focus, application changes, secure input, and repeated selections.

## v0.3.25
- 将最低系统要求从 macOS 13 下调至 macOS 12 Monterey，并同步 SwiftPM、Universal 构建目标、App 启动要求与中英文文档。
- 用基于 `NSLock` 的状态锁替换仅 macOS 13 及以上可用的 `OSAllocatedUnfairLock`，保持剪贴板回退与插件状态的并发安全。
- 统一圆环视图与窗口的外侧交互半径，修复鼠标在外侧方向选择区域松开时事件被其他视图截获、动作未执行的问题。
- 新增状态锁并发回归测试，并验证 Intel 与 Apple 芯片发布二进制的最低系统版本均为 macOS 12.0。

- Lowered the minimum system requirement from macOS 13 to macOS 12 Monterey across SwiftPM, universal build targets, the app launch requirement, and the English and Chinese documentation.
- Replaced the macOS 13-only `OSAllocatedUnfairLock` with an `NSLock`-backed state lock while preserving concurrency safety for clipboard fallback and plugin state.
- Unified the radial view and window outer interaction radius, fixing actions not firing when the mouse was released in the outer directional selection area because a sibling view intercepted the event.
- Added concurrent lock regression coverage and verified that both Intel and Apple silicon release binaries declare macOS 12.0 as their minimum system version.

## v0.3.24
- 发布自动更新验证版本，用于完整测试从 v0.3.23 检测更新、下载、Ed25519 签名校验、安装并重启的流程。
- 除版本升级与发布说明外，不包含新的功能行为变更。

- Released an automatic-update validation build for end-to-end testing from v0.3.23 through update detection, download, Ed25519 verification, installation, and relaunch.
- Contains no new functional behavior changes beyond the version bump and release notes.

## v0.3.23
- 接入 Sparkle 2 安全自动更新：检测到新版本后可在应用内下载、验证，经标准“安装并重启”确认后原子安装并重启；保留原有自动检查开关并迁移已有偏好，同时防止更新重启丢失插件编辑器的未保存内容。
- 固定 Sparkle 版本与 revision，启用 Ed25519 更新包签名、签名 appcast、解包前校验，并为框架嵌入、嵌套签名和发布资产增加门禁。
- 将发布流程收敛为无需 Developer ID 的社区模式：App 与 Sparkle helper 使用 ad-hoc 签名，更新包以 Ed25519 作为发布信任根，同时保留版本、tag、最终 DMG 与 GitHub 资产一致性校验。

- Added secure Sparkle 2 updates with the standard install-and-relaunch confirmation, atomic installation, preference migration, and protection against losing unsaved plugin edits during an update restart.
- Pinned Sparkle by version and revision, enabled Ed25519 archive signatures, signed appcasts, pre-extraction verification, and added gates for framework embedding, nested signing, and release assets.
- Switched releases to a no-Developer-ID community workflow: the app and Sparkle helpers are ad-hoc signed, Ed25519 is the update trust root, and version, tag, final-DMG, and GitHub-asset consistency gates remain enforced.

## v0.3.22
- 加固文本选择手势的一致性，避免跨应用、跨窗口与受保护输入状态误触发，同时保留首次聚焦输入框和浏览器正文选区。
- 将 Cmd+C 回退改为可回滚的剪贴板事务，稳定读取复制结果，完整恢复多类型与大体积内容，并在失败路径清理临时资源。
- 收紧插件安装、删除、信任、URL、脚本环境和正则过滤边界，修复目录穿越、符号链接、安装时序与编辑配置丢失问题。
- 修复圆环菜单、粘贴弹窗、状态栏、诊断窗口与更新检查中的重复执行、陈旧状态和异步生命周期竞态。
- 增加严格并发检查、并行回归、发布构建与本地 DMG 冒烟验证；正式发布改为强制 Developer ID 签名、公证、装订及完整校验。
- 修复自定义快捷键插件录制后未写回配置的问题，支持新建与重新录制，并保留全局快捷键回调行为。
- 将插件监听路径发现移出主线程并增加独立防抖；原子替换配置后会立即重挂目标 watcher，避免连续编辑丢失更新。
- 为 Developer ID 发布包补齐 Apple Events 权限及用途说明，并新增签名产物权限门禁。

- Hardened text-selection gesture consistency across processes, windows, protected inputs, newly focused fields, and browser content.
- Made Cmd+C fallback a rollback-safe clipboard transaction with stable reads, multi-type and large-payload restoration, and failure cleanup.
- Tightened plugin install, delete, trust, URL, script-environment, and regex boundaries, including traversal, symlink, install-race, and editor-preservation fixes.
- Fixed duplicate actions and stale async state across the radial menu, paste popup, status item, diagnostics, and update checks.
- Added strict-concurrency checks, parallel regressions, release builds, and local DMG smoke tests; distributable releases now require signing, notarization, stapling, and full validation.
- Fixed custom key-combo recording so new and replacement combinations are persisted without changing global-hotkey callbacks.
- Moved plugin watcher discovery off the main thread, added separate debouncing, and immediately reattached atomically replaced paths so consecutive edits are not missed.
- Added the Apple Events entitlement and purpose string to Developer ID releases, with a gate that verifies the signed artifact.

## v0.3.21
- 提升文本选择触发的稳定性：将 Event Tap 回调收敛为轻量事件转发，增加前台进程与上下文复核，并阻止无障碍信息不可读时重复使用旧的 Cmd+C 文本，同时保留 Chrome、Telegram 与同类 WebView 应用的新选区回退能力。
- 强化剪贴板保护：完整保留多类型剪贴板内容，大数据自动暂存到临时文件并按需恢复，失败或取消时及时清理，降低 Cmd+C 回退覆盖用户剪贴板的风险。
- 修复内置剪切与删除动作的执行路由和可编辑上下文判定；外部快捷键与脚本插件继续经过受保护的信任快照，避免绕过安全确认。
- 加固插件生命周期：限制插件包大小与文件数量、拒绝危险符号链接、对完整受保护插件包生成信任指纹，并将插件安装、保存、信任检查改为更安全的原子或后台流程。
- 优化圆环菜单、快捷键、应用排除与诊断状态的一致性，并完善中英文安装镜像提示。
- 扩充回归测试至 205 项，覆盖文本选择、剪贴板恢复、插件安全、菜单关闭与配置容错。

- Improved text-selection reliability by reducing the Event Tap callback to lightweight event forwarding, revalidating the frontmost process and context, and rejecting stale Cmd+C text when Accessibility data is unreadable while preserving fresh-selection fallback for Chrome, Telegram, and similar WebView apps.
- Hardened clipboard protection by preserving multiple pasteboard representations, spilling large payloads to temporary files for lazy restoration, and cleaning them up after failure or cancellation.
- Fixed execution routing and editable-context checks for the built-in Cut and Delete actions; external shortcuts and script plugins continue to use protected trust snapshots.
- Strengthened the plugin lifecycle with package size and file-count limits, unsafe symlink rejection, whole-package trust fingerprints, and safer atomic or background install, save, and trust-check flows.
- Improved consistency across radial-menu dismissal, hotkey validation, app exclusions, diagnostics, and bilingual DMG installation guidance.
- Expanded regression coverage to 205 tests across selection handling, clipboard restoration, plugin security, menu dismissal, and configuration validation.

## v0.3.20
- 修复 Chrome 等浏览器里选中文本无法唤起圆环的问题：当 AX 焦点元素不可读时，允许受控的浏览器/Chromium 富文本宿主走 Cmd+C 回退获取选中文本。
- 保留文件拖拽、窗口拖拽和普通编辑器的保护逻辑，避免为了修复浏览器触发而重新引入误触发。
- 补充 `AccessibilityManager` 与 `TextSelectionMonitor` 回归测试，覆盖 Chrome、Arc/Codex、Telegram 与 Remote Desktop 边界。

- Fixed text selection not opening the radial menu in Chrome and similar browsers by allowing controlled browser/Chromium rich-text hosts to use the Cmd+C fallback when AX focused elements are unreadable.
- Kept file-drag, window-drag, and regular-editor safeguards in place so the browser fix does not reintroduce false triggers.
- Added `AccessibilityManager` and `TextSelectionMonitor` regression coverage for Chrome, Arc/Codex, Telegram, and Remote Desktop boundaries.

## v0.3.19
- 修复直接往插件目录新增 `.actionhaloext` 插件包后列表不刷新的问题：现在会同时监听用户插件目录和已有插件包目录，包内 `Config.json` 后续写入也会触发重新加载。
- 插件管理列表滚动条改为默认显示，避免用户误以为只加载了前 10 个插件。
- 补充 `PluginManager` 回归测试，覆盖可监听插件目录筛选与新增插件包监听链路。

- Fixed plugin packages added directly to the plugins folder not appearing in the management list: ActionHalo now watches both the user plugins directory and existing `.actionhaloext` package directories, so later writes such as `Config.json` trigger reloads.
- Made the plugin management scrollbar always visible so users can tell there are more than the first 10 plugins.
- Added `PluginManager` regression coverage for watchable plugin-directory discovery and newly added plugin package watching.

## v0.3.18
- 默认将整套办公软件加入 `ExcludedApps`：Apple iWork（`Pages / Numbers / Keynote`，含旧版 iWork bundle id）、Microsoft Office（`Word / Excel / PowerPoint`）与 WPS。
- 新增一次性迁移逻辑：新装和老用户升级都会补齐上述默认禁用项，但用户后续手动重新开启后不会在下次启动时被自动关回去。
- 补充 `AppDelegate` 回归测试，覆盖首次迁移、合并已有排除项、避免重复写入以及迁移只执行一次的行为。

- Default-added full office suites to `ExcludedApps`: Apple iWork (`Pages / Numbers / Keynote`, including legacy iWork bundle IDs), Microsoft Office (`Word / Excel / PowerPoint`), and WPS.
- Added a one-time migration so fresh installs and upgrades both receive the default exclusions, while users who manually re-enable an app keep that choice on later launches.
- Added `AppDelegate` regression coverage for first-run migration, merging with existing exclusions, avoiding duplicates, and ensuring the migration only runs once.

## v0.3.17
- 收紧富文本宿主 heuristic，避免 `code` / `desktop` 这类宽匹配把 `Xcode`、`Remote Desktop` 等应用误判成富文本选择宿主。
- 统一空输入场景下 `Paste` 胶囊与主圆环的上下文判定，内置 `Paste` 现在也会遵守插件自身的显示规则。
- 改进 diagnostics：在 AX 读不到当前选区时回退展示最近一次真实获取到的文本，并把插件状态区分为 `Shown`、`Shown, Disabled`、`Hidden`。
- 将前台应用抑制也纳入 diagnostics readiness，避免 report 在 Finder / Dock / 截图工具等被抑制场景里误报可触发。
- 补充 `AccessibilityManager`、`AppDelegate` 与新增 `DiagnosticsWindow` 回归测试，覆盖 heuristic 边界、Paste 上下文一致性和 diagnostics 状态表达。

- Tightened rich-text host heuristics so broad `code` / `desktop` substring matches no longer misclassify apps like Xcode or Remote Desktop as rich-text selection hosts.
- Unified the empty-input `Paste` capsule with the main radial-menu context rules so the built-in paste action now respects its plugin visibility filters in both entry points.
- Improved diagnostics by falling back to the most recently acquired real selection text when AX cannot read the current selection, and by distinguishing plugin states as `Shown`, `Shown, Disabled`, and `Hidden`.
- Added frontmost-app suppression to diagnostics readiness so the report no longer implies the menu is ready inside intentionally suppressed contexts such as Finder, Dock, or screenshot tools.
- Added regression coverage for heuristic boundaries, paste-context consistency, and diagnostics presentation state across `AccessibilityManager`, `AppDelegate`, and `DiagnosticsWindow`.

## v0.3.16
- 允许内置 `Paste` 动作出现在主圆环中，不再只通过空输入框场景下的 `Paste / Clear` 胶囊入口访问。
- 将 `Paste` 的可执行条件收紧为“当前焦点必须可编辑”，这样它在非输入上下文里仍可见但会保持灰态，避免误导点击。
- 同步更新中英文 README，对 `Paste` 在圆环与空输入快捷入口中的分工做了重新说明。
- 补充 `AppDelegate` 回归测试，覆盖 `Paste` 进入圆环以及其可执行条件。

- Allowed the built-in `Paste` action to appear in the main radial menu instead of being restricted to the empty-input `Paste / Clear` capsule.
- Tightened `Paste` executability so it only becomes active when the current focus is editable, keeping it visible but disabled in non-editable contexts.
- Updated the English and Chinese READMEs to describe the new relationship between radial-menu paste and the empty-input shortcut.
- Added `AppDelegate` regression coverage for paste-in-ring behavior and its executability rules.

## v0.3.15
- 修复 Telegram 文本选择回归：恢复 Telegram 正文拖选后的圆环触发，同时继续拦截拖拽窗口导致的误触发。
- 将“拖拽窗口误触发”的判断从脆弱的 AX 文本命中切换为前台窗口位移检测；只要本次手势导致前台窗口真的移动，就直接视为窗口拖拽并抑制。
- 为富文本宿主补充更稳的焦点边界辅助判定，并为 Telegram 保留 `Cmd+C` 盲区 fallback，避免其在鼠标抬起瞬间拿不到 AX 命中/焦点时丢失正常触发能力。
- 补充 `TextSelectionMonitor` 与 `AccessibilityManager` 回归测试，覆盖窗口位移检测、Telegram fallback 与富文本焦点上下文判定。

- Restored Telegram text-selection triggering so dragging over Telegram message text brings up the radial menu again while window-drag false positives remain suppressed.
- Replaced the fragile AX-hit-test-based window-drag guard with frontmost-window movement detection, treating any gesture that actually moves the active window as a window drag and suppressing it immediately.
- Added a more resilient focused-element bounds signal for rich-text hosts and kept a Telegram-specific `Cmd+C` blind fallback so selection still works even when Telegram exposes no usable AX hit/focus element at mouse-up time.
- Added regression coverage for frontmost-window movement detection, Telegram fallback gating, and rich-text focused-context handling in `TextSelectionMonitor` and `AccessibilityManager`.

## v0.3.14
- 修复网页与 WebView 富文本场景的文本选择回归：恢复 Chrome、Codex App、Telegram 及同类 Electron/WebView 应用中的选中文本触发，同时保持拖窗口、拖文件等非文本手势不再误触发圆环。
- 将网页正文命中从按应用名猜测改为按 `AXBrowser`、`AXWebArea`、`AXDocument` 等富文本上下文识别，并为富文本 `AXGroup` 容器补充通用判定，减少对单个应用白名单的依赖。
- 强化 `Cmd+C` 回退链路：改为在短窗口内轮询 pasteboard，等待异步复制真正写入新文本后再触发，提高 Chrome、Codex App 等浏览器/WebView 类应用的稳定性。
- 补充 `AccessibilityManager` 与 `TextSelectionMonitor` 回归测试，覆盖网页/富文本上下文命中、异步 pasteboard 更新以及“从文本区域起手”的 fallback 触发条件。

- Restored text-selection triggering in browser and WebView rich-text contexts, bringing back reliable selection handling in Chrome, Codex App, Telegram, and similar Electron/WebView hosts while still suppressing non-text gestures such as window drags and file drags.
- Replaced app-name heuristics for page-text detection with richer `AXBrowser` / `AXWebArea` / `AXDocument` context checks and generalized `AXGroup` handling for rich-text containers, reducing dependence on per-app allowlists.
- Hardened the `Cmd+C` fallback path by polling the pasteboard briefly for asynchronously written copied text before triggering, improving stability for Chrome, Codex App, and other browser/WebView-based apps.
- Added regression coverage for rich-text context detection, asynchronous pasteboard updates, and the restored “started in text context” fallback gating in `AccessibilityManager` and `TextSelectionMonitor`.

## v0.3.13
- 调整 Accessibility 旧记录清理逻辑：首次安装、同版本重装或升级后只要当前权限实际缺失，就会在弹出权限引导前先同步 reset，避免用户进入辅助功能页时仍看到旧的 ActionHalo 授权记录。
- 修复文件拖拽与文本拖选的判定冲突：文件拖拽抑制现在要求拖拽 pasteboard 在本次手势内确实发生变化，避免旧的拖拽残留把正常文本选中一直误判成文件拖拽。
- 修复 Finder 中文本编辑场景被过度拦截的问题：普通文件拖拽仍不触发圆环，但在 Finder 重命名文件名时选中文本会恢复正常触发。
- 补充 `AppDelegate` 与 `TextSelectionMonitor` 回归测试，覆盖同版本重装缺权限、拖拽 pasteboard 变化判定和 Finder 可编辑文本焦点等场景。

- Refined stale Accessibility-entry cleanup so first installs, same-version reinstalls, and upgrades all reset before prompting whenever access is actually missing, preventing old ActionHalo entries from misleading users in System Settings.
- Fixed the conflict between file-drag suppression and normal text selection by requiring the drag pasteboard to change during the current gesture before treating it as a file drag.
- Restored radial-menu triggering for editable Finder rename fields while continuing to suppress ordinary file-drag interactions.
- Added regression coverage for the updated `AppDelegate` and `TextSelectionMonitor` behaviors, including same-version reinstalls without access, drag-pasteboard change gating, and editable Finder text focus.

## v0.3.12
- 修复文件拖拽误触发：将 `Dock` 也纳入文件管理场景抑制范围，避免拖动文件到桌面、Dock 或相关系统区域时错误弹出圆环。
- 为 `TextSelectionMonitor` 补充 `Dock` 场景回归测试，同时保持 `Telegram Desktop`、`Remote Desktop` 等正常应用不受误伤。

- Fixed file-drag false positives by treating `Dock` as another file-management context, preventing the radial menu from appearing while dragging files through the desktop, Dock, or related system surfaces.
- Added regression coverage for the `Dock` suppression path while keeping normal apps such as Telegram Desktop and Remote Desktop unaffected.

## v0.3.11
- 调整升级后的 Accessibility 权限恢复策略：不再对所有版本升级一刀切 reset，但如果升级后检测到当前权限已失效，仍会自动执行一次 reset，修复“权限面板里还是旧版本记录导致新版本不生效”的场景。
- 补充 `AppDelegate` 回归测试，覆盖首启、同版本重启、显式兼容兜底和“升级后权限失效”这几种权限重置分支。

- Refined the post-upgrade Accessibility recovery policy so version changes no longer reset permissions unconditionally, while still automatically resetting once when an upgraded build detects that Accessibility access is no longer effective.
- Added `AppDelegate` regression coverage for first launch, same-version relaunch, explicit compatibility fallback, and the “permission missing after upgrade” recovery path.

## v0.3.10
- 收紧前台应用抑制规则：Finder/Desktop 仍会被正确屏蔽，但不再误伤 `Telegram Desktop`、`Remote Desktop` 等名称包含 Desktop 的普通应用。
- 优化选中文本回退复制链路：不再先清空系统剪贴板，只有在确实拿到新的复制结果时才恢复旧内容，减少剪贴板闪动和覆盖风险。
- 收紧空输入点击判定：拿不到输入框边界时不再乐观假定命中，降低 `Paste / Clear` 弹窗误触发概率。
- 优化升级体验：版本变更时默认不再自动 reset Accessibility 权限，只保留显式开启的兼容兜底开关。
- 补充 `TextSelectionMonitor`、`AccessibilityManager` 与 `AppDelegate` 相关回归测试，覆盖以上行为调整。

- Tightened frontmost-app suppression so Finder/Desktop remain blocked without incorrectly disabling normal apps whose names include “Desktop”, such as Telegram Desktop or Remote Desktop.
- Improved the fallback copy path by no longer clearing the system pasteboard first and only restoring the previous clipboard when a fresh copied value is actually observed.
- Made empty-input hit testing conservative when field bounds are unavailable, reducing accidental `Paste / Clear` popup triggers.
- Improved upgrade UX by no longer resetting Accessibility permissions on every version change unless the explicit compatibility fallback is enabled.
- Added regression coverage for the updated `TextSelectionMonitor`, `AccessibilityManager`, and `AppDelegate` behaviors.

## v0.3.9
- 修复 Finder/Desktop 文件管理场景的误触发：将 app 拖入“应用程序”文件夹等安装动作不再触发圆环。
- 为 Finder 与 Desktop(WindowManager) 前台场景补充抑制回归测试，防止文件拖拽安装再次误判为文本选择。

- Fixed false positives in Finder/Desktop file-management contexts so drag-install flows such as dropping an app into Applications no longer trigger the radial menu.
- Added regression coverage for Finder and Desktop (WindowManager) frontmost suppression to prevent file drag installs from being misclassified as text selection.

## v0.3.8
- 修复截图工具兼容性：当前台应用是系统截图、Snipaste、CleanShot X、Shottr、Xnapper、Snagit、PixPin、iShot 等抓屏工具时，ActionHalo 不再介入鼠标抬起后的选区/输入框检测，避免截图界面因为鼠标移动或状态切换被打断。
- 同时屏蔽 ActionHalo 自身作为前台应用时的全局触发检测，减少自干扰。

- Fixed screen-capture compatibility so ActionHalo no longer hooks mouse-up selection or empty-input detection while the frontmost app is a screenshot tool such as macOS Screenshot, Snipaste, CleanShot X, Shottr, Xnapper, Snagit, PixPin, or iShot.
- Also suppressed global trigger detection while ActionHalo itself is frontmost to reduce self-interference.

## v0.3.6
- 修复受保护输入场景的误触发：密码框、隐藏输入框及开启 Secure Event Input 的输入上下文中，不再因为选中内容而弹出圆环。
- 保持圆环的键盘关闭语义不变：普通场景下按下任意按键仍会立即收起圆环，避免选中后继续输入时被遮挡。

- Fixed protected-input false positives so password fields, hidden text inputs, and other Secure Event Input contexts no longer trigger the radial menu when text is selected.
- Preserved keyboard dismissal semantics so any normal key press still closes the radial menu immediately in non-protected contexts.

## v0.3.5
- 理顺快捷键语义：将“自动触发开关”和“手动呼出圆环”拆成两条独立逻辑，关闭自动触发后仍可通过手动快捷键呼出菜单。
- 修正菜单栏中的快捷键文案，明确区分“呼出菜单快捷键”和“自动触发开关快捷键”，减少混淆。
- 移除此前错误挂到菜单项上的本地快捷键绑定，避免未设置或冲突时出现误触。
- 为首次启动提供更顺手的默认快捷键：`⇧⌥D` 呼出菜单，`⇧⌥X` 切换自动触发；同时保留“用户清空后不再自动恢复默认值”的行为。

- Split hotkey semantics so automatic text-selection triggering and manual menu invocation are independent; manual invocation still works when auto-trigger is off.
- Clarified menu-bar copy to distinguish the “open menu” hotkey from the “auto-trigger toggle” hotkey.
- Removed the incorrect local NSMenuItem shortcut binding that could cause accidental triggers when unset or conflicted.
- Added more ergonomic first-run defaults: `⇧⌥D` to open the menu and `⇧⌥X` to toggle auto-trigger, while still respecting explicit user clearing.

## v0.3.4
- 改写 README 中关于触发方式、`Paste / Clear` 与可编辑输入框场景的描述，使文案与实际行为一致。
- 为默认内置功能新增 `Delete` 区域，并限制其仅在可编辑选区中可执行。
- 为鼠标选中文本触发加入短暂缓冲，降低对立即删除、覆盖输入和继续改选区的打扰。
- 修复空输入 `Paste` 快捷入口绕过按应用禁用规则的问题，并补齐相关测试。
- 统一插件安装、保存、删除和用户覆盖包识别逻辑，避免旧命名插件遮蔽新版本。
- 为脚本插件加入超时与强制终止保护，降低卡死风险。
- 将启动时的 Accessibility TCC reset 改为异步执行，避免阻塞启动。
- 加强 Accessibility 类型检查，修复异常 AX 返回值下的潜在崩溃。
- 改进 Launch at Login、语言切换后的重启、更新检查和 Diagnostics 的状态一致性。
- 修复更新检查请求指向错误 GitHub 仓库 owner 导致的 `404` 错误。
- 修复 Telegram 搜索与 iTerm2 执行的重复触发排查链路，并收敛 Telegram 冷启动搜索脚本为更稳的单轮 ready-gated 方案。
- 修复 Diagnostics 窗口文本视图布局错误导致面板看起来空白的问题。
- 新增全局 `Per-App Overrides` 管理窗口，可集中查看并恢复“某插件在哪个应用中被禁用”的覆盖规则。
- 修正 Diagnostics 的 readiness 判断，使其优先基于最近一次真实输入框探测位置，而不是当前鼠标位置。
- 为 `Per-App Overrides` 和“当前应用插件管理”窗口补充搜索、自动刷新与更轻量的状态同步。
- 为菜单栏中的 `Per-App Overrides` 增加实时数量提示，方便快速发现是否存在按应用禁用记录。
- 优化插件安装反馈，成功后改为轻量状态栏提示，不再额外弹出成功对话框。
- 为插件管理列表补充长名称截断与 tooltip，减少窄宽度下的信息拥挤。
- 为插件编辑器加入实时保存前校验，提前拦截非法 identifier、无效 URL 和缺失内容。

- Rewrote README trigger, `Paste / Clear`, and editable-input wording so the documentation matches the actual behavior.
- Added a built-in `Delete` action and limited it to editable selections only.
- Added a short delay for mouse-selection-triggered menus to reduce interference with immediate delete, overwrite, or reselection flows.
- Fixed the empty-input `Paste` shortcut bypassing per-app plugin disable rules and added coverage for it.
- Unified plugin install, save, delete, and user-override resolution so legacy-named bundles no longer shadow newer overrides.
- Added timeout and forced-termination protection for script plugins to reduce hang risk.
- Moved the launch-time Accessibility TCC reset off the startup path to avoid blocking launch.
- Hardened Accessibility type handling to prevent crashes on unexpected AX return values.
- Improved consistency across Launch at Login, relaunch-after-language-change, update checking, and Diagnostics state reporting.
- Fixed update checks hitting the wrong GitHub repository owner and returning `404`.
- Investigated the duplicate-trigger reports for Telegram Search and Run in iTerm2, then converged Telegram cold-start search to a more reliable single-pass, ready-gated AppleScript flow.
- Fixed a Diagnostics text-view layout bug that could leave the diagnostics panel visually blank.
- Added a global `Per-App Overrides` window to review and restore app-specific plugin disables from one place.
- Corrected Diagnostics readiness reporting so it prefers the last real empty-input probe location instead of the current mouse position.
- Added search, live refresh, and lighter state syncing for both the global per-app overrides window and the current-app plugin window.
- Added a live override-count badge to the menu-bar `Per-App Overrides` entry so app-scoped disables are easier to spot.
- Reduced install friction by replacing the post-install success dialog with lightweight menu-bar feedback.
- Improved plugin list readability with truncation and tooltips for long names and compact action buttons.
- Added real-time pre-save validation in the plugin editor for invalid identifiers, malformed URLs, and missing action content.

## v0.3.2
- 修复多屏场景下的 Accessibility 坐标换算，降低副屏和非主屏上的文本命中误判。
- 为插件目录热重载加入防抖，减少连续文件变更时的重复扫描和预热卡顿。
- 改进全局热键注册失败处理，遇到重复快捷键或系统冲突时直接提示，而不是静默失效。
- 为脚本插件建立执行信任模型：安装时提示风险、首次运行前确认、脚本内容变化后自动重新要求信任，并支持在插件管理里查看或撤销信任。
- 修复 GTA 氛围模式下脚本插件信任弹窗无法点击的问题，改为先收起菜单再弹确认框。
- 优化插件管理和编辑器界面：调整操作按钮布局，增强信任徽章视觉状态，修复长提示文案遮挡，并显著增大执行内容输入区高度。
- 新增诊断窗口，可查看当前前台应用、焦点元素、选中文本状态、最近一次文本获取来源与失败原因，以及每个插件当前为何可见或不可用。
- 持久化 ActionHalo 全局启用状态，并新增“当前应用插件管理”窗口，支持按应用禁用特定插件且在重启后保留。
- 补充并扩展单元测试，覆盖多屏坐标换算、脚本插件信任、按应用插件覆盖和诊断相关行为。

- Fixed Accessibility coordinate conversion across multiple displays to reduce false hits on secondary and non-primary screens.
- Added debounce to plugin directory hot reloads to avoid repeated rescans and prewarm stalls during bursts of file changes.
- Improved global hotkey registration failure handling so duplicate shortcuts and system conflicts surface clear alerts instead of failing silently.
- Added an execution trust model for script plugins, including install-time warnings, first-run confirmation, automatic re-approval after plugin changes, and trust inspection or revocation from plugin management.
- Fixed script-plugin trust prompts being unclickable in GTA mode by dismissing the menu before presenting the confirmation dialog.
- Refined plugin management and editor UI by reworking action button layout, strengthening trust badge states, fixing clipped long warnings, and giving action-content editors much more vertical space.
- Added a diagnostics window that shows the current frontmost app, focused element, selected-text status, latest text acquisition source and failure reason, and why each plugin is currently visible or unavailable.
- Persisted the global ActionHalo enabled state and added a “manage plugins in current app” window so app-specific plugin disables survive relaunches.
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
- 菜单栏图标支持右键直接切换 ActionHalo 的启用状态。
- 新增默认关闭的 “Run in iTerm2 / 在 iTerm2 中执行” 插件，可将选中文本作为 shell 命令发送到 iTerm2 执行。
- 更新中英文 README，明确产品灵感同时来自 GTA V 和 PopClip。
- 修正文档中的 Script Extensions 示例，补充推荐的外部脚本文件写法与内联脚本说明。

- Added right-click toggling on the menu bar icon to enable or disable ActionHalo directly.
- Added a default-disabled "Run in iTerm2" plugin that sends selected text to iTerm2 as a shell command.
- Updated both READMEs to clarify that ActionHalo draws inspiration from both GTA V and PopClip.
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
