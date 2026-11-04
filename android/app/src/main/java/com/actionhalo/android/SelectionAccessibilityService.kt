package com.actionhalo.android

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.PixelFormat
import android.view.Gravity
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.app.KeyguardManager
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.Toast
import java.lang.ref.WeakReference

/** Selection observer. Clipboard reads require a visible window with real input focus. */
class SelectionAccessibilityService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private val settings by lazy { getSharedPreferences(SETTINGS_NAME, MODE_PRIVATE) }
    private val appRules by lazy { AppRulesStore(this) }
    private val rulesPreferences by lazy { getSharedPreferences(AppRulesStore.PREFERENCES, MODE_PRIVATE) }
    private var selectionHelper: View? = null
    private val windowManager by lazy { getSystemService(WindowManager::class.java) }
    private var pending: PendingSelection? = null
    private var overlay: RadialMenuView? = null
    private var overlayRoot: View? = null
    private var overlayWindow: SelectionHaloWindow? = null
    private var selectionToolbarWindowId: Int? = null
    private var overlaySelection: PendingSelection? = null
    private var deferredSelectionAction: HaloAction? = null
    private var selectionObscured = false
    private var holdingCopiedText = false
    private val copyTimeout = Runnable { dismissCurrentSelection() }
    private val sourceTimeout = Runnable {
        if (deferredSelectionAction != null) Toast.makeText(this, R.string.copy_probe_expired, Toast.LENGTH_SHORT).show()
        clearSelection()
    }
    private var lastSelection: SelectionKey? = null
    private var selectionPrimedOnly = false
    private var listenersRegistered = false
    private var lastCopyEventUptime = 0L
    // Short-lived window IDs and times only: no node contents, app names, or clipboard history.
    private val copyWindowOpenedAt = linkedMapOf<Int, Long>()
    private val clipboardHaloOverlay by lazy {
        ClipboardHaloOverlay(this, canOperate = {
            screenAvailable() && copyMenuEnabled()
        })
    }
    private val telegramCopyAssistant by lazy {
        TelegramCopyAssistant(this, ::availableScreenBounds,
            // Only a real selection event or a shown native entry owns the interaction.
            { screenAvailable() && copyMenuEnabled() && !clipboardHaloOverlay.isShowing &&
                pending == null && overlay == null && selectionHelper == null && (lastSelection == null || selectionPrimedOnly) },
            ::clearSelection, ::openAssistedCopy)
    }

    private data class SelectionKey(
        val packageName: String,
        val windowId: Int,
        val nodeId: Int,
        val range: SelectionPolicy.Range,
    )

    private data class PendingSelection(
        val source: AccessibilityNodeInfo,
        val key: SelectionKey,
    )

    private val showPending = Runnable { presentPendingSelection() }
    private val resumeSelection = Runnable {
        val shown = overlay ?: return@Runnable
        val selected = overlaySelection ?: return@Runnable
        if (selectionStillValid(shown.selectedText) &&
            SourceWindowState.read(this, selected.key.windowId) == SourceWindowState.State.PRESENT &&
            (selectionToolbarWindowId == null || HaloSafeArea.selectionToolbarWindowId(this, selected.key.windowId) != null)) {
            overlayWindow?.resumeSelection()
        }
    }
    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == AUTO_POPUP_KEY || key == CONSENT_KEY) {
            handler.post { clearSelection(); telegramCopyAssistant.clear(); clipboardHaloOverlay.dismiss() }
        } else if (key == null || key == TelegramCopyPolicy.SETTING || key == TelegramCopyPolicy.STANDARD_MENU_SETTING) {
            // Preference listeners run on the main thread; cancel before changing authorization.
            clearSelection()
            copyWindowOpenedAt.clear()
            telegramCopyAssistant.clear()
            clipboardHaloOverlay.dismiss()
            telegramCopyAssistant.setEnabled(settings.getBoolean(TelegramCopyPolicy.SETTING, false),
                settings.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false))
        } else if (HaloAppearance.isAppearanceKey(key)) {
            handler.post { clearSelection(); telegramCopyAssistant.clear(); clipboardHaloOverlay.dismiss() }
        }
    }
    private val rulesListener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        clearSelection()
        telegramCopyAssistant.clear()
        clipboardHaloOverlay.dismiss()
    }
    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                AccessibilityHealthDiagnostics.recordScreenOff(this@SelectionAccessibilityService)
                AppRulesStore.clearVisitPauses()
                clearSelection()
                copyWindowOpenedAt.clear()
                telegramCopyAssistant.clear()
                clipboardHaloOverlay.dismiss()
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        connectedService = WeakReference(this)
        AccessibilityHealthDiagnostics.recordConnected(this)
        SelectionDiagnostics.reset()
        TelegramCopyDiagnostics.reset()
        telegramCopyAssistant.setEnabled(settings.getBoolean(TelegramCopyPolicy.SETTING, false),
            settings.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false))
        if (!listenersRegistered) {
            settings.registerOnSharedPreferenceChangeListener(preferenceListener)
            rulesPreferences.registerOnSharedPreferenceChangeListener(rulesListener)
            val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(screenOffReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(screenOffReceiver, filter)
            }
            listenersRegistered = true
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            appRules.refreshVisitPauses { SourceWindowState.read(this, it) != SourceWindowState.State.REPLACED }
        }
        if (!screenAvailable()) {
            clearSelection()
            telegramCopyAssistant.clear()
            clipboardHaloOverlay.dismiss()
            return
        }
        if (event.packageName?.toString() != packageName && event.eventType in setOf(
                AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED, AccessibilityEvent.TYPE_VIEW_LONG_CLICKED)) {
            val sourcePackage = event.packageName?.toString()
            when {
                appRules.triggerMode(sourcePackage) == AppRulesStore.TriggerMode.OFF -> SelectionDiagnostics.record(SelectionDiagnostics.Result.APP_DISABLED)
                appRules.appPauseRemainingMillis(sourcePackage) > 0 || appRules.isVisitPaused(sourcePackage) -> SelectionDiagnostics.record(SelectionDiagnostics.Result.APP_PAUSED)
            }
        }
        if (copyMenuEnabled()) {
            telegramCopyAssistant.onEvent(event)
            if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED ||
                event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) clipboardHaloOverlay.onWindowsChanged()
        }
        if (copyMenuEnabled() && settings.getBoolean(TelegramCopyPolicy.SETTING, false)) {
            when (event.eventType) {
                AccessibilityEvent.TYPE_WINDOWS_CHANGED -> observeCopyWindows(event)
                AccessibilityEvent.TYPE_VIEW_CLICKED -> if (!telegramCopyAssistant.suppressesClick(event.windowId, event.eventTime)) {
                    observeTelegramCopy(event)
                }
                else -> Unit
            }
        }
        val fixedSample = overlay != null && lastSelection?.packageName == packageName
        if ((!settings.getBoolean(CONSENT_KEY, false) && !fixedSample) || appRules.isPaused() || telegramCopyAssistant.isShowing || clipboardHaloOverlay.isShowing) {
            clearSelection()
            return
        }
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED ->
                if (nativeSelectionEnabled(event.packageName?.toString())) observeSelection(event) else clearSelection()
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED ->
                if (nativeSelectionEnabled(event.packageName?.toString())) primeLongPress(event) else clearSelection()
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                if (event.windowId == lastSelection?.windowId || event.windowId == pending?.key?.windowId) {
                    clearSelection()
                }
            }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                if (event.windowId == lastSelection?.windowId || event.windowId == pending?.key?.windowId) {
                    clearSelection()
                }
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> dismissIfWindowChanged()
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                // A returned toolbar can publish its readable children after its window event.
                val selected = overlaySelection
                val sourcePackage = event.packageName?.toString()
                if (overlay != null && selected != null && sourcePackage != null && sourcePackage != packageName &&
                    sourcePackage == selected.key.packageName && nativeSelectionEnabled(sourcePackage)) {
                    dismissIfWindowChanged()
                }
            }
            else -> Unit
        }
    }

    private fun openAssistedCopy(startedUptime: Long, startedWall: Long, finishedWall: Long, action: HaloAction, hostWindowId: Int, sourcePackage: String) {
        if (!screenAvailable() || !copyMenuEnabled() || !appRules.allowsButton(sourcePackage, true)) return
        clipboardHaloOverlay.show(startedUptime, startedWall, finishedWall, action, hostWindowId, sourcePackage)
    }

    private fun copyMenuEnabled(): Boolean = !appRules.isPaused() &&
        (settings.getBoolean(TelegramCopyPolicy.SETTING, false) || settings.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false))

    private fun observeCopyWindows(event: AccessibilityEvent) {
        val now = SystemClock.uptimeMillis()
        val appearedAt = if (TelegramCopyPolicy.isRecentEvent(event.eventTime, now)) event.eventTime else now
        val available = windows
        try {
            copyWindowOpenedAt.entries.removeAll { now - it.value > 120_000 }
            for (window in available) {
                if (window.type == AccessibilityWindowInfo.TYPE_APPLICATION && window.id >= 0) {
                    copyWindowOpenedAt.putIfAbsent(window.id, appearedAt)
                }
            }
            while (copyWindowOpenedAt.size > 24) copyWindowOpenedAt.remove(copyWindowOpenedAt.keys.first())
        } finally {
            if (Build.VERSION.SDK_INT < 33) {
                @Suppress("DEPRECATION")
                available.forEach { it.recycle() }
            }
        }
    }

    private fun observeTelegramCopy(event: AccessibilityEvent) {
        val now = SystemClock.uptimeMillis()
        val sourcePackage = event.packageName?.toString()
        val sourceClass = event.className?.toString()
        if (sourcePackage != "org.telegram.messenger" && sourcePackage != "org.telegram.messenger.web") return
        if (!appRules.allowsAutomatic(sourcePackage, true)) return
        TelegramCopyDiagnostics.received()
        if (!TelegramCopyPolicy.supportsSource(sourcePackage, sourceClass)) {
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.UNSUPPORTED_CONTROL)
            return
        }
        if (event.isPassword || !TelegramCopyPolicy.isRecentEvent(event.eventTime, now) ||
            event.eventTime <= lastCopyEventUptime) {
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.STALE_EVENT)
            return
        }
        val labels = event.text.map { it.toString() }.toMutableList()
        event.contentDescription?.let { labels.add(it.toString()) }
        if (!TelegramCopyPolicy.isCopyClick(sourcePackage, sourceClass, labels,
                android.content.res.Resources.getSystem().getString(android.R.string.copy))) {
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.NOT_COPY)
            return
        }
        TelegramCopyDiagnostics.recognized()
        val menuOpenedAt = copyWindowOpenedAt[event.windowId]
        if (menuOpenedAt == null || menuOpenedAt > event.eventTime) {
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.MENU_NOT_SEEN)
            return
        }
        lastCopyEventUptime = event.eventTime
        clearSelection()
        SelectionDiagnostics.record(SelectionDiagnostics.Result.COPY_RECEIVED)
        TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.LAUNCH_REQUESTED)
        try {
            // The user has explicitly pressed Copy. The service never reads the clipboard;
            // a visible activity takes focus, verifies freshness, and consumes that text once.
            startActivity(ClipboardHaloActivity.requestIntent(this).apply {
                action = ClipboardHaloActivity.ACTION_TELEGRAM_COPY
                addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                putExtra("com.actionhalo.android.SOURCE_PACKAGE", sourcePackage)
                putExtra(ClipboardHaloActivity.EXTRA_EVENT_UPTIME, event.eventTime)
                putExtra(ClipboardHaloActivity.EXTRA_EVENT_WALL_TIME, System.currentTimeMillis() - (now - event.eventTime))
                putExtra(ClipboardHaloActivity.EXTRA_MENU_OPENED_WALL_TIME, System.currentTimeMillis() - (now - menuOpenedAt))
            })
        } catch (_: ActivityNotFoundException) {
            SelectionDiagnostics.record(SelectionDiagnostics.Result.BLOCKED)
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.LAUNCH_BLOCKED)
        } catch (_: SecurityException) {
            SelectionDiagnostics.record(SelectionDiagnostics.Result.BLOCKED)
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.LAUNCH_BLOCKED)
        }
    }

    private fun observeSelection(event: AccessibilityEvent, initial: Boolean = false) {
        if (event.packageName?.toString() == packageName) return
        SelectionDiagnostics.received()
        if (event.isPassword) {
            SelectionDiagnostics.record(SelectionDiagnostics.Result.FILTERED)
            clearSelection()
            return
        }

        val source = event.source ?: run {
            SelectionDiagnostics.inspectRanges(event.fromIndex, event.toIndex, null, null)
            rejectSelection(SelectionDiagnostics.Result.NO_SOURCE)
            return
        }
        var keepSource = false
        try {
            // The event is a snapshot. A delayed collapse notification can arrive after the
            // control has a newer nonempty selection, so consult the fresh node first.
            if (!source.refresh()) return rejectSelection(SelectionDiagnostics.Result.STALE)
            if (!safeSource(source)) {
                SelectionDiagnostics.record(SelectionDiagnostics.Result.FILTERED)
                clearSelection()
                return
            }
            SelectionDiagnostics.inspectRanges(event.fromIndex, event.toIndex,
                source.textSelectionStart, source.textSelectionEnd)
            val sourcePackage = source.packageName?.toString() ?: return clearSelection()
            val text = source.text ?: return rejectSelection(SelectionDiagnostics.Result.NO_TEXT)
            val range = sourceRange(source, text.length, event.fromIndex, event.toIndex)
                ?: return rejectSelection(rangeFailure(source, event.fromIndex, event.toIndex))
            val key = SelectionKey(sourcePackage, source.windowId, source.hashCode(), range)
            if (!initial) selectionPrimedOnly = false
            else if (key != lastSelection && key != pending?.key) selectionPrimedOnly = true
            // Keep a dismissed selection dismissed until it changes; retain no selected text here.
            if (!initial && (key == lastSelection || key == pending?.key)) return
            val previous = pending?.key ?: lastSelection
            val firstSelection = initial || previous == null || previous.packageName != key.packageName ||
                previous.windowId != key.windowId || previous.nodeId != key.nodeId
            if (firstSelection) selectionToolbarWindowId = null
            val shown = overlay
            val shownSelection = overlaySelection?.key
            if (!firstSelection && shown != null && shownSelection?.packageName == key.packageName &&
                shownSelection.windowId == key.windowId && shownSelection.nodeId == key.nodeId &&
                SourceWindowState.read(this, key.windowId) == SourceWindowState.State.PRESENT) {
                val selectedText = SelectionPolicy.selectedText(text, range)
                    ?: return rejectSelection(SelectionDiagnostics.Result.NO_TEXT)
                cancelPending()
                overlaySelection?.source?.let(::recycleNode)
                @Suppress("DEPRECATION")
                val retained = AccessibilityNodeInfo.obtain(source)
                overlaySelection = PendingSelection(retained, key)
                lastSelection = key
                // Refinement replaces the text, not the window, page or first-touch anchor.
                deferredSelectionAction = null
                selectionObscured = false
                handler.removeCallbacks(sourceTimeout)
                handler.removeCallbacks(copyTimeout)
                holdingCopiedText = false
                shown.beginInteractionSession()
                shown.selectedText = selectedText
                updateSelectionWindow()
                SelectionDiagnostics.record(SelectionDiagnostics.Result.SHOWN)
                return
            }
            cancelPending()
            hideOverlay()
            if (firstSelection && appRules.triggerMode(sourcePackage) != AppRulesStore.TriggerMode.BUTTON) {
                lastSelection = key
                SelectionDiagnostics.record(SelectionDiagnostics.Result.INITIAL_SELECTION)
                return
            }
            lastSelection = null
            pending = PendingSelection(source, key)
            SelectionDiagnostics.record(SelectionDiagnostics.Result.RECEIVED)
            keepSource = true
            handler.postDelayed(showPending, SELECTION_DELAY_MS)
        } catch (_: IllegalStateException) {
            rejectSelection(SelectionDiagnostics.Result.STALE)
        } catch (_: SecurityException) {
            rejectSelection(SelectionDiagnostics.Result.FILTERED)
        } finally {
            if (!keepSource) recycleNode(source)
        }
    }

    private fun primeLongPress(event: AccessibilityEvent) = observeSelection(event, initial = true)

    private fun presentPendingSelection(explicit: Boolean = false) {
        if (telegramCopyAssistant.isShowing || clipboardHaloOverlay.isShowing) {
            clearSelection()
            return
        }
        val candidate = pending ?: return
        if (SourceWindowState.read(this, candidate.key.windowId) != SourceWindowState.State.PRESENT) {
            dismissIfWindowChanged()
            return
        }
        pending = null
        val source = candidate.source
        var keepSource = false
        fun retainIfObscured(): Boolean {
            if (SourceWindowState.read(this, candidate.key.windowId) != SourceWindowState.State.OBSCURED) return false
            pending = candidate
            keepSource = true
            dismissIfWindowChanged()
            // The modal may close during the second window query; resume without waiting for another event.
            if (pending === candidate && !selectionObscured) handler.post(showPending)
            return true
        }
        try {
            if (!nativeSelectionEnabled(candidate.key.packageName) || !screenAvailable()) return
            if (!source.refresh() || !safeSource(source)) {
                if (!retainIfObscured()) rejectSelection(SelectionDiagnostics.Result.STALE)
                return
            }
            if (source.windowId != candidate.key.windowId ||
                source.packageName?.toString() != candidate.key.packageName
            ) return rejectSelection(SelectionDiagnostics.Result.STALE)
            if (!sourceWindowVisible(candidate.key.windowId)) {
                if (!retainIfObscured()) rejectSelection(SelectionDiagnostics.Result.WINDOW_CHANGED)
                return
            }
            val text = source.text ?: return rejectSelection(SelectionDiagnostics.Result.NO_TEXT)
            val range = sourceRange(source, text.length, candidate.key.range.start, candidate.key.range.end)
                ?: return rejectSelection(rangeFailure(source, candidate.key.range.start, candidate.key.range.end))
            if (range != candidate.key.range) {
                if (explicit) return rejectSelection(SelectionDiagnostics.Result.STALE)
                // The node can advance before its selection event reaches this service.
                // Keep this refinement and wait for the latest range to settle.
                pending = PendingSelection(source, candidate.key.copy(range = range))
                keepSource = true
                handler.postDelayed(showPending, SELECTION_DELAY_MS)
                return
            }
            val selectedText = SelectionPolicy.selectedText(text, range) ?: return rejectSelection(SelectionDiagnostics.Result.NO_TEXT)
            val protectedAreas = selectionAreas(source, range)
            val bounds = Rect().apply { protectedAreas.forEach(::union) }
                .takeUnless { it.isEmpty } ?: Rect().also(source::getBoundsInScreen)
            val actionContext = HaloUi.localizedContext(this)
            val actions = appRules.actionsFor(candidate.key.packageName, ActionStore(actionContext).allActions())
            if (actions.isEmpty()) return rejectSelection(SelectionDiagnostics.Result.NO_ACTIONS)
            if (!explicit && appRules.triggerMode(candidate.key.packageName) == AppRulesStore.TriggerMode.BUTTON) {
                showSelectionHelper(bounds, actionContext)
            } else showOverlay(selectedText, bounds, actions, actionContext, sourcePackage = candidate.key.packageName,
                sourceWindowId = candidate.key.windowId, protectedAreas = protectedAreas)
            if (overlay != null || selectionHelper != null) {
                lastSelection = candidate.key
                selectionPrimedOnly = false
                @Suppress("DEPRECATION")
                val retained = AccessibilityNodeInfo.obtain(source)
                overlaySelection = PendingSelection(retained, candidate.key)
                if (overlay != null) updateSelectionWindow()
            }
        } catch (_: IllegalStateException) {
            rejectSelection(SelectionDiagnostics.Result.STALE)
        } catch (_: SecurityException) {
            rejectSelection(SelectionDiagnostics.Result.FILTERED)
        } finally {
            if (!keepSource) recycleNode(source)
        }
    }

    private fun safeSource(source: AccessibilityNodeInfo): Boolean =
        source.packageName?.toString() != packageName && !source.isPassword && source.isVisibleToUser &&
            (Build.VERSION.SDK_INT < 34 || !source.isAccessibilityDataSensitive)

    private fun sourceRange(
        source: AccessibilityNodeInfo,
        textLength: Int,
        fallbackStart: Int,
        fallbackEnd: Int,
    ): SelectionPolicy.Range? {
        val start = source.textSelectionStart
        val end = source.textSelectionEnd
        // Some custom views publish ranges only in the event. A reported collapsed selection
        // must never fall back to an earlier, nonempty event.
        return if (start >= 0 && end >= 0) {
            SelectionPolicy.range(textLength, start, end)
        } else {
            SelectionPolicy.range(textLength, fallbackStart, fallbackEnd)
        }
    }

    private fun rangeFailure(source: AccessibilityNodeInfo, fallbackStart: Int, fallbackEnd: Int): SelectionDiagnostics.Result {
        val hasNodeRange = source.textSelectionStart >= 0 && source.textSelectionEnd >= 0
        val start = if (hasNodeRange) source.textSelectionStart else fallbackStart
        val end = if (hasNodeRange) source.textSelectionEnd else fallbackEnd
        return if (start >= 0 && start == end) SelectionDiagnostics.Result.COLLAPSED
            else SelectionDiagnostics.Result.NO_RANGE
    }

    private fun dismissIfWindowChanged() {
        val tracked = pending?.key ?: lastSelection ?: return
        when (SourceWindowState.read(this, tracked.windowId)) {
            SourceWindowState.State.PRESENT -> {
                val resumed = selectionObscured
                handler.removeCallbacks(sourceTimeout)
                selectionObscured = false
                HaloSafeArea.selectionToolbarWindowId(this, tracked.windowId)?.let { selectionToolbarWindowId = it }
                overlay?.showOperationStatus(null)
                updateSelectionWindow()
                if (resumed && pending != null) {
                    handler.removeCallbacks(showPending)
                    handler.post(showPending)
                }
                val action = deferredSelectionAction
                deferredSelectionAction = null
                if (action != null) overlay?.let { performSelectionAction(it, action) }
            }
            SourceWindowState.State.OBSCURED -> if (!selectionObscured) {
                selectionObscured = true
                overlay?.showOperationStatus(getString(R.string.operation_waiting_source))
                handler.postDelayed(sourceTimeout, 30_000)
            }
            SourceWindowState.State.REPLACED -> {
                if (pending != null) SelectionDiagnostics.record(SelectionDiagnostics.Result.WINDOW_CHANGED)
                clearSelection()
            }
        }
    }

    private fun updateSelectionWindow() {
        val selected = overlaySelection ?: return
        val window = overlayWindow ?: return
        handler.removeCallbacks(resumeSelection)
        val toolbar = HaloSafeArea.selectionToolbarWindowId(this, selected.key.windowId)
        if (toolbar != null) selectionToolbarWindowId = toolbar
        if (selectionToolbarWindowId != null) window.updateSelectionMenu(toolbar != null)
        val source = selected.source
        try {
            if (source.refresh() && safeSource(source)) window.updateProtectedAreas(selectionAreas(source, selected.key.range))
        } catch (_: IllegalStateException) {
            clearSelection()
            return
        } catch (_: SecurityException) {
            clearSelection()
            return
        }
        // shortcut: Without readable menu metadata, use range settling until a release signal is available.
        if (toolbar != null || selectionToolbarWindowId == null) handler.postDelayed(resumeSelection, SELECTION_DELAY_MS)
    }

    private fun sourceWindowVisible(id: Int): Boolean {
        val available = windows
        return try { available.any { it.id == id } } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) available.forEach { it.recycle() }
        }
    }

    private fun selectionStillValid(text: String): Boolean {
        if (!screenAvailable()) return false
        val selection = overlaySelection ?: return lastSelection?.packageName == packageName
        val source = selection.source
        return try {
            sourceWindowVisible(selection.key.windowId) && source.refresh() && safeSource(source) &&
                source.windowId == selection.key.windowId && source.packageName?.toString() == selection.key.packageName &&
                source.text?.let { current ->
                    sourceRange(source, current.length, selection.key.range.start, selection.key.range.end) == selection.key.range &&
                        SelectionPolicy.selectedText(current, selection.key.range) == text
                } == true
        } catch (_: IllegalStateException) { false } catch (_: SecurityException) { false }
    }

    private fun performSelectionAction(view: RadialMenuView, action: HaloAction) {
        if (overlay !== view || !screenAvailable()) return
        if (lastSelection?.packageName != packageName && !nativeSelectionEnabled(overlaySelection?.key?.packageName)) return
        val selection = overlaySelection
        if (!selectionStillValid(view.selectedText)) {
            if (selection != null && SourceWindowState.read(this, selection.key.windowId) == SourceWindowState.State.OBSCURED) {
                deferredSelectionAction = action
                dismissIfWindowChanged()
                view.showOperationStatus(getString(R.string.operation_waiting_source))
            } else clearSelection()
            return
        }
        if (ActionExecutor.execute(view.context, action, view.selectedText, view::showActionError, selection?.key?.packageName)) {
            if (HaloAppearance.keepAfterCopy(this, action)) {
                view.beginInteractionSession()
                view.showActionFeedback(R.string.action_copied)
                if (!holdingCopiedText) handler.postDelayed(copyTimeout, HaloAppearance.COPY_SESSION_MS)
                holdingCopiedText = true
            } else dismissCurrentSelection()
        } else view.beginInteractionSession()
    }

    private fun activeApplicationWindowId(): Int? {
        val available = windows
        return try {
            available.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isActive }?.id
                ?: available.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_APPLICATION && it.isFocused }?.id
        } finally {
            if (Build.VERSION.SDK_INT < 33) {
                @Suppress("DEPRECATION")
                available.forEach { it.recycle() }
            }
        }
    }

    private fun showOverlay(text: String, sourceBounds: Rect, actions: List<HaloAction>, actionContext: Context,
        adjustable: Boolean = true, sourcePackage: String? = null, sourceWindowId: Int? = null,
        protectedAreas: List<Rect> = emptyList()) {
        hideOverlay()
        val view = RadialMenuView(actionContext).apply {
            gtaModeEnabled = HaloAppearance.isGtaModeEnabled(this@SelectionAccessibilityService)
            selectedText = text
            setActions(actions)
            onActionSelected = { action -> if (isShown) performSelectionAction(this, action) }
            onDismiss = { dismissCurrentSelection() }
        }
        SourceAppControls.bind(view, sourcePackage, sourceWindowId, ::dismissCurrentSelection)
        val window = SelectionHaloWindow(actionContext, windowManager, availableScreenBounds(), sourceBounds, view, 0f,
            onOutsideTouch = {
                handler.postDelayed(resumeSelection, SELECTION_DELAY_MS)
            }, keyboardBounds = keyboardBounds())
        window.updateProtectedAreas(protectedAreas)
        val toolbar = sourceWindowId?.let { HaloSafeArea.selectionToolbarWindowId(this, it) }
        if (toolbar != null) selectionToolbarWindowId = toolbar
        if (adjustable && sourceWindowId != null && selectionToolbarWindowId != null) window.updateSelectionMenu(toolbar != null)
        val root = window.root
        if (!adjustable) window.expand()
        try {
            windowManager.addView(root, window.params)
            overlay = view
            overlayRoot = root
            overlayWindow = window
            SelectionDiagnostics.record(SelectionDiagnostics.Result.SHOWN)
        } catch (_: WindowManager.BadTokenException) {
            view.selectedText = ""
            SelectionDiagnostics.record(SelectionDiagnostics.Result.BLOCKED)
        } catch (_: SecurityException) {
            view.selectedText = ""
            SelectionDiagnostics.record(SelectionDiagnostics.Result.BLOCKED)
        }
    }

    private fun showSelectionHelper(sourceBounds: Rect, context: Context) {
        hideOverlay()
        val screen = availableScreenBounds()
        val frame = HaloSafeArea.initialFrame(screen, sourceBounds, dp(160), dp(8),
            HaloAppearance.InitialPosition.AUTO, keyboardBounds())
        val width = frame.width()
        val height = minOf(dp(56), frame.height()).coerceAtLeast(1)
        val button = HaloUi.button(context, context.getString(R.string.selection_open_halo)).apply {
            contentDescription = context.getString(R.string.selection_open_halo)
            setOnClickListener {
                val selected = overlaySelection ?: return@setOnClickListener clearSelection()
                if (!nativeSelectionEnabled(selected.key.packageName)) return@setOnClickListener clearSelection()
                @Suppress("DEPRECATION")
                val retained = AccessibilityNodeInfo.obtain(selected.source)
                val candidate = PendingSelection(retained, selected.key)
                hideOverlay()
                cancelPending()
                pending = candidate
                presentPendingSelection(explicit = true)
            }
        }
        val params = WindowManager.LayoutParams(width, height, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT).apply {
            @Suppress("RtlHardcoded")
            gravity = Gravity.TOP or Gravity.LEFT
            x = frame.left - screen.left
            y = frame.top - screen.top
            title = "ActionHalo selection helper"
            if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        }
        try {
            windowManager.addView(button, params)
            selectionHelper = button
            overlayRoot = button
        } catch (_: WindowManager.BadTokenException) { SelectionDiagnostics.record(SelectionDiagnostics.Result.BLOCKED) }
        catch (_: SecurityException) { SelectionDiagnostics.record(SelectionDiagnostics.Result.BLOCKED) }
    }

    private fun keyboardBounds(): List<Rect> {
        val available = windows
        return try {
            available.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }.map { window -> Rect().also(window::getBoundsInScreen) }
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) available.forEach { it.recycle() }
        }
    }

    private fun selectionAreas(source: AccessibilityNodeInfo, range: SelectionPolicy.Range): List<Rect> =
        HaloSafeArea.selectionHandleBounds(this, source, range) +
            HaloSafeArea.selectionControlBounds(this, source.windowId, selectionToolbarWindowId)

    private fun availableScreenBounds(): Rect {
        if (Build.VERSION.SDK_INT >= 30) {
            val metrics = windowManager.currentWindowMetrics
            val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
            )
            return Rect(metrics.bounds).apply {
                left += insets.left
                top += insets.top
                right -= insets.right
                bottom -= insets.bottom
            }
        }
        val size = Point()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealSize(size)
        return Rect(0, 0, size.x, size.y)
    }

    private fun automaticModeEnabled(): Boolean =
        settings.getBoolean(CONSENT_KEY, false) && !appRules.isPaused() &&
            (settings.getBoolean(AUTO_POPUP_KEY, false) || appRules.packages().any {
                appRules.triggerMode(it) in setOf(AppRulesStore.TriggerMode.AUTO, AppRulesStore.TriggerMode.BUTTON)
            })

    private fun nativeSelectionEnabled(sourcePackage: String?): Boolean =
        settings.getBoolean(CONSENT_KEY, false) && appRules.allowsButton(sourcePackage, settings.getBoolean(AUTO_POPUP_KEY, false))

    private fun screenAvailable(): Boolean =
        getSystemService(PowerManager::class.java).isInteractive &&
            !getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun dismissCurrentSelection() {
        cancelPending()
        hideOverlay()
    }

    private fun cancelPending() {
        handler.removeCallbacks(showPending)
        pending?.source?.let(::recycleNode)
        pending = null
    }

    private fun hideOverlay() {
        holdingCopiedText = false
        handler.removeCallbacks(copyTimeout)
        handler.removeCallbacks(sourceTimeout)
        handler.removeCallbacks(resumeSelection)
        selectionObscured = false
        deferredSelectionAction = null
        overlaySelection?.source?.let(::recycleNode)
        overlaySelection = null
        val view = overlay
        val root = overlayRoot ?: selectionHelper ?: view ?: return
        selectionHelper?.setOnClickListener(null)
        selectionHelper = null
        overlay = null
        overlayRoot = null
        overlayWindow = null
        view?.selectedText = ""
        view?.onActionSelected = null
        view?.onDismiss = null
        view?.onInteractionStarted = null
        root.setOnTouchListener(null)
        try {
            windowManager.removeViewImmediate(root)
        } catch (_: IllegalArgumentException) {
            // The system may already have removed the service's overlay window.
        }
    }

    private fun clearSelection() {
        cancelPending()
        hideOverlay()
        lastSelection = null
        selectionToolbarWindowId = null
        selectionPrimedOnly = false
    }

    private fun rejectSelection(result: SelectionDiagnostics.Result) {
        SelectionDiagnostics.record(result)
        clearSelection()
        telegramCopyAssistant.onSelectionUnavailable()
    }

    /** Explicit in-app check uses fixed example text, without reading another app. */
    private fun showTestOverlay(): Boolean {
        if ((!automaticModeEnabled() && !copyMenuEnabled()) || !screenAvailable()) return false
        clearSelection()
        SelectionDiagnostics.reset()
        val context = HaloUi.localizedContext(this)
        val actions = ActionStore(context).actions()
        if (actions.isEmpty()) {
            SelectionDiagnostics.record(SelectionDiagnostics.Result.NO_ACTIONS)
            return false
        }
        val bounds = availableScreenBounds()
        val text = context.getString(R.string.sample_text)
        val windowId = activeApplicationWindowId() ?: -1
        showOverlay(text, Rect(bounds.centerX(), bounds.centerY(), bounds.centerX(), bounds.centerY()), actions, context, adjustable = false)
        if (overlay != null) {
            lastSelection = SelectionKey(packageName, windowId, 0, SelectionPolicy.Range(0, text.length))
            SelectionDiagnostics.record(SelectionDiagnostics.Result.TEST_SHOWN)
        }
        return overlay != null
    }

    override fun onInterrupt() {
        clearSelection()
        telegramCopyAssistant.clear()
        clipboardHaloOverlay.dismiss()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        clearSelection()
        telegramCopyAssistant.clear()
        clipboardHaloOverlay.dismiss()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        AccessibilityHealthDiagnostics.recordUnbound(this)
        releaseResources()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        AccessibilityHealthDiagnostics.recordDestroyed(this)
        releaseResources()
        super.onDestroy()
    }

    private fun releaseResources() {
        AppRulesStore.clearVisitPauses()
        if (connectedService?.get() === this) connectedService = null
        clearSelection()
        telegramCopyAssistant.clear()
        clipboardHaloOverlay.dismiss()
        copyWindowOpenedAt.clear()
        handler.removeCallbacksAndMessages(null)
        if (listenersRegistered) {
            settings.unregisterOnSharedPreferenceChangeListener(preferenceListener)
            rulesPreferences.unregisterOnSharedPreferenceChangeListener(rulesListener)
            unregisterReceiver(screenOffReceiver)
            listenersRegistered = false
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    @Suppress("DEPRECATION")
    private fun recycleNode(node: AccessibilityNodeInfo) {
        if (Build.VERSION.SDK_INT < 33) node.recycle()
    }

    companion object {
        private var connectedService: WeakReference<SelectionAccessibilityService>? = null
        internal fun isConnected(): Boolean = connectedService?.get() != null
        internal fun checkOverlay(): Boolean = connectedService?.get()?.showTestOverlay() ?: false
        private const val SETTINGS_NAME = "actionhalo_settings"
        private const val AUTO_POPUP_KEY = "auto_popup_enabled"
        private const val CONSENT_KEY = "accessibility_consent"
        private const val SELECTION_DELAY_MS = 250L
    }
}
