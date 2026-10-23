package com.actionhalo.android

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.SystemClock
import android.view.Gravity
import android.view.ContextThemeWrapper
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.widget.Button
import android.widget.CompoundButton
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Real touch streams guard release-to-execute semantics and the live GTA action preview. */
@RunWith(AndroidJUnit4::class)
class GtaRadialMenuTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private var hadModePreference = false
    private var previousMode = true
    private var hadPageSizePreference = false
    private var previousPageSize = HaloAppearance.DEFAULT_ACTIONS_PER_PAGE
    private val fixtureActions = listOf(
        HaloAction("fixture-first", "Copy", "1", ActionType.COPY),
        HaloAction("fixture-second", "Search", "2", ActionType.COPY),
        HaloAction("fixture-third", "Share", "3", ActionType.COPY),
    )

    @Before fun resetMode() {
        val preferences = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        hadModePreference = preferences.contains(HaloAppearance.GTA_MODE_KEY)
        previousMode = HaloAppearance.isGtaModeEnabled(context)
        hadPageSizePreference = preferences.contains(HaloAppearance.ACTIONS_PER_PAGE_KEY)
        previousPageSize = HaloAppearance.actionsPerPage(context)
        assertTrue(preferences.edit().remove(HaloAppearance.GTA_MODE_KEY)
            .remove(HaloAppearance.ACTIONS_PER_PAGE_KEY).commit())
    }

    @After fun restoreMode() {
        val editor = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE).edit()
        if (hadModePreference) editor.putBoolean(HaloAppearance.GTA_MODE_KEY, previousMode)
        else editor.remove(HaloAppearance.GTA_MODE_KEY)
        if (hadPageSizePreference) editor.putInt(HaloAppearance.ACTIONS_PER_PAGE_KEY, previousPageSize)
        else editor.remove(HaloAppearance.ACTIONS_PER_PAGE_KEY)
        assertTrue(editor.commit())
    }

    @Test fun gtaDragUpdatesCenterBeforeReleaseAndExecutesOnlyTheFinalActionOnce() {
        withMenu(gtaMode = true) { menu ->
            val gesture = TouchStream()
            gesture.send(MotionEvent.ACTION_DOWN, menu.center)
            assertTrue(menu.executed.isEmpty())

            gesture.send(MotionEvent.ACTION_MOVE, menu.actions[0])
            assertCenter(menu.view) { text ->
                assertTrue("The current action must appear while the finger is still down", text.contains(fixtureActions[0].title))
                assertTrue("The center must identify the current slot", text.contains("01"))
            }
            instrumentation.runOnMainSync {
                assertEquals(1.22f, actionButton(menu.view, fixtureActions[0].title).scaleX, 0.001f)
                assertEquals(1.22f, actionButton(menu.view, fixtureActions[0].title).scaleY, 0.001f)
            }
            assertTrue("Moving onto an action must not execute it", menu.executed.isEmpty())

            gesture.send(MotionEvent.ACTION_MOVE, menu.actions[1])
            assertCenter(menu.view) { text ->
                assertTrue(text.contains(fixtureActions[1].title))
                assertFalse("The previous action must leave the live preview", text.contains(fixtureActions[0].title))
                assertTrue(text.contains("02"))
            }
            instrumentation.runOnMainSync {
                assertEquals(1f, actionButton(menu.view, fixtureActions[0].title).scaleX, 0.001f)
                assertEquals(1.22f, actionButton(menu.view, fixtureActions[1].title).scaleX, 0.001f)
            }
            assertTrue("Moving between sectors must not execute either action", menu.executed.isEmpty())

            gesture.send(MotionEvent.ACTION_UP, menu.actions[1])
            assertEquals(listOf(fixtureActions[1].id), menu.executed.toList())
            assertEquals(0, menu.dismissals.get())
        }
    }

    @Test fun selectedGtaWhiteIconsKeepTheirDarkShadowAndRepeatedDrawsStayStable() {
        withMenu(gtaMode = true) { menu ->
            val gesture = TouchStream()
            gesture.send(MotionEvent.ACTION_DOWN, menu.actions[0])
            instrumentation.runOnMainSync {
                val first = Bitmap.createBitmap(menu.view.width, menu.view.height, Bitmap.Config.ARGB_8888)
                val second = Bitmap.createBitmap(menu.view.width, menu.view.height, Bitmap.Config.ARGB_8888)
                try {
                    menu.view.draw(Canvas(first))
                    menu.view.draw(Canvas(second))
                    val button = actionButton(menu.view, fixtureActions[0].title)
                    val cx = (button.left + button.right) / 2
                    val cy = (button.top + button.bottom) / 2
                    val radius = (12f * menu.view.resources.displayMetrics.density).toInt()
                    var white = 0
                    var dark = 0
                    for (y in cy - radius..cy + radius) for (x in cx - radius..cx + radius) {
                        val pixel = first.getPixel(x, y)
                        if (Color.alpha(pixel) > 240) {
                            if (Color.red(pixel) > 245) white++
                            if (Color.red(pixel) < 180) dark++
                        }
                    }
                    assertTrue("The selected icon must stay white", white > 5)
                    assertTrue("Black icon shading must remain visible on the bright selected sector", dark > 5)
                    assertTrue("Reusing the shadow cache must preserve the same visible result", first.sameAs(second))
                } finally { first.recycle(); second.recycle() }
            }
            gesture.send(MotionEvent.ACTION_CANCEL, menu.actions[0])
            assertTrue(menu.executed.isEmpty())
        }
    }

    @Test fun gtaCancellationAndSecondFingerCancelWithoutExecutingOrDismissing() {
        withMenu(gtaMode = true) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[0])
                send(MotionEvent.ACTION_CANCEL, menu.actions[0])
            }
            assertTrue(menu.executed.isEmpty())
            assertCenter(menu.view) { assertFalse(it.contains(fixtureActions[0].title)) }

            // A second finger cancels the entire gesture, even when the original finger stays.
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[0])
                sendMulti(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to menu.actions[0], 1 to menu.actions[1])
                sendMulti(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to menu.actions[0], 1 to menu.actions[1])
                send(MotionEvent.ACTION_MOVE, menu.actions[1])
                send(MotionEvent.ACTION_UP, menu.actions[1])
            }
            assertTrue("The surviving original finger must not fire a cancelled selection", menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())

            // Nor may the second finger inherit a selection after the first finger lifts.
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[0])
                sendMulti(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to menu.actions[0], 1 to menu.actions[1])
                sendMulti(MotionEvent.ACTION_POINTER_UP, 0 to menu.actions[0], 1 to menu.actions[1])
                sendMulti(MotionEvent.ACTION_UP, 1 to menu.actions[1])
            }
            assertTrue(menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
        }
    }

    @Test fun returningToTheGtaCenterCancelsTheSelectedActionOnRelease() {
        withMenu(gtaMode = true) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[2])
                send(MotionEvent.ACTION_MOVE, menu.center)
                assertCenter(menu.view) { assertFalse(it.contains(fixtureActions[2].title)) }
                send(MotionEvent.ACTION_UP, menu.center)
            }
            assertTrue(menu.executed.isEmpty())
            assertEquals(1, menu.dismissals.get())
        }
    }

    @Test fun ordinaryModeStillSupportsDragReleaseAndAccessibleActionButtons() {
        withMenu(gtaMode = false) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[2])
                assertTrue(menu.executed.isEmpty())
                send(MotionEvent.ACTION_UP, menu.actions[2])
            }
            assertEquals(listOf(fixtureActions[2].id), menu.executed.toList())
            instrumentation.runOnMainSync {
                menu.view.beginInteractionSession()
                actionButton(menu.view, fixtureActions[0].title).performClick()
            }
            assertEquals(listOf(fixtureActions[2].id, fixtureActions[0].id), menu.executed.toList())
        }
    }

    @Test fun onlyTheFirstOutsidePressMovesTheWheelAndLaterGesturesKeepItsCenter() {
        val many = (1..10).map { HaloAction("anchor-$it", "Anchor action $it", "$it", ActionType.COPY) }
        for (gta in listOf(true, false)) withMenu(gta, many) { menu ->
            val bounds = availableBounds(menu.view)
            val anchor = Point(bounds.exactCenterX(), bounds.top + 1f)
            assertOutsideMenu(menu.view, anchor)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, anchor)
                assertWheelCenter(menu.view, anchor)
                assertCenter(menu.view) { text ->
                    assertTrue("A relocated press starts in the center without an action preview",
                        many.none { text.contains(it.title) })
                }
                assertTrue("Relocating must wait for release", menu.executed.isEmpty())
                assertEquals(0, menu.dismissals.get())
                val first = actionCenter(menu.view, many[2].title)
                val last = actionCenter(menu.view, many[3].title)
                send(MotionEvent.ACTION_MOVE, first)
                assertCenter(menu.view) { assertTrue(it.contains(many[2].title)) }
                assertWheelCenter(menu.view, anchor)
                send(MotionEvent.ACTION_MOVE, last)
                assertCenter(menu.view) { assertTrue(it.contains(many[3].title)) }
                assertWheelCenter(menu.view, anchor)
                assertTrue(menu.executed.isEmpty())
                send(MotionEvent.ACTION_UP, last)
            }
            assertEquals(listOf(many[3].id), menu.executed.toList())
            assertEquals(0, menu.dismissals.get())
            instrumentation.runOnMainSync {
                assertFalse("Relocating must not activate the pager", pageButton(menu.view, R.string.radial_previous_page).isEnabled)
                actionButton(menu.view, many[0].title).performClick()
                menu.view.beginInteractionSession()
            }
            assertEquals("A repeated click belongs to the same execution session", listOf(many[3].id), menu.executed.toList())

            val nextAnchor = Point(bounds.exactCenterX(), bounds.bottom - 1f)
            assertOutsideMenu(menu.view, nextAnchor)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, nextAnchor)
                assertWheelCenter(menu.view, anchor)
                val next = actionCenter(menu.view, many[6].title)
                send(MotionEvent.ACTION_MOVE, next)
                assertWheelCenter(menu.view, anchor)
                send(MotionEvent.ACTION_UP, next)
            }
            assertEquals("Later gestures must still select from the first anchor after an interaction reset",
                listOf(many[3].id, many[6].id), menu.executed.toList())
        }
    }

    @Test fun stationaryTouchesBeyondTheWheelBufferDismissAfterTheFirstAnchorInBothModes() {
        for (gta in listOf(true, false)) withMenu(gta) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_CANCEL, menu.center)
            }
            val expected = fixtureActions[if (gta) 0 else 1]
            for (bufferDp in listOf(31f, 32f)) {
                val near = pointBeyondRightEdge(menu.view, bufferDp)
                TouchStream().apply {
                    sendOnSurface(menu.view, MotionEvent.ACTION_DOWN, near)
                    assertCenter(menu.view) { assertTrue("The outside buffer remains selectable", it.contains(expected.title)) }
                    sendOnSurface(menu.view, MotionEvent.ACTION_UP, near)
                }
                assertEquals(listOf(expected.id), menu.executed.toList())
                assertEquals(0, menu.dismissals.get())
                menu.executed.clear()
                instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            }
            val far = pointBeyondRightEdge(menu.view, 33f)
            repeat(2) { index ->
                TouchStream().apply {
                    send(MotionEvent.ACTION_DOWN, far)
                    assertWheelCenter(menu.view, menu.center)
                    assertCenter(menu.view) { text ->
                        assertTrue("A stationary outside press must not preview an action", fixtureActions.none { text.contains(it.title) })
                    }
                    assertEquals(index, menu.dismissals.get())
                    if (index == 1) SystemClock.sleep(ViewConfiguration.getLongPressTimeout().toLong() + 50)
                    send(MotionEvent.ACTION_UP, far)
                }
                assertTrue("Outside taps and held releases must only close", menu.executed.isEmpty())
                assertEquals(index + 1, menu.dismissals.get())
                instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            }
        }
    }

    @Test fun distantDragsAndHistoricalExcursionsNeverExecuteOutsideTheSelectionLimitInBothModes() {
        for (gta in listOf(true, false)) withMenu(gta) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_CANCEL, menu.center)
            }
            val bounds = availableBounds(menu.view)
            val far = Point(bounds.exactCenterX(), bounds.bottom - 1f)
            val excursion = Point(bounds.left + 1f, bounds.bottom - 1f)
            assertOutsideMenu(menu.view, far)
            repeat(3) { variant ->
                TouchStream().apply {
                    if (variant == 0) {
                        send(MotionEvent.ACTION_DOWN, far)
                        send(MotionEvent.ACTION_MOVE, excursion)
                        send(MotionEvent.ACTION_UP, far)
                    } else {
                        sendOnSurface(menu.view, MotionEvent.ACTION_DOWN, far)
                        if (variant == 1) {
                            sendOnSurface(menu.view, MotionEvent.ACTION_MOVE, far, listOf(excursion))
                            assertCenter(menu.view) { text -> assertTrue(fixtureActions.none { text.contains(it.title) }) }
                            sendOnSurface(menu.view, MotionEvent.ACTION_UP, far)
                        } else {
                            sendOnSurface(menu.view, MotionEvent.ACTION_UP, far, listOf(excursion))
                        }
                    }
                }
                assertTrue("Movement and history must not bypass the selection distance limit", menu.executed.isEmpty())
                assertEquals(variant + 1, menu.dismissals.get())
                assertWheelCenter(menu.view, menu.center)
                menu.executed.clear()
                instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            }
        }
    }

    @Test fun leavingTheSelectionBufferClearsPreviewAndReturningRestoresSelectionInBothModes() {
        for (gta in listOf(true, false)) withMenu(gta) { menu ->
            val near = pointBeyondRightEdge(menu.view, 31f)
            val far = pointBeyondRightEdge(menu.view, 33f)
            val expected = fixtureActions[if (gta) 0 else 1]
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.actions[0])
                assertWheelCenter(menu.view, menu.center)
                send(MotionEvent.ACTION_MOVE, near)
                assertCenter(menu.view) { assertTrue(it.contains(expected.title)) }
                send(MotionEvent.ACTION_MOVE, far)
                assertCenter(menu.view) { text -> assertTrue(fixtureActions.none { text.contains(it.title) }) }
                assertTrue("Leaving the buffer must not execute or close while held", menu.executed.isEmpty())
                assertEquals(0, menu.dismissals.get())
                send(MotionEvent.ACTION_MOVE, near)
                assertCenter(menu.view) { assertTrue(it.contains(expected.title)) }
                send(MotionEvent.ACTION_UP, near)
            }
            assertEquals("Re-entering the buffer must allow one release action", listOf(expected.id), menu.executed.toList())
            instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, far)
                send(MotionEvent.ACTION_MOVE, near)
                assertCenter(menu.view) { assertTrue("Even a short move back inside must restore selection", it.contains(expected.title)) }
                send(MotionEvent.ACTION_UP, near)
            }
            assertEquals(listOf(expected.id, expected.id), menu.executed.toList())
            instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.actions[0])
                assertCenter(menu.view) { assertTrue(it.contains(fixtureActions[0].title)) }
                send(MotionEvent.ACTION_UP, far)
            }
            assertEquals("A release outside must not execute the previously highlighted action", listOf(expected.id, expected.id), menu.executed.toList())
            assertEquals(1, menu.dismissals.get())
            assertWheelCenter(menu.view, menu.center)
        }
    }

    @Test fun distantTapCandidatesCancelWithoutClosingOrExecutingInBothModes() {
        for (gta in listOf(true, false)) withMenu(gta) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_CANCEL, menu.center)
            }
            val bounds = availableBounds(menu.view)
            val far = Point(bounds.exactCenterX(), bounds.bottom - 1f)
            assertOutsideMenu(menu.view, far)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, far)
                send(MotionEvent.ACTION_CANCEL, far)
            }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, far)
                sendMulti(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to far, 1 to menu.center)
                sendMulti(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to far, 1 to menu.center)
                send(MotionEvent.ACTION_UP, far)
            }
            assertTrue(menu.executed.isEmpty())
            assertEquals("System cancellation and another finger must not close an outside tap candidate", 0, menu.dismissals.get())
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, far)
                send(MotionEvent.ACTION_UP, far)
            }
            assertEquals("A fresh outside tap remains usable after cancellation", 1, menu.dismissals.get())
            assertTrue(menu.executed.isEmpty())
            assertWheelCenter(menu.view, menu.center)
        }
    }

    @Test fun anchoredGesturesKeepDisabledLinksCancellationAndFollowingSessionsSafeInBothModes() {
        val openLink = HaloAction("anchor-open-link", "Open link", "↗", ActionType.OPEN_URL)
        val many = listOf(openLink) + (1..7).map { HaloAction("anchor-$it", "Anchor action $it", "$it", ActionType.COPY) }
        for (gta in listOf(true, false)) withMenu(gta, many) { menu ->
            val bounds = availableBounds(menu.view)
            val anchor = Point(bounds.left + 1f, bounds.exactCenterY())
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, anchor)
                assertWheelCenter(menu.view, anchor)
                val disabled = actionCenter(menu.view, openLink.title)
                send(MotionEvent.ACTION_MOVE, disabled)
                assertCenter(menu.view) { assertFalse("A disabled link must not gain a preview", it.contains(openLink.title)) }
                send(MotionEvent.ACTION_UP, disabled)
            }
            assertTrue("A relocated release must not execute a disabled link", menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())

            val laterPress = Point(bounds.exactCenterX(), bounds.exactCenterY())
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, laterPress)
                assertWheelCenter(menu.view, anchor)
                val available = actionCenter(menu.view, many[2].title)
                send(MotionEvent.ACTION_MOVE, available)
                send(MotionEvent.ACTION_CANCEL, available)
            }
            assertCenter(menu.view) { assertFalse(it.contains(many[2].title)) }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, laterPress)
                assertWheelCenter(menu.view, anchor)
                val available = actionCenter(menu.view, many[2].title)
                val second = actionCenter(menu.view, many[1].title)
                send(MotionEvent.ACTION_MOVE, available)
                sendMulti(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to available, 1 to second)
                sendMulti(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to available, 1 to second)
                send(MotionEvent.ACTION_MOVE, available)
                send(MotionEvent.ACTION_UP, available)
            }
            assertTrue("System cancellation and a second finger must cancel the selection", menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
            assertWheelCenter(menu.view, anchor)

            val fittedAnchor = wheelCenter(menu.view)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, fittedAnchor)
                val available = actionCenter(menu.view, many[2].title)
                send(MotionEvent.ACTION_MOVE, available)
                send(MotionEvent.ACTION_MOVE, fittedAnchor)
                send(MotionEvent.ACTION_UP, fittedAnchor)
            }
            assertTrue("Returning to the new center must cancel", menu.executed.isEmpty())
            assertEquals(1, menu.dismissals.get())
            instrumentation.runOnMainSync {
                menu.view.beginInteractionSession()
                menu.view.selectedText = "https://example.com/path"
                assertTrue(actionButton(menu.view, openLink.title).isEnabled)
            }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, anchor)
                val enabledLink = actionCenter(menu.view, openLink.title)
                send(MotionEvent.ACTION_MOVE, enabledLink)
                send(MotionEvent.ACTION_UP, enabledLink)
            }
            assertEquals("Cancelled gestures and a disabled link must leave the next valid session usable", listOf(openLink.id), menu.executed.toList())
            assertEquals(1, menu.dismissals.get())
        }
    }

    @Test fun pressingNearAScreenEdgeFitsAllActionsAndAllowsAnInwardSelection() {
        val many = (1..8).map { HaloAction("edge-$it", "Edge action $it", "$it", ActionType.COPY) }
        for (gta in listOf(true, false)) withMenu(gta, many) { menu ->
            val bounds = availableBounds(menu.view)
            val anchor = Point(bounds.left + 1f, bounds.exactCenterY())
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, anchor)
                assertWheelCenter(menu.view, anchor)
                instrumentation.runOnMainSync {
                    val visible = Rect().also(menu.view::getWindowVisibleDisplayFrame)
                    many.forEach { action ->
                        val point = screenCenter(actionButton(menu.view, action.title))
                        assertTrue("Every action must remain reachable at the screen edge", visible.contains(point.x.toInt(), point.y.toInt()))
                    }
                    assertTrue("An unsafe edge anchor is fitted inward", screenCenter(menu.view).x > anchor.x)
                }
                val inward = actionCenter(menu.view, many[2].title)
                assertTrue("The inward action must stay in the usable area", bounds.contains(inward.x.toInt(), inward.y.toInt()))
                send(MotionEvent.ACTION_MOVE, inward)
                assertWheelCenter(menu.view, anchor)
                assertCenter(menu.view) { assertTrue(it.contains(many[2].title)) }
                send(MotionEvent.ACTION_UP, inward)
            }
            assertEquals(listOf(many[2].id), menu.executed.toList())
            assertEquals(0, menu.dismissals.get())
        }
    }

    @Test fun firstIconPressKeepsTheWheelInPlaceForTapsAndHeldSelectionsInBothModes() {
        for (gta in listOf(true, false)) for (held in listOf(false, true)) withMenu(gta) { menu ->
            val icon = actionCenter(menu.view, fixtureActions[1].title)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, icon)
                assertWheelCenter(menu.view, menu.center)
                assertCenter(menu.view) { assertTrue(it.contains(fixtureActions[1].title)) }
                assertTrue(menu.executed.isEmpty())
                if (held) SystemClock.sleep(ViewConfiguration.getLongPressTimeout().toLong() + 50)
                send(MotionEvent.ACTION_UP, icon)
            }
            assertEquals("gta=$gta, held=$held: the first icon press executes once on release",
                listOf(fixtureActions[1].id), menu.executed.toList())
            instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            val nextIcon = actionCenter(menu.view, fixtureActions[0].title)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, nextIcon)
                assertWheelCenter(menu.view, menu.center)
                send(MotionEvent.ACTION_UP, nextIcon)
            }
            assertEquals("A later short icon tap executes without relocating",
                listOf(fixtureActions[1].id, fixtureActions[0].id), menu.executed.toList())
            instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            val heldIcon = actionCenter(menu.view, fixtureActions[2].title)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, heldIcon)
                assertWheelCenter(menu.view, menu.center)
                SystemClock.sleep(ViewConfiguration.getLongPressTimeout().toLong() + 50)
                send(MotionEvent.ACTION_UP, heldIcon)
            }
            assertEquals("A later held icon stays in its sector and executes",
                listOf(fixtureActions[1].id, fixtureActions[0].id, fixtureActions[2].id), menu.executed.toList())
            instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                assertWheelCenter(menu.view, menu.center)
                send(MotionEvent.ACTION_UP, menu.center)
            }
            assertEquals("The fixed center must remain easy to tap to close", 1, menu.dismissals.get())
        }
    }

    @Test fun cancelledFirstPressOnADisabledIconLocksThePositionAndStillAllowsOutsideDismissal() {
        val openLink = HaloAction("fixture-open-link", "Open link", "↗", ActionType.OPEN_URL)
        for (gta in listOf(true, false)) withMenu(gta, listOf(openLink) + fixtureActions.take(2)) { menu ->
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.actions[0])
                assertWheelCenter(menu.view, menu.center)
                assertCenter(menu.view) { assertFalse(it.contains(openLink.title)) }
                send(MotionEvent.ACTION_CANCEL, menu.actions[0])
            }
            val far = pointBeyondRightEdge(menu.view, 33f)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, far)
                assertWheelCenter(menu.view, menu.center)
                send(MotionEvent.ACTION_UP, far)
            }
            assertTrue("Disabled and cancelled selections must not execute", menu.executed.isEmpty())
            assertEquals("The first press must consume positioning even when cancelled", 1, menu.dismissals.get())
        }
    }

    @Test fun eachNewMenuAllowsItsOwnFirstTouchToMoveTheCenter() {
        for (gta in listOf(true, false)) repeat(2) {
            withMenu(gta) { menu ->
                val bounds = availableBounds(menu.view)
                val anchor = Point(bounds.exactCenterX(), bounds.top + 1f)
                assertOutsideMenu(menu.view, anchor)
                TouchStream().apply {
                    send(MotionEvent.ACTION_DOWN, anchor)
                    assertWheelCenter(menu.view, anchor)
                    send(MotionEvent.ACTION_CANCEL, anchor)
                }
                val laterPress = Point(bounds.exactCenterX(), bounds.bottom - 1f)
                TouchStream().apply {
                    send(MotionEvent.ACTION_DOWN, laterPress)
                    assertWheelCenter(menu.view, anchor)
                    send(MotionEvent.ACTION_CANCEL, laterPress)
                }
                TouchStream().apply {
                    val fittedAnchor = wheelCenter(menu.view)
                    send(MotionEvent.ACTION_DOWN, fittedAnchor)
                    send(MotionEvent.ACTION_UP, fittedAnchor)
                }
                assertEquals("Cancelling the first gesture must keep the close target fixed", 1, menu.dismissals.get())
                assertTrue(menu.executed.isEmpty())
            }
        }
    }

    @Test fun openLinkIsDisabledForNonUrlsAndBecomesAvailableWithoutConsumingTheSession() {
        val openLink = HaloAction("fixture-open-link", "Open link", "↗", ActionType.OPEN_URL)
        for (gta in listOf(true, false)) withMenu(gta, listOf(openLink) + fixtureActions.take(2)) { menu ->
            for (text in listOf("Ordinary selected words", "", "javascript:alert(1)", "file:///private/test", "data:text/plain,test")) {
                instrumentation.runOnMainSync {
                    menu.view.selectedText = text
                    val button = actionButton(menu.view, openLink.title)
                    assertFalse("Non-URL text must disable opening links: $text", button.isEnabled)
                    assertFalse(button.isClickable)
                    assertFalse(button.isFocusable)
                    val copyButton = actionButton(menu.view, fixtureActions[0].title)
                    assertTrue("The disabled action must look unavailable", button.alpha < copyButton.alpha)
                    assertTrue("Other actions remain available", copyButton.isEnabled)
                    button.performClick()
                }
                TouchStream().apply {
                    send(MotionEvent.ACTION_DOWN, menu.center)
                    send(MotionEvent.ACTION_MOVE, menu.actions[0])
                    assertCenter(menu.view) { assertFalse(it.contains(openLink.title)) }
                    send(MotionEvent.ACTION_UP, menu.actions[0])
                }
                assertTrue("Disabled buttons and sectors must not execute", menu.executed.isEmpty())
                assertEquals(0, menu.dismissals.get())
            }
            for (text in listOf("http://example.com", "https://example.com/path?q=test", "example.com/path")) {
                instrumentation.runOnMainSync {
                    menu.view.selectedText = text
                    val button = actionButton(menu.view, openLink.title)
                    assertTrue("A valid URL must enable opening links: $text", button.isEnabled)
                    assertTrue(button.isClickable)
                    assertTrue(button.isFocusable)
                }
            }
            instrumentation.runOnMainSync {
                actionButton(menu.view, openLink.title).performClick()
                actionButton(menu.view, openLink.title).performClick()
            }
            assertEquals("Rejected attempts must leave one execution available", listOf(openLink.id), menu.executed.toList())
        }
    }

    @Test fun invalidatingAHighlightedLinkCancelsReleaseAndAllowsTheNextValidSelection() {
        val openLink = HaloAction("fixture-open-link", "Open link", "↗", ActionType.OPEN_URL)
        for (gta in listOf(true, false)) withMenu(gta, listOf(openLink) + fixtureActions.take(2)) { menu ->
            instrumentation.runOnMainSync { menu.view.selectedText = "https://example.com" }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[0])
                assertCenter(menu.view) { assertTrue(it.contains(openLink.title)) }
                instrumentation.runOnMainSync {
                    menu.view.selectedText = "No longer a URL"
                    val button = actionButton(menu.view, openLink.title)
                    assertFalse(button.isEnabled)
                    assertEquals(1f, button.scaleX, 0.001f)
                }
                assertCenter(menu.view) { assertFalse("Invalidated links must leave the preview", it.contains(openLink.title)) }
                send(MotionEvent.ACTION_UP, menu.actions[0])
            }
            assertTrue("Releasing a stale highlighted link must not execute it", menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
            instrumentation.runOnMainSync { menu.view.selectedText = "example.com/path" }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, menu.actions[0])
                send(MotionEvent.ACTION_UP, menu.actions[0])
            }
            assertEquals(listOf(openLink.id), menu.executed.toList())
        }
    }

    @Test fun ordinaryModeChoosesByDirectionInsideTheHoleAndStillCancelsAtCenter() {
        withMenu(gtaMode = false) { menu ->
            val distance = 24 * context.resources.displayMetrics.density
            val aboveCenter = Point(menu.center.x, menu.center.y - distance)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, aboveCenter)
                assertTrue(menu.executed.isEmpty())
                send(MotionEvent.ACTION_UP, aboveCenter)
            }
            assertEquals(listOf(fixtureActions[0].id), menu.executed.toList())
            instrumentation.runOnMainSync { menu.view.beginInteractionSession() }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, aboveCenter)
                send(MotionEvent.ACTION_MOVE, menu.center)
                send(MotionEvent.ACTION_UP, menu.center)
            }
            assertEquals(listOf(fixtureActions[0].id), menu.executed.toList())
            assertEquals(1, menu.dismissals.get())
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, aboveCenter)
                sendMulti(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to aboveCenter, 1 to menu.actions[1])
                sendMulti(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to aboveCenter, 1 to menu.actions[1])
                send(MotionEvent.ACTION_UP, aboveCenter)
            }
            assertEquals(listOf(fixtureActions[0].id), menu.executed.toList())
            assertEquals(1, menu.dismissals.get())
        }
    }

    @Test fun pagingPreservesEightSlotsAndDispatchesTheCorrectSecondPageActionOnce() {
        val many = (1..10).map { HaloAction("page-$it", "Action $it", "$it", ActionType.COPY) }
        for (gta in listOf(true, false)) withMenu(gta, many) { menu ->
            lateinit var staleFirst: Button
            instrumentation.runOnMainSync {
                staleFirst = actionButton(menu.view, many[0].title)
                assertFalse(pageButton(menu.view, R.string.radial_previous_page).isEnabled)
                assertEquals(8, descendants(menu.view).filterIsInstance<Button>().count {
                    it.contentDescription?.toString()?.startsWith("Action ") == true
                })
                val footerTop = pageButton(menu.view, R.string.radial_next_page).top
                many.take(8).forEach {
                    assertTrue("Action accessibility bounds must not cover the pager",
                        actionButton(menu.view, it.title).bottom <= footerTop)
                }
            }
            val next = buttonCenter(menu.view, R.string.radial_next_page)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, next)
                assertWheelCenter(menu.view, menu.center)
                send(MotionEvent.ACTION_UP, next)
            }
            assertWheelCenter(menu.view, menu.center)
            assertTrue(menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
            instrumentation.runOnMainSync {
                assertFalse(pageButton(menu.view, R.string.radial_next_page).isEnabled)
                assertEquals(2, descendants(menu.view).filterIsInstance<Button>().count {
                    it.contentDescription?.toString()?.startsWith("Action ") == true
                })
                staleFirst.performClick()
            }
            assertTrue("An obsolete page button must not execute a different action", menu.executed.isEmpty())
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, next)
                send(MotionEvent.ACTION_UP, next)
            }
            assertTrue(menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
            val bounds = availableBounds(menu.view)
            val anchor = Point(bounds.exactCenterX(), bounds.top + 1f)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, anchor)
                assertWheelCenter(menu.view, anchor)
                send(MotionEvent.ACTION_CANCEL, anchor)
            }
            val previous = buttonCenter(menu.view, R.string.radial_previous_page)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, previous)
                send(MotionEvent.ACTION_UP, previous)
            }
            assertWheelCenter(menu.view, anchor)
            val laterPress = Point(bounds.exactCenterX(), bounds.bottom - 1f)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, laterPress)
                assertWheelCenter(menu.view, anchor)
                send(MotionEvent.ACTION_CANCEL, laterPress)
            }
            val nextAtAnchor = buttonCenter(menu.view, R.string.radial_next_page)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, nextAtAnchor)
                send(MotionEvent.ACTION_UP, nextAtAnchor)
            }
            assertWheelCenter(menu.view, anchor)
            assertTrue("Paging must neither consume nor reset the first-touch position", menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
            instrumentation.runOnMainSync {
                actionButton(menu.view, many[9].title).performClick()
                actionButton(menu.view, many[9].title).performClick()
                pageButton(menu.view, R.string.radial_previous_page).performClick()
                actionButton(menu.view, many[8].title).performClick()
            }
            assertEquals(listOf(many[9].id), menu.executed.toList())
            instrumentation.runOnMainSync {
                menu.view.setActions(many)
                assertFalse(pageButton(menu.view, R.string.radial_previous_page).isEnabled)
                actionButton(menu.view, many[0].title).performClick()
            }
            assertEquals(listOf(many[9].id, many[0].id), menu.executed.toList())
        }
    }

    @Test fun pagingControlsNeverTurnAnInterruptedDragIntoAnActionOrDismissal() {
        val many = (1..17).map { HaloAction("page-$it", "Action $it", "$it", ActionType.COPY) }
        for (gta in listOf(true, false)) withMenu(gta, many) { menu ->
            val next = buttonCenter(menu.view, R.string.radial_next_page)
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, next)
                send(MotionEvent.ACTION_MOVE, menu.actions[0])
                send(MotionEvent.ACTION_UP, menu.actions[0])
            }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, menu.center)
                send(MotionEvent.ACTION_MOVE, next)
                send(MotionEvent.ACTION_UP, next)
            }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, next)
                send(MotionEvent.ACTION_CANCEL, next)
                send(MotionEvent.ACTION_UP, next)
            }
            TouchStream().apply {
                send(MotionEvent.ACTION_DOWN, next)
                sendMulti(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to next, 1 to menu.center)
                sendMulti(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    0 to next, 1 to menu.center)
                send(MotionEvent.ACTION_UP, next)
            }
            instrumentation.runOnMainSync {
                assertFalse(pageButton(menu.view, R.string.radial_previous_page).isEnabled)
                pageButton(menu.view, R.string.radial_next_page).performClick()
                pageButton(menu.view, R.string.radial_next_page).performClick()
                assertFalse(pageButton(menu.view, R.string.radial_next_page).isEnabled)
                pageButton(menu.view, R.string.radial_previous_page).performClick()
                assertTrue(pageButton(menu.view, R.string.radial_next_page).isEnabled)
                actionButton(menu.view, many[8].title).performClick()
            }
            assertEquals(listOf(many[8].id), menu.executed.toList())
            assertEquals(0, menu.dismissals.get())
        }
    }

    @Test fun vectorIconsFitAt320DpWithLargerFontsAndRevealTheirFullTitleWhileDragging() {
        val preferences = context.getSharedPreferences("vector_icon_test_fixture", Context.MODE_PRIVATE)
        assertTrue(preferences.edit().clear().commit())
        val fixtureContext = object : ContextWrapper(context) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = preferences
        }
        try {
            val store = ActionStore(fixtureContext)
            val defaults = store.allActions()
            val custom = (1..5).map {
                store.addCustom("自定义链接 $it 完整中文标题", "https://example.com/search?q={text}")
            }
            for (count in listOf(6, 8, 12, 16)) for (gta in listOf(true, false)) {
                HaloAppearance.setActionsPerPage(context, count)
                val many = (defaults.take(count) + custom).take(count + 2)
                withMenu(gtaMode = gta, actions = many, fontScale = 1.3f) { menu ->
                    fun checkIcons(expected: List<HaloAction>) {
                        instrumentation.runOnMainSync {
                            assertEquals(1.3f, menu.view.resources.configuration.fontScale, 0.001f)
                            val footerTop = pageButton(menu.view, R.string.radial_next_page).top
                            expected.forEach { action ->
                                val button = actionButton(menu.view, action.title)
                                val detail = "count=$count GTA=$gta action=${action.id} button=${button.width}x${button.height}"
                                assertEquals("The action must display a vector without text; $detail", "", button.text.toString())
                                assertEquals(action.title, button.contentDescription.toString())
                                assertTrue("Action bounds must not cover the pager; $detail", button.bottom <= footerTop)
                                assertTrue("The action must have drawable bounds; $detail", button.width > 0 && button.height > 0)
                                val bitmap = Bitmap.createBitmap(button.width, button.height, Bitmap.Config.ARGB_8888)
                                try {
                                    button.draw(Canvas(bitmap))
                                    var left = bitmap.width
                                    var top = bitmap.height
                                    var right = -1
                                    var bottom = -1
                                    for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                                        if (Color.alpha(bitmap.getPixel(x, y)) > 0) {
                                            left = minOf(left, x)
                                            top = minOf(top, y)
                                            right = maxOf(right, x)
                                            bottom = maxOf(bottom, y)
                                        }
                                    }
                                    assertTrue("The vector must render visible pixels; $detail", right >= left && bottom >= top)
                                    assertTrue("The vector must fit without touching or clipping at button edges; $detail bounds=$left,$top,$right,$bottom",
                                        left > 0 && top > 0 && right < bitmap.width - 1 && bottom < bitmap.height - 1)
                                } finally {
                                    bitmap.recycle()
                                }
                            }
                            if (gta) assertSlotNumbersAndIconsHaveSeparateInk(menu.view, expected)
                        }
                    }
                    fun checkDragPreview(action: HaloAction) {
                        val target = AtomicReference<Point>()
                        instrumentation.runOnMainSync { target.set(screenCenter(actionButton(menu.view, action.title))) }
                        val downTime = SystemClock.uptimeMillis()
                        fun dispatch(eventAction: Int, point: Point) {
                            instrumentation.runOnMainSync {
                                val origin = IntArray(2)
                                menu.view.getLocationOnScreen(origin)
                                val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), eventAction,
                                    point.x - origin[0], point.y - origin[1], 0).apply {
                                    source = InputDevice.SOURCE_TOUCHSCREEN
                                }
                                try { assertTrue(menu.view.dispatchTouchEvent(event)) } finally { event.recycle() }
                            }
                        }
                        dispatch(MotionEvent.ACTION_DOWN, menu.center)
                        dispatch(MotionEvent.ACTION_MOVE, target.get())
                        assertCenter(menu.view) {
                            if (gta) assertTrue("The GTA center must preview ${action.title}", it.contains(action.title))
                            else assertEquals(action.title, it)
                        }
                        assertTrue(menu.executed.isEmpty())
                        dispatch(MotionEvent.ACTION_CANCEL, target.get())
                        assertTrue("Cancelling a preview must not execute an action", menu.executed.isEmpty())
                    }
                    checkIcons(many.take(count))
                    checkDragPreview(many[1])
                    instrumentation.runOnMainSync { pageButton(menu.view, R.string.radial_next_page).performClick() }
                    instrumentation.waitForIdleSync()
                    checkIcons(many.drop(count))
                    checkDragPreview(many.last())
                    assertEquals(0, menu.dismissals.get())
                }
            }
        } finally {
            assertTrue(preferences.edit().clear().commit())
        }
    }

    @Test fun configuredPageSizesKeepActionOrderGlobalSlotsAndTouchTargetsInBothModes() {
        for (count in listOf(6, 8, 12, 16)) for (gta in listOf(true, false)) {
            HaloAppearance.setActionsPerPage(context, count)
            val many = (1..(count + 2)).map { HaloAction("sized-$it", "Page action $it", "$it", ActionType.COPY) }
            withMenu(gta, many) { menu ->
                fun assertVisibleActions(expected: List<HaloAction>) {
                    instrumentation.runOnMainSync {
                        val titles = descendants(menu.view).filterIsInstance<Button>().mapNotNull {
                            it.contentDescription?.toString()?.takeIf { title -> title.startsWith("Page action ") }
                        }
                        assertEquals("Page size $count, GTA $gta must preserve order", expected.map { it.title }, titles)
                    }
                }
                assertVisibleActions(many.take(count))
                lateinit var staleFirst: Button
                instrumentation.runOnMainSync { staleFirst = actionButton(menu.view, many.first().title) }
                val next = buttonCenter(menu.view, R.string.radial_next_page)
                TouchStream().apply {
                    send(MotionEvent.ACTION_DOWN, next)
                    send(MotionEvent.ACTION_UP, next)
                }
                assertVisibleActions(many.drop(count))
                val points = AtomicReference<List<Point>>()
                instrumentation.runOnMainSync {
                    assertFalse(pageButton(menu.view, R.string.radial_next_page).isEnabled)
                    staleFirst.performClick()
                    points.set(many.drop(count).map { screenCenter(actionButton(menu.view, it.title)) })
                }
                assertTrue("A button from the previous page must not execute", menu.executed.isEmpty())
                // Isolate these count combinations from proven system resampling; existing tests inject full touch streams.
                val downTime = SystemClock.uptimeMillis()
                fun dispatch(action: Int, point: Point) {
                    instrumentation.runOnMainSync {
                        val origin = IntArray(2)
                        menu.view.getLocationOnScreen(origin)
                        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action,
                            point.x - origin[0], point.y - origin[1], 0).apply {
                            source = InputDevice.SOURCE_TOUCHSCREEN
                        }
                        try { assertTrue(menu.view.dispatchTouchEvent(event)) } finally { event.recycle() }
                    }
                }
                dispatch(MotionEvent.ACTION_DOWN, menu.center)
                dispatch(MotionEvent.ACTION_MOVE, points.get()[0])
                assertCenter(menu.view) {
                    val detail = "count=$count GTA=$gta expected=${many[count].title} actual=$it center=${menu.center} points=${points.get()}"
                    assertTrue("First second-page action should be highlighted; $detail", it.contains(many[count].title))
                    if (gta) assertTrue("First global slot should match; $detail", it.contains("SLOT %02d".format(Locale.ROOT, count + 1)))
                }
                dispatch(MotionEvent.ACTION_MOVE, points.get()[1])
                assertCenter(menu.view) {
                    val detail = "count=$count GTA=$gta expected=${many[count + 1].title} actual=$it center=${menu.center} points=${points.get()}"
                    assertTrue("Second second-page action should be highlighted; $detail", it.contains(many[count + 1].title))
                    if (gta) assertTrue("Second global slot should match; $detail", it.contains("SLOT %02d".format(Locale.ROOT, count + 2)))
                }
                assertTrue(menu.executed.isEmpty())
                dispatch(MotionEvent.ACTION_UP, points.get()[1])
                assertEquals(listOf(many[count + 1].id), menu.executed.toList())
                assertEquals(0, menu.dismissals.get())
            }
        }
    }

    @Test fun gtaAccessibleClicksExecuteOnlyOnceUntilTheHostBeginsANewSession() {
        withMenu(gtaMode = true) { menu ->
            instrumentation.runOnMainSync {
                val first = actionButton(menu.view, fixtureActions[0].title)
                first.performClick()
                first.performClick()
                actionButton(menu.view, fixtureActions[1].title).performClick()
            }
            assertEquals("Repeated accessibility or keyboard clicks belong to one menu session",
                listOf(fixtureActions[0].id), menu.executed.toList())

            instrumentation.runOnMainSync {
                menu.view.beginInteractionSession()
                val second = actionButton(menu.view, fixtureActions[1].title)
                second.performClick()
                second.performClick()
            }
            assertEquals("An explicit new session permits one new action",
                listOf(fixtureActions[0].id, fixtureActions[1].id), menu.executed.toList())
        }
    }

    @Test fun mouseHoverOverAnActionButtonUpdatesTheGtaPreviewWithoutExecuting() {
        withMenu(gtaMode = true) { menu ->
            fun hover(action: Int) {
                instrumentation.runOnMainSync {
                    val buttonCenter = screenCenter(actionButton(menu.view, fixtureActions[1].title))
                    val menuOrigin = IntArray(2)
                    menu.view.getLocationOnScreen(menuOrigin)
                    val now = SystemClock.uptimeMillis()
                    val event = MotionEvent.obtain(now, now, action,
                        buttonCenter.x - menuOrigin[0], buttonCenter.y - menuOrigin[1], 0)
                    event.source = InputDevice.SOURCE_MOUSE
                    try { menu.view.dispatchGenericMotionEvent(event) } finally { event.recycle() }
                }
            }

            // Exercise ViewGroup dispatch with a child Button directly under the pointer.
            hover(MotionEvent.ACTION_HOVER_MOVE)
            assertCenter(menu.view) { assertTrue(it.contains(fixtureActions[1].title)) }
            instrumentation.runOnMainSync {
                val button = actionButton(menu.view, fixtureActions[1].title)
                assertEquals(1.22f, button.scaleX, 0.001f)
                assertEquals(1.22f, button.scaleY, 0.001f)
            }
            assertTrue("Hovering must never execute an action", menu.executed.isEmpty())

            hover(MotionEvent.ACTION_HOVER_EXIT)
            assertCenter(menu.view) {
                assertTrue(it.contains("ActionHalo"))
                assertFalse(it.contains(fixtureActions[1].title))
            }
            instrumentation.runOnMainSync {
                assertEquals(1f, actionButton(menu.view, fixtureActions[1].title).scaleX, 0.001f)
            }
            assertTrue(menu.executed.isEmpty())
            assertEquals(0, menu.dismissals.get())
        }
    }

    @Test fun modeDefaultsToGtaAndUiChangesSurviveRecreationAndReachIncomingMenus() {
        assertTrue(HaloAppearance.isGtaModeEnabled(context))
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.APPEARANCE)).use { scenario ->
            scenario.onActivity { activity ->
                val toggle = modeToggle(activity)
                assertTrue(toggle.isChecked)
                toggle.performClick()
                assertFalse(toggle.isChecked)
                assertFalse(HaloAppearance.isGtaModeEnabled(context))
            }
            scenario.recreate()
            scenario.onActivity { assertFalse(modeToggle(it).isChecked) }

            val incoming = Intent(context, HaloActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, "Mode persistence fixture")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val halo = instrumentation.startActivitySync(incoming) as HaloActivity
            try {
                awaitWindowFocus(halo)
                instrumentation.runOnMainSync {
                    val menu = descendants(halo.window.decorView).filterIsInstance<RadialMenuView>().single()
                    assertFalse("New incoming menus must use the saved ordinary mode", menu.gtaModeEnabled)
                }
            } finally {
                instrumentation.runOnMainSync { halo.finish() }
                instrumentation.waitForIdleSync()
            }
            scenario.onActivity { activity ->
                modeToggle(activity).performClick()
                assertTrue(HaloAppearance.isGtaModeEnabled(context))
            }
            scenario.recreate()
            scenario.onActivity { assertTrue(modeToggle(it).isChecked) }
        }
    }

    private fun withMenu(gtaMode: Boolean, actions: List<HaloAction> = fixtureActions, fontScale: Float? = null,
        check: (MenuFixture) -> Unit) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            val reference = AtomicReference<RadialMenuView>()
            val activityReference = AtomicReference<Activity>()
            val executed = CopyOnWriteArrayList<String>()
            val dismissals = AtomicInteger()
            scenario.onActivity { activity ->
                activityReference.set(activity)
                val menuContext = if (fontScale == null) activity else ContextThemeWrapper(
                    activity.createConfigurationContext(Configuration(activity.resources.configuration).apply {
                        this.fontScale = fontScale
                    }), android.R.style.Theme_Material_Light_NoActionBar)
                val menu = RadialMenuView(menuContext).apply {
                    gtaModeEnabled = gtaMode
                    selectedText = "Selected text fixture"
                    setActions(actions)
                    onActionSelected = { executed += it.id }
                    onDismiss = { dismissals.incrementAndGet() }
                }
                val surface = FrameLayout(activity)
                val size = (320 * activity.resources.displayMetrics.density).toInt()
                surface.addView(menu, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
                menu.bindTouchSurface(surface)
                activity.setContentView(surface)
                reference.set(menu)
            }
            awaitWindowFocus(activityReference.get())
            instrumentation.settleInput()
            val fixture = AtomicReference<MenuFixture>()
            scenario.onActivity {
                val menu = reference.get()
                assertTrue(menu.width > 0 && menu.height > 0)
                fixture.set(MenuFixture(menu, screenCenter(menu), actions.take(HaloAppearance.actionsPerPage(menu.context)).map { screenCenter(actionButton(menu, it.title)) }, executed, dismissals))
            }
            check(fixture.get())
        }
    }

    private fun assertCenter(menu: RadialMenuView, check: (String) -> Unit) {
        instrumentation.runOnMainSync {
            val center = descendants(menu).filterIsInstance<Button>().single {
                it.left <= menu.width / 2 && it.right >= menu.width / 2 &&
                    it.top <= menu.height / 2 && it.bottom >= menu.height / 2
            }
            check(center.text.toString())
        }
    }

    private fun assertSlotNumbersAndIconsHaveSeparateInk(menu: RadialMenuView, actions: List<HaloAction>) {
        val labelsField = RadialMenuView::class.java.getDeclaredField("slotLabels").apply { isAccessible = true }
        val positionsField = RadialMenuView::class.java.getDeclaredField("slotPositions").apply { isAccessible = true }
        val geometryField = RadialMenuView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST") val labels = labelsField.get(menu) as List<String>
        @Suppress("UNCHECKED_CAST") val positions = positionsField.get(menu) as List<Pair<Float, Float>>
        val geometry = geometryField.get(menu) as RadialGeometry
        val buttons = actions.map { actionButton(menu, it.title) }
        val labelPixels = Bitmap.createBitmap(menu.width, menu.height, Bitmap.Config.ARGB_8888)
        val emptyPixels = Bitmap.createBitmap(menu.width, menu.height, Bitmap.Config.ARGB_8888)
        val originalText = menu.selectedText
        val density = menu.resources.displayMetrics.density
        fun hover(action: Int, button: Button = buttons.first()) {
            val now = SystemClock.uptimeMillis()
            val event = MotionEvent.obtain(now, now, action,
                (button.left + button.right) / 2f, (button.top + button.bottom) / 2f, 0).apply {
                source = InputDevice.SOURCE_MOUSE
            }
            try { menu.dispatchGenericMotionEvent(event) } finally { event.recycle() }
        }
        try {
            menu.selectedText = "https://example.com/"
            hover(MotionEvent.ACTION_HOVER_EXIT)
            // Compare actual draws with/without labels so font metrics, rotation and antialiasing are measured.
            buttons.forEach { it.visibility = View.INVISIBLE }
            menu.draw(Canvas(labelPixels))
            labelsField.set(menu, labels.map { "" })
            menu.draw(Canvas(emptyPixels))
            labelsField.set(menu, labels)
            buttons.forEach { it.visibility = View.VISIBLE }
            val labelOuterRadius = FloatArray(actions.size) { Float.NEGATIVE_INFINITY }
            val labelInnerRadius = FloatArray(actions.size) { Float.POSITIVE_INFINITY }
            for (y in 0 until menu.height) for (x in 0 until menu.width) {
                if (labelPixels.getPixel(x, y) == emptyPixels.getPixel(x, y)) continue
                val index = positions.indices.minBy { index ->
                    val (slotX, slotY) = positions[index]
                    hypot(x + 0.5f - slotX, y + 0.5f - slotY)
                }
                val radius = hypot(x + 0.5f - geometry.centerX, y + 0.5f - geometry.centerY)
                labelOuterRadius[index] = maxOf(labelOuterRadius[index], radius)
                labelInnerRadius[index] = minOf(labelInnerRadius[index], radius)
            }
            buttons.forEachIndexed { index, button ->
                val detail = "${actions.size} actions, slot ${labels[index]} (${actions[index].id})"
                assertTrue("The slot number must render; $detail", labelOuterRadius[index].isFinite())
                assertTrue("Slot number must stay inside its ring; $detail",
                    labelInnerRadius[index] >= geometry.innerRadius - 1f && labelOuterRadius[index] <= geometry.outerRadius + 1f)
                fun checkIcon() {
                    val bitmap = Bitmap.createBitmap(menu.width, menu.height, Bitmap.Config.ARGB_8888)
                    try {
                        Canvas(bitmap).apply {
                            translate(button.left.toFloat(), button.top.toFloat())
                            concat(button.matrix)
                            button.draw(this)
                        }
                        val bounds = RectF(0f, 0f, button.width.toFloat(), button.height.toFloat())
                        button.matrix.mapRect(bounds)
                        bounds.offset(button.left.toFloat(), button.top.toFloat())
                        var innerRadius = Float.POSITIVE_INFINITY
                        var outerRadius = Float.NEGATIVE_INFINITY
                        for (y in floor(bounds.top).toInt().coerceAtLeast(0) until ceil(bounds.bottom).toInt().coerceAtMost(menu.height)) {
                            for (x in floor(bounds.left).toInt().coerceAtLeast(0) until ceil(bounds.right).toInt().coerceAtMost(menu.width)) {
                                if (Color.alpha(bitmap.getPixel(x, y)) == 0) continue
                                val radius = hypot(x + 0.5f - geometry.centerX, y + 0.5f - geometry.centerY)
                                innerRadius = minOf(innerRadius, radius)
                                outerRadius = maxOf(outerRadius, radius)
                            }
                        }
                        assertTrue("The icon must render; $detail", innerRadius.isFinite())
                        assertTrue("Icon and slot number need 2 dp of empty space; $detail scale=${button.scaleX} gap=${(innerRadius - labelOuterRadius[index]) / density} dp",
                            innerRadius - labelOuterRadius[index] >= 2f * density)
                        assertTrue("The icon must stay inside its ring when selected; $detail scale=${button.scaleX}",
                            innerRadius >= geometry.innerRadius - 1f && outerRadius <= geometry.outerRadius + 1f)
                    } finally { bitmap.recycle() }
                }
                checkIcon()
                hover(MotionEvent.ACTION_HOVER_MOVE, button)
                assertEquals("Hover must measure the selected icon; $detail", 1.22f, button.scaleX, 0.001f)
                checkIcon()
            }
        } finally {
            labelsField.set(menu, labels)
            buttons.forEach { it.visibility = View.VISIBLE }
            hover(MotionEvent.ACTION_HOVER_EXIT)
            menu.selectedText = originalText
            labelPixels.recycle()
            emptyPixels.recycle()
        }
    }

    private fun modeToggle(activity: Activity) = descendants(activity.window.decorView)
        .filterIsInstance<CompoundButton>().single {
            it.text.toString() == activity.getString(R.string.gta_mode_title) ||
                it.contentDescription?.toString() == activity.getString(R.string.gta_mode_title)
        }

    private fun actionButton(menu: RadialMenuView, title: String) = descendants(menu)
        .filterIsInstance<Button>().single { it.contentDescription?.toString() == title }

    private fun pageButton(menu: RadialMenuView, description: Int) = actionButton(menu, context.getString(description))

    private fun buttonCenter(menu: RadialMenuView, description: Int): Point {
        val result = AtomicReference<Point>()
        instrumentation.runOnMainSync { result.set(screenCenter(pageButton(menu, description))) }
        return result.get()
    }

    private fun actionCenter(menu: RadialMenuView, title: String): Point {
        val result = AtomicReference<Point>()
        instrumentation.runOnMainSync { result.set(screenCenter(actionButton(menu, title))) }
        return result.get()
    }

    private fun pointBeyondRightEdge(menu: RadialMenuView, extraDp: Float): Point {
        val result = AtomicReference<Point>()
        instrumentation.runOnMainSync {
            val field = RadialMenuView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
            val geometry = field.get(menu) as RadialGeometry
            val center = screenCenter(menu)
            result.set(Point(center.x + geometry.outerRadius + extraDp * menu.resources.displayMetrics.density, center.y))
        }
        return result.get()
    }

    private fun assertWheelCenter(menu: RadialMenuView, expected: Point) {
        instrumentation.runOnMainSync {
            val field = RadialMenuView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
            val geometry = field.get(menu) as RadialGeometry
            val density = menu.resources.displayMetrics.density
            val visible = Rect().also(menu::getWindowVisibleDisplayFrame)
            val radius = geometry.outerRadius + 8f * density
            val footer = pageButton(menu, R.string.radial_next_page)
            val bottomExtent = if (footer.visibility == View.VISIBLE) maxOf(radius, footer.bottom - geometry.centerY) else radius
            val fittedX = expected.x.coerceIn(visible.left + radius + 4f * density, visible.right - radius - 4f * density)
            val fittedY = expected.y.coerceIn(visible.top + radius + 4f * density, visible.bottom - bottomExtent - 4f * density)
            val actual = screenCenter(menu)
            assertEquals("The visual center must keep its first safe anchor", fittedX, actual.x, 1f)
            assertEquals("The visual center must keep its first safe anchor", fittedY, actual.y, 1f)
        }
    }

    private fun wheelCenter(menu: RadialMenuView): Point {
        val result = AtomicReference<Point>()
        instrumentation.runOnMainSync { result.set(screenCenter(menu)) }
        return result.get()
    }

    private fun assertOutsideMenu(menu: RadialMenuView, point: Point) {
        instrumentation.runOnMainSync {
            val origin = IntArray(2)
            menu.getLocationOnScreen(origin)
            assertTrue("The press must begin outside the previous menu rectangle",
                point.x < origin[0] || point.x >= origin[0] + menu.width ||
                    point.y < origin[1] || point.y >= origin[1] + menu.height)
        }
    }

    private fun screenCenter(view: View): Point {
        val origin = IntArray(2)
        view.getLocationOnScreen(origin)
        return Point(origin[0] + view.width / 2f, origin[1] + view.height / 2f)
    }

    private fun availableBounds(menu: RadialMenuView): Rect {
        val result = AtomicReference<Rect>()
        instrumentation.runOnMainSync {
            val surface = menu.parent as View
            val surfaceOrigin = IntArray(2)
            surface.getLocationOnScreen(surfaceOrigin)
            val available = Rect()
            surface.getWindowVisibleDisplayFrame(available)
            assertTrue(available.intersect(surfaceOrigin[0], surfaceOrigin[1],
                surfaceOrigin[0] + surface.width, surfaceOrigin[1] + surface.height))
            if (Build.VERSION.SDK_INT >= 30) {
                val window = surface.rootView
                val windowOrigin = IntArray(2)
                window.getLocationOnScreen(windowOrigin)
                val bars = requireNotNull(window.rootWindowInsets).getInsets(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                assertTrue(available.intersect(windowOrigin[0] + bars.left, windowOrigin[1] + bars.top,
                    windowOrigin[0] + window.width - bars.right, windowOrigin[1] + window.height - bars.bottom))
            }
            val inset = (24 * surface.resources.displayMetrics.density).toInt()
            available.inset(inset, inset)
            assertFalse("The app must expose a touchable area outside the system bars", available.isEmpty)
            result.set(available)
        }
        return result.get()
    }

    private inner class TouchStream {
        private val downTime = SystemClock.uptimeMillis()

        fun send(action: Int, point: Point) = sendMulti(action, 0 to point)

        fun sendOnSurface(menu: RadialMenuView, action: Int, point: Point, history: List<Point> = emptyList()) {
            instrumentation.runOnMainSync {
                val surface = menu.parent as View
                val origin = IntArray(2)
                surface.getLocationOnScreen(origin)
                val samples = history + point
                val now = SystemClock.uptimeMillis()
                val first = samples.first()
                val event = MotionEvent.obtain(downTime, now, MotionEvent.ACTION_MOVE,
                    first.x - origin[0], first.y - origin[1], 0).apply {
                    source = InputDevice.SOURCE_TOUCHSCREEN
                    samples.drop(1).forEachIndexed { index, sample ->
                        addBatch(now + index + 1L, sample.x - origin[0], sample.y - origin[1], 1f, 1f, 0)
                    }
                    this.action = action
                }
                try { assertTrue(surface.dispatchTouchEvent(event)) } finally { event.recycle() }
            }
            instrumentation.settleInput()
        }

        fun sendMulti(action: Int, vararg points: Pair<Int, Point>) {
            val properties = points.map { (id, _) -> MotionEvent.PointerProperties().apply {
                this.id = id
                toolType = MotionEvent.TOOL_TYPE_FINGER
            } }.toTypedArray()
            val coordinates = points.map { (_, point) -> MotionEvent.PointerCoords().apply {
                x = point.x
                y = point.y
                pressure = 1f
                size = 1f
            } }.toTypedArray()
            val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, points.size,
                properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { instrumentation.sendPointerSync(event) } finally { event.recycle() }
            instrumentation.settleInput()
        }
    }

    private fun awaitWindowFocus(activity: Activity) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            instrumentation.waitForIdleSync()
            var focused = false
            instrumentation.runOnMainSync { focused = activity.window.decorView.hasWindowFocus() }
            if (focused) return
            SystemClock.sleep(25)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("Expected ${activity.javaClass.simpleName} to gain window focus")
    }

    private fun descendants(root: View): List<View> = buildList {
        add(root)
        if (root is ViewGroup) for (index in 0 until root.childCount) addAll(descendants(root.getChildAt(index)))
    }

    private data class Point(val x: Float, val y: Float)
    private data class MenuFixture(
        val view: RadialMenuView,
        val center: Point,
        val actions: List<Point>,
        val executed: CopyOnWriteArrayList<String>,
        val dismissals: AtomicInteger,
    )
}
