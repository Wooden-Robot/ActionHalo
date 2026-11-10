package com.actionhalo.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Toast
import com.actionhalo.android.SelectionDiagnostics.Trace
import com.actionhalo.android.SelectionDiagnostics.MenuRejection

/** Shows actions for a real selection menu; copies only when the user chooses an action. */
internal class TelegramCopyAssistant(
    private val service: AccessibilityService,
    private val screenBounds: () -> Rect,
    private val canOperate: () -> Boolean,
    private val beforeCopy: () -> Unit,
    private val copied: (startedUptime: Long, startedWall: Long, finishedWall: Long, action: HaloAction, hostWindowId: Int, sourcePackage: String, menuBounds: Rect?) -> Unit,
) {
    private val appRules = AppRulesStore(service)
    private val handler = Handler(Looper.getMainLooper())
    private val manager = service.getSystemService(WindowManager::class.java)
    private var enabled = false
    private var telegramEnabled = false
    private var standardMenusEnabled = false
    private var view: View? = null
    private var radial: RadialMenuView? = null
    private var haloWindow: SelectionHaloWindow? = null
    private var shownWindow = -1
    private var shownHost = -1
    private var shownPackage: String? = null
    private var shownFrame: Rect? = null
    private var pendingAction: HaloAction? = null
    private var pendingActionStartedUptime = 0L
    private data class Selection(val windowId: Int, val nodeId: Int, val range: SelectionPolicy.Range, val protectedAreas: List<Rect>)
    private var selection: Selection? = null
    private var waitingForSource = false
    private val sourceTimeout = Runnable {
        TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED)
        waitingForSource = false
        pendingAction = null
        radial?.apply {
            beginInteractionSession()
            showOperationStatus(null)
            showActionError(R.string.copy_probe_expired)
        } ?: hide()
    }
    private val dismissed = mutableSetOf<Int>()
    private val consumed = mutableMapOf<Int, Long>()
    private val probeRejections = java.util.EnumSet.noneOf(MenuRejection::class.java)
    private var shownMenuMetadataMissing = false
    private val refresh = Runnable { refreshMenu() }
    private val settledRefresh = Runnable { refreshMenu(settled = true) }
    val isShowing: Boolean get() = radial != null

    fun setEnabled(value: Boolean, standardMenus: Boolean = false) {
        if (telegramEnabled != value || standardMenusEnabled != standardMenus) clear()
        telegramEnabled = value
        standardMenusEnabled = standardMenus
        enabled = value || standardMenus
        val info = service.serviceInfo ?: run { clear(); return }
        val flag = AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        val flags = if (enabled) info.flags or flag else info.flags and flag.inv()
        if (info.flags != flags) {
            info.flags = flags
            service.serviceInfo = info
        }
        if (enabled) schedule() else clear()
    }

    fun onEvent(event: AccessibilityEvent) {
        if (!enabled || appRules.isPaused()) return
        if (!appRules.allowsButton(event.packageName?.toString(), true) &&
            event.eventType != AccessibilityEvent.TYPE_WINDOWS_CHANGED && event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                protectCurrentSelection()
                if (radial != null) refreshMenu()
                schedule()
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                if (standardMenusEnabled || (telegramEnabled &&
                        TelegramCopyPolicy.supportsPackage(event.packageName?.toString()))) {
                    observeSelection(event, initial = false)
                    // A refined selection may reuse the same native toolbar window.
                    dismissed.clear()
                    schedule()
                }
            }
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED -> {
                if (standardMenusEnabled || (telegramEnabled &&
                        TelegramCopyPolicy.supportsPackage(event.packageName?.toString()))) {
                    if (event.packageName?.toString() != service.packageName) SelectionDiagnostics.trace(Trace.MENU_LONG_PRESS)
                    observeSelection(event, initial = true)
                    schedule()
                }
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> cancelPendingForTextChange(event)
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED ->
                if (standardMenusEnabled || (telegramEnabled &&
                        TelegramCopyPolicy.supportsPackage(event.packageName?.toString()))) {
                    if (radial != null && event.packageName?.toString() == shownPackage) {
                        cancelPendingForTextChange(event)
                        if (event.windowId == shownHost) observeSelection(event, initial = false, rangeEvent = false)
                        protectCurrentSelection()
                        if (radial != null) refreshMenu()
                    }
                    schedule()
                }
            else -> Unit
        }
    }

    private fun cancelPendingForTextChange(event: AccessibilityEvent) {
        val selected = selection ?: return
        if (pendingAction == null || selected.windowId != shownHost || event.windowId != shownHost ||
            event.packageName?.toString() != shownPackage || event.eventTime < pendingActionStartedUptime) return
        val textChanged = if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) {
            event.fromIndex >= 0 && (event.addedCount > 0 || event.removedCount > 0)
        } else event.contentChangeTypes and AccessibilityEvent.CONTENT_CHANGE_TYPE_TEXT != 0
        if (!textChanged) return
        val source = event.source ?: return
        try {
            // Invalidate by source identity and explicit change metadata, without reading its text.
            if (source.windowId != selected.windowId || source.hashCode() != selected.nodeId ||
                source.packageName?.toString() != shownPackage) return
            pendingAction = null
            radial?.beginInteractionSession()
            waitForSource()
            schedule()
        } finally { recycle(source) }
    }

    private fun observeSelection(event: AccessibilityEvent, initial: Boolean, rangeEvent: Boolean = !initial) {
        if (event.packageName?.toString() == service.packageName) return
        if (initial || event.isPassword) {
            selection = null
            if (event.windowId == shownHost) hide()
        }
        if (event.isPassword) return
        val source = event.source ?: return
        try {
            if (!source.refresh() || source.isPassword || !source.isVisibleToUser ||
                source.packageName?.toString() != event.packageName?.toString() ||
                (Build.VERSION.SDK_INT >= 34 && source.isAccessibilityDataSensitive)) return
            if (!initial && !rangeEvent && (source.windowId != selection?.windowId ||
                    source.hashCode() != selection?.nodeId)) return
            if (!initial && !rangeEvent && (source.textSelectionStart < 0 || source.textSelectionEnd < 0)) return
            val start = if (source.textSelectionStart >= 0) source.textSelectionStart else event.fromIndex
            val end = if (source.textSelectionEnd >= 0) source.textSelectionEnd else event.toIndex
            // Only range metadata is needed here; do not read message or page text.
            val range = SelectionPolicy.range(maxOf(start, end), start, end) ?: run {
                // Missing range metadata does not cancel a still-available Copy menu.
                if (!initial && start >= 0 && start == end) {
                    SelectionDiagnostics.trace(Trace.MENU_COLLAPSED)
                    selection = null
                    if (source.windowId == shownHost) hide()
                } else SelectionDiagnostics.trace(Trace.MENU_RANGE_UNAVAILABLE)
                return
            }
            val current = Selection(source.windowId, source.hashCode(), range, HaloSafeArea.selectionProtectionBounds(service, source, range))
            val previous = selection
            if (pendingAction != null && current.windowId == shownHost &&
                (previous == null || previous.windowId != current.windowId || previous.nodeId != current.nodeId || previous.range != current.range)) {
                pendingAction = null
                radial?.beginInteractionSession()
                waitForSource()
            }
            selection = current
            if (current.windowId == shownHost) haloWindow?.updateProtectedAreas(
                current.protectedAreas + HaloSafeArea.selectionControlBounds(service, shownHost, shownWindow))
        } catch (_: IllegalStateException) { }
        catch (_: SecurityException) { }
        finally { recycle(source) }
    }

    private fun protectCurrentSelection() {
        if (radial == null || shownHost < 0) return
        haloWindow?.updateProtectedAreas(selection?.takeIf { it.windowId == shownHost }?.protectedAreas.orEmpty() +
            HaloSafeArea.selectionControlBounds(service, shownHost, shownWindow))
    }

    private fun schedule() {
        handler.removeCallbacks(refresh)
        handler.removeCallbacks(settledRefresh)
        handler.postDelayed(refresh, 60)
        // A newly added popup may not have published its child nodes yet. No continuous polling.
        handler.postDelayed(settledRefresh, 260)
    }

    fun onSelectionUnavailable() {
        if (enabled) schedule()
    }

    fun suppressesClick(windowId: Int, eventUptime: Long): Boolean =
        consumed[windowId]?.let { eventUptime - it in 0..TelegramCopyPolicy.MAX_EVENT_AGE_MS } == true

    fun clear() {
        if (view != null) SelectionDiagnostics.trace(Trace.MENU_RESET)
        handler.removeCallbacks(refresh)
        handler.removeCallbacks(settledRefresh)
        hide()
        selection = null
        dismissed.clear()
        consumed.clear()
    }

    private fun refreshMenu(settled: Boolean = false) {
        if (!enabled || !canOperate()) {
            if (view != null) SelectionDiagnostics.trace(Trace.MENU_CHECK_BLOCKED)
            return hide()
        }
        if (view != null) {
            when (SourceWindowState.read(service, shownHost)) {
                SourceWindowState.State.OBSCURED -> {
                    SelectionDiagnostics.trace(Trace.MENU_HOST_OBSCURED)
                    waitForSource()
                    return
                }
                SourceWindowState.State.REPLACED -> {
                    SelectionDiagnostics.trace(Trace.MENU_HOST_REPLACED)
                    // A modal closing can publish the host before republishing its child menu.
                    if (settled) hide() else waitForSource()
                    return
                }
                SourceWindowState.State.PRESENT -> Unit
            }
        }
        consumed.entries.removeAll { SystemClock.uptimeMillis() - it.value > TelegramCopyPolicy.MAX_EVENT_AGE_MS }
        val target = findTarget()
        try {
            if (target == null) {
                if (view != null) SelectionDiagnostics.trace(Trace.MENU_MISSING)
                // Keep current visibility while the same verified popup temporarily loses its labels.
                if (!shownMenuMetadataMissing || probeRejections.isNotEmpty()) {
                    haloWindow?.updateSelectionMenu(false)
                }
                // Window metadata can outlive its readable tree during a modal transition.
                if (view != null && (!settled || radial != null && sourceState() != SourceWindowState.State.REPLACED)) waitForSource() else hide()
            } else if (target.windowId in dismissed || target.windowId in consumed) hide()
            else {
                if (pendingAction != null) {
                    shownWindow = target.windowId
                    copyFromMenu(target.windowId, checkNotNull(pendingAction))
                } else {
                    handler.removeCallbacks(sourceTimeout)
                    waitingForSource = false
                    radial?.showOperationStatus(null)
                    show(target)
                    haloWindow?.updateSelectionMenu(true, settled)
                }
            }
        } finally { target?.let { recycle(it.node) } }
    }

    private fun sourceState(): SourceWindowState.State {
        val host = SourceWindowState.read(service, shownHost)
        return if (host == SourceWindowState.State.PRESENT) SourceWindowState.read(service, shownWindow) else host
    }

    private data class Target(val windowId: Int, val hostWindowId: Int, val packageName: String,
        val node: AccessibilityNodeInfo, val bounds: Rect)

    private fun findTarget(): Target? {
        val windows = service.windows
        val matches = mutableListOf<Target>()
        probeRejections.clear()
        shownMenuMetadataMissing = false
        fun absent(reason: Trace): Target? {
            shownMenuMetadataMissing = shownMenuMetadataMissing &&
                (reason == Trace.MENU_NO_COPY || reason == Trace.MENU_UNREADABLE)
            SelectionDiagnostics.menuProbe(reason, probeRejections)
            return null
        }
        try {
            dismissed.retainAll(windows.map { it.id }.toSet())
            // Initial discovery requires the foreground app. Once shown, follow the
            // verified host and popup across temporary dialogs taking global focus.
            val retained = view != null && windows.any { it.id == shownHost }
            var foregroundWindowId = -1
            val foregroundPackage = if (retained) shownPackage else {
                if (view != null) return null
                val apps = windows.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
                val foreground = apps.firstOrNull { it.isFocused } ?: apps.firstOrNull { it.isActive }
                    ?: return absent(Trace.MENU_NO_FOREGROUND)
                foregroundWindowId = foreground.id
                val root = foreground.root ?: return absent(Trace.MENU_FOREGROUND_UNREADABLE)
                try { root.packageName?.toString() } finally { recycle(root) }
            } ?: return null
            if (foregroundPackage == service.packageName) return null
            if (!appRules.allowsButton(foregroundPackage, true)) return absent(Trace.MENU_APP_DISABLED)
            val telegramMenu = telegramEnabled && TelegramCopyPolicy.supportsPackage(foregroundPackage)
            if (!telegramMenu && !standardMenusEnabled) return null
            var childSeen = false
            var hostSeen = false
            var readable = false
            for (window in windows) {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                // Inspect child menus only, never the main application's text tree.
                // Dragging selection handles may replace the toolbar while retaining its verified host.
                val parent = window.parent ?: continue
                childSeen = true
                val hostId = parent.id
                val parentRoot = parent.root
                val sameHost = try { parentRoot?.packageName?.toString() == foregroundPackage &&
                    // Same-package split-screen windows must not borrow each other's selection menus.
                    (retained || window.id == foregroundWindowId || hostId == foregroundWindowId) &&
                    (!retained || hostId == shownHost) && windows.any { it.id == hostId } }
                    finally { parentRoot?.let(::recycle); recycleWindow(parent) }
                if (!sameHost) continue
                hostSeen = true
                val root = window.root
                if (root == null) {
                    if (window.id == shownWindow) shownMenuMetadataMissing = true
                    continue
                }
                try {
                    if (root.packageName?.toString() != foregroundPackage) continue
                    if (window.id == shownWindow) shownMenuMetadataMissing = true
                    readable = true
                    var buttons = menuButtons(root, foregroundPackage, window.id,
                        requireStandardContainer = !telegramMenu)
                    if (buttons.isEmpty() && standardMenusEnabled &&
                        !TelegramCopyPolicy.supportsPackage(foregroundPackage) &&
                        hasCustomSelectionCommands(root, foregroundPackage, window.id)) {
                        buttons = menuButtons(root, foregroundPackage, window.id, requireStandardContainer = false)
                    }
                    val menuBounds = Rect().also(window::getBoundsInScreen)
                    buttons.forEach { matches.add(Target(window.id, hostId, foregroundPackage, it, menuBounds)) }
                } finally { recycle(root) }
            }
            if (matches.size == 1) {
                SelectionDiagnostics.menuProbe(Trace.MENU_MATCHED, probeRejections)
                return matches.removeAt(0)
            }
            return absent(when {
                matches.size > 1 -> Trace.MENU_AMBIGUOUS
                !childSeen -> Trace.MENU_NO_CHILD_WINDOW
                !hostSeen -> Trace.MENU_SOURCE_MISMATCH
                !readable -> Trace.MENU_UNREADABLE
                else -> Trace.MENU_NO_COPY
            })
        } catch (_: IllegalStateException) {
            return absent(Trace.MENU_STALE)
        } catch (_: SecurityException) {
            return absent(Trace.MENU_ACCESS_DENIED)
        } finally {
            matches.forEach { recycle(it.node) }
            windows.forEach(::recycleWindow)
        }
    }

    private fun hasCustomSelectionCommands(root: AccessibilityNodeInfo, pkg: String, windowId: Int): Boolean {
        fun hasCommand(labels: Set<String>): Boolean {
            val buttons = menuButtons(root, pkg, windowId, requireStandardContainer = false, commands = labels)
            return try { buttons.isNotEmpty() } finally { buttons.forEach(::recycle) }
        }
        val resources = android.content.res.Resources.getSystem()
        return hasCommand(setOf(resources.getString(android.R.string.cut), resources.getString(android.R.string.selectAll),
            "Cut", "CUT", "剪切", "剪下", "Select all", "SELECT ALL", "全选", "全選")) ||
            hasCommand(setOf("转发", "轉發", "Forward")) &&
            hasCommand(setOf("收藏", "Favorite", "Favorites", "Favourites"))
    }

    private fun menuButtons(root: AccessibilityNodeInfo, pkg: String, windowId: Int,
        requireStandardContainer: Boolean, commands: Set<String>? = null): List<AccessibilityNodeInfo> {
        val matches = mutableListOf<AccessibilityNodeInfo>()
        val customMenu = !requireStandardContainer && !TelegramCopyPolicy.supportsPackage(pkg)
        var visited = 0
        var truncated = false
        val label = android.content.res.Resources.getSystem().getString(android.R.string.copy)
        fun isCommandLabel(value: String): Boolean = commands?.contains(value.trim()) ?: TelegramCopyPolicy.isCopyLabel(value, label)
        // Older framework toolbars omit the container ID but identify their menu-item labels.
        val standardItems = if (requireStandardContainer)
            root.findAccessibilityNodeInfosByViewId(TelegramCopyPolicy.STANDARD_MENU_ITEM_ID) else emptyList()
        val hasStandardItems = try { standardItems.isNotEmpty() } finally { standardItems.forEach(::recycle) }
        fun eligible(node: AccessibilityNodeInfo): Boolean {
            if (node.packageName?.toString() != pkg || node.windowId != windowId || !node.isEnabled) return false
            val rejection = when {
                node.isPassword -> MenuRejection.PASSWORD
                node.isEditable -> MenuRejection.EDITABLE
                !node.isVisibleToUser -> MenuRejection.HIDDEN
                Build.VERSION.SDK_INT >= 34 && node.isAccessibilityDataSensitive -> MenuRejection.SENSITIVE
                else -> null
            }
            if (rejection != null) { probeRejections.add(rejection); return false }
            return true
        }
        fun visit(node: AccessibilityNodeInfo, nearestButton: AccessibilityNodeInfo?, depth: Int,
            insideStandardContainer: Boolean) {
            if (++visited > 80 || depth > 8) { truncated = true; return }
            if (!eligible(node)) return
            if (customMenu) {
                // Feed rows can expose the same commands as a menu; toolbars may overflow horizontally.
                val actions = node.actionList
                val vertical = AccessibilityAction.ACTION_SCROLL_UP in actions || AccessibilityAction.ACTION_SCROLL_DOWN in actions
                val horizontal = AccessibilityAction.ACTION_SCROLL_LEFT in actions || AccessibilityAction.ACTION_SCROLL_RIGHT in actions
                if (vertical || (node.isScrollable && !horizontal)) {
                    if (windowId == shownWindow) shownMenuMetadataMissing = false
                    return
                }
            }
            // Generic content events may leave a known menu's cached child labels empty.
            if (windowId == shownWindow && (node.isClickable || nearestButton != null) &&
                node.text.isNullOrBlank() && node.contentDescription.isNullOrBlank()) {
                if (!node.refresh() || !eligible(node)) return
            }
            val inside = insideStandardContainer ||
                node.viewIdResourceName == TelegramCopyPolicy.STANDARD_MENU_CONTAINER_ID
            val allowed = !requireStandardContainer || inside
            if (allowed && node.isClickable && !TelegramCopyPolicy.supportsButtonClass(node.className?.toString())) {
                probeRejections.add(MenuRejection.UNSUPPORTED_CONTROL)
            }
            var labels = if (allowed) listOfNotNull(node.text?.toString(),
                node.contentDescription?.toString()).filter { it.isNotBlank() } else emptyList()
            if (labels.any(::isCommandLabel)) {
                if (!node.refresh() || !eligible(node)) return
                labels = listOfNotNull(node.text?.toString(), node.contentDescription?.toString()).filter { it.isNotBlank() }
            }
            val button = if (allowed && node.isClickable && node.actionList.any {
                    it.id == AccessibilityNodeInfo.ACTION_CLICK
                } && TelegramCopyPolicy.supportsButtonClass(node.className?.toString())) node else nearestButton
            if (button != null && labels.isNotEmpty() && labels.all(::isCommandLabel) &&
                matches.none { it == button }) {
                @Suppress("DEPRECATION")
                matches.add(AccessibilityNodeInfo.obtain(button))
            }
            for (index in 0 until node.childCount) {
                if (visited >= 80) { truncated = true; break }
                val child = node.getChild(index) ?: continue
                try { visit(child, button, depth + 1, inside) } finally { recycle(child) }
            }
        }
        try { visit(root, null, 0, hasStandardItems) } catch (failure: RuntimeException) {
            matches.forEach(::recycle)
            throw failure
        }
        if (truncated) {
            probeRejections.add(MenuRejection.TRUNCATED)
            matches.forEach(::recycle)
            return emptyList()
        }
        return matches
    }

    private fun show(target: Target, explicit: Boolean = false) {
        val screen = screenBounds()
        val bounds = Rect(screen).apply { inset(dp(8), dp(8)) }
        val source = Rect(target.bounds).apply { inset(-dp(32), -dp(64)) }
        val protectedAreas = selection?.takeIf { it.windowId == target.hostWindowId }?.protectedAreas.orEmpty() +
            HaloSafeArea.selectionControlBounds(service, target.hostWindowId, target.windowId)
        val openHalo = explicit || radial != null || appRules.allowsAutomatic(target.packageName, true)
        if (!openHalo && appRules.triggerMode(target.packageName) != AppRulesStore.TriggerMode.BUTTON) {
            return hide()
        }
        if (view != null && shownHost == target.hostWindowId && shownPackage == target.packageName &&
            shownFrame == bounds && (radial != null) == openHalo) {
            // Selection handles can replace the native toolbar without starting a new wheel.
            shownWindow = target.windowId
            haloWindow?.updateProtectedAreas(protectedAreas)
            return
        }
        hide()
        val context = HaloUi.localizedContext(service)
        val actions = appRules.actionsFor(target.packageName, ActionStore(context).allActions())
        if (actions.isEmpty()) {
            SelectionDiagnostics.trace(Trace.MENU_NO_ACTIONS)
            return
        }
        val root: View
        val params: WindowManager.LayoutParams
        var menu: RadialMenuView? = null
        var selectionWindow: SelectionHaloWindow? = null
        if (openHalo) {
            menu = RadialMenuView(context).apply {
                gtaModeEnabled = HaloAppearance.isGtaModeEnabled(service)
                // The original application still owns its exact selection. No clipboard read here.
                selectedText = ""
                selectionTextKnown = false
                setActions(actions)
                onActionSelected = { action -> if (radial === this && isShown) copyFromMenu(shownWindow, action) }
                onDismiss = { if (radial === this) {
                    SelectionDiagnostics.trace(Trace.HALO_USER_CLOSED)
                    dismissed.add(shownWindow)
                    hide()
                } }
            }
            val actionMenu = menu
            SourceAppControls.bind(actionMenu, target.packageName, target.hostWindowId) { actionMenu.onDismiss?.invoke() }
            val window = SelectionHaloWindow(context, manager, screen, source, menu, onOutsideTouch = ::schedule, keyboardBounds = keyboardBounds())
            window.updateProtectedAreas(protectedAreas)
            selectionWindow = window
            if (explicit) window.expand()
            root = window.root
            params = window.params
            params.title = if (TelegramCopyPolicy.supportsPackage(target.packageName))
                "ActionHalo Telegram actions" else "ActionHalo selection menu actions"
        } else {
            root = HaloUi.button(context, context.getString(R.string.selection_open_halo)).apply {
                setOnClickListener {
                    if (!enabled || !canOperate()) return@setOnClickListener hide()
                    val fresh = findTarget()
                    try {
                        if (fresh != null && fresh.hostWindowId == target.hostWindowId && fresh.packageName == target.packageName) {
                            show(fresh, explicit = true)
                        } else hide()
                    } finally { fresh?.let { recycle(it.node) } }
                }
            }
            val helperFrame = HaloSafeArea.initialFrame(screen, source, dp(160), dp(8),
                HaloAppearance.InitialPosition.AUTO, keyboardBounds())
            val width = helperFrame.width()
            val label = root as android.widget.TextView
            val height = minOf(maxOf(dp(52), label.lineHeight + label.paddingTop + label.paddingBottom), helperFrame.height()).coerceAtLeast(1)
            params = WindowManager.LayoutParams(width, height, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT).apply {
                @Suppress("RtlHardcoded")
                gravity = Gravity.TOP or Gravity.LEFT
                x = helperFrame.left - screen.left
                y = helperFrame.top - screen.top
                title = "ActionHalo selection helper"
                if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                if (Build.VERSION.SDK_INT >= 28) layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER
            }
        }
        try {
            manager.addView(root, params)
            SelectionDiagnostics.trace(Trace.HALO_ATTACHED)
            view = root
            radial = menu
            haloWindow = selectionWindow
            shownWindow = target.windowId
            shownHost = target.hostWindowId
            shownPackage = target.packageName
            shownFrame = bounds
            TelegramCopyDiagnostics.record(if (menu != null) TelegramCopyDiagnostics.Stage.DIRECT_HALO_SHOWN
                else TelegramCopyDiagnostics.Stage.INITIAL_MENU_SHOWN)
        } catch (_: WindowManager.BadTokenException) {
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.LAUNCH_BLOCKED)
        } catch (_: SecurityException) {
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.LAUNCH_BLOCKED)
        }
    }

    private fun copyFromMenu(expectedWindow: Int, action: HaloAction) {
        if (!enabled || !canOperate() || expectedWindow != shownWindow || expectedWindow in consumed) return hide()
        when (sourceState()) {
            SourceWindowState.State.OBSCURED -> return deferAction(action)
            SourceWindowState.State.REPLACED -> return deferAction(action)
            SourceWindowState.State.PRESENT -> Unit
        }
        val target = findTarget()
        try {
            if (target == null) return deferAction(action)
            if (action !in appRules.actionsFor(target.packageName, ActionStore(HaloUi.localizedContext(service)).allActions())) {
                hide()
                TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED)
                return
            }
            if (target.windowId != expectedWindow || !target.node.refresh() ||
                target.node.windowId != expectedWindow ||
                target.node.packageName?.toString() != target.packageName ||
                !TelegramCopyPolicy.supportsButtonClass(target.node.className?.toString()) ||
                !target.node.isVisibleToUser || !target.node.isEnabled || target.node.isPassword || target.node.isEditable ||
                (Build.VERSION.SDK_INT >= 34 && target.node.isAccessibilityDataSensitive) ||
                target.node.actionList.none { it.id == AccessibilityNodeInfo.ACTION_CLICK }) {
                if (sourceState() != SourceWindowState.State.PRESENT) return deferAction(action)
                copyFailed()
                return
            }
            val menuBounds = radial?.let { menu ->
                val origin = IntArray(2).also(menu::getLocationOnScreen)
                Rect(origin[0], origin[1], origin[0] + menu.width, origin[1] + menu.height)
            }
            consumed[expectedWindow] = SystemClock.uptimeMillis()
            hide()
            beforeCopy()
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.DIRECT_ACTION_TAPPED)
            val startedUptime = SystemClock.uptimeMillis()
            val startedWall = System.currentTimeMillis()
            // A chosen circle action explicitly requests the current selection, then its operation.
            if (!target.node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                copyFailed()
                return
            }
            // Plain Copy is already complete in the source app; only further actions need a snapshot.
            if (action.type == ActionType.COPY && !HaloAppearance.keepAfterCopy(service, action)) {
                TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED)
            } else copied(startedUptime, startedWall, System.currentTimeMillis(), action, target.hostWindowId, target.packageName, menuBounds)
        } catch (_: IllegalStateException) { copyFailed() }
        catch (_: SecurityException) { copyFailed() }
        finally { target?.let { recycle(it.node) } }
    }

    private fun deferAction(action: HaloAction) {
        if (pendingAction == null) pendingActionStartedUptime = SystemClock.uptimeMillis()
        pendingAction = action
        radial?.showOperationStatus(service.getString(R.string.operation_waiting_source))
        waitForSource()
        if (sourceState() == SourceWindowState.State.REPLACED) schedule()
    }

    private fun copyFailed() {
        hide()
        TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.COPY_ACTION_FAILED)
        Toast.makeText(service, R.string.telegram_copy_assist_failed, Toast.LENGTH_SHORT).show()
    }

    private fun waitForSource() {
        radial?.showOperationStatus(service.getString(R.string.operation_waiting_source))
        if (!waitingForSource) {
            waitingForSource = true
            handler.postDelayed(sourceTimeout, 30_000)
        }
    }

    private fun hide() {
        handler.removeCallbacks(sourceTimeout)
        waitingForSource = false
        pendingAction = null
        val old = view ?: return
        SelectionDiagnostics.trace(Trace.HALO_DETACHED)
        old.setOnTouchListener(null)
        view = null
        radial?.apply {
            selectedText = ""
            onActionSelected = null
            onDismiss = null
            onInteractionStarted = null
        }
        radial = null
        haloWindow = null
        shownWindow = -1
        shownHost = -1
        shownPackage = null
        shownFrame = null
        try { manager.removeViewImmediate(old) } catch (_: IllegalArgumentException) { }
    }

    private fun keyboardBounds(): List<Rect> {
        val windows = service.windows
        return try {
            windows.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }.map { Rect().also(it::getBoundsInScreen) }
        } finally { windows.forEach(::recycleWindow) }
    }

    private fun dp(value: Int): Int = HaloUi.dp(service, value)
    @Suppress("DEPRECATION")
    private fun recycle(node: AccessibilityNodeInfo) { if (Build.VERSION.SDK_INT < 33) node.recycle() }
    @Suppress("DEPRECATION")
    private fun recycleWindow(window: AccessibilityWindowInfo) { if (Build.VERSION.SDK_INT < 33) window.recycle() }
}
