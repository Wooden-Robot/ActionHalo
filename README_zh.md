<div align="center">

# ActionHalo 🔥

**一个在 macOS 上支持“松开后点击执行”和“松开后按下拖拽再松开执行”的丝滑圆环菜单工具。**

[English](./README.md) • [**简体中文**](./README_zh.md)

[![macOS 12.0+](https://img.shields.io/badge/macOS-12.0+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/macos)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

<img src="./Assets/demo.gif" width="600" alt="ActionHalo 演示 1" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 24px 0 12px;"/>

<img src="./Assets/demo2.gif" width="600" alt="ActionHalo 演示 2" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 12px 0 24px;"/>

> ActionHalo 的灵感同时来自 GTA V 和 PopClip，并在 UI、交互与性能上基于原生 Core Animation 和 Swift Concurrency 做了大规模重构与极速优化。

</div>

---

## ✨ 核心特性

🚀 **电竞级响应速度**
基于 `mouseDown` / `mouseDragged` / `mouseUp` 的底层命中测试，告别点击丢失。两种交互的共同前提都是：**先完成选中文字，再松开鼠标，圆环才会触发**。触发后有两种执行方式：

- **松开后直接点一下执行**：先选中文字，松开鼠标让圆环弹出，再点击目标扇区执行功能。
- **松开后立即按下、拖拽到目标、再松开执行**：先选中文字并松开触发圆环，随后立刻按下鼠标，拖到目标扇区，最后松开执行。

悬停高亮几乎零延迟，“指哪打哪”，第二种方式尤其像 GTA 5 的武器轮盘，而不是传统右键菜单。

💫 **原生毛玻璃与 60FPS 动画**
采用 `NSVisualEffectView` 与 `CAShapeLayer` 缓冲池，翻页、悬停、点击动画丝滑无掉帧。

🎛️ **高度可定制 UI**
支持在菜单栏直接调节圆环的 **背景透明度**、**单页最大显示数量**（6、8、12 或 16 个），也支持一键切换 **GTA 氛围**，把圆环切成更厚重的武器轮盘 HUD 风格。

🔌 **热插拔插件系统**
支持自定义 `.actionhaloext` 插件包。提供双击安装、后台线程异步加载、支持删除/禁用的包管理机制。

🧠 **智能触发上下文**
底层重写 Accessibility 识别逻辑。与“选中文本”直接相关的动作保留在主圆环里，而输入相关动作也会继续尊重“当前焦点是否真的可编辑”。

✂️ **更干净的快捷操作**
当 ActionHalo 检测到你点击的是可编辑输入框，且当前没有选中文本时，可以在光标附近弹出轻量的 `Paste / Clear` 胶囊操作条，方便快速粘贴，或直接清空当前剪贴板内容。当剪贴板为空时，这个快捷入口不会显示。内置 `粘贴` 动作在可编辑选区里也可以出现在主圆环中。

🚫 **可定制黑名单应用**
自带全自动黑名单管理 UI，支持拖拽添加应用、点击 `+` 浏览添加应用，精准屏蔽特定软件。

---

## 🚀 安装指南

### 系统要求

- **macOS 12 Monterey 或更高版本**。不支持 macOS 11 Big Sur 及更早版本。
- Universal 版本同时支持 Apple 芯片和 Intel 芯片 Mac。

### 安装步骤

1. 在 [Releases](https://github.com/Wooden-Robot/ActionHalo/releases) 页面下载最新的 `.dmg` 安装包。
2. 双击打开，将 **ActionHalo** 图标拖入 `Applications` 应用程序文件夹。
3. 运行 ActionHalo。社区版使用 ad-hoc 签名且未经 Apple 公证，首次启动可能被 macOS 拦截；请前往 **系统设置 → 隐私与安全**，为 ActionHalo 选择**仍要打开**。
4. 前往 **系统设置 → 隐私与安全 → 辅助功能**，为 ActionHalo 授予必须的辅助功能权限（用于监听文本选中事件）。

### 自动更新

在菜单栏选择 **检查更新...**。发现已签名的新版本后，先点击 **安装更新**；下载并验证完成后，Sparkle 会按默认流程再次显示 **安装并重启** 确认，随后原子安装并重启到新版本。菜单中的自动检查开关仍可随时启用或关闭。如果插件编辑器中存在未保存内容，ActionHalo 会阻止退出，直到你保存或明确丢弃这些修改。

ActionHalo 社区版目前不使用 Developer ID。更新真实性由 App 内置的 Ed25519 公钥保证：安装前会同时校验 appcast 和下载归档。由于 ad-hoc 签名无法提供稳定的 Apple 身份，版本更新后 macOS 可能要求重新授予辅助功能或自动化权限。

### 从 OpenFire 升级

- OpenFire `v0.3.23`–`v0.3.26` 可在 GitHub 仓库原地改名后通过 Sparkle 自动升级到 ActionHalo。旧仓库 URL 必须持续重定向到 `Wooden-Robot/ActionHalo`；不要删除重建仓库，也不要再次占用旧的 `OpenFire` 仓库名。
- `v0.3.22` 及更早版本尚未内置可信更新公钥，需要最后手动安装一次 ActionHalo DMG。
- 兼容期内保留现有 Bundle ID，以延续偏好设置、登录启动状态、macOS 允许保留的权限和已签名更新链。原地升级后，应用文件在磁盘上可能仍叫 `OpenFire.app`，但显示名和运行程序已经是 ActionHalo。不要同时安装两份 `OpenFire.app` 与 `ActionHalo.app`。
- 旧用户插件会从 `Application Support/OpenFire/Plugins` 一次性复制到 ActionHalo 插件目录，旧副本保留用于回滚。兼容期内仍可使用 `.openfireext`、`com.openfire.*` 插件 ID，以及 `OPENFIRE_TEXT` / `OPENFIRE_TEXT_FILE`。

### 触发方式说明

ActionHalo 实际上有 **两个“打开圆环”的入口**，之前容易和“打开后怎么执行动作”混在一起：

1. **鼠标选中触发**：正常框选文字，等你松开鼠标后，圆环才会出现。也就是说，圆环不会在按住拖拽选中的过程中提前弹出。
2. **可选的手动快捷键触发**：如果你在菜单栏里设置了 `呼出菜单快捷键`，ActionHalo 也可以针对当前已选中的文本直接打开圆环，不必依赖“选中后松开鼠标”这条路径。

而在圆环已经出现之后，又有 **两种执行动作的方式**：

1. **选中，松开，再点击**：圆环弹出后，直接点击目标扇区执行动作。
2. **选中，松开，再按下拖拽，最后松开**：圆环弹出后，立刻再次按下鼠标，拖到目标扇区，松开时执行动作。

第二种是 ActionHalo 很有辨识度的交互方式：圆环一出现，你就可以立刻进入“按下-拖拽-松开”的武器轮盘式操作，而不必停下来改用传统菜单式的点按节奏。

如果你想排查“为什么会触发”或“为什么没有触发”，可以直接查看独立的[诊断文档](./DIAGNOSTICS_zh.md)。

### 当前触发逻辑概览

ActionHalo 并不是“只要鼠标拖了一下就触发”。当前这版触发链路是偏保守的：

1. 一次手势首先得看起来像真正的文本拖选。位移过短会被当成普通点击，而不是文本选择。
2. 在尝试取文本之前，ActionHalo 会先拦掉明显不是文本选择的场景：
   - 通过 drag pasteboard 识别出的文件拖拽
   - Finder、Dock、Desktop、ActionHalo 自身这类前台文件管理或自干扰场景
   - 已知截图工具
   - 窗口拖拽：通过比较本次手势前后前台窗口 frame 是否真的发生变化来判断
3. 如果这次手势通过了上面的过滤，ActionHalo 会优先尝试原生 Accessibility 选区获取。
4. 如果 Accessibility 没能及时拿到可用文本，就会退到受保护的 `Cmd+C fallback`。
5. 只有在某条链路真的拿到了非空选中文本后，圆环才会弹出。

实际效果可以理解成：

- 原生编辑器里的普通文本选择，通常优先走 Accessibility
- 浏览器和 WebView 里的文本选择，可能走 Accessibility，也可能走 `Cmd+C fallback`
- Telegram 因为鼠标抬起时 AX 命中和焦点都不稳定，所以更依赖 `Cmd+C fallback`
- 拖文件、拖窗口不应该触发圆环
- 像 Finder 重命名这种“虽然应用本身通常被拦住，但当前确实进入可编辑文本态”的场景，仍然可以正常触发

### `Cmd+C fallback` 到底是什么

`Cmd+C fallback` 是 ActionHalo 在某些应用里拿不到稳定 Accessibility 选中文本时使用的兼容路径。

它不是“猜测你选中了什么”，而是按下面的步骤工作：

1. 先保存当前系统剪贴板快照。
2. 短暂等待一下，避免用户手势里残留的物理修饰键影响这次模拟复制。
3. 发送一次合成的 `Cmd+C`。
4. 在一个很短的时间窗口里轮询系统 pasteboard，等待新的非空文本真正出现。
5. 如果确认这次复制确实产出了新的文本，就把这段文本当作当前选中内容使用，并恢复之前的剪贴板快照。

这条路径主要是为下面这类应用准备的：

- Telegram
- Electron 应用
- Accessibility 选区暴露不完整或时序很飘的浏览器 / WebView 宿主

它也不是“对所有拖拽都无脑复制”。即使走到 fallback，ActionHalo 仍然会先判断这次手势是否像文本选择，而不是文件拖拽、窗口拖拽或其他非文本交互。与此同时，只有在确认这次模拟复制真的拿到了新的复制结果时，才会恢复旧剪贴板，从而尽量减少不必要的剪贴板抖动。

所以可以简单理解成：

- `Accessibility API` 是首选路径
- `Cmd+C fallback` 是兼容路径
- 两条路径都要先通过“这次像是在选文本，而不是在拖文件或拖窗口”的判断

### 菜单栏可调项

ActionHalo 常驻在 macOS 菜单栏里，主要设置都可以直接从这里调：

- **圆环透明度**：`0%（不透明）` 到 `100%（完全透明）`
- **GTA 氛围**：切换成更重、更像 GTA 5 武器轮盘的 HUD 风格
- **菜单最大功能数**：`6 / 8 / 12 / 16`
- **呼出菜单快捷键**：手动对当前已选中文本打开圆环。默认：`Shift + Option + D`
- **自动触发开关快捷键**：切换“选中文字后自动弹出圆环”功能。默认：`Shift + Option + X`
- **插件管理** 和 **黑名单应用**

注意：开启 **GTA 氛围** 后，圆环会强制使用不透明渲染，因此透明度菜单会自动禁用。

---

## 🧩 插件生态

ActionHalo 的强大之处在于插件自定义能力。插件以 `.actionhaloext` 文件夹形式存在，内含极简的 `Config.json` 配置。

### 默认预装插件
| 🔌 插件 | 📝 功能描述 |
| :--- | :--- |
| **复制 / 剪切 / 删除** | 直接作用于当前选中文本的基础编辑动作。 |
| **搜索 / 翻译 / 词典** | 面向日常文本处理的常用动作，可直接搜索、翻译或调用 macOS 原生词典。 |
| **打开链接 / 打开文件位置** | 这类内置动作会根据当前选中文本判断是否可执行，例如 URL 和文件路径。 |

这些核心默认插件属于 ActionHalo 内置能力本身，可以在菜单栏里启用、禁用和排序，但不能编辑或删除；不需要某个核心动作时可将其禁用。安装包自带的社区插件，以及你创建或安装的插件，可以在“插件管理”中编辑。
只要插件处于启用状态，就会在圆环里保留自己的位置；如果当前上下文不匹配，它会以灰态显示，而不是在分页前被直接过滤掉。
内置 `粘贴` 动作在当前焦点可编辑时可以进入主圆环；在空输入框场景下，它也会继续复用 `Paste / Clear` 胶囊入口。

### 社区生态插件
内置于安装包中，可随时通过“插件管理”界面启用、编辑或删除：
- 🔍 [百度搜索](./Plugins/BaiduSearch.actionhaloext/Config.json) / [Google 搜索](./Plugins/GoogleSearch.actionhaloext/Config.json)：将选中文本直接送去网页搜索。
- 🧑‍💻 [GitHub 搜索](./Plugins/GitHubSearch.actionhaloext/Config.json)：直接用选中文本去 GitHub 搜索。
- 📚 [NeoDB 搜书](./Plugins/NeoDBBook.actionhaloext/Config.json) / [豆瓣搜书](./Plugins/DoubanBook.actionhaloext/Config.json)：按当前选中文本快速查书。
- 🎬 [豆瓣搜电影](./Plugins/DoubanMovie.actionhaloext/Config.json)：按选中的电影名直接去豆瓣搜索。
- ✈️ [Telegram 搜索](./Plugins/Search%20Telegram.actionhaloext/Config.json)：把选中文本送进 Telegram 搜索。
- 📂 [打开文件位置](./Plugins/RevealPath.actionhaloext/Config.json)：当选中文本是文件路径时，直接在 Finder 中打开对应位置。
- 🖥️ [Run Shell](./Plugins/Run%20Shell.actionhaloext/Config.json)：默认关闭，执行打包在插件里的 Shell 脚本，并把选中文本传进去。
- 💻 [在 iTerm2 中执行](./Plugins/Run%20in%20iTerm2.actionhaloext/Config.json)：默认关闭，可把选中文本作为 shell 命令发送到 iTerm2 执行。

---

## 🛠️ 自己动手写插件

ActionHalo 内置了功能完善的**可视化插件编辑器**，无需再手动编写繁琐的 JSON 配置文件！

1. 点击 macOS 顶部状态栏的 🔥 ActionHalo 图标。
2. 在下拉菜单中选择 **插件管理...**
3. 点击界面最下方中间的 `+` 按钮打开编辑器。
4. 填写插件名称、图标，并选择动作类型即可完成创建。

### 支持的扩展类型 (Action `type`)
- 🌐 `url`: 打开系统浏览器访问 `{text}`
- 🐚 `shell-script`: 执行打包在插件里的 Shell 脚本，ActionHalo 会通过环境变量注入选中文本
- 🍎 `applescript`: 执行打包在插件里的 AppleScript，供插件处理当前选中文本
- ⌨️ `key-combo`: 直接在 UI 上录制并发送系统快捷键
- 📋 `copy`: 复制到剪切板
- 📝 `paste`: 粘贴到当前输入区
- 📂 `reveal-path`: 当选中文本是文件路径时，在 Finder 中打开对应位置

#### 安全正则筛选
插件的 `filter.regex` 使用线性时间、无回溯的匹配器，避免导入的插件用恶意表达式卡住菜单。支持的子集包括字面量、`.`、`^` / `$`、分组与 `(?:...)`、或、字符类、`*` / `+` / `?` / `{m,n}`，以及 `\s`、`\d`、`\w` 系列；前后查找、反向引用、模式修饰符、惰性量词和占有量词会被拒绝。表达式上限为 1 KiB，参与正则筛选的选中文本上限为 4,096 个 UTF-16 code unit；若希望匹配所有文本，请省略 `filter.regex`。

#### 脚本类扩展
对于 `shell-script` 和 `applescript`，标准插件写法是让 `action.script` 指向 `.actionhaloext` 包内附带的脚本文件。ActionHalo 也支持把简短脚本直接内联写进同一个 `script` 字段。`ACTIONHALO_TEXT_FILE` 始终是规范的 UTF-8 输入；仅当文本不超过 32 KiB 且不含 NUL 字符时才同时提供 `ACTIONHALO_TEXT`。改名兼容期内，旧变量 `OPENFIRE_TEXT_FILE` 与 `OPENFIRE_TEXT` 也按同样规则提供。

**推荐的插件结构**
```text
My Script.actionhaloext/
  Config.json
  script.sh
```

**示例：引用 Shell 脚本文件**
```json
"action": {
  "type": "shell-script",
  "script": "script.sh"
}
```

**示例：引用 AppleScript 文件**
```json
"action": {
  "type": "applescript",
  "script": "script.applescript"
}
```

**短脚本也可以直接内联**
```json
"action": {
  "type": "shell-script",
  "script": "echo \"Selected: $ACTIONHALO_TEXT\" >> ~/Desktop/actionhalo.log"
}
```

---

## 🔨 构建与验证

仓库内受版本管理的 `Makefile` 是发布构建的真源：

```bash
make all                 # 优化后的 universal 二进制
make test                # 串行测试
swift test --parallel    # 并行运行回归检查
make package             # 本地验证用 .app 与 .dmg
```

`make package` 生成 ad-hoc 签名的社区版 `.app` 与 `.dmg`，但不执行发布版本校验。可发布的社区版必须在干净提交及准确的 `vX.Y.Z` tag 上使用独立的 `make release` 门禁，并显式传入 `VERSION=X.Y.Z`；该版本必须同时匹配 tag、源码与打包后 App 的 `Info.plist` 两个版本字段：

```bash
make release VERSION=X.Y.Z SPARKLE_ACCOUNT="OpenFire"
```

首个 ActionHalo 版本必须高于 `0.3.26`。`make release` 会在仓库状态、版本、tag 或 Sparkle 配置不合法时提前失败，并再次核对打包后 App 的版本。检查通过后，它会对 Sparkle 嵌套 helper 和主 App 执行 ad-hoc 签名，验证 Apple Events 权限、通用架构以及最终 DMG 内的 App；随后使用钥匙串中旧 `OpenFire` 账户保存的现有 Ed25519 私钥生成 `.build/appcast.xml`。这里的账户名只用于本机查找签名密钥，并非对外品牌，因此有意保留。门禁会把 feed 与 enclosure 签名、归档长度、版本和 URL 全部与这份最终 DMG 逐项绑定。Ed25519 私钥是社区版发布的信任根，必须安全备份。

先创建一个**不含资产的草稿 GitHub Release**，再执行 `make publish-release-assets VERSION=X.Y.Z SPARKLE_ACCOUNT=OpenFire`。该目标拒绝覆盖已有资产，在 Release 仍不可见时上传 DMG 与 appcast，核对两个远端 SHA-256 摘要后才公开 Release，避免客户端看到只上传一半或互不匹配的更新资产。

这套流程明确不使用 Developer ID 签名与 Apple 公证，因此无法消除首次启动警告，也无法保证 TCC 权限在更新后持续有效；Ed25519 负责的是更新真实性，而不是建立 Apple 信任的应用身份。

CI 固定使用 Xcode 16.4，先执行常规测试，再启用 actor 数据竞争检查实际运行测试，并用正反向样例验证发布权限与 Sparkle 更新门禁、对应用构建强制执行严格并发诊断，随后构建 SwiftPM Release 产物，并对 ad-hoc 签名的 universal App/DMG 做完整冒烟验证。每周定时任务和手动触发任务会在 Thread Sanitizer 下运行完整测试。

---

## 💻 技术栈简介

- **语言与框架**: Swift 5.9, AppKit, Objective-C Runtime 辅助
- **渲染引擎**: Core Animation (`CAShapeLayer`, `CATextLayer`, `CATransaction` 无阻塞动画)
- **底层监听**: CGEventTap, macOS Accessibility API (`AXUIElement`, `AXObserver`)
- **自动更新**: Sparkle 2，使用 Ed25519 签名更新包与 appcast
- **并发控制**: GCD (`DispatchQueue.global`) 与 Swift Concurrency 异步加载

---

## 📒 更新日志

请查看 [CHANGELOG.md](CHANGELOG.md)。

---

## 📄 开源协议

ActionHalo 采用 [MIT License](LICENSE) 协议开源。
