package com.actionhalo.android

import android.content.Context
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout

/** Leave selection handles touchable until the user starts operating the wheel. */
@android.annotation.SuppressLint("RtlHardcoded")
internal class SelectionHaloWindow(
    context: Context,
    private val manager: WindowManager,
    private val screen: Rect,
    source: Rect,
    private val menu: RadialMenuView,
    private val standardDim: Float = HaloAppearance.STANDARD_DIM_AMOUNT,
    // Outside presses belong to the source, including its selection handles. Selection
    // cancellation / menu removal closes this bounded window through the source observer.
    private val onOutsideTouch: () -> Unit = {},
    private val keyboardBounds: List<Rect> = emptyList(),
) {
    private val margin = HaloUi.dp(context, 8)
    private var frame = HaloSafeArea.initialFrame(screen, source,
        HaloUi.dp(context, HaloAppearance.menuSizeDp(context)), margin, HaloAppearance.initialPosition(context), keyboardBounds)
    private val size = frame.width()
    private var expanded = false
    private var selectionMoving = false
    private var waitingForMenuReturn = false
    private var menuWasHidden = false
    private var placementBlocked = false
    private var protectedAreas: List<Rect> = emptyList()
    private val viewport = Rect(screen)
    val root = object : FrameLayout(context) {
        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                waitingForMenuReturn = true
                menuWasHidden = false
                setSelectionMoving(true)
                onOutsideTouch()
                return true
            }
            val origin = IntArray(2)
            if (!expanded) menu.getLocationOnScreen(origin)
            val x = if (expanded) frame.left + menu.translationX else origin[0].toFloat()
            val y = if (expanded) frame.top + menu.translationY else origin[1].toFloat()
            // Expanding a window can change its local input coordinates during the same gesture.
            val translated = MotionEvent.obtain(event).apply { setLocation(event.rawX - x, event.rawY - y) }
            return try { menu.dispatchTouchEvent(translated) } finally { translated.recycle() }
        }
    }.apply {
        addView(menu, FrameLayout.LayoutParams(size, size))
        addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            if (expanded) {
                // The screen-space frame is fixed for this gesture. Expansion and keyboard
                // relayouts only change the root origin, never the user's selected anchor.
                val origin = IntArray(2).also(::getLocationOnScreen)
                val x = frame.left - origin[0]
                val y = frame.top - origin[1]
                val old = menu.layoutParams as FrameLayout.LayoutParams
                if (old.width != size || old.height != size || old.leftMargin != x || old.topMargin != y) {
                    menu.layoutParams = FrameLayout.LayoutParams(size, size).apply {
                        leftMargin = x
                        topMargin = y
                    }
                }
            }
        }
    }
    val params = WindowManager.LayoutParams(size, size, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH, PixelFormat.TRANSLUCENT).apply {
        gravity = Gravity.TOP or Gravity.LEFT
        x = frame.left - screen.left
        y = frame.top - screen.top
        dimAmount = 0f
        if (Build.VERSION.SDK_INT >= 30) {
            setFitInsetsTypes(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        }
        if (Build.VERSION.SDK_INT >= 28) {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER
        }
    }

    init {
        menu.bindTouchSurface(root)
        menu.screenOriginForAnchor = { frame.left + menu.translationX to frame.top + menu.translationY }
        menu.onInteractionStarted = ::expand
    }

    fun updateProtectedAreas(areas: List<Rect>) {
        protectedAreas = areas.map(::Rect)
        if (expanded || selectionMoving) return
        placementBlocked = false
        if (areas.none { Rect.intersects(frame, it) }) return updateVisibility()
        val source = Rect().apply { areas.forEach(::union) }
        val next = HaloSafeArea.initialFrame(screen, source, size, margin,
            HaloAppearance.initialPosition(root.context), keyboardBounds + areas)
        if (next.width() != size || areas.any { Rect.intersects(next, it) }) {
            // Keep the source usable when a full-size wheel cannot fit between its controls.
            placementBlocked = true
            return updateVisibility()
        }
        // The whole window, including transparent padding, must leave the handles touchable.
        frame = next
        params.x = frame.left - screen.left
        params.y = frame.top - screen.top
        if (root.isAttachedToWindow) manager.updateViewLayout(root, params)
        updateVisibility()
    }

    fun updateSelectionMenu(visible: Boolean) {
        if (expanded) return
        if (!visible) {
            menuWasHidden = true
            setSelectionMoving(true)
        } else if (!waitingForMenuReturn || menuWasHidden) {
            waitingForMenuReturn = false
            menuWasHidden = false
            setSelectionMoving(false)
        }
    }

    fun resumeSelection() {
        waitingForMenuReturn = false
        menuWasHidden = false
        setSelectionMoving(false)
    }

    private fun setSelectionMoving(moving: Boolean) {
        if (expanded || selectionMoving == moving) return
        selectionMoving = moving
        if (moving) updateVisibility() else updateProtectedAreas(protectedAreas)
    }

    private fun updateVisibility() {
        val hidden = selectionMoving || placementBlocked
        val visibility = if (hidden) View.INVISIBLE else View.VISIBLE
        if (menu.visibility == visibility) return
        menu.visibility = visibility
        params.flags = if (hidden) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        if (root.isAttachedToWindow) manager.updateViewLayout(root, params)
    }

    fun expand() {
        if (expanded) return
        selectionMoving = false
        waitingForMenuReturn = false
        menuWasHidden = false
        placementBlocked = false
        updateVisibility()
        if (menu.isAttachedToWindow) {
            val origin = IntArray(2)
            menu.getLocationOnScreen(origin)
            frame = Rect(origin[0], origin[1], origin[0] + menu.width, origin[1] + menu.height)
        }
        expanded = true
        if (root.isAttachedToWindow) root.getWindowVisibleDisplayFrame(viewport)
        menu.layoutParams = FrameLayout.LayoutParams(size, size).apply {
            leftMargin = frame.left - viewport.left
            topMargin = frame.top - viewport.top
        }
        params.width = WindowManager.LayoutParams.MATCH_PARENT
        params.height = WindowManager.LayoutParams.MATCH_PARENT
        params.x = 0
        params.y = 0
        params.flags = params.flags and WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH.inv() or
            WindowManager.LayoutParams.FLAG_DIM_BEHIND
        params.dimAmount = HaloAppearance.dimAmount(root.context, standardDim)
        HaloAppearance.bindBackdrop(root, params) { manager.updateViewLayout(root, it) }
        if (root.isAttachedToWindow) manager.updateViewLayout(root, params)
    }
}
