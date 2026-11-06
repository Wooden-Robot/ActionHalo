package com.actionhalo.android

import android.app.UiAutomation
import android.content.Context
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HaloPageSizeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val settings get() = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
    private var previousValue: Any? = null

    @Before fun savePageSize() {
        previousValue = settings.all[HaloAppearance.ACTIONS_PER_PAGE_KEY]
        assertTrue(settings.edit().remove(HaloAppearance.ACTIONS_PER_PAGE_KEY).commit())
    }

    @After fun restorePageSize() {
        val key = HaloAppearance.ACTIONS_PER_PAGE_KEY
        val editor = settings.edit()
        when (val value = previousValue) {
            is Int -> editor.putInt(key, value)
            is String -> editor.putString(key, value)
            is Boolean -> editor.putBoolean(key, value)
            is Long -> editor.putLong(key, value)
            is Float -> editor.putFloat(key, value)
            is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
            else -> editor.remove(key)
        }
        assertTrue(editor.commit())
    }

    @Test fun absentOrInvalidStoredPageSizesKeepTheExistingEightActionLayout() {
        assertEquals(8, HaloAppearance.actionsPerPage(context))
        for (invalid in listOf(0, -1, 7, 9, Int.MAX_VALUE)) {
            assertTrue(settings.edit().putInt(HaloAppearance.ACTIONS_PER_PAGE_KEY, invalid).commit())
            assertEquals(8, HaloAppearance.actionsPerPage(context))
        }
        assertTrue(settings.edit().putString(HaloAppearance.ACTIONS_PER_PAGE_KEY, "12").commit())
        assertEquals(8, HaloAppearance.actionsPerPage(context))
    }

    @Test fun desktopPageSizesPersistAndUnsupportedValuesDoNotOverwriteTheChoice() {
        assertEquals(listOf(6, 8, 12, 16), HaloAppearance.ACTION_COUNTS)
        for (count in HaloAppearance.ACTION_COUNTS) {
            HaloAppearance.setActionsPerPage(context, count)
            assertEquals(count, HaloAppearance.actionsPerPage(context.applicationContext))
            assertEquals(count, settings.getInt(HaloAppearance.ACTIONS_PER_PAGE_KEY, -1))
        }
        try {
            HaloAppearance.setActionsPerPage(context, 10)
            fail("Unsupported counts must be rejected")
        } catch (_: IllegalArgumentException) { }
        assertEquals(16, HaloAppearance.actionsPerPage(context))
    }

    @Test fun homePagePickerSavesTheChoiceAndShowsItAfterRecreation() {
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.APPEARANCE)).use { scenario ->
            scenario.onActivity { activity ->
                assertTrue(descendants(activity.window.decorView).filterIsInstance<Button>().single {
                    it.text.toString() == activity.getString(R.string.page_size_current, 8)
                }.performClick())
            }
            val label = context.getString(R.string.page_size_option, 12)
            val deadline = SystemClock.uptimeMillis() + 5_000
            var selected = false
            do {
                val option = automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(label)
                    ?.firstOrNull { it.text?.toString() == label && it.isVisibleToUser }
                if (option != null) {
                    selected = option.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    if (selected) break
                }
                SystemClock.sleep(30)
            } while (SystemClock.uptimeMillis() < deadline)
            assertTrue("The native picker must expose the twelve-action choice", selected)
            instrumentation.waitForIdleSync()
            assertEquals(12, HaloAppearance.actionsPerPage(context))
            scenario.recreate()
            scenario.onActivity { activity ->
                assertTrue(descendants(activity.window.decorView).filterIsInstance<Button>().any {
                    it.text.toString() == activity.getString(R.string.page_size_current, 12)
                })
            }
        }
    }

    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) addAll(descendants(view.getChildAt(index)))
    }
}
