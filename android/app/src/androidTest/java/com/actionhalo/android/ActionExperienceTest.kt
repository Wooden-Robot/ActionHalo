package com.actionhalo.android

import android.app.UiAutomation
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Parcel
import android.os.SystemClock
import android.os.TransactionTooLargeException
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.view.inspector.WindowInspector
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.Switch
import android.widget.ListView
import android.widget.TextView
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
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

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

    @Test fun oversizedExpandedLinkHandlesTheRealSystemTransactionFailure() {
        val text = "中".repeat(IncomingText.MAX_LENGTH)
        val action = ActionStore(context).addCustom("Large request fixture",
            "https://example.com/?a={text}&b={text}&c={text}&d={text}")
        assertTrue(IncomingText.isUsable(text))
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            scenario.onActivity { activity ->
                var systemFailure: Exception? = null
                var parcelBytes = 0
                val systemContext = object : ContextWrapper(activity) {
                    override fun startActivity(intent: Intent) {
                        // Exercise the real Binder call without opening a browser if a platform accepts it.
                        val request = Intent(intent).setClass(activity, EditTextActivity::class.java)
                        parcelBytes = intentParcelBytes(request)
                        try { super.startActivity(request) } catch (failure: Exception) {
                            systemFailure = failure
                            Log.i("ActionPayloadProbe", "startActivity bytes=$parcelBytes causes=${failureTypes(failure)}")
                            throw failure
                        }
                    }
                }
                val failures = mutableListOf<Int>()
                var result: Boolean? = null
                var escaped: Exception? = null
                try { result = ActionExecutor.execute(systemContext, action, text, failures::add) }
                catch (failure: Exception) { escaped = failure }
                assertTrue("The actual Intent parcel must exceed the documented shared Binder buffer", parcelBytes > 1_048_576)
                assertTrue("The system must expose its oversized-transaction cause: ${failureTypes(systemFailure)}",
                    generateSequence(systemFailure as Throwable?) { it.cause }.any { it is TransactionTooLargeException })
                assertNull("A system payload rejection must become a recoverable action failure", escaped)
                assertEquals(false, result)
                assertEquals(listOf(R.string.action_request_too_large), failures)
                assertFalse(activity.isFinishing)
            }
        }
    }

    @Test fun oversizedTransactionsDoNotRetryTheSamePayloadThroughFallbackRoutes() {
        val store = ActionStore(context)
        val destinations = ActionDestinations(context)
        val routes = listOf("google" to null, "google" to "package:org.example.browser",
            "douban" to null, "telegram" to null, "telegram" to "package:${TelegramSearch.packages.last()}")
        instrumentation.runOnMainSync {
            for ((id, route) in routes) for (wrapped in listOf(false, true)) {
                val action = store.allActions().single { it.id == id }
                destinations.setRoute(id, route)
                val oversized = TransactionTooLargeException("Synthetic oversized launch")
                val failure = if (wrapped) RuntimeException("Failure from system", oversized) else oversized
                val recording = RecordingContext(context) { throw failure }
                val failures = mutableListOf<Int>()
                var result: Boolean? = null
                var escaped: Exception? = null
                try { result = ActionExecutor.execute(recording, action, selected, failures::add) }
                catch (unexpected: Exception) { escaped = unexpected }
                assertNull("Oversized $id requests must return failure, including wrapped system exceptions", escaped)
                assertEquals(false, result)
                assertEquals("The same oversized data must not reach another browser or Telegram package", 1, recording.launches.size)
                assertEquals(listOf(R.string.action_request_too_large), failures)
            }
            val unexpected = IllegalStateException("Unrelated fixture failure")
            val recording = RecordingContext(context) { throw unexpected }
            val failures = mutableListOf<Int>()
            var escaped: Exception? = null
            try { ActionExecutor.execute(recording, store.allActions().single { it.id == "google" }, selected, failures::add) }
            catch (failure: Exception) { escaped = failure }
            assertTrue("Unrelated programming failures must not be disguised as payload errors", escaped === unexpected)
            assertTrue(failures.isEmpty())
        }
    }

    @Test fun editorTestOpenKeepsItsDraftAndCanRetryAfterAnOversizedTransaction() {
        var attempts = 0
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_VIEW) return null
                attempts++
                if (attempts == 1) throw RuntimeException("Failure from system",
                    TransactionTooLargeException("Synthetic editor launch"))
                return android.app.Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
                assertPayloadToast {
                    scenario.onActivity { activity ->
                        assertTrue(button(activity.window.decorView, R.string.add_action).performClick())
                        val editor = actionEditor(activity)
                        val root = editor.window!!.decorView
                        val fields = descendants(root).filterIsInstance<EditText>()
                        val name = fields.single { it.tag == "action_editor_name" }
                        val url = fields.single { it.tag == "action_editor_url" }
                        val sample = fields.single { it.tag == "action_editor_sample" }
                        name.setText("Kept request draft")
                        url.setText("https://example.com/?q={text}")
                        sample.setText(selected)
                        assertTrue(button(root, R.string.action_test_preview).performClick())
                        var escaped: Exception? = null
                        try { assertTrue(button(root, R.string.action_test_open).performClick()) }
                        catch (failure: Exception) { escaped = failure }
                        assertNull("The editor must handle the same system launch failure as the wheel", escaped)
                        assertEquals(1, attempts)
                        assertTrue(editor.isShowing)
                        assertFalse(activity.isFinishing)
                        assertEquals("Kept request draft", name.text.toString())
                        assertEquals(selected, sample.text.toString())
                        assertTrue(button(root, R.string.action_test_open).performClick())
                        assertEquals(2, attempts)
                    }
                }
            }
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun oversizedLiteralDestinationQueryDoesNotCrashItsChooser() {
        val action = HaloAction("google", "Large destination fixture", "", ActionType.URL,
            "https://example.com/" + "a".repeat(1_100_000) + "?q={text}")
        assertTrue(ActionUrls.validateTemplate(requireNotNull(action.template)))
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            assertPayloadToast {
                scenario.onActivity { activity ->
                    val request = Intent(Intent.ACTION_VIEW, Uri.parse(ActionExecutor.webUrl(action, "example.com")))
                    val bytes = intentParcelBytes(request)
                    var queryFailure: Exception? = null
                    try {
                        @Suppress("DEPRECATION")
                        activity.packageManager.queryIntentActivities(request, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
                    } catch (failure: Exception) { queryFailure = failure }
                    Log.i("ActionPayloadProbe", "queryIntentActivities bytes=$bytes causes=${failureTypes(queryFailure)}")
                    assertTrue(bytes > 1_048_576)
                    assertTrue("The real destination query must reject its oversized Binder request",
                        generateSequence(queryFailure as Throwable?) { it.cause }.any { it is TransactionTooLargeException })
                    var saved = false
                    var escaped: Exception? = null
                    try { ActionDestinations(activity).choose(activity, action) { saved = true } }
                    catch (failure: Exception) { escaped = failure }
                    assertNull("Opening destination preferences must report the payload failure without crashing", escaped)
                    assertFalse(saved)
                    assertFalse(activity.isFinishing)
                    assertNull(ActionDestinations(activity).route(action.id))
                }
            }
        }
    }

    private fun intentParcelBytes(intent: Intent): Int {
        val parcel = Parcel.obtain()
        return try { intent.writeToParcel(parcel, 0); parcel.dataSize() } finally { parcel.recycle() }
    }

    private fun failureTypes(failure: Throwable?): String =
        generateSequence(failure) { it.cause }.take(6).joinToString(" -> ") { it.javaClass.name }

    private fun assertPayloadToast(operation: () -> Unit) {
        val event = automation.executeAndWaitForEvent({ operation() }, { event ->
            event.eventType == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED &&
                event.className?.toString() == "android.widget.Toast" &&
                event.packageName?.toString() == context.packageName &&
                event.text.any { it.toString() == context.getString(R.string.action_request_too_large) }
        }, 5_000)
        try {
            assertEquals(listOf(context.getString(R.string.action_request_too_large)), event.text.map(CharSequence::toString))
        } finally { event.recycle() }
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

    @Test fun editingRestoresTheCaretAndUnicodeSelectionAfterRecreation() {
        val text = "Prefix 中文 🧑‍💻 café e\u0301 suffix"
        val start = text.indexOf("中文")
        val end = text.indexOf(" suffix")
        val intent = Intent(context, EditTextActivity::class.java).putExtra(HaloActivity.EXTRA_DEMO_TEXT, text)
        ActivityScenario.launch<EditTextActivity>(intent).use { scenario ->
            for ((selectionStart, selectionEnd) in listOf(start to start, start to end)) {
                scenario.onActivity { activity ->
                    descendants(activity.window.decorView).filterIsInstance<EditText>().single()
                        .setSelection(selectionStart, selectionEnd)
                }
                scenario.recreate()
                scenario.onActivity { activity ->
                    val editor = descendants(activity.window.decorView).filterIsInstance<EditText>().single()
                    assertEquals(text, editor.text.toString())
                    assertEquals(selectionStart, editor.selectionStart)
                    assertEquals(selectionEnd, editor.selectionEnd)
                    assertFalse(editor.isSaveEnabled)
                    assertFalse(activity.isFinishing)
                }
            }
        }
    }

    @Test fun blankAndOversizedEditedSelectionsSurviveRecreationAndShowAnActionableError() {
        val intent = Intent(context, EditTextActivity::class.java).putExtra(HaloActivity.EXTRA_DEMO_TEXT, "Original")
        ActivityScenario.launch<EditTextActivity>(intent).use { scenario ->
            listOf("" to R.string.empty_text, " \n " to R.string.empty_text,
                "x".repeat(IncomingText.MAX_LENGTH + 1) to R.string.text_too_long)
                .forEach { (text, message) ->
                    scenario.onActivity { activity ->
                        descendants(activity.window.decorView).filterIsInstance<EditText>().single().setText(text)
                    }
                    scenario.recreate()
                    scenario.onActivity { activity ->
                        val editor = descendants(activity.window.decorView).filterIsInstance<EditText>().single()
                        assertEquals(text, editor.text.toString())
                        assertFalse(editor.isSaveEnabled)
                        assertEquals("Original", activity.intent.getStringExtra(HaloActivity.EXTRA_DEMO_TEXT))
                        assertTrue(button(activity.window.decorView, R.string.edit_text_continue).performClick())
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
                val deletedState = preferences("halo_actions").all.toMap()
                assertTrue(button(activity.window.decorView, R.string.add_action).performClick())
                val editor = actionEditor(activity)
                val fields = descendants(editor.window!!.decorView).filterIsInstance<EditText>()
                fields.single { it.tag == "action_editor_name" }.setText("Invalid draft")
                fields.single { it.tag == "action_editor_url" }.setText("https://{text}.example.com/search")
                assertTrue(editor.getButton(AlertDialog.BUTTON_POSITIVE).performClick())
                assertTrue(editor.isShowing)
                assertEquals(deletedState, preferences("halo_actions").all.toMap())
                assertEquals("A rejected edit must not erase deletion recovery", View.VISIBLE, undo.visibility)
                editor.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
                assertTrue(undo.performClick())
                assertEquals(actions, store.allActions())
                assertEquals(enabled, store.actions())
                assertEquals(View.GONE, undo.visibility)
            }
        }
    }

    @Test fun routeLimitPreflightDoesNotWriteAndReusesDefaultOrDeletedActionSlots() {
        val actions = seedRouteLimit()
        val store = ActionStore(context)
        val destinations = ActionDestinations(context)
        val before = preferenceNames.associateWith { preferences(it).all.toMap() }
        try { destinations.validateAdditionalRoute("web"); fail("An additional route must be rejected") }
        catch (_: ActionDestinations.RouteLimitException) { }
        try { destinations.setRoute("google", "web"); fail("The next action must not exceed the route limit") }
        catch (_: ActionDestinations.RouteLimitException) { }
        assertEquals(before, preferenceNames.associateWith { preferences(it).all.toMap() })
        destinations.setRoute(actions[0].id, "package:com.example.browser")
        assertEquals("package:com.example.browser", destinations.route(actions[0].id))
        destinations.setRoute(actions[1].id, null)
        val afterDefault = preferences("action_destinations").all.toMap()
        destinations.validateAdditionalRoute("web")
        assertEquals(afterDefault, preferences("action_destinations").all.toMap())
        destinations.setRoute("google", "web")
        assertEquals(ActionDestinations.MAX_ROUTES, destinations.snapshot().length())

        assertTrue(store.deleteCustom(actions[2].id))
        val withStaleRoute = preferences("action_destinations").all.toMap()
        destinations.validateAdditionalRoute("web")
        assertEquals("Preflight must leave stale-route cleanup to the actual save", withStaleRoute,
            preferences("action_destinations").all.toMap())
        destinations.setRoute("translate", "web")
        assertNull(destinations.route(actions[2].id))
        assertEquals(ActionDestinations.MAX_ROUTES, destinations.snapshot().length())
    }

    @Test fun actionsPageRecreationKeepsTheVisibleCatalogPosition() {
        val store = ActionStore(context)
        val actions = (1..40).map { store.addCustom("Scroll fixture $it", "https://example.com/$it?q={text}") }
        val target = actions[25]
        var savedY = 0
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            scenario.onActivity { activity ->
                val scroll = descendants(activity.window.decorView).filterIsInstance<ScrollView>().single()
                val toggle = descendants(scroll).filterIsInstance<Switch>().single { it.text.toString() == target.title }
                val row = toggle.parent as View
                val bounds = Rect(0, 0, row.width, row.height)
                scroll.offsetDescendantRectToMyCoords(row, bounds)
                scroll.scrollTo(0, bounds.top - scroll.paddingTop)
                savedY = scroll.scrollY
                assertTrue("The fixture must scroll well into the action catalog", savedY > scroll.height)
                val visible = Rect()
                assertTrue(toggle.getGlobalVisibleRect(visible))
                assertEquals(toggle.height, visible.height())
            }
            scenario.recreate()
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                val scroll = descendants(activity.window.decorView).filterIsInstance<ScrollView>().single()
                assertEquals("Rebuilding settings must keep the catalog position", savedY, scroll.scrollY)
                val toggle = descendants(scroll).filterIsInstance<Switch>().single { it.text.toString() == target.title }
                val visible = Rect()
                assertTrue("The action being managed must remain visible", toggle.getGlobalVisibleRect(visible))
                assertEquals(toggle.height, visible.height())
            }
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    fun routeChooserAtTheLimitKeepsTheActualSelectionAndCanStillChooseDefault() {
        seedRouteLimit()
        val store = ActionStore(context)
        val removed = store.addCustom("Unrouted undo fixture", "https://example.com/?q={text}")
        val destinations = ActionDestinations(context)
        val before = preferences("action_destinations").all.toMap()
        val google = store.allActions().single { it.id == "google" }
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            openActionMenu(scenario, removed)
            clickMenuText(context.getString(R.string.delete))
            confirmDialog()
            openActionMenu(scenario, google)
            clickMenuText(context.getString(R.string.destination_menu))
            instrumentation.runOnMainSync {
                val root = WindowInspector.getGlobalWindowViews().single { window ->
                    descendants(window).any { it.tag == "destination_save_error" }
                }
                val list = descendants(root).filterIsInstance<ListView>().single()
                assertTrue(list.performItemClick(list.getChildAt(1), 1, list.adapter.getItemId(1)))
                val error = descendants(root).filterIsInstance<TextView>().single { it.tag == "destination_save_error" }
                assertEquals(context.getString(R.string.destination_limit_reached, ActionDestinations.MAX_ROUTES), error.text.toString())
                assertEquals(View.ACCESSIBILITY_LIVE_REGION_POLITE, error.accessibilityLiveRegion)
                assertTrue(root.isAttachedToWindow)
                assertEquals(0, list.checkedItemPosition)
                assertEquals(before, preferences("action_destinations").all.toMap())
            }
            scenario.onActivity { activity ->
                assertEquals("A rejected route must preserve deletion recovery", View.VISIBLE,
                    button(activity.window.decorView, R.string.undo_change).visibility)
            }
            instrumentation.runOnMainSync {
                val root = WindowInspector.getGlobalWindowViews().single { window ->
                    descendants(window).any { it.tag == "destination_save_error" }
                }
                val list = descendants(root).filterIsInstance<ListView>().single()
                assertTrue(list.performItemClick(list.getChildAt(0), 0, list.adapter.getItemId(0)))
            }
            instrumentation.waitForIdleSync()
            assertNull(destinations.route(google.id))
            scenario.onActivity { activity ->
                assertEquals(View.GONE, button(activity.window.decorView, R.string.undo_change).visibility)
            }
            instrumentation.runOnMainSync {
                assertTrue(WindowInspector.getGlobalWindowViews().none { window ->
                    descendants(window).any { it.tag == "destination_save_error" }
                })
            }
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    fun duplicateAtTheRouteLimitKeepsItsDraftAndCreatesOnlyOneActionAfterRetry() {
        val store = ActionStore(context)
        val destinations = ActionDestinations(context)
        val actions = seedRouteLimit()
        val source = actions.first()
        store.setEnabled(source.id, false)
        val scope = ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader"))
        store.setAppScope(source.id, scope)
        val before = preferenceNames.associateWith { preferences(it).all.toMap() }
        val beforeIds = store.allActions().map { it.id }.toSet()
        measured("512 routes: initial actions page") {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS))
        }.use { scenario ->
            scenario.onActivity { activity ->
                val toggles = descendants(activity.window.decorView).filterIsInstance<Switch>()
                assertFalse(toggles.single { it.text.toString() == source.title }.isChecked)
                assertTrue(toggles.single { it.text.toString() == actions[1].title }.isChecked)
            }
            openActionMenu(scenario, source)
            clickMenuText(context.getString(R.string.action_duplicate))
            scenario.onActivity { activity ->
                val editor = actionEditor(activity)
                val name = descendants(editor.window!!.decorView).filterIsInstance<EditText>()
                    .single { it.tag == "action_editor_name" }
                name.setText("Kept duplicate draft")
                name.requestFocus()
                activity.getSystemService(InputMethodManager::class.java).showSoftInput(name, InputMethodManager.SHOW_IMPLICIT)
            }
            if (Build.VERSION.SDK_INT >= 30) {
                var keyboardVisible = false
                val deadline = SystemClock.uptimeMillis() + 5_000
                do {
                    scenario.onActivity { activity ->
                        keyboardVisible = actionEditor(activity).window!!.decorView.rootWindowInsets
                            ?.isVisible(WindowInsets.Type.ime()) == true
                    }
                    if (!keyboardVisible) SystemClock.sleep(30)
                } while (!keyboardVisible && SystemClock.uptimeMillis() < deadline)
                assertTrue("The draft is edited with the software keyboard visible", keyboardVisible)
            }
            scenario.onActivity { activity ->
                val editor = actionEditor(activity)
                repeat(2) {
                    measured("512 routes: rejected duplicate save") {
                        assertTrue(editor.getButton(AlertDialog.BUTTON_POSITIVE).performClick())
                    }
                }
                assertEquals(before, preferenceNames.associateWith { preferences(it).all.toMap() })
                assertEquals(beforeIds, store.allActions().map { it.id }.toSet())
                assertTrue(editor.isShowing)
                val views = descendants(editor.window!!.decorView)
                assertEquals("Kept duplicate draft", views.filterIsInstance<EditText>()
                    .single { it.tag == "action_editor_name" }.text.toString())
                assertEquals(context.getString(R.string.destination_limit_reached, ActionDestinations.MAX_ROUTES),
                    views.filterIsInstance<TextView>().single { it.tag == "action_editor_save_error" }.text.toString())
            }
            instrumentation.waitForIdleSync()
            if (InstrumentationRegistry.getArguments().getString("capture_route_limit") == "true") {
                SystemClock.sleep(100)
                automation.takeScreenshot()?.let { bitmap ->
                    java.io.FileOutputStream(java.io.File(context.cacheDir, "route-limit-error.png")).use {
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                    }
                    bitmap.recycle()
                }
            }
            scenario.onActivity { activity ->
                val editor = actionEditor(activity)
                val error = descendants(editor.window!!.decorView).filterIsInstance<TextView>()
                    .single { it.tag == "action_editor_save_error" }
                val bounds = Rect()
                assertTrue("The route limit explanation must be visible above the keyboard", error.getGlobalVisibleRect(bounds))
                assertEquals("The full route limit explanation must fit in the editor viewport", error.height, bounds.height())
                val location = IntArray(2).also(error::getLocationOnScreen)
                val onScreen = Rect(location[0], location[1], location[0] + error.width, location[1] + error.height)
                val visibleFrame = Rect().also(error::getWindowVisibleDisplayFrame)
                assertTrue("The explanation must fit above the software keyboard: $onScreen inside $visibleFrame",
                    visibleFrame.contains(onScreen))
                destinations.setRoute(actions[1].id, null)
                measured("512 routes: successful duplicate save") {
                    assertTrue(editor.getButton(AlertDialog.BUTTON_POSITIVE).performClick())
                }
                assertFalse(editor.isShowing)
                val created = store.allActions().single { it.id !in beforeIds }
                assertEquals("Kept duplicate draft", created.title)
                assertEquals(source.template, created.template)
                assertEquals(ActionIcons.key(source), created.icon)
                assertFalse(store.isEnabled(created.id))
                assertEquals(scope, store.appScope(created.id))
                assertEquals("web", destinations.route(created.id))
                assertEquals(beforeIds.size + 1, store.allActions().size)
                assertEquals(ActionDestinations.MAX_ROUTES, destinations.snapshot().length())
            }
        }
    }

    @Test @SdkSuppress(minSdkVersion = 29)
    fun savingAnOpeningPreferenceInvalidatesDeletionUndoAfterCleaningItsOldRoute() {
        val store = ActionStore(context)
        val removed = store.addCustom("Routed deletion fixture", "https://example.com/?q={text}")
        val google = store.allActions().single { it.id == "google" }
        val destinations = ActionDestinations(context)
        destinations.setRoute(removed.id, "web")
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            openActionMenu(scenario, removed)
            clickMenuText(context.getString(R.string.delete))
            confirmDialog()
            scenario.onActivity { activity ->
                assertEquals(View.VISIBLE, button(activity.window.decorView, R.string.undo_change).visibility)
            }
            openActionMenu(scenario, google)
            clickMenuText(context.getString(R.string.destination_menu))
            instrumentation.runOnMainSync {
                val root = WindowInspector.getGlobalWindowViews().single { window ->
                    descendants(window).any { it.tag == "destination_save_error" }
                }
                val list = descendants(root).filterIsInstance<ListView>().single()
                assertTrue(list.performItemClick(list.getChildAt(1), 1, list.adapter.getItemId(1)))
            }
            scenario.onActivity { activity ->
                val undo = button(activity.window.decorView, R.string.undo_change)
                assertEquals(View.GONE, undo.visibility)
                undo.performClick()
                assertFalse(store.allActions().any { it.id == removed.id })
                assertNull(destinations.route(removed.id))
                assertEquals("web", destinations.route(google.id))
            }
        }
    }

    private fun seedRouteLimit(): List<HaloAction> {
        val store = ActionStore(context)
        val value = store.snapshot()
        val custom = JSONArray()
        repeat(ActionDestinations.MAX_ROUTES) { index ->
            val id = "custom:${UUID.randomUUID()}"
            custom.put(JSONObject().put("id", id).put("title", "Route fixture $index")
                .put("template", "https://example.com/$index?q={text}"))
            value.getJSONArray("order").put(id)
            value.getJSONObject("enabled").put(id, true)
        }
        value.put("custom", custom)
        store.restoreSnapshot(value)
        val actions = store.allActions().filter { it.id.startsWith("custom:") }
        val routes = JSONObject().apply { actions.forEach { put(it.id, "web") } }
        val destinations = ActionDestinations(context)
        destinations.restoreSnapshot(destinations.validateSnapshot(routes, store.allActions().map { it.id }.toSet()))
        return actions
    }

    private fun actionEditor(activity: MainActivity) = MainActivity::class.java
        .getDeclaredField("editorDialog").apply { isAccessible = true }.get(activity) as AlertDialog

    private fun openActionMenu(scenario: ActivityScenario<MainActivity>, action: HaloAction) {
        scenario.onActivity { activity ->
            measured("actions page: filter ${action.title}") {
                descendants(activity.window.decorView).filterIsInstance<EditText>().single { it.tag == "action_search" }
                    .setText(action.title)
            }
            val manage = descendants(activity.window.decorView).single {
                it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, action.title)
            }
            val list = (manage.parent as View).parent as View
            descendants(activity.window.decorView).filterIsInstance<ScrollView>().single()
                .scrollTo(0, list.top - HaloUi.dp(activity, 24))
        }
        instrumentation.waitForIdleSync()
        scenario.onActivity { activity ->
            assertTrue(descendants(activity.window.decorView).single {
                it.contentDescription?.toString() == activity.getString(R.string.action_manage_description, action.title)
            }.performClick())
        }
        instrumentation.waitForIdleSync()
    }

    private fun <T> measured(label: String, operation: () -> T): T {
        val started = SystemClock.elapsedRealtime()
        return operation().also { Log.i("ActionExperienceTiming", "$label: ${SystemClock.elapsedRealtime() - started} ms") }
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
