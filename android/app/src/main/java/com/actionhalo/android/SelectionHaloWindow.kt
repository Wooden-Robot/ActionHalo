package com.actionhalo.android

import android.content.Context
import android.graphics.PixelFormat
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.Region
import android.os.Build
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import kotlin.math.hypot

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
    private val preferredSize = frame.width()
    private var size = preferredSize
    private var expanded = false
    private var selectionMoving = false
    private var waitingForMenuReturn = false
    private var menuWasHidden = false
    private var placementBlocked = false
    private var protectedAreas: List<Rect> = emptyList()
    private var appliedTouchRegion: Region? = null
    private var pressPoint: PointF? = null
    private var backdropShown = false
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val heldBackdrop = Runnable { showBackdrop() }
    private val touchRegionLayout = ViewTreeObserver.OnGlobalLayoutListener { updateTouchableRegion() }
    private val viewport = Rect(screen)
    val root = object : FrameLayout(context) {
        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            if (Build.VERSION.SDK_INT >= 33) {
                viewTreeObserver.addOnGlobalLayoutListener(touchRegionLayout)
                updateTouchableRegion()
            }
        }

        override fun onDetachedFromWindow() {
            removeCallbacks(heldBackdrop)
            pressPoint = null
            viewTreeObserver.removeOnGlobalLayoutListener(touchRegionLayout)
            appliedTouchRegion = null
            super.onDetachedFromWindow()
        }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            // Hidden windows can still receive queued input, including outside-touch notifications.
            if (selectionMoving || placementBlocked) return false
            if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                SelectionDiagnostics.trace(SelectionDiagnostics.Trace.HALO_OUTSIDE_TOUCH)
                waitingForMenuReturn = true
                menuWasHidden = false
                setSelectionMoving(true)
                onOutsideTouch()
                return true
            }
            // Handle bounds can update before the window has finished moving out of their way.
            if (!expanded && protectedAreas.any { it.contains(event.rawX.toInt(), event.rawY.toInt()) }) return false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    pressPoint = PointF(event.rawX, event.rawY)
                    removeCallbacks(heldBackdrop)
                    if (!backdropShown) postDelayed(heldBackdrop, ViewConfiguration.getLongPressTimeout().toLong())
                }
                MotionEvent.ACTION_MOVE -> pressPoint?.let { start ->
                    if (hypot(event.rawX - start.x, event.rawY - start.y) > touchSlop) {
                        removeCallbacks(heldBackdrop)
                        showBackdrop()
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL,
                MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> {
                    removeCallbacks(heldBackdrop)
                    pressPoint = null
                }
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
        menu.onInteractionStarted = { expand(withBackdrop = false) }
    }

    fun updateProtectedAreas(areas: List<Rect>) {
        protectedAreas = areas.map(::Rect)
        updateTouchableRegion()
        if (expanded || selectionMoving) return
        placementBlocked = false
        if (size == preferredSize && areas.none { Rect.intersects(frame, it) }) return updateVisibility()
        val source = Rect().apply { areas.forEach(::union) }
        val obstacles = keyboardBounds + areas
        val position = HaloAppearance.initialPosition(root.context)
        fun fit(gap: Int) = HaloSafeArea.initialFrame(screen, source, preferredSize, gap, position, obstacles)
            .takeIf { candidate -> obstacles.none { Rect.intersects(candidate, it) } }
        // Drop the decorative gap before hiding a wheel that still fits clear of every control.
        val spaced = fit(margin)
        val flush = fit(0)
        val next = spaced?.takeIf { it.width() == preferredSize }
            ?: flush?.takeIf { it.width() == preferredSize }
            ?: if (Build.VERSION.SDK_INT < 33) listOfNotNull(spaced, flush)
                .filter { it.width() >= minOf(preferredSize, HaloUi.dp(root.context, 180)) }
                .maxByOrNull { it.width() } else null
        if (next == null) {
            // Older systems cannot exclude individual controls from the window's touch region.
            placementBlocked = Build.VERSION.SDK_INT < 33
            if (!placementBlocked) SelectionDiagnostics.trace(SelectionDiagnostics.Trace.HALO_HANDLE_PASSTHROUGH)
            return updateVisibility()
        }
        // The whole window, including transparent padding, must leave the handles touchable.
        frame = next
        size = frame.width()
        params.width = size
        params.height = size
        if (menu.layoutParams.width != size || menu.layoutParams.height != size) {
            menu.layoutParams = FrameLayout.LayoutParams(size, size)
        }
        params.x = frame.left - screen.left
        params.y = frame.top - screen.top
        if (root.isAttachedToWindow) manager.updateViewLayout(root, params)
        updateVisibility()
    }

    private fun updateTouchableRegion() {
        if (Build.VERSION.SDK_INT < 33) return
        val surface = root.rootSurfaceControl ?: return
        // An explicit full region avoids Android 15's null-reset crash when a window is removed.
        val region = Region(0, 0, root.width, root.height)
        if (!expanded && protectedAreas.isNotEmpty()) {
            val origin = IntArray(2).also(root::getLocationOnScreen)
            protectedAreas.forEach { area ->
                region.op(Rect(area).apply { offset(-origin[0], -origin[1]) }, Region.Op.DIFFERENCE)
            }
        }
        // The platform requests layout when the region changes; avoid a traversal loop.
        if (region == appliedTouchRegion) return
        surface.setTouchableRegion(region)
        appliedTouchRegion = region
    }

    fun updateSelectionMenu(visible: Boolean, settled: Boolean = false) {
        if (expanded) return
        if (!visible) {
            menuWasHidden = true
            setSelectionMoving(true)
        } else if (settled || !waitingForMenuReturn || menuWasHidden) {
            // A settled, verified menu may remain visible throughout selection adjustment.
            resumeSelection()
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
        if (hidden) {
            root.removeCallbacks(heldBackdrop)
            pressPoint = null
        }
        val visibility = if (hidden) View.INVISIBLE else View.VISIBLE
        if (menu.visibility == visibility) return
        SelectionDiagnostics.trace(when {
            selectionMoving -> SelectionDiagnostics.Trace.HALO_WAITING_MENU
            placementBlocked -> SelectionDiagnostics.Trace.HALO_NO_SPACE
            else -> SelectionDiagnostics.Trace.HALO_VISIBLE
        })
        menu.visibility = visibility
        params.flags = if (hidden) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        if (root.isAttachedToWindow) manager.updateViewLayout(root, params)
    }

    fun expand(withBackdrop: Boolean = true) {
        if (expanded) {
            if (withBackdrop) showBackdrop()
            return
        }
        selectionMoving = false
        waitingForMenuReturn = false
        menuWasHidden = false
        placementBlocked = false
        updateVisibility()
        if (menu.isAttachedToWindow) {
            val origin = IntArray(2)
            menu.getLocationOnScreen(origin)
            // Freeze the targets actually drawn if a pending resize has not reached layout yet.
            size = menu.width
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
        params.flags = params.flags and WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH.inv()
        updateTouchableRegion()
        if (withBackdrop) showBackdrop()
        if (root.isAttachedToWindow) manager.updateViewLayout(root, params)
    }

    private fun showBackdrop() {
        if (!expanded || backdropShown) return
        backdropShown = true
        params.flags = params.flags or WindowManager.LayoutParams.FLAG_DIM_BEHIND
        params.dimAmount = HaloAppearance.dimAmount(root.context, standardDim)
        HaloAppearance.bindBackdrop(root, params) { manager.updateViewLayout(root, it) }
    }
}
