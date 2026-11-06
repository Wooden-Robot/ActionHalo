package com.actionhalo.android

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.abs

/** The same geometry drives drawing, button placement, and touch hit testing. */
internal class RadialGeometry(
    val centerX: Float,
    val centerY: Float,
    val innerRadius: Float,
    val outerRadius: Float,
    val actionCount: Int,
    val gtaMode: Boolean = false,
    val density: Float = 1f,
) {
    init {
        require(innerRadius >= 0f && outerRadius > innerRadius)
        require(actionCount >= 0)
        require(density.isFinite() && density > 0f)
    }

    sealed class Target {
        data object Center : Target()
        data object Outside : Target()
        data object Gap : Target()
        data class Action(val index: Int) : Target()
    }

    val sweepDegrees: Float
        get() = if (actionCount == 0) 360f else 360f / actionCount

    val selectionRadius: Float = outerRadius + 32f * density

    /** Visible sector sweep; GTA leaves the gap immediately after each sector. */
    val sectorSweepDegrees: Float
        get() = sweepDegrees - if (gtaMode && actionCount > 0) {
            Math.toDegrees(when {
                actionCount >= 12 -> 0.015
                actionCount >= 8 -> 0.025
                else -> 0.04
            }).toFloat()
        } else 0f

    /** Ordinary mode centers the first action at twelve; GTA starts its first sector there. */
    fun sectorStartDegrees(index: Int): Float =
        -90f - (if (gtaMode) 0f else sweepDegrees / 2f) + index * sweepDegrees

    fun actionAngleDegrees(index: Int): Float {
        require(index in 0 until actionCount)
        return sectorStartDegrees(index) + sectorSweepDegrees / 2f
    }

    /** Shared centerline for the icon and its slot number, at different radii. */
    fun pointAt(index: Int, radius: Float): Pair<Float, Float> {
        val radians = Math.toRadians(actionAngleDegrees(index).toDouble())
        return Pair(
            centerX + cos(radians).toFloat() * radius,
            centerY + sin(radians).toFloat() * radius,
        )
    }

    fun actionCenter(index: Int): Pair<Float, Float> {
        val radius = (innerRadius + outerRadius) / 2f
        return pointAt(index, radius)
    }

    fun hitTest(x: Float, y: Float): Target {
        if (!x.isFinite() || !y.isFinite()) return Target.Outside
        val dx = x - centerX
        val dy = y - centerY
        val distance = hypot(dx, dy)
        if (distance > selectionRadius) return Target.Outside
        val deadzoneRadius = 16f * density
        if (distance <= deadzoneRadius || actionCount == 0) return Target.Center
        val degrees = Math.toDegrees(atan2(dy, dx).toDouble()).toFloat()
        val normalized = ((degrees - sectorStartDegrees(0)) % 360f + 360f) % 360f
        val index = (normalized / sweepDegrees).toInt().coerceAtMost(actionCount - 1)
        if (gtaMode && normalized - index * sweepDegrees > sectorSweepDegrees) return Target.Gap
        return Target.Action(index)
    }

    /** A narrow angular latch for an ongoing drag; direct taps use [hitTest]. */
    fun dragTarget(x: Float, y: Float, previousIndex: Int): Target {
        val target = hitTest(x, y)
        // Cancellation boundaries and the GTA gaps remain exact, including on release.
        if (target !is Target.Action || previousIndex !in 0 until actionCount || target.index == previousIndex) return target
        val angle = Math.toDegrees(atan2(y - centerY, x - centerX).toDouble()).toFloat()
        val previousCenter = sectorStartDegrees(previousIndex) + sweepDegrees / 2f
        val difference = abs(((angle - previousCenter + 540f) % 360f) - 180f)
        val latch = minOf(4f, sweepDegrees * 0.12f)
        return if (difference <= sweepDegrees / 2f + latch) Target.Action(previousIndex) else target
    }
}
