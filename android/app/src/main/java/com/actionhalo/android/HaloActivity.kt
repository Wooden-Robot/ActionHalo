package com.actionhalo.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast

/** User-invoked text-menu/share target. Never needs accessibility access. */
open class HaloActivity : Activity() {
    companion object { const val EXTRA_DEMO_TEXT = "com.actionhalo.android.DEMO_TEXT" }
    private var copyHeld = false
    private var heldMenu: RadialMenuView? = null
    private val expireCopy = Runnable { if (copyHeld) finish() }
    protected open val sourcePackage: String? get() = callingActivity?.packageName?.takeUnless { it == packageName }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        receiveText()
    }

    protected open fun receiveText() {
        val selected = try {
            when (intent.action) {
                Intent.ACTION_PROCESS_TEXT -> intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
                Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
                else -> if (callingActivity?.packageName == packageName || intent.action == null)
                    intent.getCharSequenceExtra(EXTRA_DEMO_TEXT) else null
            }
        } catch (_: RuntimeException) { null }
        showHalo(selected)
    }

    protected fun showHalo(selected: CharSequence?) {
        if (!IncomingText.isUsable(selected)) {
            Toast.makeText(this, if (selected != null && selected.length > IncomingText.MAX_LENGTH)
                R.string.text_too_long else R.string.empty_text, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        val text = selected.toString()
        val actions = AppRulesStore(this).actionsFor(sourcePackage, ActionStore(this).allActions())
        if (actions.isEmpty()) {
            Toast.makeText(this, R.string.no_actions, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        val gtaMode = HaloAppearance.isGtaModeEnabled(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setDimAmount(HaloAppearance.dimAmount(this))
        val root = FrameLayout(this)
        HaloAppearance.bindBackdrop(root, window.attributes) { window.attributes = it }
        val menu = RadialMenuView(this).apply {
            gtaModeEnabled = gtaMode
            selectedText = text
            setActions(actions)
            onDismiss = { finish() }
            onActionSelected = { action ->
                if (ActionExecutor.execute(this@HaloActivity, action, text, ::showActionError, sourcePackage)) {
                    if (HaloAppearance.keepAfterCopy(this@HaloActivity, action)) {
                        if (!copyHeld) window.decorView.postDelayed(expireCopy, HaloAppearance.COPY_SESSION_MS)
                        copyHeld = true
                        heldMenu = this
                        beginInteractionSession()
                        showActionFeedback(R.string.action_copied)
                    } else finish()
                } else beginInteractionSession()
            }
        }
        SourceAppControls.bind(menu, sourcePackage, close = ::finish)
        menu.bindTouchSurface(root)
        val preferredSize = HaloUi.dp(this, HaloAppearance.menuSizeDp(this))
        val size = minOf(preferredSize, resources.displayMetrics.widthPixels - HaloUi.dp(this, 16))
        root.addView(menu, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
        HaloSafeArea.bindInitialPlacement(root, menu)
        setContentView(root)
        HaloUi.applyInsets(this, root)
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(0) { finish() }
        }
        menu.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onStop() {
        super.onStop()
        if (copyHeld) finish()
    }

    override fun onDestroy() {
        window.decorView.removeCallbacks(expireCopy)
        heldMenu?.apply { selectedText = ""; onActionSelected = null; onDismiss = null }
        heldMenu = null
        super.onDestroy()
    }
}
