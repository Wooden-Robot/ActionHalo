<div align="center">

# OpenFire 🔥

**An ultra-smooth circular menu tool for macOS with both click-to-execute and press-drag-release execution after selection.**

[**English**](./README.md) • [简体中文](./README_zh.md)

[![macOS 13.0+](https://img.shields.io/badge/macOS-13.0+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/macos)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

<img src="./Assets/demo.gif" width="600" alt="OpenFire Demo 1" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 24px 0 12px;"/>

<img src="./Assets/demo2.gif" width="600" alt="OpenFire Demo 2" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15); margin: 12px 0 24px;"/>

> OpenFire draws inspiration from both GTA V and PopClip, then massively refactors and optimizes the UI, interaction model, and performance with native Core Animation and Swift Concurrency.

</div>

---

## ✨ Features That Wow

🚀 **Esports-level Response Speed**
Bottom-layer hit testing based on `mouseDown` / `mouseDragged` / `mouseUp`. Bid farewell to missed clicks. In both workflows, the wheel is triggered only after you finish the text selection and release the mouse button. From there, OpenFire supports two distinct execution styles:

- **Release, then click to execute**: select text, release to open the wheel, then click the action you want.
- **Release, press, drag, then release to execute**: select text, release to open the wheel, immediately press again, drag across to the target slice, then release to fire that action.

The hover state tracks your cursor with near-zero latency, so the second mode feels closer to a GTA V weapon wheel than a traditional context menu.

💫 **Native Blur & 60FPS Animations**
Uses `NSVisualEffectView` and `CAShapeLayer` buffer pool. Page flipping, hovering, and clicking animations are buttery smooth with no frame drops.

🎛️ **Highly Customizable UI**
Adjust the radial menu's **Ring Opacity** and **Max Items limit** (6, 8, 12, or 16 items per page) directly from the Menu Bar. You can also toggle **GTA Mode** for a heavier weapon-wheel style presentation with a darker HUD-like look.

🔌 **Hot-pluggable Plugin System**
Supports custom `.openfireext` plugin packages. Features double-click installation, background thread asynchronous loading, and a package management mechanism supporting deletion and disabling.

🧠 **Smart Trigger Context**
Rewritten Accessibility recognition logic at the foundation. Text-selection actions stay focused on the selected content itself, while input-related actions still respect whether the current focus is actually editable.

✂️ **Cleaner Quick Actions**
When OpenFire detects that you clicked into an editable field and there is no active text selection, it can show a lightweight `Paste / Clear` capsule near the cursor for quick paste access or for clearing the current clipboard contents. When the clipboard is empty, this shortcut does not appear. The built-in `Paste` action can also appear in the radial menu for editable selections.

🚫 **Customizable App Blacklist**
Built-in automatic blacklist management UI. Supports dragging and dropping apps, or browsing via the `+` button to precisely block specific software.

---

## 🚀 Getting Started

### Installation

1. Download the latest `.dmg` from the [Releases](https://github.com/Wooden-Robot/OpenFire/releases) page.
2. Open the downloaded file and drag the **OpenFire** app into your `Applications` folder.
3. Launch OpenFire.
4. Open **System Settings → Privacy & Security → Accessibility** and grant permissions to OpenFire (required for text selection detection).

### How Triggering Works

OpenFire has **two ways to open the wheel**, and they are easy to confuse if described as one flow:

1. **Mouse selection trigger**: select text normally, then release the mouse button. The wheel appears only after the selection is complete and the button is up.
2. **Optional manual hotkey trigger**: if you set an `Open Menu Hotkey` in the menu bar, OpenFire can open the wheel for the current selection without waiting for the mouse-release flow.

Once the wheel is already visible, there are **two ways to execute an action**:

1. **Release, then click**: let the wheel pop up, then click the slice you want.
2. **Release, press, drag, then release**: let the wheel pop up, press down again right away, drag into the target slice, then release to fire it.

The second execution style is the signature interaction: as soon as the wheel appears, you can go straight into a weapon-wheel-like press-drag-release motion instead of pausing to click a slice.

If you need to debug why the wheel did or did not appear, see the dedicated [Diagnostics Guide](./DIAGNOSTICS.md).

### Trigger Logic Summary

OpenFire does not simply fire on every mouse drag. The current trigger pipeline is intentionally conservative:

1. A gesture must first look like an actual text-selection drag. Very short movements are treated as normal clicks instead of selection triggers.
2. OpenFire suppresses obvious non-text scenarios before trying to acquire text:
   - file drags detected through the drag pasteboard
   - frontmost file-management or self contexts such as Finder, Dock, Desktop, and OpenFire itself
   - known screenshot tools
   - window drags, detected by checking whether the frontmost window frame actually moved during the gesture
3. If the gesture survives those filters, OpenFire tries native Accessibility selection first.
4. If Accessibility does not yield usable selected text quickly enough, OpenFire falls back to a guarded `Cmd+C` path and waits briefly for a fresh clipboard update.
5. The wheel appears only after OpenFire has real non-empty selected text from one of those paths.

In practice, this means:

- normal text selection in native editors should usually trigger through Accessibility
- browser and WebView selections may trigger through either Accessibility or the `Cmd+C` fallback, depending on what the host app exposes
- Telegram is allowed to rely more heavily on the `Cmd+C` fallback because its AX hit/focus state is often unreliable at mouse-up time
- dragging files or dragging windows should not trigger the wheel
- editable text inside otherwise blocked contexts, such as Finder rename fields, can still trigger normally

### What `Cmd+C` Fallback Actually Means

`Cmd+C` fallback is OpenFire's backup acquisition path for apps that do not expose selected text reliably through the Accessibility API.

Instead of guessing the selected text, OpenFire does the following:

1. Save the current pasteboard snapshot.
2. Wait very briefly so physical modifier keys from the user's gesture do not interfere with the synthetic copy event.
3. Post a synthetic `Cmd+C`.
4. Poll the system pasteboard for a short window and wait for a fresh non-empty text value to appear.
5. If a fresh copied value really arrived, use that text as the selection and restore the previous pasteboard snapshot.

This path exists mainly for apps such as:

- Telegram
- Electron-based apps
- browser or WebView hosts whose Accessibility selection state is incomplete or delayed

It is intentionally guarded and is **not** a blind "always copy on every drag" behavior. OpenFire still checks context before allowing the fallback result to trigger the wheel. It also restores the previous clipboard only when the synthetic copy actually produced a fresh copied value, which helps avoid unnecessary clipboard churn.

So in short:

- `Accessibility API` is the preferred path
- `Cmd+C` fallback is the compatibility path
- both still require OpenFire to conclude that the gesture looked like text selection rather than a file drag, window drag, or other non-text interaction

### Menu Bar Controls

OpenFire lives in the macOS menu bar and exposes the main controls there:

- **Ring Opacity**: `0% (Opaque)` to `100% (Transparent)`
- **GTA Mode**: swaps the wheel into a heavier GTA V-style HUD presentation
- **Max Items in Menu**: `6 / 8 / 12 / 16`
- **Open Menu Hotkey**: manually open the wheel for the current selection. Default: `Shift + Option + D`
- **Auto Trigger Toggle Hotkey**: turn automatic text-selection triggering on or off. Default: `Shift + Option + X`
- **Plugin Management** and **App Blacklist**

Note: when **GTA Mode** is enabled, the wheel is intentionally rendered fully opaque and the opacity menu is disabled.

---

## 🧩 The Plugin Ecosystem

OpenFire's true power lies in its plugin system. Plugins exist as `.openfireext` packages containing a simple `Config.json`.

### Pre-installed Plugins
| 🔌 Plugin | 📝 Description |
| :--- | :--- |
| **Copy / Cut / Delete** | Core editing actions for the selected text itself. |
| **Search / Translate / Dict** | Everyday text actions for web search, translation, and the macOS Dictionary app. |
| **Open Link / Reveal in Finder** | Context-aware built-ins for URLs and file paths. They stay visible and become executable only when the current selection matches. |

These default built-ins are part of OpenFire itself. They can be enabled, disabled, reordered, and also edited from the menu bar. Editing a built-in plugin creates your own override on top of the bundled default.
Enabled plugins keep their slot in the wheel. If the current selection does not match a plugin's context, the action stays visible but disabled instead of disappearing before pagination.
The built-in `Paste` action can appear in the text-selection wheel when the current focus is editable, and it is also reused by the empty-input `Paste / Clear` popup.

### Community Plugins
Built into the package, they can be enabled or removed at any time via the "Plugin Management" interface:
- 🔍 [Baidu Search](./Plugins/BaiduSearch.openfireext/Config.json) / [Google Search](./Plugins/GoogleSearch.openfireext/Config.json): search the selected text on the web.
- 🧑‍💻 [GitHub Search](./Plugins/GitHubSearch.openfireext/Config.json): search the selected text on GitHub.
- 📚 [NeoDB Book Search](./Plugins/NeoDBBook.openfireext/Config.json) / [Douban Book Search](./Plugins/DoubanBook.openfireext/Config.json): look up books directly from the current selection.
- 🎬 [Douban Movie Search](./Plugins/DoubanMovie.openfireext/Config.json): search selected movie titles on Douban.
- ✈️ [Search in Telegram](./Plugins/Search%20Telegram.openfireext/Config.json): send the selected text into Telegram search.
- 📂 [Reveal in Finder](./Plugins/RevealPath.openfireext/Config.json): when the selection is a file path, open its location in Finder.
- 🖥️ [Run Shell](./Plugins/Run%20Shell.openfireext/Config.json): a default-disabled script plugin that runs a bundled shell script with the selected text.
- 💻 [Run in iTerm2](./Plugins/Run%20in%20iTerm2.openfireext/Config.json): a default-disabled plugin that sends the selected text to iTerm2 as a shell command.

---

## 🛠️ Build Your Own Plugin

OpenFire comes with a fully-featured **Visual Plugin Editor** built right into the app. You no longer need to write JSON configurations manually!

1. Click the 🔥 OpenFire icon in the macOS Menu Bar.
2. Select **Plugin Management...**
3. Click the `+` button at the bottom to open the Plugin Editor.
4. Fill in the details and choose an action type.

### Supported Action Types (Action `type`)
- 🌐 `url`: Open the system browser to visit `{text}`
- 🐚 `shell-script`: Run a bundled shell script with the selected text injected via environment variables
- 🍎 `applescript`: Run a bundled AppleScript with the selected text passed in by OpenFire
- ⌨️ `key-combo`: Record system combo shortcuts directly from the UI
- 📋 `copy`: Copy to clipboard
- 📝 `paste`: Paste into the current input area
- 📂 `reveal-path`: Open the selected file path in Finder

#### Script Extensions
For `shell-script` and `applescript`, the standard plugin layout is to point `action.script` at a bundled script file inside the `.openfireext` package. OpenFire also supports inline script text in the same `script` field for short snippets. When triggered, the selected text is injected into `$OPENFIRE_TEXT` and `OPENFIRE_TEXT_FILE`.

**Recommended package layout**
```text
My Script.openfireext/
  Config.json
  script.sh
```

**Example: Shell script file**
```json
"action": {
  "type": "shell-script",
  "script": "script.sh"
}
```

**Example: AppleScript file**
```json
"action": {
  "type": "applescript",
  "script": "script.applescript"
}
```

**Inline alternative for short scripts**
```json
"action": {
  "type": "shell-script",
  "script": "echo \"Selected: $OPENFIRE_TEXT\" >> ~/Desktop/openfire.log"
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
