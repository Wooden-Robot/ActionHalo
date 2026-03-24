# OpenFire Diagnostics Guide

This guide explains how to read the built-in Diagnostics window and how the current text-selection trigger pipeline works in `v0.3.15`.

## Open The Diagnostics Window

1. Open the OpenFire menu bar item.
2. Click `Diagnostics...`.
3. Click `Refresh` after reproducing the problem once.
4. Use `Copy Report` if you want to share the current report.

## What The Diagnostics Window Shows

The Diagnostics panel is a snapshot of the current OpenFire context. It is built in [`DiagnosticsWindow.swift`](./Sources/App/UI/DiagnosticsWindow.swift).

### Core Context Fields

- `Frontmost app`: The current foreground application name.
- `Bundle ID`: The current foreground application bundle identifier.
- `Accessibility`: Whether OpenFire currently has Accessibility permission.
- `App exclusion`: Whether the current app is disabled by the app blacklist.
- `Focused element`: The current focused accessibility role or role/subrole.
- `Selected text length`: The selected text length returned by Accessibility.
- `Selected text preview`: A short preview of the selected text.
- `Clipboard`: Whether the general pasteboard currently contains text.
- `Empty-input probe point`: The last location checked for the `Paste / Clear` capsule.
- `Selection source`: The last successful acquisition path:
  - `Accessibility API`
  - `Cmd+C Fallback`
- `Last selection failure`: The most recent failed path, such as:
  - `accessibilityEmptySelection`
  - `copyFallbackEmptySelection`
  - `observerSetupFailed`
  - `observerTimedOut`
  - `noFocusedApplication`
- `Menu readiness`: Whether OpenFire currently believes the menu can be shown.

### Plugin Visibility Section

The lower half of the report explains plugin visibility for the current text and app context.

- `Visible`: The plugin matches the current context and can appear in the ring.
- `Hidden`: The plugin is currently blocked.
- Common hidden reasons include:
  - plugin disabled
  - plugin disabled for current app
  - selected text too short or too long
  - regex mismatch
  - current app not in allowlist
  - missing execution trust for script plugins

## Current Trigger Logic

The main selection trigger path lives in [`TextSelectionMonitor.swift`](./Sources/App/Core/TextSelectionMonitor.swift) and [`AccessibilityManager.swift`](./Sources/App/Core/AccessibilityManager.swift).

### High-Level Flow

1. OpenFire records state on `leftMouseDown`.
2. OpenFire evaluates the gesture on `leftMouseUp`.
3. Non-text gestures are filtered out first.
4. If the gesture still looks like text selection, OpenFire tries to acquire the selected text.
5. If text is acquired, the radial menu is shown after a short presentation delay.

### Gesture Filters Applied Before Triggering

OpenFire suppresses the menu before any text acquisition if any of the following is true:

- The drag pasteboard changed during the gesture and now contains file-drag types such as `public.file-url`.
- The frontmost app is a suppressed context:
  - OpenFire itself
  - Finder
  - Dock
  - Desktop / WindowManager
  - known screenshot tools
- The current gesture moved the frontmost window itself.

That last rule is important in `v0.3.15`: window dragging is now blocked by comparing the frontmost window frame before and after the gesture instead of relying on fragile AX text hit-testing.

### How OpenFire Decides A Gesture Is “Text-Like”

OpenFire captures these signals:

- whether the gesture started in a text context
- whether the gesture ended in a text context
- whether the pointer was inside the focused element bounds
- whether the Accessibility selection snapshot changed

`Text context` means one of:

- the hit-tested element is treated as text
- the point is inside an editable text input
- the point is inside a focused element that looks like rich-text selection context

### Preferred Acquisition Path: Accessibility

OpenFire first tries native Accessibility selection state.

It succeeds when:

- the current selection snapshot is readable via Accessibility
- the selected text is non-empty
- the selection actually changed compared with the `mouseDown` snapshot

When this path works, Diagnostics shows:

- `Selection source: Accessibility API`

### Fallback Acquisition Path: Cmd+C

If native Accessibility does not yield text quickly enough, OpenFire falls back to synthetic `Cmd+C`.

This path:

- posts `Cmd+C`
- polls the pasteboard briefly
- waits for a fresh non-empty copied string
- restores the previous pasteboard snapshot only when a fresh copied value actually arrived

When this path works, Diagnostics shows:

- `Selection source: Cmd+C Fallback`

## Browser / WebView / Telegram Behavior

Different hosts expose different AX quality, so OpenFire treats them slightly differently.

### Native Editors

Examples:

- TextEdit
- many native text fields

These typically succeed via native Accessibility snapshots.

### Browsers And WebViews

Examples:

- Chrome
- Edge
- Brave
- Codex app

These may succeed either through Accessibility or through `Cmd+C` fallback, depending on timing and DOM accessibility exposure.

### Telegram

Telegram is the most important special case in `v0.3.15`.

Observed behavior:

- on mouse-up, Telegram may expose no usable AX hit element
- on mouse-up, Telegram may expose no usable focused element

Because of that, OpenFire now avoids requiring stable AX hit/focus evidence for Telegram’s fallback path. Instead:

- if the gesture did not move the frontmost window
- and `Cmd+C` produced fresh non-empty text

OpenFire still allows the radial menu to trigger.

This is the reason Telegram can now work again without reintroducing the old “dragging the window also triggers the menu” bug.

## How To Read Common Failure Patterns

### Case 1: Nothing Triggers Anywhere

Typical report:

- `Accessibility: Missing`
- `Menu readiness: Blocked`
- `Last selection failure: noFocusedApplication` or repeated empty selection

Usually means:

- Accessibility permission is missing or ineffective

### Case 2: Text Selection Works In Some Apps But Not Others

Typical report:

- `Accessibility: Granted`
- `App exclusion: Active in current app`
- some plugins visible, some hidden
- repeated `copyFallbackEmptySelection` in the failing app

Usually means:

- the host app exposes poor AX selection state
- fallback copy did not produce a fresh clipboard value
- or the app is blacklisted / plugin-scoped filtered

### Case 3: Dragging A Window Opens The Ring

In `v0.3.15`, this should no longer happen under normal conditions.

The relevant guard is:

- frontmost window movement detection

If this regresses again, compare:

- gesture path
- whether the frontmost app changed mid-gesture
- whether the moved surface was actually a separate panel instead of the main window

### Case 4: Finder File Management Should Not Trigger, But Rename Should

Expected behavior:

- dragging files: blocked
- desktop / Dock file management: blocked
- Finder rename field text selection: allowed

This works because file-management contexts are suppressed broadly, but editable text context inside Finder still bypasses that suppression.

## Practical Reproduction Workflow

When debugging a report:

1. Reproduce the issue once.
2. Open `Diagnostics...`.
3. Click `Refresh`.
4. Check:
   - frontmost app
   - Accessibility permission
   - focused element
   - selected text preview
   - selection source
   - last selection failure
   - plugin visibility reasons
5. If needed, reproduce again and compare whether the source flips between `Accessibility API` and `Cmd+C Fallback`.

## Source Pointers

- Trigger pipeline: [`Sources/App/Core/TextSelectionMonitor.swift`](./Sources/App/Core/TextSelectionMonitor.swift)
- Accessibility acquisition and fallback: [`Sources/App/Core/AccessibilityManager.swift`](./Sources/App/Core/AccessibilityManager.swift)
- Diagnostics UI: [`Sources/App/UI/DiagnosticsWindow.swift`](./Sources/App/UI/DiagnosticsWindow.swift)
