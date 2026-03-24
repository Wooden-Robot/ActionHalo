# OpenFire 诊断文档

这份文档说明如何阅读 OpenFire 内置的 `Diagnostics` 窗口，以及 `v0.3.15` 当前的选中文本触发链路。

## 如何打开 Diagnostics

1. 点击菜单栏里的 OpenFire 图标。
2. 选择 `诊断信息...` / `Diagnostics...`。
3. 先复现一次问题，再点击 `Refresh`。
4. 如果要发给别人排查，可以点 `Copy Report` 复制当前报告。

## Diagnostics 窗口里都有什么

Diagnostics 面板本质上是一个“当前上下文快照”，实现位置在 [`DiagnosticsWindow.swift`](./Sources/App/UI/DiagnosticsWindow.swift)。

### 核心上下文字段

- `Frontmost app`：当前前台应用名称。
- `Bundle ID`：当前前台应用 bundle id。
- `Accessibility`：OpenFire 当前是否拥有辅助功能权限。
- `App exclusion`：当前应用是否被加入了黑名单。
- `Focused element`：当前焦点元素的 Accessibility role / subrole。
- `Selected text length`：通过 Accessibility 读到的选中文本长度。
- `Selected text preview`：选中文本预览。
- `Clipboard`：当前系统剪贴板是否有文本。
- `Empty-input probe point`：最近一次用于探测 `Paste / Clear` 胶囊的坐标。
- `Selection source`：最近一次成功拿到选中文本的来源：
  - `Accessibility API`
  - `Cmd+C Fallback`
- `Last selection failure`：最近一次失败发生在哪条链路，例如：
  - `accessibilityEmptySelection`
  - `copyFallbackEmptySelection`
  - `observerSetupFailed`
  - `observerTimedOut`
  - `noFocusedApplication`
- `Menu readiness`：OpenFire 当前是否认为圆环可以弹出。

### 插件可见性区域

报告下半部分会列出当前文本和当前应用上下文下，每个插件为什么可见或不可见。

- `Visible`：插件满足当前上下文，可以出现在圆环里。
- `Hidden`：插件当前被拦住了。
- 常见隐藏原因包括：
  - 插件本身被禁用
  - 插件在当前应用中被禁用
  - 文本太短或太长
  - 正则不匹配
  - 当前应用不在 allowlist
  - 脚本插件缺少执行信任

## 当前触发逻辑

主触发链路在 [`TextSelectionMonitor.swift`](./Sources/App/Core/TextSelectionMonitor.swift) 和 [`AccessibilityManager.swift`](./Sources/App/Core/AccessibilityManager.swift)。

### 整体流程

1. `leftMouseDown` 时记录手势起点状态。
2. `leftMouseUp` 时判断这次手势是不是“像文本选择”。
3. 先过滤掉明显不是文本选择的场景。
4. 然后尝试获取当前选中文本。
5. 获取成功后，经过一个很短的延迟，再弹出圆环。

### 触发前会先做哪些拦截

只要命中下面任意一条，就不会继续走文本检测：

- 这次手势里的 drag pasteboard 变成了文件拖拽类型，比如 `public.file-url`
- 当前前台应用属于抑制名单：
  - OpenFire 自己
  - Finder
  - Dock
  - Desktop / WindowManager
  - 已知截图工具
- 这次手势导致“前台窗口本身”发生了位移

`v0.3.15` 里最重要的变化就是最后这一条：  
拖拽窗口不再靠脆弱的 AX 文本命中来判断，而是直接比较手势前后前台窗口的 frame 有没有变化。

### OpenFire 怎么判断“这次像在选文本”

当前会综合记录这些信号：

- 手势起点是否在文本语境里
- 手势终点是否在文本语境里
- 点位是否落在焦点元素边界内
- 这次手势前后 Accessibility 选区快照是否发生变化

这里的“文本语境”指的是：

- 鼠标命中的元素本身被判定为文本
- 当前点位落在可编辑输入框里
- 当前点位落在一个看起来像富文本选择上下文的焦点元素里

## 首选路径：Accessibility

OpenFire 会优先走原生 Accessibility 选区获取。

这条路径成功的条件是：

- 当前选区快照可读
- 选中文本非空
- 相比 `mouseDown` 时，选区真的发生了变化

如果这条路径成功，Diagnostics 里通常会看到：

- `Selection source: Accessibility API`

## 回退路径：Cmd+C

如果原生 Accessibility 没能及时拿到文本，OpenFire 会回退到模拟一次 `Cmd+C`。

这条路径会：

- 发送一次 `Cmd+C`
- 短时间轮询 pasteboard
- 等待新的非空文本真正写进去
- 只有在确认这次复制真的产出了新内容时，才恢复原来的剪贴板

如果这条路径成功，Diagnostics 里通常会看到：

- `Selection source: Cmd+C Fallback`

## 浏览器 / WebView / Telegram 的差异

不同类型的应用，AX 质量差异很大，所以 OpenFire 会做不同程度的兼容。

### 原生编辑器

例如：

- TextEdit
- 多数原生输入框

这类通常主要靠原生 Accessibility 快照就能成功。

### 浏览器和 WebView

例如：

- Chrome
- Edge
- Brave
- Codex App

这类有时能直接走 Accessibility，有时会因为时序问题走 `Cmd+C fallback`。

### Telegram

Telegram 是 `v0.3.15` 里最重要的特殊场景。

现场抓到的行为是：

- 鼠标抬起那一刻，它可能完全不给可用的 AX hit element
- 鼠标抬起那一刻，它也可能完全不给可用的 focused element

所以现在对 Telegram，不再强依赖那一瞬间的 AX 命中/焦点。  
当前策略是：

- 只要这次手势没有真的拖动前台窗口
- 且 `Cmd+C` 复制到了新的非空文本

就仍然允许圆环触发。

这也是为什么 Telegram 现在可以重新正常工作，同时“拖拽窗口也触发”的旧 bug 不会一起回来。

## 常见问题怎么看

### 情况 1：所有地方都不触发

常见报告特征：

- `Accessibility: Missing`
- `Menu readiness: Blocked`
- `Last selection failure` 反复是空选区或无前台应用

通常说明：

- 辅助功能权限缺失，或者当前这份授权没有真正生效

### 情况 2：有些应用里可以，有些不行

常见报告特征：

- `Accessibility: Granted`
- 当前 app 没被黑名单禁用
- Diagnostics 里能看到插件，但 `Selection source` 和 `Last selection failure` 在不同应用里表现不同
- 失败应用里常见 `copyFallbackEmptySelection`

通常说明：

- 这个应用的 AX 选区暴露很差
- 或者 `Cmd+C fallback` 没复制到新的剪贴板内容
- 或者插件 / 应用上下文规则把它挡住了

### 情况 3：拖拽窗口也会弹圆环

在 `v0.3.15` 里，这种情况正常不应该再出现。

当前专门的保护是：

- 对比手势前后前台窗口 frame 是否发生位移

如果这条以后又回归，重点要看：

- 手势过程中前台应用有没有切换
- 你拖动的是主窗口，还是一个独立 panel
- 这次移动有没有被系统算进同一个前台窗口

### 情况 4：Finder 里为什么平时不触发，但重命名时又能触发

这是预期行为：

- 普通文件管理场景：不触发
- 桌面 / Dock 文件场景：不触发
- Finder 重命名文件名时的可编辑文本：触发

也就是说，Finder 作为文件管理场景整体被抑制，但真正进入可编辑文本态后仍然允许走文本链路。

## 推荐排查流程

遇到问题时，建议按这个顺序来：

1. 先复现一次问题。
2. 打开 `Diagnostics...`。
3. 点击 `Refresh`。
4. 重点看：
   - 前台应用
   - Accessibility 权限
   - Focused element
   - Selected text preview
   - Selection source
   - Last selection failure
   - 插件可见性原因
5. 如果有需要，再复现一次，对比这两次是不是在 `Accessibility API` 和 `Cmd+C Fallback` 之间切换。

## 相关源码入口

- 触发主链路：[`Sources/App/Core/TextSelectionMonitor.swift`](./Sources/App/Core/TextSelectionMonitor.swift)
- Accessibility 与回退复制：[`Sources/App/Core/AccessibilityManager.swift`](./Sources/App/Core/AccessibilityManager.swift)
- Diagnostics UI：[`Sources/App/UI/DiagnosticsWindow.swift`](./Sources/App/UI/DiagnosticsWindow.swift)
