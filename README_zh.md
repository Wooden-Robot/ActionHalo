<div align="center">

# OpenFire 🔥

**一个在 macOS 上支持“松开后点击执行”和“松开后按下拖拽再松开执行”的丝滑圆环菜单工具。**

[English](./README.md) • [**简体中文**](./README_zh.md)

[![macOS 13.0+](https://img.shields.io/badge/macOS-13.0+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/macos)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

<img src="./Assets/demo.gif" width="600" alt="OpenFire 演示 1" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 24px 0 12px;"/>

<img src="./Assets/demo2.gif" width="600" alt="OpenFire 演示 2" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 12px 0 24px;"/>

> OpenFire 的灵感同时来自 GTA V 和 PopClip，并在 UI、交互与性能上基于原生 Core Animation 和 Swift Concurrency 做了大规模重构与极速优化。

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
支持自定义 `.openfireext` 插件包。提供双击安装、后台线程异步加载、支持删除/禁用的包管理机制。

🧠 **智能触发上下文**
底层重写 Accessibility 识别逻辑。与“选中文本”直接相关的动作保留在主圆环里，而像“粘贴”这种只适用于输入框的动作，则单独放进可编辑输入场景下的快捷入口，不去污染主圆环。

✂️ **更干净的快捷操作**
当 OpenFire 检测到你点击的是可编辑输入框，且当前没有选中文本时，可以在光标附近弹出轻量的 `Paste / Clear` 胶囊操作条，方便快速粘贴，或直接清空当前剪贴板内容。当剪贴板为空时，这个快捷入口不会显示。内置 `粘贴` 动作现在默认也通过这里触发，而不是放进选中文本后的主圆环。

🚫 **可定制黑名单应用**
自带全自动黑名单管理 UI，支持拖拽添加应用、点击 `+` 浏览添加应用，精准屏蔽特定软件。

---

## 🚀 安装指南

### 安装步骤

1. 在 [Releases](https://github.com/Wooden-Robot/OpenFire/releases) 页面下载最新的 `.dmg` 安装包。
2. 双击打开，将 **OpenFire** 图标拖入 `Applications` 应用程序文件夹。
3. 运行 OpenFire。
4. 前往 **系统设置 → 隐私与安全 → 辅助功能**，为 OpenFire 授予必须的辅助功能权限（用于监听文本选中事件）。

### 触发方式说明

OpenFire 实际上有 **两个“打开圆环”的入口**，之前容易和“打开后怎么执行动作”混在一起：

1. **鼠标选中触发**：正常框选文字，等你松开鼠标后，圆环才会出现。也就是说，圆环不会在按住拖拽选中的过程中提前弹出。
2. **可选的手动快捷键触发**：如果你在菜单栏里设置了 `呼出菜单快捷键`，OpenFire 也可以针对当前已选中的文本直接打开圆环，不必依赖“选中后松开鼠标”这条路径。

而在圆环已经出现之后，又有 **两种执行动作的方式**：

1. **选中，松开，再点击**：圆环弹出后，直接点击目标扇区执行动作。
2. **选中，松开，再按下拖拽，最后松开**：圆环弹出后，立刻再次按下鼠标，拖到目标扇区，松开时执行动作。

第二种是 OpenFire 很有辨识度的交互方式：圆环一出现，你就可以立刻进入“按下-拖拽-松开”的武器轮盘式操作，而不必停下来改用传统菜单式的点按节奏。

### 菜单栏可调项

OpenFire 常驻在 macOS 菜单栏里，主要设置都可以直接从这里调：

- **圆环透明度**：`0%（不透明）` 到 `100%（完全透明）`
- **GTA 氛围**：切换成更重、更像 GTA 5 武器轮盘的 HUD 风格
- **菜单最大功能数**：`6 / 8 / 12 / 16`
- **呼出菜单快捷键**：手动对当前已选中文本打开圆环。默认：`Shift + Option + D`
- **自动触发开关快捷键**：切换“选中文字后自动弹出圆环”功能。默认：`Shift + Option + X`
- **插件管理** 和 **黑名单应用**

注意：开启 **GTA 氛围** 后，圆环会强制使用不透明渲染，因此透明度菜单会自动禁用。

---

## 🧩 插件生态

OpenFire 的强大之处在于插件自定义能力。插件以 `.openfireext` 文件夹形式存在，内含极简的 `Config.json` 配置。

### 默认预装插件
| 🔌 插件 | 📝 功能描述 |
| :--- | :--- |
| **复制 / 剪切 / 删除** | 直接作用于当前选中文本的基础编辑动作。 |
| **搜索 / 翻译 / 词典** | 面向日常文本处理的常用动作，可直接搜索、翻译或调用 macOS 原生词典。 |
| **打开链接 / 打开文件位置** | 这类内置动作会根据当前选中文本判断是否可执行，例如 URL 和文件路径。 |

这些默认预装插件属于 OpenFire 内置能力本身，可以在菜单栏里启用、禁用、排序，也可以直接编辑；编辑内置插件时，OpenFire 会在系统默认版本之上创建你的用户覆盖版本。
只要插件处于启用状态，就会在圆环里保留自己的位置；如果当前上下文不匹配，它会以灰态显示，而不是在分页前被直接过滤掉。
内置 `粘贴` 动作是单独处理的：它默认通过空输入框场景下的 `Paste / Clear` 胶囊出现，而不会进入选中文本后的主圆环。

### 社区生态插件
内置于安装包中，可随时通过“插件管理”界面启用或删除：
- 🔍 [百度搜索](./Plugins/BaiduSearch.openfireext/Config.json) / [Google 搜索](./Plugins/GoogleSearch.openfireext/Config.json)：将选中文本直接送去网页搜索。
- 🧑‍💻 [GitHub 搜索](./Plugins/GitHubSearch.openfireext/Config.json)：直接用选中文本去 GitHub 搜索。
- 📚 [NeoDB 搜书](./Plugins/NeoDBBook.openfireext/Config.json) / [豆瓣搜书](./Plugins/DoubanBook.openfireext/Config.json)：按当前选中文本快速查书。
- 🎬 [豆瓣搜电影](./Plugins/DoubanMovie.openfireext/Config.json)：按选中的电影名直接去豆瓣搜索。
- ✈️ [Telegram 搜索](./Plugins/Search%20Telegram.openfireext/Config.json)：把选中文本送进 Telegram 搜索。
- 📂 [打开文件位置](./Plugins/RevealPath.openfireext/Config.json)：当选中文本是文件路径时，直接在 Finder 中打开对应位置。
- 🖥️ [Run Shell](./Plugins/Run%20Shell.openfireext/Config.json)：默认关闭，执行打包在插件里的 Shell 脚本，并把选中文本传进去。
- 💻 [在 iTerm2 中执行](./Plugins/Run%20in%20iTerm2.openfireext/Config.json)：默认关闭，可把选中文本作为 shell 命令发送到 iTerm2 执行。

---

## 🛠️ 自己动手写插件

OpenFire 内置了功能完善的**可视化插件编辑器**，无需再手动编写繁琐的 JSON 配置文件！

1. 点击 macOS 顶部状态栏的 🔥 OpenFire 图标。
2. 在下拉菜单中选择 **插件管理...**
3. 点击界面最下方中间的 `+` 按钮打开编辑器。
4. 填写插件名称、图标，并选择动作类型即可完成创建。

### 支持的扩展类型 (Action `type`)
- 🌐 `url`: 打开系统浏览器访问 `{text}`
- 🐚 `shell-script`: 执行打包在插件里的 Shell 脚本，OpenFire 会通过环境变量注入选中文本
- 🍎 `applescript`: 执行打包在插件里的 AppleScript，供插件处理当前选中文本
- ⌨️ `key-combo`: 直接在 UI 上录制并发送系统快捷键
- 📋 `copy`: 复制到剪切板
- 📝 `paste`: 粘贴到当前输入区
- 📂 `reveal-path`: 当选中文本是文件路径时，在 Finder 中打开对应位置

#### 脚本类扩展
对于 `shell-script` 和 `applescript`，标准插件写法是让 `action.script` 指向 `.openfireext` 包内附带的脚本文件。OpenFire 也支持把简短脚本直接内联写进同一个 `script` 字段。当触发脚本时，OpenFire 会自动注入 `$OPENFIRE_TEXT` 和 `OPENFIRE_TEXT_FILE`。

**推荐的插件结构**
```text
My Script.openfireext/
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
  "script": "echo \"Selected: $OPENFIRE_TEXT\" >> ~/Desktop/openfire.log"
}
```

---

## 💻 技术栈简介

- **语言与框架**: Swift 5.9, AppKit, Objective-C Runtime 辅助
- **渲染引擎**: Core Animation (`CAShapeLayer`, `CATextLayer`, `CATransaction` 无阻塞动画)
- **底层监听**: CGEventTap, macOS Accessibility API (`AXUIElement`, `AXObserver`)
- **并发控制**: GCD (`DispatchQueue.global`) 与 Swift Concurrency 异步加载

---

## 📒 更新日志

请查看 [CHANGELOG.md](CHANGELOG.md)。

---

## 📄 开源协议

OpenFire 采用 [MIT License](LICENSE) 协议开源。
