package com.actionhalo.android

import android.content.Context
import android.graphics.Rect
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class AppearanceUxTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val prefs = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
    private var saved: Map<String, *> = emptyMap<String, Any?>()

    @Before fun isolate() { saved = prefs.all.toMap(); assertTrue(prefs.edit().clear().commit()) }
    @After fun restore() {
        val edit = prefs.edit().clear()
        saved.forEach { (key, value) -> when (value) {
            is Boolean -> edit.putBoolean(key, value)
            is Int -> edit.putInt(key, value)
            is Long -> edit.putLong(key, value)
            is Float -> edit.putFloat(key, value)
            is String -> edit.putString(key, value)
        } }
        assertTrue(edit.commit())
    }

    @Test fun dockedKeyboardLeavesAnUnobstructedWheelInsideNonzeroWindowBounds() {
        val screen = Rect(100, 200, 1100, 1800)
        val keyboard = Rect(100, 1100, 1100, 1800)
        for (position in HaloAppearance.InitialPosition.entries) {
            val frame = HaloSafeArea.initialFrame(screen, Rect(300, 600, 700, 650), 400, 8, position,
                listOf(keyboard))
            assertEquals(400, frame.width())
            assertTrue(screen.contains(frame))
            assertFalse(Rect.intersects(frame, keyboard))
            assertTrue(frame.bottom <= keyboard.top - 8)
        }
    }

    @Test fun floatingKeyboardDoesNotDiscardFreeSpaceBesideAndBelowIt() {
        val screen = Rect(0, 0, 1000, 1600)
        val keyboard = Rect(550, 650, 980, 1050)
        val frame = HaloSafeArea.initialFrame(screen, null, 400, 8,
            HaloAppearance.InitialPosition.LEFT, listOf(keyboard))
        assertEquals(400, frame.width())
        assertEquals(8, frame.left)
        assertEquals(1592, frame.bottom)
        assertFalse(Rect.intersects(frame, keyboard))
    }

    @Test fun automaticPlacementKeepsSelectionClearAndHandedPreferencesStayInsideSmallWindows() {
        val screen = Rect(20, 40, 620, 940)
        val source = Rect(100, 200, 300, 240)
        val auto = HaloSafeArea.initialFrame(screen, source, 400, 8, HaloAppearance.InitialPosition.AUTO)
        assertEquals(248, auto.top)
        assertFalse(Rect.intersects(auto, source))
        val left = HaloSafeArea.initialFrame(screen, null, 320, 8, HaloAppearance.InitialPosition.LEFT)
        val right = HaloSafeArea.initialFrame(screen, null, 320, 8, HaloAppearance.InitialPosition.RIGHT)
        assertEquals(left.top, right.top)
        assertTrue(left.left < right.left)
        val small = Rect(200, 80, 410, 460)
        val smallFrame = HaloSafeArea.initialFrame(small, null, 480, 8, HaloAppearance.InitialPosition.RIGHT)
        assertEquals(194, smallFrame.width())
        assertTrue(small.contains(smallFrame))
    }

    @Test fun selectionControlsHideAnUnusableWindowAndFreeSpaceRestoresIt() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val manager = context.getSystemService(android.view.WindowManager::class.java)
            val menu = RadialMenuView(context)
            val window = SelectionHaloWindow(context, manager, Rect(0, 0, 500, 600), Rect(), menu)
            val originalSize = window.params.width
            val exactFit = Rect(0, 0, 500, 600 - originalSize)
            window.updateProtectedAreas(listOf(exactFit))
            assertEquals(View.VISIBLE, menu.visibility)
            assertEquals(originalSize, window.params.width)
            assertEquals("The full-size wheel must fit just below the protected area", exactFit.bottom, window.params.y)
            window.updateProtectedAreas(listOf(Rect(0, 280, 500, 320)))
            assertEquals("The setting must remain stable when no full-size placement fits", originalSize, window.params.width)
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                assertEquals("A protected area must not hide the entire wheel when regional touch pass-through is available",
                    View.VISIBLE, menu.visibility)
                assertEquals(0, window.params.flags and android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
            } else {
                assertEquals(View.INVISIBLE, menu.visibility)
                assertTrue(window.params.flags and android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE != 0)
            }
            window.updateProtectedAreas(emptyList())
            assertEquals(originalSize, window.params.width)
            assertEquals(View.VISIBLE, menu.visibility)
            assertEquals(0, window.params.flags and android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        }
    }

    @Test fun olderWindowsFitACompactMenuAndFreezeItsSizeForNonTouchControls() {
        org.junit.Assume.assumeTrue(android.os.Build.VERSION.SDK_INT < 33)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            fun dp(value: Int) = HaloUi.dp(context, value)
            val manager = context.getSystemService(android.view.WindowManager::class.java)
            val screen = Rect(0, 0, dp(600), dp(800))
            val obstacle = Rect(0, dp(220), screen.right, dp(580))
            HaloAppearance.setActionsPerPage(context, 16)
            for (trigger in listOf(R.string.radial_next_page, R.string.source_app_options)) {
                val menu = RadialMenuView(context).apply {
                    setActions((1..18).map { HaloAction("compact-$it", "Compact $it", "", ActionType.COPY) })
                }
                SourceAppControls.bind(menu, "com.example.compact") { }
                val window = SelectionHaloWindow(context, manager, screen, Rect(), menu)
                val originalSize = window.params.width
                window.updateProtectedAreas(listOf(obstacle))
                val compactSize = window.params.width
                assertTrue(compactSize < originalSize)
                assertTrue(compactSize >= dp(180))
                assertEquals(View.VISIBLE, menu.visibility)
                assertFalse(Rect.intersects(obstacle, Rect(window.params.x, window.params.y,
                    window.params.x + compactSize, window.params.y + compactSize)))
                fun layout() {
                    window.root.measure(View.MeasureSpec.makeMeasureSpec(window.params.width, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(window.params.height, View.MeasureSpec.EXACTLY))
                    window.root.layout(0, 0, window.params.width, window.params.height)
                }
                layout()
                val actions = (0 until menu.childCount).map(menu::getChildAt).filterIsInstance<Button>()
                    .filter { it.contentDescription?.startsWith("Compact ") == true }
                assertEquals(4, actions.size)
                val options = (0 until menu.childCount).map(menu::getChildAt).filterIsInstance<Button>()
                    .single { it.contentDescription == context.getString(R.string.source_app_options) }
                val optionsBounds = Rect(options.left, options.top, options.right, options.bottom)
                assertTrue(Rect(0, 0, menu.width, menu.height).contains(optionsBounds))
                assertTrue(actions.all { it.height >= dp(40) && !Rect.intersects(optionsBounds,
                    Rect(it.left, it.top, it.right, it.bottom)) })
                window.updateProtectedAreas(emptyList())
                assertEquals(originalSize, window.params.width)
                window.updateProtectedAreas(listOf(Rect(0, dp(170), screen.right, dp(630))))
                assertEquals(View.INVISIBLE, menu.visibility)
                assertTrue(window.params.flags and android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE != 0)
                window.updateProtectedAreas(listOf(obstacle))
                layout()
                val button = (0 until menu.childCount).map(menu::getChildAt).filterIsInstance<Button>()
                    .single { it.contentDescription == context.getString(trigger) }
                button.performClick()
                assertEquals(android.view.WindowManager.LayoutParams.MATCH_PARENT, window.params.width)
                val frozen = menu.layoutParams as FrameLayout.LayoutParams
                val frozenBounds = Rect(frozen.leftMargin, frozen.topMargin,
                    frozen.leftMargin + frozen.width, frozen.topMargin + frozen.height)
                window.updateProtectedAreas(emptyList())
                val after = menu.layoutParams as FrameLayout.LayoutParams
                assertEquals(frozenBounds, Rect(after.leftMargin, after.topMargin,
                    after.leftMargin + after.width, after.topMargin + after.height))
                assertEquals(compactSize, after.width)
                assertEquals(16, HaloAppearance.actionsPerPage(context))
                assertEquals(HaloAppearance.MENU_SIZE_DP, HaloAppearance.menuSizeDp(context))
            }
        }
    }

    @Test fun hiddenSelectionWheelRejectsQueuedTouchesWithoutMovingOrExpanding() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val menu = RadialMenuView(context)
            var outsideTouches = 0
            val window = SelectionHaloWindow(context, context.getSystemService(android.view.WindowManager::class.java),
                Rect(0, 0, 1080, 2340), Rect(0, 0, 300, 100), menu, onOutsideTouch = { outsideTouches++ })
            val size = window.params.width
            window.root.measure(View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY))
            window.root.layout(0, 0, size, size)
            window.updateSelectionMenu(false)
            val origin = IntArray(2).also(menu::getLocationOnScreen)
            val down = android.os.SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_OUTSIDE, MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE,
                MotionEvent.ACTION_UP, MotionEvent.ACTION_OUTSIDE)) {
                val event = MotionEvent.obtain(down, down, action, origin[0] + size / 2f, origin[1] + size / 2f, 0)
                    .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                try { window.root.dispatchTouchEvent(event) } finally { event.recycle() }
            }
            assertEquals("A queued handle touch must not expand the hidden wheel", size, window.params.width)
            assertEquals(View.INVISIBLE, menu.visibility)
            assertEquals(0f, menu.translationX, 0f)
            assertEquals(0f, menu.translationY, 0f)
            assertEquals("Outside events arriving after hide must not restart menu checks", 0, outsideTouches)
        }
    }

    @Test fun queuedSelectionHandleTouchBeforeRelayoutDoesNotRepositionTheWheel() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val menu = RadialMenuView(context).apply { setActions(ActionStore(context).actions()) }
            val window = SelectionHaloWindow(context, context.getSystemService(android.view.WindowManager::class.java),
                Rect(0, 0, 1080, 2340), Rect(0, 0, 300, 100), menu)
            val size = window.params.width
            window.root.measure(View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY))
            window.root.layout(0, 0, size, size)
            val origin = IntArray(2).also(menu::getLocationOnScreen)
            val x = origin[0] + size * .2f
            val y = origin[1] + size * .2f
            window.updateProtectedAreas(listOf(Rect(x.toInt() - 16, y.toInt() - 16, x.toInt() + 16, y.toInt() + 16)))
            assertEquals("The wheel can remain visible at its newly requested safe position", View.VISIBLE, menu.visibility)
            val down = android.os.SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(down, down, action, x, y, 0)
                    .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
                try { window.root.dispatchTouchEvent(event) } finally { event.recycle() }
            }
            assertEquals("A queued selection-handle touch must not activate the action surface", size, window.params.width)
            assertEquals(0f, menu.translationX, 0f)
            assertEquals(0f, menu.translationY, 0f)
        }
    }

    @Test fun initialPositionIsValidatedAndResetUndoRestoresOnlyAppearance() {
        assertEquals(HaloAppearance.InitialPosition.AUTO, HaloAppearance.initialPosition(context))
        assertTrue(prefs.edit().putString(HaloAppearance.INITIAL_POSITION_KEY, "unknown").commit())
        assertEquals(HaloAppearance.InitialPosition.AUTO, HaloAppearance.initialPosition(context))
        HaloAppearance.setInitialPosition(context, HaloAppearance.InitialPosition.LEFT)
        HaloAppearance.setMenuSizeDp(context, 320)
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            var undo: (() -> Unit)? = null
            val content = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            AppearanceSettings(activity) { undo = it }.addControls(content)
            descendants(content).filterIsInstance<Button>().single {
                it.text.toString() == activity.getString(R.string.halo_reset)
            }.performClick()
            assertEquals(HaloAppearance.InitialPosition.AUTO, HaloAppearance.initialPosition(context))
            assertEquals(400, HaloAppearance.menuSizeDp(context))
            assertNotNull(undo)
            assertTrue(prefs.edit().putBoolean("auto_popup_enabled", true).commit())
            undo!!.invoke()
            assertEquals(HaloAppearance.InitialPosition.LEFT, HaloAppearance.initialPosition(context))
            assertEquals(320, HaloAppearance.menuSizeDp(context))
            assertTrue(prefs.getBoolean("auto_popup_enabled", false))
        } }
    }

    @Test fun livePreviewRefreshesAndItsActionsNeverLeaveSettings() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            val content = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            val settings = AppearanceSettings(activity)
            settings.addControls(content)
            activity.setContentView(content)
            val initial = descendants(content).filterIsInstance<RadialMenuView>().single()
            assertTrue(initial.gtaModeEnabled)
            descendants(content).filterIsInstance<Switch>().single {
                it.text.toString() == activity.getString(R.string.gta_mode_title)
            }.isChecked = false
            val wheel = descendants(content).filterIsInstance<RadialMenuView>().single()
            assertFalse(wheel.gtaModeEnabled)
            assertNotSame(initial, wheel)
            val action = ActionStore(activity).allActions().first { it.id == "copy" }
            wheel.onActionSelected!!.invoke(action)
            assertFalse(activity.isFinishing)
            assertTrue(descendants(content).filterIsInstance<TextView>().any {
                it.text.toString() == activity.getString(R.string.halo_preview_selected, action.title)
            })
            wheel.onDismiss!!.invoke()
            assertEquals(View.INVISIBLE, wheel.visibility)
            descendants(content).filterIsInstance<Button>().single {
                it.text.toString() == activity.getString(R.string.halo_preview_restart)
            }.performClick()
            assertEquals(View.VISIBLE, descendants(content).filterIsInstance<RadialMenuView>().single().visibility)
        } }
    }

    @Test fun aLaterAppearanceEditInvalidatesTheResetUndo() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            var undo: (() -> Unit)? = null
            val content = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            AppearanceSettings(activity, onChanged = { undo = null }, onReset = { undo = it }).addControls(content)
            descendants(content).filterIsInstance<Button>().single {
                it.text.toString() == activity.getString(R.string.halo_reset)
            }.performClick()
            assertNotNull(undo)
            descendants(content).filterIsInstance<Switch>().single {
                it.text.toString() == activity.getString(R.string.gta_mode_title)
            }.isChecked = false
            assertNull(undo)
            assertFalse(HaloAppearance.isGtaModeEnabled(context))
        } }
    }

    @Test fun pinnedPreviewKeepsRefreshingAfterItLeavesTheScrollingControls() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            val controls = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            val settings = AppearanceSettings(activity)
            settings.addControls(controls)
            val initial = descendants(controls).filterIsInstance<RadialMenuView>().single()
            val pinned = settings.takePinnedPreview()
            assertTrue(descendants(pinned).contains(initial))
            assertFalse(descendants(controls).contains(initial))
            assertNull(pinned.parent)
            val outer = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(pinned)
                addView(controls)
            }
            activity.setContentView(outer)
            descendants(controls).filterIsInstance<Switch>().single {
                it.text.toString() == activity.getString(R.string.gta_mode_title)
            }.isChecked = false
            val wheel = descendants(pinned).filterIsInstance<RadialMenuView>().single()
            assertFalse(wheel.gtaModeEnabled)
            assertNotSame(initial, wheel)
            assertTrue((wheel.parent as View).layoutParams.height <= HaloUi.dp(activity, 200))
            wheel.onDismiss!!.invoke()
            descendants(pinned).filterIsInstance<Button>().single {
                it.text.toString() == activity.getString(R.string.halo_preview_restart)
            }.performClick()
            assertEquals(View.VISIBLE, descendants(pinned).filterIsInstance<RadialMenuView>().single().visibility)
        } }
    }

    @Test fun initialPlacementStopsMovingAsSoonAsAGestureBegins() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            HaloAppearance.setInitialPosition(activity, HaloAppearance.InitialPosition.LEFT)
            val root = FrameLayout(activity)
            val menu = RadialMenuView(activity).apply { setActions(ActionStore(activity).actions()) }
            root.addView(menu, FrameLayout.LayoutParams(400, 400))
            HaloSafeArea.bindInitialPlacement(root, menu)
            root.measure(View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, 800, 1200)
            val before = menu.layoutParams as FrameLayout.LayoutParams
            val expected = Rect(before.leftMargin, before.topMargin, before.width, before.height)
            menu.onInteractionStarted!!.invoke()
            HaloAppearance.setInitialPosition(activity, HaloAppearance.InitialPosition.RIGHT)
            root.layout(0, 0, 801, 1200)
            val after = menu.layoutParams as FrameLayout.LayoutParams
            assertEquals(expected, Rect(after.leftMargin, after.topMargin, after.width, after.height))
        } }
    }

    private fun descendants(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()
}
