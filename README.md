<div align="center">

# OpenFire 🔥

**An ultra-smooth, "select-to-pop" circular menu tool for macOS.**

[**English**](./README.md) • [简体中文](./README_zh.md)

[![macOS 13.0+](https://img.shields.io/badge/macOS-13.0+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/macos)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

<img src="./Assets/demo.gif" width="600" alt="OpenFire Demo 1" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 24px 0 12px;"/>

<img src="./Assets/demo2.gif" width="600" alt="OpenFire Demo 2" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 12px 0 24px;"/>

> OpenFire is heavily inspired by PopClip but massively refactored and extremely optimized in UI, interaction, and performance using native Core Animation and Swift Concurrency.

</div>

---

## ✨ Features That Wow

🚀 **Esports-level Response Speed**
Bottom-layer hit testing based on `mouseDown` / `mouseDragged` / `mouseUp`. Bid farewell to missed clicks. Once text is selected, the menu pops up instantly. Click and drag to execute functions immediately with zero-lag hover states that snap instantly to your cursor like GTA V's weapon wheel.

💫 **Native Blur & 60FPS Animations**
Uses `NSVisualEffectView` and `CAShapeLayer` buffer pool. Page flipping, hovering, and clicking animations are buttery smooth with no frame drops.

🎛️ **Highly Customizable UI**
Adjust the radial menu's **Ring Opacity** and **Max Items limit** (6, 8, 12, or 16 items per page) directly from the Menu Bar. You can also toggle **GTA Mode** for a heavier weapon-wheel style presentation with a darker HUD-like look.

🔌 **Hot-pluggable Plugin System**
Supports custom `.openfireext` plugin packages. Features double-click installation, background thread asynchronous loading, and a package management mechanism supporting deletion and disabling.

🧠 **Smart Trigger Context**
Rewritten Accessibility recognition logic at the foundation. The "paste" function only appears inside genuinely editable text fields, and Open URL can reserve a slot without hijacking space from context-matching actions.

✂️ **Cleaner Quick Actions**
When OpenFire detects an empty editable field, it can show a lightweight `Paste / Clear` capsule near the cursor for faster text entry cleanup without opening the full wheel.

🚫 **Customizable App Blacklist**
Built-in automatic blacklist management UI. Supports dragging and dropping apps, or browsing via the `+` button to precisely block specific software.

---

## 🚀 Getting Started

### Installation

1. Download the latest `.dmg` from the [Releases](https://github.com/woodenrobot/OpenFire/releases) page.
2. Open the downloaded file and drag the **OpenFire** app into your `Applications` folder.
3. Launch OpenFire.
4. Open **System Settings → Privacy & Security → Accessibility** and grant permissions to OpenFire (required for text selection detection).

### Menu Bar Controls

OpenFire lives in the macOS menu bar and exposes the main controls there:

- **Ring Opacity**: `0% (Opaque)` to `100% (Transparent)`
- **GTA Mode**: swaps the wheel into a heavier GTA V-style HUD presentation
- **Max Items in Menu**: `6 / 8 / 12 / 16`
- **Plugin Management** and **App Blacklist**

Note: when **GTA Mode** is enabled, the wheel is intentionally rendered fully opaque and the opacity menu is disabled.

---

## 🧩 The Plugin Ecosystem

OpenFire's true power lies in its plugin system. Plugins exist as `.openfireext` packages containing a simple `Config.json`.

### Pre-installed Plugins
| 🔌 Plugin | 📝 Description |
| :--- | :--- |
| **Copy / Cut / Paste** | System clipboard management (intelligently recognizes input box context) |
| **Search / Translate / Dict** | Jump to Google, invoke macOS native dictionary |
| **Open Link** | Automatically identifies URLs in selected text and attempts to open them |

Built-in plugins are filtered by current context before pagination, so irrelevant actions do not crowd out actually usable slots.

### Community Plugins
Built into the package, they can be enabled or removed at any time via the "Plugin Management" interface:
- 🔍 Baidu Search / Google Search
- 📚 NeoDB / Douban Book Search
- 🎬 Douban Movie Search
- ✈️ Search in Telegram

---

## 🛠️ Build Your Own Plugin

OpenFire comes with a fully-featured **Visual Plugin Editor** built right into the app. You no longer need to write JSON configurations manually!

1. Click the 🔥 OpenFire icon in the macOS Menu Bar.
2. Select **Plugin Management...**
3. Click the `+` button at the bottom to open the Plugin Editor.
4. Fill in the details and choose an action type.

### Supported Action Types (Action `type`)
- 🌐 `url`: Open the system browser to visit `{text}`
- ⌨️ `key-combo`: Record system combo shortcuts directly from the UI
- 📋 `copy`: Copy to clipboard
- 📝 `paste`: Paste into the current input area

#### Script Extensions (Inline Execution)
For `shell-script` and `applescript`, you can write the short code block directly into the `script` string field for convenience. When triggered, OpenFire will automatically inject the text selected by the user into an environment variable named `$OPENFIRE_TEXT`.

**Example: Run Shell**
```json
"action": {
  "type": "shell-script",
  "script": "echo \"Selected: $OPENFIRE_TEXT\" >> ~/Desktop/openfire.log"
}
```

**Example: Run AppleScript**
```json
"action": {
  "type": "applescript",
  "script": "set envText to (system attribute \"OPENFIRE_TEXT\")\ndisplay dialog \"You selected: \" & envText"
}
```

---

## 💻 Tech Stack

- **Language:** Swift 5.9, AppKit, Objective-C Runtime
- **Rendering:** Core Animation (`CAShapeLayer`, `CATextLayer`, `CATransaction`)
- **Event Monitoring:** CGEventTap, macOS Accessibility API (`AXUIElement`, `AXObserver`)
- **Concurrency:** GCD (`DispatchQueue.global`) and Swift Concurrency

---

## 📒 Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## 📄 License

OpenFire is released under the [MIT License](LICENSE).
