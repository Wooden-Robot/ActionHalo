# OpenFire 🔥

[English](./README.md) | [**简体中文**](./README_zh.md)

<div align="center">
  <img src="./Assets/openfire-demo.png" width="600" alt="OpenFire 演示"/>
</div>

一个在 macOS 上极致丝滑的“选中即弹出”圆环菜单工具。类似于 PopClip，但在 UI、交互和性能上基于原生 Core Animation 和 Swift Concurrency 进行了大规模重构与极速优化。

## ✨ 核心特性

- 🎯 **电竞级响应速度**：基于 `mouseDown` / `mouseDragged` / `mouseUp` 的底层命中测试，告别点击丢失。选中文字后，菜单瞬间唤出；拖拽点击，功能瞬间执行。“指哪打哪”的零延迟悬停高亮，如同 GTA 5 武器轮盘般干脆利落。
- 💫 **原生毛玻璃与 60FPS 动画**：采用 `NSVisualEffectView` 与 `CAShapeLayer` 缓冲池，翻页、悬停、点击动画丝滑无掉帧。
- 🎛️ **高度可定制 UI**：支持在菜单栏直接调节圆环的 **背景透明度** 以及 **单页最大显示数量**（6、8、12 或 16 个），完美契合你的个人屏幕与工作流。
- 🔌 **热插拔插件系统**：支持自定义 `.openfireext` 插件包。提供双击安装、后台线程异步加载、支持删除/禁用的包管理机制。
- 🛡️ **智能触发上下文**：底层重写 Accessibility 识别逻辑。只在真正的可编辑文本框内弹出“粘贴”功能，告别在网页背景层上的无效弹出。
- 🚫 **可定制黑名单应用**：自带全自动黑名单管理 UI，支持拖拽添加应用、点击 `+` 浏览添加应用，精准屏蔽特定软件。

## 📦 安装说明

1. 在 [Releases](https://github.com/woodenrobot/OpenFire/releases) 中下载最新的 `OpenFire.dmg`。
2. 双击打开，将 `OpenFire.app` 拖入 `Applications` 文件夹图标。
3. 运行应用，并在 **系统设置 → 隐私与安全 → 辅助功能** 中授予 OpenFire 权限。


## 🧩 插件生态

OpenFire 提供强大的插件自定义能力，插件以 `.openfireext` 文件夹形式存在，内含 `Config.json`：

### 默认预装插件
| 插件 | 功能 |
|---|---|
| 📋 复制 / 剪切 / 粘贴 | 系统剪贴板管理 (智能识别输入框上下文) |
| 🔍 搜索 / 翻译 / 词典 | 跳转 Google、调用 macOS 原生词典 |
| 🔗 打开链接 | 自动识别选中文字中的 URL 并尝试打开 |

### 社区生态插件 (可选内置)
内置于包中，可以通过“插件管理”界面随时启用、删除：
- **百度搜索** / **Google 搜索**
- **NeoDB 搜书**
- **豆瓣搜书** / **豆瓣搜电影**

### 自己动手写插件（支持 6 种动作类型）

OpenFire 内置了功能完善的**可视化插件编辑器**，无需再手动编写繁琐的 JSON 配置文件！

1. 点击 macOS 顶部状态栏的 OpenFire 图标。
2. 在下拉菜单中选择 **插件管理...**。
3. 点击最下方的 `+` 按钮，即可打开编辑器。
4. 填写插件名称、自定义图标，并选择动作类型即可轻松完成创建。

#### 支持的 Action `type`:
- `url`: 打开系统浏览器 `{text}`
- `shell-script`: 执行 Bash 脚本，读取 `$OPENFIRE_TEXT`
- `applescript`: 运行 osascript
- `key-combo`: 直接在 UI 上录制并发送系统快捷键
- `copy`: 复制到剪切板
- `paste`: 粘贴到当前输入区

## 🛠 技术栈

- **语言 / 框架**: Swift 5.9, AppKit, Objective-C Runtime 辅助
- **渲染引擎**: Core Animation (`CAShapeLayer`, `CATextLayer`, `CATransaction` 无阻塞动画)
- **底层监听**: CGEventTap, macOS Accessibility API (`AXUIElement`, `AXObserver`)
- **多线程**: GCD (`DispatchQueue.global`) 与 Swift Concurrency 并发加载资源

## 📄 License
MIT License
