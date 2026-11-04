package com.actionhalo.android

import android.app.UiAutomation
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inspector.WindowInspector
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the actual settings rows, native menus, editor, and subsequent halo. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 29)
class ActionManagementUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = HaloUi.localizedContext(instrumentation.targetContext)
    private val preferences get() = context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE)
    private lateinit var automation: UiAutomation
    private var previousActions: Map<String, *> = emptyMap<String, Any?>()

    @Before fun isolateActions() {
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        previousActions = preferences.all.toMap()
        assertTrue(preferences.edit().clear().commit())
    }

    @After fun restoreActions() {
        val editor = preferences.edit().clear()
        previousActions.forEach { (key, value) -> editor.restore(key, value) }
        assertTrue(editor.commit())
    }

    @Test fun editingBuiltInWebsitePersistsNameUrlAndIconWithoutEnablingIt() {
        val store = ActionStore(context)
        store.setEnabled("google", false)
        val original = store.allActions().single { it.id == "google" }
        val originalIcon = ActionIcons.resource(original)
        val title = "Fixture dictionary"
        val template = "https://example.com/lookup?q={text}&language=zh"

        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            openManagement(scenario, original.title)
            clickMenuText(context.getString(R.string.edit_action))
            instrumentation.runOnMainSync {
                val fields = editorFields()
                assertEquals(original.title, fields.first.text.toString())
                assertEquals(original.template, fields.second.text.toString())
                fields.first.setText(title)
                fields.second.setText(template)
                val icon = dialogViews().filterIsInstance<Spinner>().single()
                assertTrue(icon.count > 1)
                icon.setSelection((icon.selectedItemPosition + 1) % icon.count)
                saveButton().performClick()
            }
            instrumentation.waitForIdleSync()
            scenario.recreate()
            scenario.onActivity { activity ->
                val updated = ActionStore(activity).allActions().single { it.id == original.id }
                assertEquals(title, updated.title)
                assertEquals(template, updated.template)
                assertNotEquals(originalIcon, ActionIcons.resource(updated))
                assertFalse(ActionStore(activity).isEnabled(updated.id))
                val row = descendants(activity.window.decorView).filterIsInstance<Switch>().single {
                    it.text.toString() == title
                }
                assertFalse(row.isChecked)
                assertTrue(descendants(activity.window.decorView).any {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, title)
                })
            }
        }
    }

    @Test fun unsavedActionEditorSurvivesRecreationWithoutChangingStoredAction() {
        val original = ActionStore(context).allActions().single { it.id == "google" }
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            openManagement(scenario, original.title)
            clickMenuText(context.getString(R.string.edit_action))
            var selectedIcon = 0
            instrumentation.runOnMainSync {
                editorFields().first.setText("Draft search")
                editorFields().second.setText("https://example.com/?q={text}")
                val icons = dialogViews().filterIsInstance<Spinner>().single()
                selectedIcon = (icons.selectedItemPosition + 1) % icons.count
                icons.setSelection(selectedIcon)
            }
            scenario.recreate()
            instrumentation.runOnMainSync {
                assertEquals("Draft search", editorFields().first.text.toString())
                assertEquals("https://example.com/?q={text}", editorFields().second.text.toString())
                assertEquals(selectedIcon, dialogViews().filterIsInstance<Spinner>().single().selectedItemPosition)
                assertEquals(original, ActionStore(context).allActions().single { it.id == original.id })
                saveButton().performClick()
            }
            assertEquals("Draft search", ActionStore(context).allActions().single { it.id == original.id }.title)
        }
    }

    @Test fun actionSearchSurvivesRecreationAndNeverReordersTheStoredCatalog() {
        val store = ActionStore(context)
        val wanted = store.addCustom("Unique dictionary fixture", "https://example.com/?q={text}")
        val original = store.allActions()
        val title = wanted.title
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            scenario.onActivity { activity ->
                assertFalse("Settings search must not summon the keyboard on opening", activity.currentFocus is EditText)
                val search = descendants(activity.window.decorView).single { it.tag == "action_search" } as EditText
                search.setText(title)
                assertEquals(listOf(title), settingsRowTitles(activity, original.map { it.title }))
                val row = descendants(activity.window.decorView).single { it.tag == wanted.id }
                assertFalse("Filtering must not use an incorrect global drag index", row.performLongClick())
                assertEquals(original, store.allActions())
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val search = descendants(activity.window.decorView).single { it.tag == "action_search" } as EditText
                assertEquals(title, search.text.toString())
                search.setText("No matching action fixture")
                assertTrue(settingsRowTitles(activity, original.map { it.title }).isEmpty())
                search.setText("")
                assertEquals(original.map { it.title }, settingsRowTitles(activity, original.map { it.title }))
            }
            assertEquals(original, store.allActions())
        }
    }

    @Test fun duplicateActionAndLinkTestKeepTheOriginalAndRequireAnExplicitOpen() {
        val store = ActionStore(context)
        val original = store.addCustom("Fixture dictionary", "https://example.com/lookup?q={text}", "book")
        store.setEnabled(original.id, false)
        val scope = ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader"))
        store.setAppScope(original.id, scope)
        val launches = java.util.concurrent.CopyOnWriteArrayList<Intent>()
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_VIEW) return null
                launches.add(Intent(intent))
                return android.app.Instrumentation.ActivityResult(android.app.Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
                openManagement(scenario, original.title)
                clickMenuText(context.getString(R.string.action_duplicate))
                instrumentation.runOnMainSync {
                    assertEquals(original.template, editorFields().second.text.toString())
                    assertEquals(context.getString(R.string.action_duplicate_name, original.title), editorFields().first.text.toString())
                    val sample = dialogViews().single { it.tag == "action_editor_sample" } as EditText
                    sample.setText("猫 & café 🌍")
                    dialogViews().filterIsInstance<Button>().single { it.text == context.getString(R.string.action_test_preview) }.performClick()
                    assertTrue("Preview must not open a website", launches.isEmpty())
                    editorFields().second.setText("https://{text}.example.com/search")
                    dialogViews().filterIsInstance<Button>().single { it.text == context.getString(R.string.action_test_preview) }.performClick()
                    assertNotEquals(null, editorFields().second.error)
                    assertEquals(View.GONE, dialogViews().filterIsInstance<Button>().single { it.text == context.getString(R.string.action_test_open) }.visibility)
                    assertTrue(launches.isEmpty())
                    editorFields().second.setText(original.template)
                    dialogViews().filterIsInstance<Button>().single { it.text == context.getString(R.string.action_test_preview) }.performClick()
                    dialogViews().filterIsInstance<Button>().single { it.text == context.getString(R.string.action_test_open) }.performClick()
                    assertEquals(1, launches.size)
                    assertEquals("猫 & café 🌍", launches.single().data!!.getQueryParameter("q"))
                    saveButton().performClick()
                }
                instrumentation.waitForIdleSync()
                val copied = store.allActions().single { it.title == context.getString(R.string.action_duplicate_name, original.title) }
                assertNotEquals(original.id, copied.id)
                assertEquals(original.template, copied.template)
                assertEquals(original.icon, copied.icon)
                assertFalse(store.isEnabled(copied.id))
                assertEquals(scope, store.appScope(copied.id))
                assertEquals(original, store.allActions().single { it.id == original.id })
            }
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun invalidEditedDestinationLeavesDialogOpenAndStoredActionUnchanged() {
        val original = ActionStore(context).allActions().single { it.id == "google" }
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            openManagement(scenario, original.title)
            clickMenuText(context.getString(R.string.edit_action))
            instrumentation.runOnMainSync {
                val fields = editorFields()
                fields.first.setText("Must not be saved")
                fields.second.setText("https://{text}.example.com/search")
                assertTrue(saveButton().performClick())
                assertEquals(context.getString(R.string.custom_invalid), fields.second.error?.toString())
                assertTrue(fields.second.isAttachedToWindow)
                assertTrue(fields.second.isShown)
                assertEquals(original, ActionStore(context).allActions().single { it.id == original.id })
            }
            instrumentation.runOnMainSync {
                assertTrue(dialogViews().filterIsInstance<Button>().single {
                    it.id == android.R.id.button2 && it.isShown
                }.performClick())
            }
        }
    }

    @Test fun movingActionsUpdatesSettingsImmediatelyAndTheNextHaloUsesThatOrder() {
        val original = ActionStore(context).allActions()
        val google = original.single { it.id == "google" }
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            openManagement(scenario, google.title)
            clickMenuText(context.getString(R.string.action_move_down))
            val moved = original.toMutableList().apply {
                val index = indexOf(google)
                add(index + 1, removeAt(index))
            }
            assertSettingsOrder(scenario, moved.map { it.title })
            openManagement(scenario, google.title)
            clickMenuText(context.getString(R.string.action_move_up))
            assertSettingsOrder(scenario, original.map { it.title })
            openManagement(scenario, google.title)
            clickMenuText(context.getString(R.string.action_move_down))
            scenario.recreate()
            assertSettingsOrder(scenario, moved.map { it.title })
            assertNextHaloOrder(listOf("copy", "translate", "google"))
        }
    }

    @Test fun longPressDraggingPreviewsWithoutSavingThenPersistsAfterDrop() {
        val original = ActionStore(context).allActions()
        val google = original.single { it.id == "google" }
        val translate = original.single { it.id == "translate" }
        val moved = original.toMutableList().apply { add(2, removeAt(1)) }
        val beforeDrag = preferences.all.toMap()

        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            dragAction(scenario, google.title, translate.title, fromToggle = false, cancel = false) {
                assertEquals(beforeDrag, preferences.all)
                scenario.onActivity { activity ->
                    assertEquals(moved.map { it.title }, settingsRowTitles(activity, original.map { it.title }))
                }
            }
            assertSettingsOrder(scenario, moved.map { it.title })
            scenario.recreate()
            assertSettingsOrder(scenario, moved.map { it.title })
            assertNextHaloOrder(listOf("copy", "translate", "google"))
        }
    }

    @Test fun cancellingLongPressDragRestoresOrderAndDoesNotToggleOrSaveTheAction() {
        val store = ActionStore(context)
        store.setEnabled("google", false)
        val original = store.allActions()
        val google = original.single { it.id == "google" }
        val translate = original.single { it.id == "translate" }
        val beforeDrag = preferences.all.toMap()

        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            dragAction(scenario, google.title, translate.title, fromToggle = true, cancel = true) {
                assertEquals(beforeDrag, preferences.all)
                scenario.onActivity { activity ->
                    assertNotEquals(original.map { it.title }, settingsRowTitles(activity, original.map { it.title }))
                }
            }
            assertEquals(beforeDrag, preferences.all)
            assertFalse(ActionStore(context).isEnabled(google.id))
            assertSettingsOrder(scenario, original.map { it.title })
            scenario.recreate()
            assertSettingsOrder(scenario, original.map { it.title })
        }
    }

    @Test fun draggingAtTheBottomEdgeScrollsAcrossRowsAndSavesOnlyAfterDrop() {
        val store = ActionStore(context)
        repeat(6) { store.addCustom("Drag fixture ${it + 1}", "https://example.com/search?q={text}") }
        val original = store.allActions()
        val google = original.single { it.id == "google" }
        val beforeDrag = preferences.all.toMap()

        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            lateinit var scroll: ScrollView
            lateinit var list: View
            lateinit var sourceBounds: Rect
            var edgeY = 0f
            var initialScroll = 0
            var rowHeight = 0
            scenario.onActivity { activity ->
                val views = descendants(activity.window.decorView)
                val source = views.single {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, google.title)
                }
                list = (source.parent as View).parent as View
                scroll = views.filterIsInstance<ScrollView>().single()
                scroll.scrollTo(0, list.top - HaloUi.dp(activity, 24))
            }
            instrumentation.settleInput()
            scenario.onActivity { activity ->
                val source = descendants(activity.window.decorView).single {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, google.title)
                }
                sourceBounds = Rect().also { assertTrue(source.getGlobalVisibleRect(it)) }
                assertEquals(source.height, sourceBounds.height())
                rowHeight = (source.parent as View).height
                val location = IntArray(2).also(scroll::getLocationOnScreen)
                edgeY = location[1] + scroll.height - scroll.paddingBottom - HaloUi.dp(activity, 12).toFloat()
                initialScroll = scroll.scrollY
            }

            val downTime = SystemClock.uptimeMillis()
            val x = sourceBounds.exactCenterX()
            val startY = sourceBounds.exactCenterY()
            var releaseY = edgeY
            lateinit var preview: List<String>
            injectTouch(downTime, MotionEvent.ACTION_DOWN, x, startY)
            try {
                awaitNativeDrag(scenario, google.id, draggingExpected = true)
                for (step in 1..15) {
                    injectTouch(downTime, MotionEvent.ACTION_MOVE, x, startY + (edgeY - startY) * step / 15f)
                    SystemClock.sleep(20)
                }
                val deadline = SystemClock.uptimeMillis() + 3_000
                var scrolled = 0
                do {
                    SystemClock.sleep(40)
                    scenario.onActivity { scrolled = scroll.scrollY - initialScroll }
                } while (scrolled < rowHeight * 2 && SystemClock.uptimeMillis() < deadline)
                assertTrue("Holding at the bottom edge must scroll past two rows", scrolled >= rowHeight * 2)
                assertEquals(beforeDrag, preferences.all)

                scenario.onActivity { activity ->
                    val visibleList = Rect().also { assertTrue(list.getGlobalVisibleRect(it)) }
                    releaseY = minOf(edgeY - HaloUi.dp(activity, 64),
                        visibleList.exactCenterY())
                    assertTrue(visibleList.contains(x.toInt(), releaseY.toInt()))
                }
                injectTouch(downTime, MotionEvent.ACTION_MOVE, x, releaseY)
                instrumentation.settleInput()
                scenario.onActivity { activity ->
                    preview = settingsRowTitles(activity, original.map { it.title })
                }
                assertTrue("The preview must move the action across several rows",
                    preview.indexOf(google.title) >= original.indexOf(google) + 3)
                assertEquals(beforeDrag, preferences.all)
            } finally {
                injectTouch(downTime, MotionEvent.ACTION_UP, x, releaseY)
                awaitNativeDrag(scenario, google.id, draggingExpected = false)
            }
            assertSettingsOrder(scenario, preview)
            scenario.recreate()
            assertSettingsOrder(scenario, preview)
        }
    }

    private fun dragAction(scenario: ActivityScenario<MainActivity>, sourceTitle: String, targetTitle: String,
        fromToggle: Boolean, cancel: Boolean, checkPreview: () -> Unit) {
        lateinit var sourceBounds: Rect
        lateinit var targetBounds: Rect
        lateinit var sourceId: String
        scenario.onActivity { activity ->
            val views = descendants(activity.window.decorView)
            val source = if (fromToggle) views.filterIsInstance<Switch>().single { it.text.toString() == sourceTitle }
                else views.single {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, sourceTitle)
                }
            val list = (source.parent as View).parent as View
            val scroll = views.filterIsInstance<ScrollView>().single()
            scroll.scrollTo(0, list.top - HaloUi.dp(activity, 24))
        }
        instrumentation.settleInput()
        scenario.onActivity { activity ->
            val views = descendants(activity.window.decorView)
            val source = if (fromToggle) views.filterIsInstance<Switch>().single { it.text.toString() == sourceTitle }
                else views.single {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, sourceTitle)
                }
            val target = views.filterIsInstance<Switch>().single { it.text.toString() == targetTitle }
            sourceId = (source.parent as View).tag as String
            sourceBounds = Rect().also { assertTrue(source.getGlobalVisibleRect(it)) }
            targetBounds = Rect().also { assertTrue(target.getGlobalVisibleRect(it)) }
            assertEquals(source.height, sourceBounds.height())
            assertEquals(target.height, targetBounds.height())
        }
        val downTime = SystemClock.uptimeMillis()
        val x = sourceBounds.exactCenterX()
        val startY = sourceBounds.exactCenterY()
        val endY = targetBounds.top + targetBounds.height() * 0.75f
        injectTouch(downTime, MotionEvent.ACTION_DOWN, x, startY)
        try {
            awaitNativeDrag(scenario, sourceId, draggingExpected = true)
            for (step in 1..10) {
                injectTouch(downTime, MotionEvent.ACTION_MOVE, x, startY + (endY - startY) * step / 10f)
                SystemClock.sleep(25)
            }
            instrumentation.settleInput()
            checkPreview()
        } finally {
            // Cancel the native drag session; Android 11 turns an injected touch CANCEL into a drop.
            try {
                if (cancel) {
                    scenario.onActivity { it.window.decorView.cancelDragAndDrop() }
                    // Cancellation is asynchronous; UP must not race it into a successful drop.
                    awaitNativeDrag(scenario, sourceId, draggingExpected = false)
                }
            } finally {
                // Ending a native drag does not release the injected touch pointer.
                injectTouch(downTime, MotionEvent.ACTION_UP, x, endY, afterDragCancel = cancel)
            }
            if (!cancel) awaitNativeDrag(scenario, sourceId, draggingExpected = false)
        }
    }

    private fun awaitNativeDrag(scenario: ActivityScenario<MainActivity>, actionId: String, draggingExpected: Boolean) {
        val deadline = SystemClock.uptimeMillis() + 3_000
        do {
            var dragging = false
            scenario.onActivity { activity ->
                dragging = descendants(activity.window.decorView).any { it.tag == actionId && it.alpha < 1f }
            }
            if (dragging == draggingExpected) return
            SystemClock.sleep(25)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("The native drag for '$actionId' must ${if (draggingExpected) "start" else "end and restore the row"} within three seconds")
    }

    private fun injectTouch(downTime: Long, action: Int, x: Float, y: Float, afterDragCancel: Boolean = false) {
        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0).apply {
            source = InputDevice.SOURCE_TOUCHSCREEN
        }
        try {
            // A completed native cancellation can leave the cleanup UP without a target window.
            assertTrue(automation.injectInputEvent(event, true) || (afterDragCancel && action == MotionEvent.ACTION_UP))
        } finally { event.recycle() }
    }

    private fun assertNextHaloOrder(expectedFirstIds: List<String>) {
        val intent = Intent(context, HaloActivity::class.java)
            .putExtra(HaloActivity.EXTRA_DEMO_TEXT, "Ordering fixture")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val halo = instrumentation.startActivitySync(intent) as HaloActivity
        try {
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                val menu = descendants(halo.window.decorView).filterIsInstance<RadialMenuView>().single()
                val expected = ActionStore(halo).actions().take(HaloAppearance.actionsPerPage(halo)).map { it.title }
                val actual = descendants(menu).filterIsInstance<Button>().mapNotNull {
                    it.contentDescription?.toString()?.takeIf { title -> title in expected }
                }
                assertEquals(expected, actual)
                assertEquals(expectedFirstIds, ActionStore(halo).actions().take(expectedFirstIds.size).map { it.id })
            }
        } finally {
            instrumentation.runOnMainSync { halo.finish() }
            instrumentation.waitForIdleSync()
        }
    }

    private fun openManagement(scenario: ActivityScenario<MainActivity>, title: String) {
        scenario.onActivity { activity ->
            val button = descendants(activity.window.decorView).single {
                it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, title)
            }
            button.requestRectangleOnScreen(Rect(0, 0, button.width, button.height), true)
        }
        instrumentation.waitForIdleSync()
        scenario.onActivity { activity ->
            assertTrue(descendants(activity.window.decorView).single {
                it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, title)
            }.performClick())
        }
        instrumentation.waitForIdleSync()
    }

    private fun clickMenuText(label: String) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            val match = automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(label)
                ?.firstOrNull { it.text?.toString() == label && it.isVisibleToUser && it.isEnabled }
            var node = match
            while (node != null) {
                if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    instrumentation.waitForIdleSync()
                    return
                }
                node = node.parent
            }
            SystemClock.sleep(30)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("The native menu must expose a clickable '$label' item")
    }

    private fun assertSettingsOrder(scenario: ActivityScenario<MainActivity>, expected: List<String>) {
        scenario.onActivity { activity ->
            assertEquals(expected, ActionStore(activity).allActions().map { it.title })
            assertEquals(expected, settingsRowTitles(activity, expected))
        }
    }

    private fun settingsRowTitles(activity: MainActivity, titles: List<String>) =
        descendants(activity.window.decorView).filterIsInstance<Switch>()
            .map { it.text.toString() }.filter { it in titles }

    private fun dialogViews(): List<View> = WindowInspector.getGlobalWindowViews().flatMap(::descendants)

    private fun editorFields(): Pair<EditText, EditText> {
        val fields = dialogViews().filterIsInstance<EditText>()
        return fields.single { it.contentDescription?.toString() == context.getString(R.string.name_hint) } to
            fields.single { it.contentDescription?.toString() == context.getString(R.string.custom_help) }
    }

    private fun saveButton(): Button = dialogViews().filterIsInstance<Button>().single {
        it.text.toString() == context.getString(R.string.save) && it.isShown
    }

    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) addAll(descendants(view.getChildAt(index)))
    }

    private fun SharedPreferences.Editor.restore(key: String, value: Any?) {
        when (value) {
            is Boolean -> putBoolean(key, value)
            is Int -> putInt(key, value)
            is Long -> putLong(key, value)
            is Float -> putFloat(key, value)
            is String -> putString(key, value)
            is Set<*> -> putStringSet(key, value.filterIsInstance<String>().toSet())
        }
    }
}
