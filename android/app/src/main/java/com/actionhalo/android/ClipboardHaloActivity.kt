package com.actionhalo.android

import android.app.KeyguardManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import android.view.View
import android.view.ViewGroup
import android.widget.Toast

/** Internal entry. Reads a single text clip only after this visible activity owns window focus. */
class ClipboardHaloActivity : HaloActivity() {
    override val sourcePackage: String? get() = intent.getStringExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE)
    private var attemptedRead = false
    private var completedRead = false
    private var readAttempts = 0
    private var focusGeneration = 0
    private var readGeneration = -1
    private var waitingMenu: RadialMenuView? = null
    private val expiresAt = SystemClock.uptimeMillis() + 30_000
    private val automaticCopy: Boolean get() = intent.action == ACTION_TELEGRAM_COPY ||
        intent.action == ACTION_TELEGRAM_COPY_ASSISTED
    private val appRules by lazy { AppRulesStore(this) }
    private val rulesPreferences by lazy { getSharedPreferences(AppRulesStore.PREFERENCES, MODE_PRIVATE) }
    private val rulesListener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        if (!automaticRequestAllowed()) closeRequest()
    }
    private val timeout = Runnable {
        if (!completedRead && !isFinishing) {
            if (automaticCopy) TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED)
            reject(R.string.copy_probe_expired)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Recreating a dismissed/process-killed request must not silently consume a newer clip.
        attemptedRead = savedInstanceState?.getBoolean(READ_ATTEMPTED) ?: false
        super.onCreate(savedInstanceState)
        if (automaticCopy) rulesPreferences.registerOnSharedPreferenceChangeListener(rulesListener)
        if (attemptedRead || (automaticCopy && !TelegramCopyPolicy.isRecentEvent(
                intent.getLongExtra(EXTRA_EVENT_UPTIME, 0), SystemClock.uptimeMillis())) || !automaticRequestAllowed()) {
            if (automaticCopy) TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED)
            closeRequest()
            return
        }
        window.decorView.postDelayed(timeout, 30_000)
    }

    private fun automaticRequestAllowed(): Boolean {
        if (!automaticCopy) return true
        val source = sourcePackage?.takeIf { AppRulesStore.isValidPackageName(it) } ?: return false
        return if (intent.action == ACTION_TELEGRAM_COPY_ASSISTED) appRules.allowsButton(source, true)
            else appRules.allowsAutomatic(source, true)
    }

    override fun receiveText() {
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(HaloAppearance.dimAmount(this))
        val root = FrameLayout(this)
        HaloAppearance.bindBackdrop(root, window.attributes) { window.attributes = it }
        val menu = RadialMenuView(this).apply {
            gtaModeEnabled = HaloAppearance.isGtaModeEnabled(this@ClipboardHaloActivity)
            selectionTextKnown = false
            setActions(listOf(HaloAction(ActionIcons.CLIPBOARD_RETRY_ID,
                getString(R.string.clipboard_read_retry), "", ActionType.COPY)))
            onDismiss = { closeRequest() }
            onActionSelected = {
                readAttempts = 0
                readGeneration = -1
                readOnce()
            }
            showOperationStatus(getString(R.string.clipboard_focus_waiting))
        }
        waitingMenu = menu
        menu.bindTouchSurface(root)
        val size = minOf(HaloUi.dp(this, HaloAppearance.menuSizeDp(this)),
            resources.displayMetrics.widthPixels - HaloUi.dp(this, 16))
        root.addView(menu, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
        HaloSafeArea.bindInitialPlacement(root, menu)
        setContentView(root)
        HaloUi.applyInsets(this, root)
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(0) { closeRequest() }
        }
        menu.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (completedRead || isFinishing || isDestroyed) return
        if (!hasFocus) {
            waitingMenu?.showOperationStatus(getString(R.string.clipboard_focus_waiting))
            return
        }
        focusGeneration++
        window.decorView.post { readOnce() }
    }

    private fun readOnce() {
        if (completedRead || isFinishing || isDestroyed || !hasWindowFocus()) return
        if (!automaticRequestAllowed()) {
            closeRequest()
            return
        }
        if (getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
            reject(R.string.clipboard_unlock)
            return
        }
        val assistedCopy = intent.action == ACTION_TELEGRAM_COPY_ASSISTED
        if (SystemClock.uptimeMillis() > expiresAt || (automaticCopy &&
                !getSharedPreferences("actionhalo_settings", MODE_PRIVATE).getBoolean(TelegramCopyPolicy.SETTING, false))) {
            if (automaticCopy) TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED)
            reject(R.string.copy_probe_expired)
            return
        }
        if (readGeneration == focusGeneration) return
        if (readAttempts >= 2) {
            showReadRetry()
            return
        }
        waitingMenu?.showOperationStatus(getString(R.string.operation_reading_selection))
        readGeneration = focusGeneration
        readAttempts++
        attemptedRead = true
        if (automaticCopy) TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.FOCUSED)
        val clip = try {
            // No hasPrimaryClip/description pre-read, listeners, URI coercion, or background polling.
            getSystemService(ClipboardManager::class.java).primaryClip
        } catch (_: SecurityException) {
            null
        }
        if (clip == null) {
            if (automaticCopy) TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.CLIP_UNAVAILABLE)
            showReadRetry()
            return
        }
        val freshCopy = if (assistedCopy) {
            TelegramCopyPolicy.isFreshAssistedClip(clip.description.timestamp,
                intent.getLongExtra(EXTRA_COPY_STARTED_WALL_TIME, 0),
                intent.getLongExtra(EXTRA_COPY_FINISHED_WALL_TIME, 0))
        } else {
            TelegramCopyPolicy.isFreshClip(clip.description.timestamp,
                intent.getLongExtra(EXTRA_EVENT_WALL_TIME, 0),
                intent.getLongExtra(EXTRA_MENU_OPENED_WALL_TIME, 0))
        }
        if (automaticCopy && !freshCopy) {
            SelectionDiagnostics.record(SelectionDiagnostics.Result.COPY_UNCONFIRMED)
            TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.CLIP_NOT_FRESH)
            reject(R.string.clipboard_not_fresh)
            return
        }
        // A file/Intent clip must never be dereferenced, and a multi-item clip must not be truncated.
        val text = if (clip.itemCount == 1) clip.getItemAt(0).text else null
        if (!IncomingText.isUsable(text)) {
            if (automaticCopy) SelectionDiagnostics.record(SelectionDiagnostics.Result.NO_TEXT)
            if (automaticCopy) TelegramCopyDiagnostics.record(TelegramCopyDiagnostics.Stage.NO_TEXT)
            reject(if (text != null && text.length > IncomingText.MAX_LENGTH)
                R.string.text_too_long else R.string.clipboard_no_text)
            return
        }
        completedRead = true
        window.decorView.removeCallbacks(timeout)
        clearWaitingMenu()
        showHalo(text.toString())
        if (automaticCopy) SelectionDiagnostics.record(if (isFinishing)
            SelectionDiagnostics.Result.NO_ACTIONS else SelectionDiagnostics.Result.COPY_SHOWN)
        if (automaticCopy) TelegramCopyDiagnostics.record(if (isFinishing)
            TelegramCopyDiagnostics.Stage.NO_ACTIONS else TelegramCopyDiagnostics.Stage.SHOWN)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(READ_ATTEMPTED, attemptedRead)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        if (automaticCopy) rulesPreferences.unregisterOnSharedPreferenceChangeListener(rulesListener)
        window.decorView.removeCallbacks(timeout)
        clearWaitingMenu()
        super.onDestroy()
    }

    private fun reject(message: Int) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        closeRequest()
    }

    private fun closeRequest() {
        clearWaitingMenu()
        finish()
    }

    private fun showReadRetry() {
        waitingMenu?.apply {
            beginInteractionSession()
            showActionError(R.string.clipboard_read_unavailable)
        }
    }

    private fun clearWaitingMenu() {
        waitingMenu?.let { menu ->
            menu.onActionSelected = null
            menu.onDismiss = null
            menu.selectedText = ""
            (menu.parent as? ViewGroup)?.removeView(menu)
        }
        waitingMenu = null
    }

    companion object {
        /** Each explicit request replaces our isolated task and validates its own clipboard. */
        fun requestIntent(context: Context): Intent = Intent(context, ClipboardHaloActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)

        const val ACTION_TELEGRAM_COPY = "com.actionhalo.android.TELEGRAM_COPY"
        const val ACTION_TELEGRAM_COPY_ASSISTED = "com.actionhalo.android.TELEGRAM_COPY_ASSISTED"
        const val EXTRA_EVENT_UPTIME = "copy_event_uptime"
        const val EXTRA_EVENT_WALL_TIME = "copy_event_wall_time"
        const val EXTRA_MENU_OPENED_WALL_TIME = "copy_menu_opened_wall_time"
        const val EXTRA_COPY_STARTED_WALL_TIME = "copy_started_wall_time"
        const val EXTRA_COPY_FINISHED_WALL_TIME = "copy_finished_wall_time"
        private const val READ_ATTEMPTED = "clipboard_read_attempted"
    }
}
