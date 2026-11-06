package com.actionhalo.android

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.os.Build
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityWindowInfo

internal object SourceWindowState {
    enum class State { PRESENT, OBSCURED, REPLACED }

    fun read(service: AccessibilityService, sourceWindowId: Int): State {
        val windows = service.windows
        try {
            if (sourceWindowId >= 0 && windows.any { it.id == sourceWindowId }) return State.PRESENT
            val topApp = windows.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
                .maxByOrNull { it.layer } ?: return State.OBSCURED
            val manager = service.getSystemService(WindowManager::class.java)
            val available = if (Build.VERSION.SDK_INT >= 30) {
                val metrics = manager.currentWindowMetrics
                val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
                )
                Rect(metrics.bounds).apply {
                    left += insets.left
                    top += insets.top
                    right -= insets.right
                    bottom -= insets.bottom
                }
            } else {
                @Suppress("DEPRECATION")
                Rect().also { manager.defaultDisplay.getRectSize(it) }
            }
            val bounds = Rect().also(topApp::getBoundsInScreen)
            // Small modal windows can hide the source from this list; wait without reading or executing until it returns.
            return if (!available.isEmpty && bounds.contains(available)) State.REPLACED else State.OBSCURED
        } finally {
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < 33) windows.forEach { it.recycle() }
        }
    }
}
