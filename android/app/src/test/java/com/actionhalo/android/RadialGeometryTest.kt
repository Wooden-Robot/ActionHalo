package com.actionhalo.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class RadialGeometryTest {
    private val geometry = RadialGeometry(160f, 160f, 70f, 150f, 4)

    @Test fun `drag latch retains the visible selection at a boundary but releases after a deliberate crossing`() {
        for (count in listOf(6, 8, 12, 16)) for (gta in listOf(false, true)) {
            val layout = RadialGeometry(200f, 200f, 70f, 150f, count, gta)
            for (previous in 0 until count) {
                fun target(extraDegrees: Float): RadialGeometry.Target {
                    val angle = Math.toRadians((layout.sectorStartDegrees(previous) + layout.sweepDegrees + extraDegrees).toDouble())
                    return layout.dragTarget(200f + cos(angle).toFloat() * 100f, 200f + sin(angle).toFloat() * 100f, previous)
                }
                assertEquals("count=$count GTA=$gta previous=$previous", RadialGeometry.Target.Action(previous), target(1f))
                assertEquals(RadialGeometry.Target.Action((previous + 1) % count), target(6f))
            }
        }
    }

    @Test fun `drag latch never masks center outside invalid coordinates or GTA gaps`() {
        val layout = RadialGeometry(200f, 200f, 70f, 150f, 8, true)
        assertEquals(RadialGeometry.Target.Center, layout.dragTarget(200f, 200f, 2))
        assertEquals(RadialGeometry.Target.Outside, layout.dragTarget(200f, 500f, 2))
        assertEquals(RadialGeometry.Target.Outside, layout.dragTarget(Float.NaN, 200f, 2))
        val angle = Math.toRadians((layout.sectorStartDegrees(2) + (layout.sectorSweepDegrees + layout.sweepDegrees) / 2f).toDouble())
        assertEquals(RadialGeometry.Target.Gap, layout.dragTarget(200f + cos(angle).toFloat() * 100f, 200f + sin(angle).toFloat() * 100f, 2))
    }

    @Test fun `center and deadzone never activate an action`() {
        assertEquals(RadialGeometry.Target.Center, geometry.hitTest(160f, 160f))
        assertEquals(RadialGeometry.Target.Center, geometry.hitTest(160f, 144f))
        assertEquals(RadialGeometry.Target.Center, geometry.hitTest(170f, 170f))
        assertEquals(RadialGeometry.Target.Action(0), geometry.hitTest(160f, 143f))
        assertEquals(RadialGeometry.Target.Action(1), geometry.hitTest(180f, 160f))
    }

    @Test fun `actions start at top and proceed clockwise`() {
        assertEquals(RadialGeometry.Target.Action(0), geometry.hitTest(160f, 50f))
        assertEquals(RadialGeometry.Target.Action(1), geometry.hitTest(270f, 160f))
        assertEquals(RadialGeometry.Target.Action(2), geometry.hitTest(160f, 270f))
        assertEquals(RadialGeometry.Target.Action(3), geometry.hitTest(50f, 160f))
    }

    @Test fun `ordinary mode only selects within the visible ring and its buffer`() {
        assertEquals(RadialGeometry.Target.Action(0), geometry.hitTest(160f, 10f))
        assertEquals(RadialGeometry.Target.Action(0), geometry.hitTest(160f, -22f))
        assertEquals(RadialGeometry.Target.Outside, geometry.hitTest(160f, -23f))
        assertEquals(RadialGeometry.Target.Outside, geometry.hitTest(11f, 10f))
        assertEquals(RadialGeometry.Target.Outside, geometry.hitTest(Float.NaN, 160f))
    }

    @Test fun `visual centers land in matching sectors for odd and even action counts`() {
        for (count in 1..12) {
            val layout = RadialGeometry(140f, 140f, 63f, 134f, count)
            for (index in 0 until count) {
                val (x, y) = layout.actionCenter(index)
                assertEquals("count=$count index=$index", RadialGeometry.Target.Action(index), layout.hitTest(x, y))
            }
        }
    }

    @Test fun `empty menu has no actionable ring`() {
        val empty = RadialGeometry(160f, 160f, 70f, 150f, 0)
        assertEquals(RadialGeometry.Target.Center, empty.hitTest(160f, 50f))
        assertEquals(RadialGeometry.Target.Outside, empty.hitTest(160f, -51f))
    }

    @Test fun `crossing the wraparound sector boundary is stable`() {
        assertEquals(RadialGeometry.Target.Action(3), geometry.hitTest(70f, 71f))
        assertEquals(RadialGeometry.Target.Action(0), geometry.hitTest(71f, 70f))
        assertEquals(RadialGeometry.Target.Action(0), geometry.hitTest(249f, 70f))
        assertEquals(RadialGeometry.Target.Action(1), geometry.hitTest(250f, 71f))
    }

    @Test fun `GTA uses a micro deadzone and directional selection inside the visible hole`() {
        val gta = RadialGeometry(200f, 200f, 85f, 130f, 6, gtaMode = true)
        assertEquals(RadialGeometry.Target.Center, gta.hitTest(200f, 200f))
        assertEquals(RadialGeometry.Target.Center, gta.hitTest(200f, 184f))
        val (x, y) = gta.pointAt(0, 20f)
        assertEquals(RadialGeometry.Target.Action(0), gta.hitTest(x, y))
    }

    @Test fun `GTA only permits release within the visible ring and its buffer`() {
        val gta = RadialGeometry(200f, 200f, 85f, 130f, 6, gtaMode = true)
        // At twelve o'clock we are exactly on the beginning of the first sector.
        assertEquals(RadialGeometry.Target.Action(0), gta.hitTest(200f, 38f))
        assertEquals(RadialGeometry.Target.Outside, gta.hitTest(200f, 37f))
        val (x, y) = gta.pointAt(3, 160f)
        assertEquals(RadialGeometry.Target.Action(3), gta.hitTest(x, y))
    }

    @Test fun `GTA first sector begins at twelve and leaves real non actionable gaps`() {
        for (count in listOf(12, 16)) {
            val dense = RadialGeometry(200f, 200f, 85f, 130f, count, gtaMode = true)
            assertEquals(360f / count - Math.toDegrees(0.015).toFloat(), dense.sectorSweepDegrees, 0.0001f)
        }
        val gta = RadialGeometry(200f, 200f, 85f, 130f, 6, gtaMode = true)
        assertEquals(-90f, gta.sectorStartDegrees(0), 0.0001f)
        assertEquals(60f - Math.toDegrees(0.04).toFloat(), gta.sectorSweepDegrees, 0.0001f)
        assertTrue(gta.actionAngleDegrees(0) > -90f && gta.actionAngleDegrees(0) < -60f)
        for (index in 0 until gta.actionCount) {
            val angle = gta.sectorStartDegrees(index) + (gta.sectorSweepDegrees + gta.sweepDegrees) / 2f
            val radians = Math.toRadians(angle.toDouble())
            val x = gta.centerX + cos(radians).toFloat() * 110f
            val y = gta.centerY + sin(radians).toFloat() * 110f
            assertEquals("gap after slot $index", RadialGeometry.Target.Gap, gta.hitTest(x, y))
        }
    }

    @Test fun `GTA density scales the deadzone and outer buffer rather than sector angles`() {
        val gta = RadialGeometry(400f, 400f, 170f, 260f, 8, gtaMode = true, density = 2f)
        assertEquals(RadialGeometry.Target.Center, gta.hitTest(400f, 368f))
        assertEquals(RadialGeometry.Target.Action(0), gta.hitTest(400f, 367f))
        assertEquals(RadialGeometry.Target.Action(0), gta.hitTest(400f, 76f))
        assertEquals(RadialGeometry.Target.Outside, gta.hitTest(400f, 75f))
        assertEquals(45f - Math.toDegrees(0.025).toFloat(), gta.sectorSweepDegrees, 0.0001f)
    }

    @Test fun `GTA icon and slot share an actionable centerline for odd and even counts`() {
        for (count in 1..8) {
            val gta = RadialGeometry(200f, 200f, 85f, 130f, count, gtaMode = true)
            for (index in 0 until count) {
                for (radius in listOf(30f, 92f, 109.5f, 160f)) {
                    val (x, y) = gta.pointAt(index, radius)
                    assertEquals("count=$count slot=$index radius=$radius", RadialGeometry.Target.Action(index), gta.hitTest(x, y))
                }
                assertEquals(gta.pointAt(index, 107.5f), gta.actionCenter(index))
            }
        }
    }

    @Test fun `selection limit scales with density in all quadrants and both modes`() {
        for (gtaMode in listOf(false, true)) for (density in listOf(1f, 2f, 3f)) {
            val layout = RadialGeometry(400f, 400f, 70f * density, 150f * density, 4, gtaMode, density)
            assertEquals(182f * density, layout.selectionRadius, 0.0001f)
            for (index in 0 until 4) {
                val (nearX, nearY) = layout.pointAt(index, 181f * density)
                assertEquals(RadialGeometry.Target.Action(index), layout.hitTest(nearX, nearY))
                val (farX, farY) = layout.pointAt(index, 183f * density)
                assertEquals(RadialGeometry.Target.Outside, layout.hitTest(farX, farY))
            }
        }
    }

    @Test fun `directional selection preserves sectors for odd and even counts in both modes`() {
        for (gtaMode in listOf(false, true)) {
            for (count in 1..16) {
                val layout = RadialGeometry(200f, 300f, 85f, 130f, count, gtaMode = gtaMode)
                for (index in 0 until count) {
                    val (x, y) = layout.pointAt(index, 161f)
                    assertEquals("gta=$gtaMode count=$count slot=$index", RadialGeometry.Target.Action(index), layout.hitTest(x, y))
                    val (farX, farY) = layout.pointAt(index, 163f)
                    assertEquals("gta=$gtaMode count=$count slot=$index outside", RadialGeometry.Target.Outside, layout.hitTest(farX, farY))
                }
            }
        }
    }

    @Test fun `directional selection keeps density scaled center cancellation and empty menus safe`() {
        for (gtaMode in listOf(false, true)) {
            val layout = RadialGeometry(400f, 400f, 170f, 260f, 8, gtaMode = gtaMode, density = 2f)
            assertEquals(RadialGeometry.Target.Center, layout.hitTest(400f, 400f))
            assertEquals(RadialGeometry.Target.Center, layout.hitTest(400f, 368f))
            val (x, y) = layout.pointAt(0, 33f)
            assertEquals(RadialGeometry.Target.Action(0), layout.hitTest(x, y))
            val empty = RadialGeometry(400f, 400f, 170f, 260f, 0, gtaMode = gtaMode, density = 2f)
            assertEquals(RadialGeometry.Target.Center, empty.hitTest(400f, 368f))
            assertEquals(RadialGeometry.Target.Outside, empty.hitTest(10000f, 400f))
        }
    }

    @Test fun `directional selection rejects non finite coordinates`() {
        for (invalid in listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            assertEquals(RadialGeometry.Target.Outside, geometry.hitTest(invalid, 160f))
            assertEquals(RadialGeometry.Target.Outside, geometry.hitTest(160f, invalid))
        }
    }

    @Test fun `GTA directional selection preserves gaps within the outer buffer`() {
        for (count in 1..16) {
            val gta = RadialGeometry(200f, 300f, 85f, 130f, count, gtaMode = true)
            for (index in 0 until count) {
                val angle = gta.sectorStartDegrees(index) + (gta.sectorSweepDegrees + gta.sweepDegrees) / 2f
                val radians = Math.toRadians(angle.toDouble())
                val x = gta.centerX + cos(radians).toFloat() * 161f
                val y = gta.centerY + sin(radians).toFloat() * 161f
                assertEquals("count=$count gap after slot $index", RadialGeometry.Target.Gap, gta.hitTest(x, y))
            }
        }
    }
}
