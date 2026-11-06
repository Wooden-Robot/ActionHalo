package com.actionhalo.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.RectF
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RadialUxTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = ContextThemeWrapper(instrumentation.targetContext, android.R.style.Theme_Material_Light_NoActionBar)

    @Test fun unknownTextAllowsExplicitLinkResolutionButKnownNonLinksStayDisabled() = instrumentation.runOnMainSync {
        val link = HaloAction("link", "Link fixture", "", ActionType.OPEN_URL)
        val menu = RadialMenuView(context).apply { setActions(listOf(link)) }
        val button = actions(menu).single()
        assertFalse(button.isEnabled)
        menu.selectionTextKnown = false
        assertTrue(button.isEnabled)
        menu.selectedText = "Plain text"
        menu.selectionTextKnown = true
        assertFalse(button.isEnabled)
        menu.selectedText = "https://example.com/"
        assertTrue(button.isEnabled)
    }

    @Test fun operationStatusAllowsSelectionAndPagingButCommittedActionsNeverRepeat() = instrumentation.runOnMainSync {
        val many = (1..18).map { HaloAction("status-$it", "Fixture $it", "", ActionType.COPY) }
        val menu = RadialMenuView(context).apply { setActions(many) }
        measure(menu, 320)
        var executed = 0
        var dismissed = 0
        menu.onActionSelected = { executed++ }
        menu.onDismiss = { dismissed++ }
        menu.showOperationStatus("Waiting for the original app")
        assertTrue(buttons(menu).any { it.text.toString() == "Waiting for the original app" })
        val next = buttons(menu).single { it.contentDescription == context.getString(R.string.radial_next_page) }
        assertTrue("A waiting message must not prevent choosing a later-page action", next.isEnabled)
        val firstPageAction = actions(menu).first().contentDescription
        next.performClick()
        measure(menu, 320)
        assertNotEquals(firstPageAction, actions(menu).first().contentDescription)
        val action = actions(menu).first()
        val x = (action.left + action.right) / 2f
        val y = (action.top + action.bottom) / 2f
        touch(menu, MotionEvent.ACTION_DOWN, x, y)
        assertTrue("The waiting message stays visible while choosing an action", buttons(menu).any { it.text.toString() == "Waiting for the original app" })
        touch(menu, MotionEvent.ACTION_UP, x, y)
        assertEquals(1, executed)
        action.performClick()
        assertEquals("A submitted action must not run again while waiting", 1, executed)
        touch(menu, MotionEvent.ACTION_DOWN, menu.width / 2f, menu.height / 2f)
        touch(menu, MotionEvent.ACTION_UP, menu.width / 2f, menu.height / 2f)
        assertEquals(1, dismissed)
        menu.beginInteractionSession()
        actions(menu).first().performClick()
        assertEquals(2, executed)
    }

    @Test fun compactLayoutPreservesOrderOffersReachablePagingAndDoesNotChangeTheSavedPageSize() = instrumentation.runOnMainSync {
        val settings = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        val previous = settings.all[HaloAppearance.ACTIONS_PER_PAGE_KEY]
        try {
            HaloAppearance.setActionsPerPage(context, 16)
            val many = (1..18).map { HaloAction("compact-$it", "Fixture $it", "", ActionType.COPY) }
            for (size in listOf(180, 220)) {
                val menu = RadialMenuView(context).apply { setActions(many) }
                measure(menu, size)
                val count = if (size < 208) 2 else 4
                assertEquals(many.take(count).map { it.title }, actions(menu).map { it.contentDescription.toString() })
                val pager = buttons(menu).single { it.contentDescription == context.getString(R.string.radial_next_page) }
                assertTrue(pager.isEnabled)
                actions(menu).forEach { button ->
                    assertTrue(button.left >= 0 && button.top >= 0 && button.right <= menu.width && button.bottom <= pager.top)
                    assertTrue("Small windows still need a usable icon target", button.height >= 40 * menu.resources.displayMetrics.density)
                }
                pager.performClick()
                measure(menu, size)
                assertEquals(many.drop(count).take(count).map { it.title }, actions(menu).map { it.contentDescription.toString() })
                assertEquals(16, HaloAppearance.actionsPerPage(context))
                val executed = mutableListOf<String>()
                menu.onActionSelected = { executed += it.id }
                val selected = actions(menu).last()
                val x = (selected.left + selected.right) / 2f
                val y = (selected.top + selected.bottom) / 2f
                touch(menu, MotionEvent.ACTION_DOWN, x, y)
                touch(menu, MotionEvent.ACTION_UP, x, y)
                assertEquals(listOf(many[count * 2 - 1].id), executed)
                val bitmap = Bitmap.createBitmap(menu.width, menu.height, Bitmap.Config.ARGB_8888)
                try { menu.draw(Canvas(bitmap)) } finally { bitmap.recycle() }
            }
            val resizing = RadialMenuView(context).apply { setActions(many) }
            measure(resizing, 180)
            assertEquals(2, actions(resizing).size)
            measure(resizing, 320)
            assertEquals(16, actions(resizing).size)
            assertEquals(16, HaloAppearance.actionsPerPage(context))
        } finally {
            val editor = settings.edit()
            if (previous is Int) editor.putInt(HaloAppearance.ACTIONS_PER_PAGE_KEY, previous) else editor.remove(HaloAppearance.ACTIONS_PER_PAGE_KEY)
            editor.commit()
        }
    }

    @Test fun safeAnchorKeepsTheEntireWheelAndFooterInsideEveryScreenCorner() {
        val screen = Rect(10, 30, 410, 730)
        val content = RectF(90f, 220f, 310f, 500f)
        for (x in listOf(-500f, 500f)) for (y in listOf(-900f, 900f)) {
            val (dx, dy) = HaloSafeArea.fittedShift(screen, content, x, y, 4f)
            val fitted = RectF(content).apply { offset(dx, dy) }
            assertTrue(fitted.left >= 14f && fitted.right <= 406f && fitted.top >= 34f && fitted.bottom <= 726f)
        }
        assertEquals(12f to 9f, HaloSafeArea.fittedShift(screen, content, 12f, 9f, 4f))
    }

    @Test fun distinctDefaultSymbolsHaveTransparentCornersAndMatchingPickerNames() = instrumentation.runOnMainSync {
        val catalog = ActionStore(context).allActions()
        assertNotEquals(ActionIcons.resource(catalog.single { it.id == "google" }), ActionIcons.resource(catalog.single { it.id == "translate" }))
        assertNotEquals(ActionIcons.resource(catalog.single { it.id == "baidu" }), ActionIcons.resource(catalog.single { it.id == "douban" }))
        assertEquals(ActionIcons.options.size, context.resources.getStringArray(R.array.action_icon_names).size)
        for (key in listOf("google", "translate", "baidu", "douban")) {
            val drawable = requireNotNull(context.getDrawable(ActionIcons.options.getValue(key)))
            val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
            try {
                drawable.setBounds(0, 0, 96, 96)
                drawable.draw(Canvas(bitmap))
                assertEquals(0, Color.alpha(bitmap.getPixel(0, 0)))
                assertEquals(0, Color.alpha(bitmap.getPixel(95, 95)))
                var ink = false
                for (y in 0 until 96) for (x in 0 until 96) if (Color.alpha(bitmap.getPixel(x, y)) > 0) ink = true
                assertTrue("$key must contain a visible transparent symbol", ink)
            } finally { bitmap.recycle() }
        }
    }

    private fun measure(menu: RadialMenuView, sizeDp: Int) {
        val size = (sizeDp * menu.resources.displayMetrics.density).toInt()
        val spec = View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY)
        menu.measure(spec, spec)
        menu.layout(0, 0, size, size)
    }

    private fun buttons(menu: RadialMenuView) = (0 until menu.childCount).map(menu::getChildAt).filterIsInstance<Button>()
    private fun actions(menu: RadialMenuView) = buttons(menu).filter { it.contentDescription?.toString()?.contains("fixture", true) == true }
    private fun touch(menu: RadialMenuView, action: Int, x: Float, y: Float) {
        val event = MotionEvent.obtain(0, 1, action, x, y, 0)
        try { menu.dispatchTouchEvent(event) } finally { event.recycle() }
    }
}
