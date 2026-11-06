package com.actionhalo.android

import android.view.View
import android.widget.CheckedTextView
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import org.junit.Assert.*
import org.junit.Test

class AppChoiceLabelsTest {
    @Test fun recycledSingleChoiceRowsKeepTheirPaddingAndCheckmarkAndClearOldIcons() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            for (direction in listOf(View.LAYOUT_DIRECTION_LTR, View.LAYOUT_DIRECTION_RTL)) {
                val parent = FrameLayout(activity).apply { layoutDirection = direction }
                activity.setContentView(parent)
                val adapter = AppChoiceLabels(activity).adapter(listOf(
                    activity.packageName to "ActionHalo", null to "System default"
                ), android.R.layout.simple_list_item_single_choice)
                val row = adapter.getView(0, null, parent) as CheckedTextView
                parent.addView(row)
                row.isChecked = true
                measure(parent)
                val padding = row.paddingStart to row.paddingEnd
                val checkmark = row.checkMarkDrawable
                assertNotNull(checkmark)
                assertNotNull(row.compoundDrawablesRelative[0])
                repeat(12) { index ->
                    val position = (index + 1) % 2
                    assertSame(row, adapter.getView(position, row, parent))
                    measure(parent)
                    assertEquals("Rebinding must not accumulate the system checkmark padding", padding,
                        row.paddingStart to row.paddingEnd)
                    assertSame(checkmark, row.checkMarkDrawable)
                    assertTrue(row.isChecked)
                    if (position == 0) assertNotNull(row.compoundDrawablesRelative[0])
                    else {
                        assertEquals("System default", row.text.toString())
                        assertNull("A non-app entry must not retain the previous app icon", row.compoundDrawablesRelative[0])
                    }
                }
            }
        } }
    }

    @Test fun blankNamesAndUninstalledAppsStillShowAReadablePackageAndIcon() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario -> scenario.onActivity { activity ->
            val missing = "com.actionhalo.fixture.uninstalled"
            val parent = FrameLayout(activity)
            activity.setContentView(parent)
            val adapter = AppChoiceLabels(activity).adapter(listOf(
                activity.packageName to "   ", missing to missing
            ), android.R.layout.simple_list_item_single_choice)
            val row = adapter.getView(0, null, parent) as CheckedTextView
            parent.addView(row)
            measure(parent)
            assertEquals(activity.packageName, row.text.toString())
            assertNotNull(row.compoundDrawablesRelative[0])
            adapter.getView(1, row, parent)
            measure(parent)
            assertEquals(missing, row.text.toString())
            val fallback = row.compoundDrawablesRelative[0]
            assertNotNull("An uninstalled saved app must remain recognizable as an app entry", fallback)
            assertTrue(fallback!!.bounds.width() > 0 && fallback.bounds.height() > 0)
            assertTrue(row.measuredHeight >= HaloUi.dp(activity, 64))
            assertNotNull(row.layout)
            assertTrue(row.layout.getLineWidth(0) > 0f)
        } }
    }

    private fun measure(parent: FrameLayout) {
        val width = HaloUi.dp(parent.context, 320)
        parent.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        parent.layout(0, 0, width, parent.measuredHeight)
    }
}
