package com.actionhalo.android

import android.app.UiAutomation
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inspector.WindowInspector
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.Switch
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ActionExperienceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val preferenceNames = listOf("halo_actions", HaloAppearance.SETTINGS_NAME, "app_rules", "action_destinations")
    private var previous: Map<String, Map<String, *>> = emptyMap()
    private lateinit var automation: UiAutomation
    private val selected = "三体 🚀 &q=other#fragment + %2F"

    @Before fun saveSettings() {
        automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        previous = preferenceNames.associateWith { preferences(it).all.toMap() }
        preferenceNames.forEach { assertTrue(preferences(it).edit().clear().commit()) }
    }

    @After fun restoreSettings() {
        previous.forEach { (name, saved) ->
            val editor = preferences(name).edit().clear()
            saved.forEach { (key, value) -> editor.restore(key, value) }
            assertTrue(editor.commit())
        }
    }

    @Test fun preferredBrowserReceivesTheSameWebsiteWithOnlyTheSelectedTextEncoded() {
        val action = ActionStore(context).allActions().single { it.id == "google" }
        ActionDestinations(context).setRoute(action.id, "package:org.example.browser")
        val recording = RecordingContext(context)
        val failures = mutableListOf<Int>()
        instrumentation.runOnMainSync { assertTrue(ActionExecutor.execute(recording, action, selected, failures::add)) }
        assertTrue(failures.isEmpty())
        val intent = recording.launches.single()
        assertEquals("org.example.browser", intent.`package`)
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals(ActionUrls.build(requireNotNull(action.template), selected), intent.dataString)
        assertEquals(selected, intent.data?.getQueryParameter("q"))
        assertEquals(setOf("q"), intent.data?.queryParameterNames)
        assertNull(intent.data?.fragment)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test fun missingPreferredBrowserFallsBackOnlyToTheExactSameWebDestination() {
        val action = ActionStore(context).allActions().single { it.id == "neodb_book" }
        ActionDestinations(context).setRoute(action.id, "package:org.example.missing")
        val recording = RecordingContext(context) { intent ->
            if (intent.`package` != null) throw ActivityNotFoundException("Fixture preferred browser unavailable")
        }
        val failures = mutableListOf<Int>()
        instrumentation.runOnMainSync { assertTrue(ActionExecutor.execute(recording, action, selected, failures::add)) }
        assertTrue(failures.isEmpty())
        assertEquals(listOf("org.example.missing", null), recording.launches.map { it.`package` })
        val expected = ActionUrls.build(requireNotNull(action.template), selected)
        assertEquals(listOf(expected, expected), recording.launches.map { it.dataString })
        assertTrue(recording.launches.all { it.action == Intent.ACTION_VIEW })
        assertEquals("book", recording.launches.last().data?.getQueryParameter("c"))
    }

    @Test fun unavailableExplicitTelegramVariantDoesNotSwitchPackagesOrInventAWebSearch() {
        val action = ActionStore(context).allActions().single { it.id == "telegram" }
        val preferred = TelegramSearch.packages.last()
        ActionDestinations(context).setRoute(action.id, "package:$preferred")
        val recording = RecordingContext(context) { intent ->
            if (intent.`package` == preferred) throw ActivityNotFoundException("Fixture chosen Telegram unavailable")
        }
        val failures = mutableListOf<Int>()
        instrumentation.runOnMainSync { assertFalse(ActionExecutor.execute(recording, action, selected, failures::add)) }
        assertEquals(listOf(R.string.action_telegram_unavailable), failures)
        assertEquals(listOf(preferred), recording.launches.map { it.`package` })
        val request = recording.launches.single()
        assertEquals("tg", request.data?.scheme)
        assertEquals("search", request.data?.host)
        assertEquals(selected, request.data?.getQueryParameter("query"))
        assertEquals(Intent.ACTION_VIEW, request.action)
        assertNull(ActionExecutor.webUrl(action, selected))
    }

    @Test fun editingSurvivesRecreationInMemoryAndPreservesTheSourceAppsActionOrder() {
        val source = "org.example.reader"
        val store = ActionStore(context)
        store.setAllEnabled(false)
        AppRulesStore(context).setProfile(source, AppRulesStore.Profile(actions = listOf("share", "copy")))
        val before = preferenceNames.associateWith { preferences(it).all.toMap() }
        val original = "Initial selection"
        val corrected = "Corrected selection with 中文 🚀"
        val intent = Intent(context, EditTextActivity::class.java)
            .putExtra(HaloActivity.EXTRA_DEMO_TEXT, original)
            .putExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE, source)
        ActivityScenario.launch<EditTextActivity>(intent).use { scenario ->
            scenario.onActivity { activity ->
                descendants(activity.window.decorView).filterIsInstance<EditText>().single().setText(corrected)
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val editor = descendants(activity.window.decorView).filterIsInstance<EditText>().single()
                assertEquals(corrected, editor.text.toString())
                assertFalse(editor.isSaveEnabled)
                assertEquals(original, activity.intent.getStringExtra(HaloActivity.EXTRA_DEMO_TEXT))
                assertTrue(button(activity.window.decorView, R.string.edit_text_continue).performClick())
                assertEditedHalo(activity, corrected, listOf("share", "copy"))
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                assertEditedHalo(activity, corrected, listOf("share", "copy"))
                assertTrue(descendants(activity.window.decorView).filterIsInstance<EditText>().isEmpty())
                assertEquals(original, activity.intent.getStringExtra(HaloActivity.EXTRA_DEMO_TEXT))
            }
        }
        assertEquals(before, preferenceNames.associateWith { preferences(it).all.toMap() })
    }

    @Test fun blankAndOversizedEditedSelectionsStayInTheEditorWithAnActionableError() {
        val intent = Intent(context, EditTextActivity::class.java).putExtra(HaloActivity.EXTRA_DEMO_TEXT, "Original")
        ActivityScenario.launch<EditTextActivity>(intent).use { scenario ->
            scenario.onActivity { activity ->
                val editor = descendants(activity.window.decorView).filterIsInstance<EditText>().single()
                val choose = button(activity.window.decorView, R.string.edit_text_continue)
                listOf(" \n " to R.string.empty_text, "x".repeat(IncomingText.MAX_LENGTH + 1) to R.string.text_too_long)
                    .forEach { (text, message) ->
                        editor.setText(text)
                        assertTrue(choose.performClick())
                        assertEquals(activity.getString(message), editor.error?.toString())
                        assertTrue(editor.isAttachedToWindow)
                        assertFalse(activity.isFinishing)
                        assertTrue(descendants(activity.window.decorView).filterIsInstance<RadialMenuView>().isEmpty())
                    }
            }
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    fun bulkDisableAndResetCanBeUndoneButALaterToggleInvalidatesStaleUndo() {
        val store = ActionStore(context)
        val custom = store.addCustom("Undo fixture", "https://example.com/?q={text}", "book")
        store.moveTo(custom.id, 0)
        store.setEnabled("google", false)
        store.editAction("douban_movie", "My film search", "https://film.example/?q={text}", "film")
        val actions = store.allActions()
        val enabled = store.actions()
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            scenario.onActivity { activity ->
                val bulk = button(activity.window.decorView, R.string.actions_disable_all)
                if (!bulk.isShown) button(activity.window.decorView, R.string.settings_more_actions).performClick()
                assertTrue(bulk.performClick())
                assertTrue(store.actions().isEmpty())
                assertTrue(button(activity.window.decorView, R.string.undo_change).performClick())
                assertEquals(actions, store.allActions())
                assertEquals(enabled, store.actions())
                assertTrue(button(activity.window.decorView, R.string.actions_reset_all).performClick())
            }
            confirmDialog()
            scenario.onActivity { activity ->
                assertFalse(store.allActions().any { it.id == custom.id })
                assertTrue(button(activity.window.decorView, R.string.undo_change).performClick())
                assertEquals(actions, store.allActions())
                assertEquals(enabled, store.actions())
                val bulk = button(activity.window.decorView, R.string.actions_disable_all)
                if (!bulk.isShown) button(activity.window.decorView, R.string.settings_more_actions).performClick()
                assertTrue(bulk.performClick())
                val copyTitle = activity.getString(R.string.action_copy)
                descendants(activity.window.decorView).filterIsInstance<Switch>().single { it.text.toString() == copyTitle }
                    .isChecked = true
                val undo = button(activity.window.decorView, R.string.undo_change)
                assertEquals(View.GONE, undo.visibility)
                undo.performClick()
                assertEquals(listOf("copy"), store.actions().map { it.id })
            }
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    fun deletingACustomActionOffersUndoThatRestoresItsIdOrderAndEnabledState() {
        val store = ActionStore(context)
        val custom = store.addCustom("Delete undo fixture", "https://example.com/?q={text}", "book")
        store.moveTo(custom.id, 0)
        store.setEnabled(custom.id, false)
        val actions = store.allActions()
        val enabled = store.actions()
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            scenario.onActivity { activity ->
                val manage = descendants(activity.window.decorView).single {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, custom.title)
                }
                val list = (manage.parent as View).parent as View
                descendants(activity.window.decorView).filterIsInstance<ScrollView>().single()
                    .scrollTo(0, list.top - HaloUi.dp(activity, 24))
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                val manage = descendants(activity.window.decorView).single {
                    it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, custom.title)
                }
                val bounds = Rect().also { assertTrue(manage.getGlobalVisibleRect(it)) }
                assertEquals(manage.height, bounds.height())
                assertEquals(manage.width, bounds.width())
                assertTrue(manage.performClick())
            }
            instrumentation.waitForIdleSync()
            clickMenuText(context.getString(R.string.delete))
            confirmDialog()
            scenario.onActivity { activity ->
                assertFalse(store.allActions().any { it.id == custom.id })
                val undo = button(activity.window.decorView, R.string.undo_change)
                assertEquals(View.VISIBLE, undo.visibility)
                assertTrue(undo.performClick())
                assertEquals(actions, store.allActions())
                assertEquals(enabled, store.actions())
                assertEquals(View.GONE, undo.visibility)
            }
        }
    }

    private fun assertEditedHalo(activity: EditTextActivity, text: String, actionIds: List<String>) {
        val menu = descendants(activity.window.decorView).filterIsInstance<RadialMenuView>().single()
        assertEquals(text, menu.selectedText)
        val catalog = ActionStore(activity).allActions().associateBy { it.id }
        val expected = actionIds.map { requireNotNull(catalog[it]).title }
        val actual = descendants(menu).filterIsInstance<Button>().mapNotNull {
            it.contentDescription?.toString()?.takeIf { label -> label in expected }
        }
        assertEquals(expected, actual)
    }

    private fun button(root: View, label: Int) = descendants(root).filterIsInstance<Button>().single {
        it.text.toString() == context.getString(label)
    }

    @SdkSuppress(minSdkVersion = 29)
    private fun confirmDialog() {
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertTrue(WindowInspector.getGlobalWindowViews().flatMap(::descendants).filterIsInstance<Button>()
                .single { it.id == android.R.id.button1 && it.isShown }.performClick())
        }
        instrumentation.waitForIdleSync()
    }

    private fun clickMenuText(label: String) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            var node = automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(label)
                ?.firstOrNull { it.text?.toString() == label && it.isVisibleToUser && it.isEnabled }
            while (node != null) {
                if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    instrumentation.waitForIdleSync(); return
                }
                node = node.parent
            }
            SystemClock.sleep(30)
        } while (SystemClock.uptimeMillis() < deadline)
        fail("The action menu must expose '$label'")
    }

    private class RecordingContext(base: Context, private val intercept: (Intent) -> Unit = {}) : ContextWrapper(base) {
        val launches = mutableListOf<Intent>()
        override fun startActivity(intent: Intent) { launches += Intent(intent); intercept(intent) }
    }

    private fun preferences(name: String) = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) repeat(view.childCount) { addAll(descendants(view.getChildAt(it))) }
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
