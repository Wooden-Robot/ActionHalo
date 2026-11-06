package com.actionhalo.android

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ScrollView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DailyInteractionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val target get() = instrumentation.targetContext
    private val names = listOf("halo_actions", HaloAppearance.SETTINGS_NAME, "app_rules", "action_destinations")
    private val context = object : ContextWrapper(InstrumentationRegistry.getInstrumentation().targetContext) {
        override fun getSharedPreferences(name: String, mode: Int) = super.getSharedPreferences("daily_test_$name", mode)
    }
    private val pkg = "com.example.reader"
    @Before fun before() = clear()
    @After fun after() = clear()
    private fun clear() { AppRulesStore.clearVisitPauses(); names.forEach { assertTrue(context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()) } }

    @Test fun temporaryAppPauseKeepsActionRulesAndManualActionsAndExpiresWithoutChangingTheGlobalPause() {
        val rules = AppRulesStore(context)
        val store = ActionStore(context)
        val profile = AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO, listOf("google", "copy"))
        rules.setProfile(pkg, profile)
        val actions = rules.actionsFor(pkg, store.allActions())
        rules.pauseAppFor(pkg, AppRulesStore.TEN_MINUTES)
        assertFalse(rules.allowsAutomatic(pkg, true))
        assertFalse(rules.allowsButton(pkg, true))
        assertTrue(rules.allowsAutomatic("com.example.other", true))
        assertFalse(rules.isPaused())
        assertEquals(profile, rules.profile(pkg))
        assertEquals(actions, rules.actionsFor(pkg, store.allActions()))
        val prefs = context.getSharedPreferences("app_rules", Context.MODE_PRIVATE)
        val temporary = JSONObject(prefs.getString("temporary_app_pauses", "{}")!!)
        temporary.getJSONObject(pkg).put("wall", System.currentTimeMillis() - 1)
        prefs.edit().putString("temporary_app_pauses", temporary.toString()).commit()
        assertEquals(0L, rules.appPauseRemainingMillis(pkg))
        assertTrue(rules.allowsAutomatic(pkg, false))
        rules.pauseAppFor(pkg, AppRulesStore.TEN_MINUTES)
        rules.resumeApp(pkg)
        assertTrue(rules.pausedPackages().isEmpty())
        assertEquals(profile, rules.profile(pkg))
    }

    @Test fun visitPauseEndsWhenTheVerifiedSourceLeavesAndDoesNotPersistInConfiguration() {
        val rules = AppRulesStore(context)
        rules.pauseAppVisit(pkg, 123)
        assertFalse(rules.allowsAutomatic(pkg, true))
        assertFalse(rules.allowsButton(pkg, true))
        assertTrue(rules.actionsFor(pkg, ActionStore(context).allActions()).isNotEmpty())
        assertTrue(rules.pausedPackages().contains(pkg))
        rules.refreshVisitPauses { id -> id == 123 }
        assertTrue(rules.isVisitPaused(pkg))
        assertFalse(ConfigurationBackup(context).export().contains(pkg))
        rules.refreshVisitPauses { false }
        assertFalse(rules.isVisitPaused(pkg))
        assertTrue(rules.allowsAutomatic(pkg, true))
        rules.pauseAppVisit(pkg, 456)
        rules.resumeApp(pkg)
        assertTrue(rules.pausedPackages().isEmpty())
    }

    @Test fun sourceOptionsAreTappedWithoutSelectingAnActionAndPreserveTheSourceProfile() = instrumentation.runOnMainSync {
        val rules = AppRulesStore(context)
        val profile = AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO, listOf("copy", "google"))
        rules.setProfile(pkg, profile)
        var closed = 0
        var executed = 0
        fun menu() = RadialMenuView(context).apply {
            setActions(ActionStore(context).actions())
            onActionSelected = { executed++ }
            SourceAppControls.bind(this, pkg) { closed++ }
            val size = HaloUi.dp(context, 320)
            measure(View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY))
            layout(0, 0, size, size)
        }
        val first = menu()
        val options = descendants(first).filterIsInstance<Button>().single { it.contentDescription == context.getString(R.string.source_app_options) }
        val now = android.os.SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, now + action, action, (options.left + options.right) / 2f, (options.top + options.bottom) / 2f, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            first.dispatchTouchEvent(event); event.recycle()
        }
        assertTrue(descendants(first).any { it is ScrollView })
        assertEquals(0, executed)
        descendants(first).single { it.tag == "source_pause_app" }.performClick()
        assertEquals(1, closed)
        assertTrue(rules.appPauseRemainingMillis(pkg) > 0)
        assertEquals(profile, rules.profile(pkg))
        val second = menu()
        second.onSourceAppOptions!!.invoke()
        descendants(second).single { it.tag == "source_disable_app" }.performClick()
        assertEquals(AppRulesStore.TriggerMode.OFF, rules.triggerMode(pkg))
        assertEquals(profile.actions, rules.profile(pkg).actions)
        assertEquals(2, closed)
    }

    @Test fun copyingCanKeepTheManualWheelForAnotherActionAndClosingClearsTheSnapshot() {
        val settings = target.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        val previous = settings.all[HaloAppearance.KEEP_AFTER_COPY_KEY]
        settings.edit().putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, true).commit()
        lateinit var retained: RadialMenuView
        try {
            val incoming = Intent(target, HaloActivity::class.java).setAction(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "Fixture snapshot 你好 🌍")
            ActivityScenario.launch<HaloActivity>(incoming).use { scenario ->
                scenario.onActivity { activity ->
                    val menu = descendants(activity.window.decorView).filterIsInstance<RadialMenuView>().single()
                    retained = menu
                    menu.showActionError(R.string.action_no_app)
                    val copy = ActionStore(activity).allActions().single { it.id == "copy" }
                    menu.onActionSelected!!.invoke(copy)
                    assertFalse(activity.isFinishing)
                    assertEquals("Fixture snapshot 你好 🌍", menu.selectedText)
                    menu.showOperationStatus(null)
                    assertFalse("Success must not redisplay the previous failure", descendants(menu).filterIsInstance<android.widget.TextView>()
                        .any { it.text.toString().contains(activity.getString(R.string.action_no_app)) })
                    menu.onActionSelected!!.invoke(copy)
                    assertFalse(activity.isFinishing)
                    menu.onDismiss!!.invoke()
                    assertTrue(activity.isFinishing)
                }
            }
            assertEquals("Closing must clear the retained selection", "", retained.selectedText)
        } finally {
            settings.edit().apply { if (previous is Boolean) putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, previous) else remove(HaloAppearance.KEEP_AFTER_COPY_KEY) }.commit()
        }
    }

    @Test fun configurationBackupKeepsTheCopyPreferenceButExcludesTemporaryAppPauses() {
        val settings = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        settings.edit().putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, true).commit()
        AppRulesStore(context).pauseAppFor(pkg, AppRulesStore.TEN_MINUTES)
        val engine = ConfigurationBackup(context)
        val backup = JSONObject(engine.export())
        assertTrue(backup.getJSONObject("appearance").getBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY))
        assertFalse(backup.toString().contains("temporary_app_pauses"))
        settings.edit().putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, false).commit()
        engine.restore(backup)
        assertTrue(HaloAppearance.keepAfterCopy(context, ActionStore(context).allActions().single { it.id == "copy" }))
        assertFalse(HaloAppearance.keepAfterCopy(context, ActionStore(context).allActions().single { it.id == "google" }))
        backup.getJSONObject("appearance").put(HaloAppearance.KEEP_AFTER_COPY_KEY, "true")
        try { engine.restore(backup); fail("Invalid preference type") } catch (_: IllegalArgumentException) { }
        assertTrue(settings.getBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, false))
    }

    private fun descendants(view: View): List<View> = listOf(view) + if (view is ViewGroup)
        (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()
}
