package com.actionhalo.android

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.ClipData
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast
import android.window.OnBackInvokedCallback

/** A visible, focused window for one user-selected action; never reads while in the background. */
internal class ClipboardHaloOverlay(
    private val service: AccessibilityService,
    private val canOperate: () -> Boolean,
    private val executeAction: ((Context, HaloAction, String) -> Boolean)? = null,
    private val readClipboard: (Context) -> ClipData? = { it.getSystemService(ClipboardManager::class.java).primaryClip },
    private val postAction: (View, Runnable) -> Unit = { view, action -> view.postOnAnimation(action) },
) {
    private val manager = service.getSystemService(WindowManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var current: Session? = null

    val isShowing: Boolean get() = current != null
    val sourceWindowId: Int? get() = current?.sourceWindowId

    fun show(startedUptime: Long, startedWall: Long, finishedWall: Long, action: HaloAction, hostWindowId: Int,
        sourcePackage: String? = null) {
        dismiss()
        if (!canOperate() || hostWindowId < 0 ||
            !TelegramCopyPolicy.isRecentEvent(startedUptime, SystemClock.uptimeMillis())) return
        val session = Session(startedWall, finishedWall, action, hostWindowId, sourcePackage)
        current = session
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_DIM_BEHIND or WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.CENTER
            dimAmount = HaloAppearance.dimAmount(service)
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
            title = "ActionHalo selected text action"
            if (Build.VERSION.SDK_INT >= 30) {
                setFitInsetsTypes(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            }
            if (Build.VERSION.SDK_INT >= 28) {
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER
            }
        }
        HaloAppearance.bindBackdrop(session, params) { manager.updateViewLayout(session, it) }
        TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.OVERLAY_REQUESTED)
        try {
            manager.addView(session, params)
            session.requestFocus()
            session.scheduleHint()
            handler.postDelayed(session.timeout, 30_000)
        } catch (_: WindowManager.BadTokenException) {
            reject(session, TelegramCopyDiagnostics.Stage.LAUNCH_BLOCKED, R.string.copy_probe_blocked)
        } catch (_: SecurityException) {
            reject(session, TelegramCopyDiagnostics.Stage.LAUNCH_BLOCKED, R.string.copy_probe_blocked)
        }
    }

    private inner class Session(
        val startedWall: Long, val finishedWall: Long, var action: HaloAction, val sourceWindowId: Int,
        val sourcePackage: String?,
    ) : FrameLayout(HaloUi.localizedContext(service)) {
        var copiedText: String? = null
        var readAttempts = 0
        var focusGeneration = 0
        var readGeneration = -1
        var submitting = false
        var choosingAction = false
        private var sourceWaiting = false
        var recoveryMenu: RadialMenuView? = null
        val expiresAt = SystemClock.uptimeMillis() + 30_000
        private var operationMessage = context.getString(R.string.operation_reading_selection)
        private var hintPending = false
        private var backCallback: OnBackInvokedCallback? = null
        val timeout = Runnable {
            if (current === this) reject(this, TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED, R.string.copy_probe_expired)
        }
        val focusHint = Runnable {
            hintPending = false
            if (current === this && !submitting && !choosingAction) {
                if (!hasWindowFocus()) operationMessage = context.getString(R.string.operation_waiting_focus)
                showMenu().showOperationStatus(operationMessage)
            }
        }

        init {
            isFocusableInTouchMode = true
            contentDescription = operationMessage
            setOnClickListener { dismiss() }
        }

        private fun showMenu(): RadialMenuView {
            recoveryMenu?.let { return it }
            contentDescription = null
            setOnClickListener(null)
            val menu = RadialMenuView(context).apply {
                gtaModeEnabled = HaloAppearance.isGtaModeEnabled(context)
                selectedText = copiedText.orEmpty()
                selectionTextKnown = copiedText != null
                setActions(AppRulesStore(context).actionsFor(sourcePackage, ActionStore(context).allActions()))
                onDismiss = { dismiss() }
                onActionSelected = { chosen ->
                    // Another explicit choice may retry a denied read; a successful snapshot is reused.
                    if (current === this@Session && !submitting) {
                        action = chosen
                        choosingAction = false
                        readAttempts = 0
                        readGeneration = -1
                        requestFocus()
                        if (copiedText != null) executeOnce(this@Session) else readOnce(this@Session)
                    }
                }
            }
            SourceAppControls.bind(menu, sourcePackage, sourceWindowId) { dismiss() }
            recoveryMenu = menu
            val size = HaloUi.dp(context, HaloAppearance.menuSizeDp(context))
            addView(menu, LayoutParams(size, size, Gravity.CENTER))
            menu.bindTouchSurface(this)
            HaloSafeArea.bindInitialPlacement(this, menu)
            return menu
        }

        fun showWaiting(stage: TelegramCopyDiagnostics.Stage) {
            sourceWaiting = true
            TelegramCopyDiagnostics.record(stage)
            operationMessage = context.getString(if (stage == TelegramCopyDiagnostics.Stage.CLIP_UNAVAILABLE)
                R.string.operation_retry_read else R.string.operation_waiting_focus)
            recoveryMenu?.apply {
                beginInteractionSession()
                showOperationStatus(operationMessage)
            }
            scheduleHint()
        }

        fun keepCopyMenu() {
            submitting = false
            choosingAction = true
            hideHint()
            showMenu().apply {
                selectedText = copiedText.orEmpty()
                selectionTextKnown = true
                beginInteractionSession()
                showActionFeedback(R.string.action_copied)
            }
        }

        fun showActionFailure(message: Int) {
            submitting = false
            choosingAction = true
            hideHint()
            showMenu().apply {
                selectedText = copiedText.orEmpty()
                selectionTextKnown = copiedText != null
                beginInteractionSession()
                showOperationStatus(null)
                showActionError(message)
            }
        }

        fun scheduleHint() {
            if (hintPending || recoveryMenu != null) return
            hintPending = true
            this@ClipboardHaloOverlay.handler.postDelayed(focusHint, 1_500)
        }

        fun hideHint() {
            sourceWaiting = false
            this@ClipboardHaloOverlay.handler.removeCallbacks(focusHint)
            hintPending = false
            recoveryMenu?.showOperationStatus(null)
        }

        fun showReading() {
            operationMessage = context.getString(R.string.operation_reading_selection)
            recoveryMenu?.showOperationStatus(operationMessage)
        }

        fun resumeChoice() {
            if (choosingAction && sourceWaiting && hasWindowFocus() &&
                SourceWindowState.read(service, sourceWindowId) == SourceWindowState.State.PRESENT) {
                sourceWaiting = false
                recoveryMenu?.showOperationStatus(null)
            }
        }

        override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
            super.onWindowFocusChanged(hasWindowFocus)
            if (hasWindowFocus) {
                focusGeneration++
                if (choosingAction) resumeChoice() else post { readOnce(this) }
            } else if (current === this && !submitting && !choosingAction) {
                showWaiting(TelegramCopyDiagnostics.Stage.OVERLAY_WAITING_FOCUS)
            }
        }

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            if (Build.VERSION.SDK_INT >= 33) {
                val callback = OnBackInvokedCallback { dismiss() }
                findOnBackInvokedDispatcher()?.registerOnBackInvokedCallback(0, callback)
                backCallback = callback
            }
        }

        override fun onDetachedFromWindow() {
            if (Build.VERSION.SDK_INT >= 33) {
                backCallback?.let { findOnBackInvokedDispatcher()?.unregisterOnBackInvokedCallback(it) }
                backCallback = null
            }
            super.onDetachedFromWindow()
        }

        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_UP) dismiss()
                return true
            }
            return super.dispatchKeyEvent(event)
        }

        override fun performClick(): Boolean = super.performClick()
    }

    private fun readOnce(session: Session) {
        if (current !== session || session.submitting || session.choosingAction || !session.isAttachedToWindow || !session.hasWindowFocus()) return
        if (!canOperate() || SystemClock.uptimeMillis() > session.expiresAt) {
            reject(session, TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED, R.string.copy_probe_expired)
            return
        }
        if (!hostVisible(session.sourceWindowId)) { onWindowsChanged(); return }
        if (session.copiedText != null) {
            session.hideHint()
            postAction(session, Runnable { executeOnce(session) })
            return
        }
        if (session.readGeneration == session.focusGeneration || session.readAttempts >= 2) return
        session.showReading()
        session.readGeneration = session.focusGeneration
        session.readAttempts++
        TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.OVERLAY_FOCUSED)
        val clip = try { readClipboard(service) }
            catch (_: SecurityException) { null }
        if (clip == null) {
            // A competing window may win focus between the callback and the system read.
            // Wait for a real focus transition or an explicit retry, never poll the clipboard.
            session.showWaiting(TelegramCopyDiagnostics.Stage.CLIP_UNAVAILABLE)
            return
        }
        if (!TelegramCopyPolicy.isFreshAssistedClip(clip.description.timestamp, session.startedWall, session.finishedWall)) {
            reject(session, TelegramCopyDiagnostics.Stage.CLIP_NOT_FRESH, R.string.clipboard_not_fresh)
            return
        }
        val text = if (clip.itemCount == 1) clip.getItemAt(0).text else null
        if (!IncomingText.isUsable(text)) {
            reject(session, TelegramCopyDiagnostics.Stage.NO_TEXT,
                if (text != null && text.length > IncomingText.MAX_LENGTH) R.string.text_too_long else R.string.clipboard_no_text)
            return
        }
        session.copiedText = text.toString()
        session.recoveryMenu?.apply {
            selectedText = text.toString()
            selectionTextKnown = true
        }
        session.hideHint()
        postAction(session, Runnable { executeOnce(session) })
    }

    private fun executeOnce(session: Session) {
        if (current !== session || session.submitting || !session.hasWindowFocus()) return
        val text = session.copiedText ?: return
        if (!AppRulesStore(session.context).actionsFor(session.sourcePackage, ActionStore(session.context).allActions())
                .contains(session.action) || !canOperate() ||
            SystemClock.uptimeMillis() > session.expiresAt) {
            reject(session, TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED, R.string.copy_probe_expired)
            return
        }
        if (!hostVisible(session.sourceWindowId)) { onWindowsChanged(); return }
        session.submitting = true
        TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.ACTION_REQUESTED)
        var error = R.string.action_no_app
        val success = executeAction?.invoke(session.context, session.action, text)
            ?: ActionExecutor.execute(session.context, session.action, text, { error = it }, session.sourcePackage)
        TelegramCopyDiagnostics.record(if (success) TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED
            else TelegramCopyDiagnostics.Stage.ACTION_FAILED)
        if (current === session) {
            if (success && HaloAppearance.keepAfterCopy(session.context, session.action)) session.keepCopyMenu()
            else if (success) dismiss() else session.showActionFailure(error)
        }
    }

    /** Dialogs and small app windows may take focus while the original host remains visible. */
    fun onWindowsChanged() {
        val session = current ?: return
        when (SourceWindowState.read(service, session.sourceWindowId)) {
            SourceWindowState.State.PRESENT -> if (session.hasWindowFocus()) {
                if (session.choosingAction) session.resumeChoice() else session.post { readOnce(session) }
            }
            SourceWindowState.State.REPLACED -> reject(session, TelegramCopyDiagnostics.Stage.SOURCE_CLOSED, R.string.copy_source_closed)
            SourceWindowState.State.OBSCURED -> session.showWaiting(TelegramCopyDiagnostics.Stage.OVERLAY_WAITING_FOCUS)
        }
    }

    private fun hostVisible(id: Int): Boolean {
        if (id < 0) return false
        val windows = service.windows
        try {
            return windows.any { it.id == id }
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    private fun reject(session: Session, stage: TelegramCopyDiagnostics.Stage, message: Int) {
        if (current !== session) return
        TelegramCopyDiagnostics.record(stage)
        Toast.makeText(HaloUi.localizedContext(service), message, Toast.LENGTH_LONG).show()
        dismiss()
    }

    fun dismiss() {
        val old = current ?: return
        current = null
        handler.removeCallbacks(old.timeout)
        old.hideHint()
        old.copiedText = null
        old.recoveryMenu?.apply {
            selectedText = ""
            onActionSelected = null
            onDismiss = null
        }
        old.recoveryMenu = null
        old.setOnClickListener(null)
        old.setOnTouchListener(null)
        try { manager.removeViewImmediate(old) } catch (_: IllegalArgumentException) { }
    }
}
