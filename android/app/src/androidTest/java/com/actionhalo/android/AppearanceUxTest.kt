package com.actionhalo.android

import android.content.Context
import android.graphics.Rect
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

    @Test fun selectionControlsNeverShrinkTheWheelAndFreeSpaceRestoresIt() {
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
            assertEquals(View.INVISIBLE, menu.visibility)
            assertTrue(window.params.flags and android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE != 0)
            window.updateProtectedAreas(emptyList())
            assertEquals(originalSize, window.params.width)
            assertEquals(View.VISIBLE, menu.visibility)
            assertEquals(0, window.params.flags and android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
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
