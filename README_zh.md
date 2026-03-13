<div align="center">

# OpenFire 🔥

**一个在 macOS 上极致丝滑的“选中即弹出”圆环菜单工具。**

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
基于 `mouseDown` / `mouseDragged` / `mouseUp` 的底层命中测试，告别点击丢失。选中文字后，菜单瞬间唤出；拖拽点击，功能瞬间执行。“指哪打哪”的零延迟悬停高亮，如同 GTA 5 武器轮盘般干脆利落。

💫 **原生毛玻璃与 60FPS 动画**
采用 `NSVisualEffectView` 与 `CAShapeLayer` 缓冲池，翻页、悬停、点击动画丝滑无掉帧。

🎛️ **高度可定制 UI**
支持在菜单栏直接调节圆环的 **背景透明度**、**单页最大显示数量**（6、8、12 或 16 个），也支持一键切换 **GTA 氛围**，把圆环切成更厚重的武器轮盘 HUD 风格。

🔌 **热插拔插件系统**
支持自定义 `.openfireext` 插件包。提供双击安装、后台线程异步加载、支持删除/禁用的包管理机制。

🧠 **智能触发上下文**
底层重写 Accessibility 识别逻辑。只在真正的可编辑文本框内弹出“粘贴”功能；`打开链接` 也会保留占位但不抢走真正匹配动作的名额。

✂️ **更干净的快捷操作**
当 OpenFire 检测到空白输入框时，可以在光标附近弹出轻量的 `Paste / Clear` 胶囊操作条，适合快速粘贴或清空输入内容。

🚫 **可定制黑名单应用**
自带全自动黑名单管理 UI，支持拖拽添加应用、点击 `+` 浏览添加应用，精准屏蔽特定软件。

---

## 🚀 安装指南

### 安装步骤

1. 在 [Releases](https://github.com/woodenrobot/OpenFire/releases) 页面下载最新的 `.dmg` 安装包。
2. 双击打开，将 **OpenFire** 图标拖入 `Applications` 应用程序文件夹。
3. 运行 OpenFire。
4. 前往 **系统设置 → 隐私与安全 → 辅助功能**，为 OpenFire 授予必须的辅助功能权限（用于监听文本选中事件）。

### 菜单栏可调项

OpenFire 常驻在 macOS 菜单栏里，主要设置都可以直接从这里调：

- **圆环透明度**：`0%（不透明）` 到 `100%（完全透明）`
- **GTA 氛围**：切换成更重、更像 GTA 5 武器轮盘的 HUD 风格
- **菜单最大功能数**：`6 / 8 / 12 / 16`
- **插件管理** 和 **黑名单应用**

注意：开启 **GTA 氛围** 后，圆环会强制使用不透明渲染，因此透明度菜单会自动禁用。

---

## 🧩 插件生态

OpenFire 的强大之处在于插件自定义能力。插件以 `.openfireext` 文件夹形式存在，内含极简的 `Config.json` 配置。

### 默认预装插件
| 🔌 插件 | 📝 功能描述 |
| :--- | :--- |
| **复制 / 剪切 / 粘贴** | 系统剪贴板管理 (智能识别输入框上下文) |
| **搜索 / 翻译 / 词典** | 跳转 Google、调用 macOS 原生词典 |
| **打开链接** | 自动识别选中文字中的 URL 并尝试打开 |

内置插件会先按当前上下文过滤再参与分页，因此不相关动作不会挤占真正可用的功能位。

### 社区生态插件
内置于安装包中，可随时通过“插件管理”界面启用或删除：
- 🔍 百度搜索 / Google 搜索
- 📚 NeoDB 搜书 / 豆瓣搜书
- 🎬 豆瓣搜电影
- ✈️ Telegram 搜索

---

## 🛠️ 自己动手写插件

OpenFire 内置了功能完善的**可视化插件编辑器**，无需再手动编写繁琐的 JSON 配置文件！

1. 点击 macOS 顶部状态栏的 🔥 OpenFire 图标。
2. 在下拉菜单中选择 **插件管理...**
3. 点击界面最下方中间的 `+` 按钮打开编辑器。
4. 填写插件名称、图标，并选择动作类型即可完成创建。

### 支持的扩展类型 (Action `type`)
- 🌐 `url`: 打开系统浏览器访问 `{text}`
- ⌨️ `key-combo`: 直接在 UI 上录制并发送系统快捷键
- 📋 `copy`: 复制到剪切板
- 📝 `paste`: 粘贴到当前输入区

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
