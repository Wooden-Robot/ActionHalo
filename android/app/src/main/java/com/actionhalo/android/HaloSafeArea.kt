package com.actionhalo.android

import android.content.Context
import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.FrameLayout
import kotlin.math.abs

/** Keyboard rectangles affect initial placement, never the coordinate system used for a gesture. */
@android.annotation.SuppressLint("RtlHardcoded")
internal object HaloSafeArea {
    /** A floating selection menu disappears while its source handles are being dragged. */
    fun selectionToolbarWindowId(service: AccessibilityService, hostWindowId: Int): Int? {
        val windows = service.windows
        val copyLabel = android.content.res.Resources.getSystem().getString(android.R.string.copy)
        try {
            for (window in windows) {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val parent = window.parent ?: continue
                val sameHost = parent.id == hostWindowId
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT < 33) parent.recycle()
                if (!sameHost) continue
                val root = window.root ?: continue
                try {
                    var visited = 0
                    fun isMenu(node: AccessibilityNodeInfo, depth: Int): Boolean {
                        if (++visited > 80 || depth > 8 || !node.isVisibleToUser || !node.isEnabled ||
                            node.isPassword || node.isEditable ||
                            (Build.VERSION.SDK_INT >= 34 && node.isAccessibilityDataSensitive)) return false
                        if (node.viewIdResourceName == TelegramCopyPolicy.STANDARD_MENU_CONTAINER_ID ||
                            node.viewIdResourceName == TelegramCopyPolicy.STANDARD_MENU_ITEM_ID ||
                            TelegramCopyPolicy.isCopyLabel(node.text?.toString().orEmpty(), copyLabel) ||
                            TelegramCopyPolicy.isCopyLabel(node.contentDescription?.toString().orEmpty(), copyLabel)) return true
                        for (index in 0 until node.childCount) {
                            if (visited >= 80) break
                            val child = node.getChild(index) ?: continue
                            try { if (isMenu(child, depth + 1)) return true } finally {
                                @Suppress("DEPRECATION")
                                if (Build.VERSION.SDK_INT < 33) child.recycle()
                            }
                        }
                        return false
                    }
                    if (isMenu(root, 0)) return window.id
                } finally {
                    @Suppress("DEPRECATION")
                    if (Build.VERSION.SDK_INT < 33) root.recycle()
                }
            }
            return null
        } catch (_: IllegalStateException) {
            return null
        } catch (_: SecurityException) {
            return null
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    /** Geometry only: do not read text while observing a compatibility menu. */
    fun selectionProtectionBounds(context: Context, source: AccessibilityNodeInfo, range: SelectionPolicy.Range): List<Rect> {
        val bounds = Rect().also(source::getBoundsInScreen)
        val key = AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_KEY
        if (key !in source.availableExtraData) return emptyList()
        val selected = Rect()
        val requestLimit = 20_000 // Android caps each character-location request at this length.
        for (index in range.start until range.end step requestLimit) {
            val arguments = android.os.Bundle().apply {
                putInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_START_INDEX, index)
                putInt(AccessibilityNodeInfo.EXTRA_DATA_TEXT_CHARACTER_LOCATION_ARG_LENGTH, minOf(requestLimit, range.end - index))
            }
            if (!source.refreshWithExtraData(key, arguments)) continue
            @Suppress("DEPRECATION")
            val locations = source.extras.getParcelableArray(key) ?: continue
            selected.union(characterLocationBounds(bounds,
                locations.take(minOf(requestLimit, range.end - index)).filterIsInstance<RectF>()))
        }
        if (selected.isEmpty) return emptyList()
        selected.inset(-HaloUi.dp(context, 32), -HaloUi.dp(context, 40))
        return listOf(selected)
    }

    fun characterLocationBounds(sourceBounds: Rect, locations: List<RectF>): Rect {
        val source = RectF(sourceBounds)
        val valid = locations.filter { !it.isEmpty && it.left.isFinite() && it.top.isFinite() &&
            it.right.isFinite() && it.bottom.isFinite() }
        // Chromium 91 uses the whole node for missing character bounds, including ligatures.
        // Keep coarse-only data; discard that exact placeholder only alongside finer glyph bounds.
        val hasGlyphBounds = valid.any { it != source && RectF.intersects(it, source) && !it.contains(source) }
        val selected = Rect()
        val character = Rect()
        for (location in valid) {
            if (hasGlyphBounds && location == source) continue
            location.roundOut(character)
            if (character.intersect(sourceBounds)) selected.union(character)
        }
        return selected
    }

    /** Keep the verified app menu and source handles touchable, even when the wheel overlaps them. */
    fun selectionControlBounds(service: AccessibilityService, hostWindowId: Int, menuWindowId: Int? = null): List<Rect> {
        val windows = service.windows
        val controls = mutableListOf<Rect>()
        val protectedAreas = mutableListOf<Rect>()
        val maximumControlSize = HaloUi.dp(service, 96)
        try {
            for (window in windows) {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val parent = window.parent ?: continue
                val sameHost = parent.id == hostWindowId
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT < 33) parent.recycle()
                if (!sameHost) continue
                val bounds = Rect().also(window::getBoundsInScreen)
                if (window.id == menuWindowId) {
                    if (!bounds.isEmpty) protectedAreas.add(bounds)
                } else if (bounds.width() in 1..maximumControlSize && bounds.height() in 1..maximumControlSize) {
                    refreshedControlBounds(window, maximumControlSize)?.let(bounds::set)
                    bounds.inset(-HaloUi.dp(service, 16), -HaloUi.dp(service, 32))
                    controls.add(bounds)
                }
            }
            // Without character locations, the space between the handles still belongs to the selection.
            if (controls.isNotEmpty()) protectedAreas.add(Rect().apply { controls.forEach(::union) })
            return protectedAreas
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }

    private fun refreshedControlBounds(window: AccessibilityWindowInfo, maximumSize: Int): Rect? {
        val root = try { window.root } catch (_: IllegalStateException) {
            null
        } catch (_: SecurityException) {
            null
        } ?: return null
        try {
            if (root.windowId != window.id || root.isPassword ||
                (Build.VERSION.SDK_INT >= 34 && root.isAccessibilityDataSensitive) || !root.refresh() ||
                root.windowId != window.id || root.isPassword ||
                (Build.VERSION.SDK_INT >= 34 && root.isAccessibilityDataSensitive)) return null
            // A moved handle's window bounds can stay cached while its root already has the new position.
            // Do not require visibility: the old wheel may currently cover the handle we must protect.
            return Rect().also(root::getBoundsInScreen).takeIf {
                it.width() in 1..maximumSize && it.height() in 1..maximumSize
            }
        } catch (_: IllegalStateException) {
            return null
        } catch (_: SecurityException) {
            return null
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) root.recycle()
        }
    }

    /** Fit a first-touch relocation without moving targets again during the gesture. */
    fun fittedShift(screen: Rect, content: RectF, desiredX: Float, desiredY: Float, margin: Float): Pair<Float, Float> {
        fun fit(start: Float, end: Float, safeStart: Float, safeEnd: Float, desired: Float): Float {
            val lower = safeStart - start
            val upper = safeEnd - end
            return if (lower <= upper) desired.coerceIn(lower, upper) else (lower + upper) / 2f
        }
        return fit(content.left, content.right, screen.left + margin, screen.right - margin, desiredX) to
            fit(content.top, content.bottom, screen.top + margin, screen.bottom - margin, desiredY)
    }

    fun initialFrame(screen: Rect, source: Rect?, preferredSize: Int, margin: Int,
        position: HaloAppearance.InitialPosition, keyboards: List<Rect> = emptyList()): Rect {
        val safe = Rect(screen).apply {
            inset(minOf(margin, (width() - 1).coerceAtLeast(0) / 2),
                minOf(margin, (height() - 1).coerceAtLeast(0) / 2))
        }
        if (safe.isEmpty) return Rect(screen.left, screen.top, screen.left + 1, screen.top + 1)
        var regions = listOf(safe)
        keyboards.forEach { keyboard ->
            val obstacle = Rect(keyboard).apply { inset(-margin, -margin) }
            regions = regions.flatMap { region ->
                val overlap = Rect(obstacle)
                if (!overlap.intersect(region)) listOf(region) else listOf(
                    Rect(region.left, region.top, region.right, overlap.top),
                    Rect(region.left, overlap.bottom, region.right, region.bottom),
                    Rect(region.left, region.top, overlap.left, region.bottom),
                    Rect(overlap.right, region.top, region.right, region.bottom),
                ).filterNot { it.isEmpty }
            }.distinct()
        }
        // shortcut: A full-screen IME leaves no free region; retain a usable frame until its next layout.
        val candidates = regions.ifEmpty { listOf(safe) }.map { region ->
            val size = minOf(preferredSize, region.width(), region.height()).coerceAtLeast(1)
            val x = when (position) {
                HaloAppearance.InitialPosition.LEFT -> region.left
                HaloAppearance.InitialPosition.RIGHT -> region.right - size
                HaloAppearance.InitialPosition.AUTO -> (source?.centerX() ?: region.centerX()) - size / 2
            }.coerceIn(region.left, region.right - size)
            val preferredY = when {
                position != HaloAppearance.InitialPosition.AUTO -> region.bottom - size
                source == null -> region.centerY() - size / 2
                source.bottom + margin + size <= region.bottom -> source.bottom + margin
                source.top - margin - size >= region.top -> source.top - margin - size
                else -> if (source.centerY() < region.centerY()) region.bottom - size else region.top
            }
            val y = preferredY.coerceIn(region.top, region.bottom - size)
            Rect(x, y, x + size, y + size)
        }
        return candidates.maxWith(compareBy<Rect> { it.width() }.thenBy {
            val overlap = Rect(it)
            if (source != null && overlap.intersect(source)) -overlap.width().toLong() * overlap.height() else 0L
        }.thenBy {
            when (position) {
                HaloAppearance.InitialPosition.LEFT -> it.bottom.toLong() - it.left
                HaloAppearance.InitialPosition.RIGHT -> it.bottom.toLong() + it.right
                HaloAppearance.InitialPosition.AUTO -> (-abs(it.centerX() - (source?.centerX() ?: safe.centerX())).toLong()
                    - abs(it.centerY() - (source?.centerY() ?: safe.centerY())))
            }
        })
    }

    /** Call after adding the menu; other interaction callbacks remain chained. */
    fun bindInitialPlacement(root: FrameLayout, menu: RadialMenuView, screenBounds: Rect? = null) {
        var interacting = false
        val previous = menu.onInteractionStarted
        menu.onInteractionStarted = { interacting = true; previous?.invoke() }
        fun place() {
            if (interacting || menu.parent !== root || root.width <= 0 || root.height <= 0) return
            val area = Rect(root.paddingLeft, root.paddingTop,
                root.width - root.paddingRight, root.height - root.paddingBottom)
            val location = IntArray(2).also(root::getLocationOnScreen)
            val visible = Rect().also(root::getWindowVisibleDisplayFrame).apply { offset(-location[0], -location[1]) }
            if (!visible.isEmpty && !area.intersect(visible)) return
            val frame = screenBounds?.let { Rect(it).apply { offset(-location[0], -location[1]) } }
                ?: initialFrame(area, null, HaloUi.dp(root.context, HaloAppearance.menuSizeDp(root.context)),
                    HaloUi.dp(root.context, 8), HaloAppearance.initialPosition(root.context), keyboardBounds(root, location))
            val old = menu.layoutParams as FrameLayout.LayoutParams
            val left = frame.left - root.paddingLeft
            val top = frame.top - root.paddingTop
            if (old.width == frame.width() && old.height == frame.height() && old.leftMargin == left &&
                old.topMargin == top && old.gravity == (Gravity.TOP or Gravity.LEFT)) return
            menu.layoutParams = FrameLayout.LayoutParams(frame.width(), frame.height(), Gravity.TOP or Gravity.LEFT).apply {
                leftMargin = left
                topMargin = top
            }
        }
        val boundsListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> place() }
        root.addOnLayoutChangeListener(boundsListener)
        val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { place() }
        val drawListener = ViewTreeObserver.OnPreDrawListener {
            if (interacting || screenBounds == null || menu.parent !== root) true else {
                place()
                val position = IntArray(2).also(menu::getLocationOnScreen)
                // A handoff must finish layout before its first frame becomes visible.
                (position[0] == screenBounds.left && position[1] == screenBounds.top &&
                    menu.width == screenBounds.width() && menu.height == screenBounds.height()).also { ready ->
                    if (!ready) menu.requestLayout()
                }
            }
        }
        val attachmentListener = object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) {
                root.viewTreeObserver.addOnGlobalLayoutListener(layoutListener)
                if (screenBounds != null) root.viewTreeObserver.addOnPreDrawListener(drawListener)
                root.post { place() }
            }
            override fun onViewDetachedFromWindow(view: View) {
                if (root.viewTreeObserver.isAlive) root.viewTreeObserver.removeOnGlobalLayoutListener(layoutListener)
                if (root.viewTreeObserver.isAlive) root.viewTreeObserver.removeOnPreDrawListener(drawListener)
            }
        }
        root.addOnAttachStateChangeListener(attachmentListener)
        menu.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = Unit
            override fun onViewDetachedFromWindow(view: View) {
                root.removeOnLayoutChangeListener(boundsListener)
                root.removeOnAttachStateChangeListener(attachmentListener)
                if (root.viewTreeObserver.isAlive) root.viewTreeObserver.removeOnGlobalLayoutListener(layoutListener)
                if (root.viewTreeObserver.isAlive) root.viewTreeObserver.removeOnPreDrawListener(drawListener)
                menu.removeOnAttachStateChangeListener(this)
            }
        })
        if (root.isAttachedToWindow) {
            root.viewTreeObserver.addOnGlobalLayoutListener(layoutListener)
            if (screenBounds != null) root.viewTreeObserver.addOnPreDrawListener(drawListener)
        }
        if (screenBounds != null) place()
        root.post { place() }
    }

    private fun keyboardBounds(root: View, location: IntArray): List<Rect> {
        if (Build.VERSION.SDK_INT < 30) return emptyList()
        val insets = root.rootWindowInsets ?: return emptyList()
        if (!insets.isVisible(WindowInsets.Type.ime())) return emptyList()
        val bottom = insets.getInsets(WindowInsets.Type.ime()).bottom
        if (bottom <= 0) return emptyList()
        val window = root.context.getSystemService(WindowManager::class.java).currentWindowMetrics.bounds
        return listOf(Rect(window.left, window.bottom - bottom, window.right, window.bottom).apply {
            offset(-location[0], -location[1])
        })
    }
}
