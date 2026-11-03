package com.actionhalo.android

import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import android.widget.Button
import android.widget.CheckBox
import androidx.test.core.app.ActivityScenario
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@SdkSuppress(minSdkVersion = 29)
class AppRulesUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val prefs = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE)
    private val actionPrefs = context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE)
    private var previousRules: Map<String, *> = emptyMap<String, Any?>()
    private var previousActions: Map<String, *> = emptyMap<String, Any?>()
    private lateinit var automation: UiAutomation
    private val source = "com.example.profiledrag"
    private val original = listOf("copy", "google", "translate")
    @Before fun isolate() {
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        previousRules = prefs.all.toMap()
        previousActions = actionPrefs.all.toMap()
        assertTrue(prefs.edit().clear().commit())
        assertTrue(actionPrefs.edit().clear().commit())
        AppRulesStore(context).setProfile(source, AppRulesStore.Profile(actions = original))
    }
    @After fun restore() {
        listOf(prefs to previousRules, actionPrefs to previousActions).forEach { (preferences, values) ->
            val edit = preferences.edit().clear()
            values.forEach { (key, value) -> when (value) {
                is String -> edit.putString(key, value)
                is Long -> edit.putLong(key, value)
                is Int -> edit.putInt(key, value)
                is Boolean -> edit.putBoolean(key, value)
                is Float -> edit.putFloat(key, value)
            } }
            assertTrue(edit.commit())
        }
    }

    @Test fun profileDraggingRestoresCancelledDragAndSavesOnlyAfterBothConfirmations() {
        val moved = listOf("copy", "translate", "google")
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.TRIGGERS)).use { scenario ->
            var profileRoot = openProfile(scenario)
            var actionRoot = openActions(profileRoot)
            drag(actionRoot, cancel = true) { assertEquals(moved, rowIds(actionRoot).take(3)) }
            instrumentation.runOnMainSync { assertEquals(original, rowIds(actionRoot).take(3)) }
            drag(actionRoot, cancel = false) { assertEquals(moved, rowIds(actionRoot).take(3)) }
            assertEquals(original, AppRulesStore(context).profile(source).actions)
            clickDialog(actionRoot, android.R.id.button1)
            assertEquals(original, AppRulesStore(context).profile(source).actions)
            clickDialog(profileRoot, android.R.id.button2)
            assertEquals(original, AppRulesStore(context).profile(source).actions)
            profileRoot = openProfile(scenario)
            actionRoot = openActions(profileRoot)
            drag(actionRoot, cancel = false) { assertEquals(moved, rowIds(actionRoot).take(3)) }
            clickDialog(actionRoot, android.R.id.button1)
            clickDialog(profileRoot, android.R.id.button1)
            assertEquals(moved, AppRulesStore(context).profile(source).actions)
        }
    }

    @Test fun nestedActionDraftSurvivesRecreationWithoutApplyingUntilBothDialogsAreConfirmed() {
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.TRIGGERS)).use { scenario ->
            val profileRoot = openProfile(scenario)
            val actionRoot = openActions(profileRoot)
            instrumentation.runOnMainSync {
                descendants(actionRoot).filterIsInstance<CheckBox>()
                    .single { (it.parent as? View)?.tag == "copy" }.isChecked = false
                val translation = ActionStore(context).allActions().single { it.id == "translate" }
                descendants(actionRoot).filterIsInstance<Button>().single {
                    it.contentDescription?.toString() == context.getString(R.string.app_rules_move_up, translation.title)
                }.performClick()
                assertEquals(listOf("copy", "translate", "google"), rowIds(actionRoot).take(3))
            }
            scenario.recreate()
            instrumentation.waitForIdleSync()
            lateinit var restoredActions: View
            lateinit var restoredProfile: View
            scenario.onActivity { activity -> restoredProfile = AppSettingsDrafts.dialogs(activity).last().window!!.decorView }
            instrumentation.runOnMainSync {
                restoredActions = WindowInspector.getGlobalWindowViews().last { window -> descendants(window).any {
                    it is CheckBox && (it.parent as? View)?.tag == "google"
                } }
                assertEquals(listOf("copy", "translate", "google"), rowIds(restoredActions).take(3))
                assertFalse(descendants(restoredActions).filterIsInstance<CheckBox>()
                    .single { (it.parent as? View)?.tag == "copy" }.isChecked)
            }
            assertEquals(original, AppRulesStore(context).profile(source).actions)
            clickDialog(restoredActions, android.R.id.button1)
            assertEquals(original, AppRulesStore(context).profile(source).actions)
            clickDialog(restoredProfile, android.R.id.button1)
            assertEquals(listOf("translate", "google"), AppRulesStore(context).profile(source).actions)
        }
    }

    private fun openProfile(scenario: ActivityScenario<MainActivity>): View {
        scenario.onActivity { activity ->
            AppRulesSettings::class.java.getDeclaredMethod("editProfile", String::class.java).apply { isAccessible = true }
                .invoke(AppRulesSettings(activity), source)
        }
        instrumentation.waitForIdleSync()
        var root: View? = null
        instrumentation.runOnMainSync {
            root = WindowInspector.getGlobalWindowViews().last { window ->
                descendants(window).filterIsInstance<Button>().any {
                    it.text.toString() == context.getString(R.string.app_rules_actions_count, original.size)
                }
            }
        }
        return checkNotNull(root)
    }

    private fun openActions(profileRoot: View): View {
        instrumentation.runOnMainSync {
            assertTrue(descendants(profileRoot).filterIsInstance<Button>().single {
                it.text.toString() == context.getString(R.string.app_rules_actions_count, original.size)
            }.performClick())
        }
        instrumentation.waitForIdleSync()
        var root: View? = null
        instrumentation.runOnMainSync {
            root = WindowInspector.getGlobalWindowViews().last { window -> descendants(window).any { it is CheckBox && it.parent is View && (it.parent as View).tag == "google" } }
        }
        return checkNotNull(root)
    }

    private fun drag(root: View, cancel: Boolean, preview: () -> Unit) {
        lateinit var start: Rect
        lateinit var end: Rect
        instrumentation.runOnMainSync {
            fun bounds(id: String): Rect {
                val checkbox = descendants(root).filterIsInstance<CheckBox>().single { (it.parent as? View)?.tag == id }
                val location = IntArray(2).also(checkbox::getLocationOnScreen)
                return Rect().also {
                    assertTrue(checkbox.getLocalVisibleRect(it))
                    it.offset(location[0], location[1])
                }
            }
            start = bounds("google")
            end = bounds("translate")
        }
        val down = SystemClock.uptimeMillis()
        val x = start.exactCenterX()
        val y = start.exactCenterY()
        val targetY = end.top + end.height() * 0.75f
        inject(down, MotionEvent.ACTION_DOWN, x, y)
        SystemClock.sleep(ViewConfiguration.getLongPressTimeout().toLong() + 150)
        for (step in 1..10) {
            inject(down, MotionEvent.ACTION_MOVE, x, y + (targetY - y) * step / 10f)
            SystemClock.sleep(25)
        }
        instrumentation.waitForIdleSync()
        try {
            instrumentation.runOnMainSync {
                val row = descendants(root).single { it.tag == "google" }
                val checkbox = descendants(row).filterIsInstance<CheckBox>().single()
                assertTrue("Long-press must start native drag: focus=${root.hasWindowFocus()} enabled=${checkbox.isEnabled} " +
                    "longClickable=${checkbox.isLongClickable} alpha=${row.alpha} start=$start end=$end", row.alpha < 1f)
                preview()
            }
            assertEquals(original, AppRulesStore(context).profile(source).actions)
        } finally {
            try {
                if (cancel) instrumentation.runOnMainSync { root.cancelDragAndDrop() }
            } finally {
                // Cancelling the native drag does not release the injected touch pointer.
                inject(down, MotionEvent.ACTION_UP, x, targetY)
            }
            val until = SystemClock.uptimeMillis() + 3_000
            var dragging: Boolean
            do {
                dragging = false
                instrumentation.runOnMainSync { dragging = descendants(root).any { it.tag == "google" && it.alpha < 1f } }
                if (dragging) SystemClock.sleep(25)
            } while (dragging && SystemClock.uptimeMillis() < until)
            assertFalse("The drag must finish and restore row opacity", dragging)
        }
    }

    private fun clickDialog(root: View, id: Int) {
        instrumentation.runOnMainSync { assertTrue(descendants(root).filterIsInstance<Button>().single { it.id == id }.performClick()) }
        instrumentation.waitForIdleSync()
    }
    private fun rowIds(root: View): List<String> = descendants(root).filterIsInstance<CheckBox>().mapNotNull { (it.parent as? View)?.tag as? String }
    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) addAll(descendants(view.getChildAt(index)))
    }
    private fun inject(down: Long, action: Int, x: Float, y: Float) {
        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
        try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
    }
}
