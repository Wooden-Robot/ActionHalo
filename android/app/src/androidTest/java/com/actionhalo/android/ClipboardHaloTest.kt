package com.actionhalo.android

import android.app.Activity
import android.app.Application
import android.app.Dialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic clips only; clipboard access and restoration always run in a focused activity. */
@RunWith(AndroidJUnit4::class)
class ClipboardHaloTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val savedPreferences = mutableMapOf<Pair<String, String>, Boolean?>()
    private val sourcePackage = "org.telegram.messenger"
    private var savedRules: Map<String, *> = emptyMap<String, Any>()

    @Before fun preparePreferences() {
        val rules = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE)
        savedRules = rules.all.toMap()
        assertTrue(rules.edit().clear().commit())
        fixturePreference("actionhalo_settings", "gta_mode_enabled", true)
        fixturePreference("actionhalo_settings", "auto_popup_enabled", false)
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, false)
        fixturePreference("halo_actions", "enabled_copy", true)
        // MainActivity initializes this upgrade preference when it is absent.
        fixturePreference("halo_actions", "enabled_douban", false)
    }

    @After fun restorePreferences() {
        val rules = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE).edit().clear()
        savedRules.forEach { (key, value) ->
            when (value) {
                is String -> rules.putString(key, value)
                is Long -> rules.putLong(key, value)
                is Boolean -> rules.putBoolean(key, value)
                is Int -> rules.putInt(key, value)
                is Float -> rules.putFloat(key, value)
                is Set<*> -> rules.putStringSet(key, value.filterIsInstance<String>().toSet())
            }
        }
        assertTrue(rules.commit())
        savedPreferences.forEach { (location, value) ->
            val editor = context.getSharedPreferences(location.first, Context.MODE_PRIVATE).edit()
            if (value == null) editor.remove(location.second) else editor.putBoolean(location.second, value)
            assertTrue(editor.commit())
        }
    }

    @Test fun unicodeTextIsReadOnceEvenAfterLosingAndRegainingFocus() = withClipboardHost { main ->
        val original = "你好 🌍 café e\u0301 & こんにちは\n第二行 👨‍👩‍👧‍👦"
        writeClip(main, ClipData.newPlainText("Fixture", original))
        val halo = launchHalo()
        try {
            awaitWindowFocus(halo)
            val originalMenu = AtomicReference<RadialMenuView>()
            instrumentation.runOnMainSync {
                val menu = haloMenu(halo)
                originalMenu.set(menu)
                assertEquals(original, menu.selectedText)
                assertTrue(menu.gtaModeEnabled)
            }
            // A separate foreground task makes the halo lose real window focus.
            val foreground = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)) as MainActivity
            try {
                awaitWindowFocus(foreground)
                instrumentation.runOnMainSync { assertFalse(halo.hasWindowFocus()) }
                writeClip(foreground, ClipData.newPlainText("Fixture replacement", "不同的新文字 🪁"))
            } finally {
                instrumentation.runOnMainSync { foreground.finishAndRemoveTask() }
            }
            awaitWindowFocus(halo)
            instrumentation.runOnMainSync {
                assertSame(originalMenu.get(), haloMenu(halo))
                assertEquals(original, haloMenu(halo).selectedText)
            }
        } finally {
            finish(halo)
        }
    }

    @Test fun automaticCopyRequiresConsentAndAClipNewerThanTheMenu() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val selected = "Telegram fixture：精确文字 🧪"
        val freshIntent = automaticIntent(main, selected, clipPredatesMenu = false)
        val fresh = launchHalo(freshIntent)
        try {
            awaitWindowFocus(fresh)
            instrumentation.runOnMainSync { assertEquals(selected, haloMenu(fresh).selectedText) }
        } finally {
            finish(fresh)
        }
        awaitWindowFocus(main)
        assertRejected(automaticIntent(main, "Earlier clipboard fixture", clipPredatesMenu = true))
        awaitWindowFocus(main)
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, false)
        assertRejected(automaticIntent(main, "Consent disabled fixture", clipPredatesMenu = false))
    }

    @Test fun automaticCopyChecksDisabledSourceAndDistinguishesButtonModeBeforeReading() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val rules = AppRulesStore(context)
        rules.setProfile(sourcePackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
        assertRejected(automaticIntent(main, "Disabled source fixture", clipPredatesMenu = false))
        awaitWindowFocus(main)
        assertRejected(assistedIntent(main, "Disabled assisted source fixture", writeDuringAction = true))
        awaitWindowFocus(main)
        rules.setProfile(sourcePackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
        assertRejected(automaticIntent(main, "Button-only source fixture", clipPredatesMenu = false))
        awaitWindowFocus(main)
        val text = "Button mode explicitly assisted copy 🪁"
        val assisted = launchHalo(assistedIntent(main, text, writeDuringAction = true))
        try {
            awaitWindowFocus(assisted)
            instrumentation.runOnMainSync { assertEquals(text, haloMenu(assisted).selectedText) }
        } finally { finish(assisted) }
        awaitWindowFocus(main)
        rules.setProfile(sourcePackage, AppRulesStore.Profile())
        assertRejected(automaticIntent(main, "Missing source fixture", clipPredatesMenu = false).apply {
            removeExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE)
        })
    }

    @Test fun automaticCopyWaitingForFocusIsCancelledWhenItsAppIsDisabled() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val rules = AppRulesStore(context)
        for (assisted in listOf(false, true)) {
            rules.setProfile(sourcePackage, AppRulesStore.Profile())
            awaitWindowFocus(main)
            val intent = if (assisted) assistedIntent(main, "Waiting assisted source 🪁", writeDuringAction = true)
                else automaticIntent(main, "Waiting automatic source 🪁", clipPredatesMenu = false)
            val blocker = AtomicReference<Dialog>()
            val callbacks = object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, state: Bundle?) {
                    if (activity !is ClipboardHaloActivity) return
                    blocker.set(Dialog(activity).apply {
                        setContentView(TextView(activity).apply { text = "Temporary focus fixture" })
                        show()
                    })
                }
                override fun onActivityStarted(activity: Activity) = Unit
                override fun onActivityResumed(activity: Activity) = Unit
                override fun onActivityPaused(activity: Activity) = Unit
                override fun onActivityStopped(activity: Activity) = Unit
                override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
                override fun onActivityDestroyed(activity: Activity) = Unit
            }
            main.application.registerActivityLifecycleCallbacks(callbacks)
            var halo: ClipboardHaloActivity? = null
            try {
                val request = launchHalo(intent)
                halo = request
                awaitCondition("A real dialog must own focus before the pending request reads") {
                    blocker.get()?.window?.decorView?.hasWindowFocus() == true && !request.hasWindowFocus()
                }
                instrumentation.runOnMainSync {
                    val waiting = haloMenu(request)
                    assertFalse("A waiting wheel must not claim clipboard text is known", waiting.selectionTextKnown)
                    assertEquals("No text is read behind the dialog", "", waiting.selectedText)
                    val retry = descendants(waiting).filterIsInstance<Button>().filter {
                        it.contentDescription?.toString() == request.getString(R.string.clipboard_read_retry)
                    }
                    assertEquals("The pending wheel only offers an explicit read retry", 1, retry.size)
                    rules.setProfile(sourcePackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
                    assertTrue("Disabling the source must immediately cancel its pending request", request.isFinishing)
                    assertTrue("Disabling removes the pending wheel immediately", descendants(request.window.decorView).none { it is RadialMenuView })
                    blocker.get().dismiss()
                }
                awaitCondition("The disabled pending request must close") { request.isDestroyed }
                instrumentation.runOnMainSync {
                    assertTrue("Restoring focus must not show a wheel", descendants(request.window.decorView).none { it is RadialMenuView })
                }
            } finally {
                main.application.unregisterActivityLifecycleCallbacks(callbacks)
                instrumentation.runOnMainSync { blocker.get()?.dismiss() }
                halo?.let(::finish)
            }
        }
    }

    @Test fun automaticCopyAlreadyShownClosesWhenItsAppIsDisabledOrPaused() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val rules = AppRulesStore(context)
        for (assisted in listOf(false, true)) for (pause in listOf(false, true)) {
            rules.resume()
            rules.setProfile(sourcePackage, AppRulesStore.Profile())
            awaitWindowFocus(main)
            val text = "Visible source rule fixture 🪁"
            val intent = if (assisted) assistedIntent(main, text, writeDuringAction = true)
                else automaticIntent(main, text, clipPredatesMenu = false)
            val halo = launchHalo(intent)
            try {
                awaitWindowFocus(halo)
                instrumentation.runOnMainSync {
                    assertEquals(text, haloMenu(halo).selectedText)
                    if (pause) rules.pauseFor(AppRulesStore.TEN_MINUTES)
                    else rules.setProfile(sourcePackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
                    assertTrue("Disabled or paused requests must close even after a successful read", halo.isFinishing)
                }
                awaitCondition("The visible request must be destroyed after disabling it") { halo.isDestroyed }
            } finally { finish(halo) }
        }
    }

    @Test fun manualClipboardRemainsAvailableWithDisabledAppsAndPauseRules() = withClipboardHost { main ->
        val rules = AppRulesStore(context)
        rules.setProfile(sourcePackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
        rules.pauseFor(AppRulesStore.TEN_MINUTES)
        val text = "User explicitly opens clipboard 🪁"
        writeClip(main, ClipData.newPlainText("Manual fixture", text))
        val halo = launchHalo()
        try {
            awaitWindowFocus(halo)
            instrumentation.runOnMainSync {
                assertEquals(text, haloMenu(halo).selectedText)
                rules.resume()
                rules.setProfile(sourcePackage, AppRulesStore.Profile())
                rules.setProfile(sourcePackage, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
                rules.pauseFor(AppRulesStore.ONE_HOUR)
                assertFalse("App trigger restrictions must not cancel the explicit clipboard entry", halo.isFinishing)
                assertEquals(text, haloMenu(halo).selectedText)
            }
        } finally { finish(halo) }
    }

    @Test fun unavailableClipboardWaitsForExplicitRetry() = withClipboardHost { main ->
        assumeTrue(Build.VERSION.SDK_INT >= 28)
        instrumentation.runOnMainSync {
            assertTrue(main.hasWindowFocus())
            main.getSystemService(ClipboardManager::class.java).clearPrimaryClip()
        }
        val halo = launchHalo()
        try {
            awaitWindowFocus(halo)
            instrumentation.runOnMainSync {
                assertFalse("An unavailable read must keep a visible retry", halo.isFinishing)
                assertFalse(haloMenu(halo).selectionTextKnown)
                assertEquals("", haloMenu(halo).selectedText)
                assertTrue("Retry stays in the wheel, without the old Continue / Cancel card",
                    descendants(halo.window.decorView).filterIsInstance<Button>().none {
                        it.text.toString() == halo.getString(R.string.copy_action_continue) ||
                            it.text.toString() == halo.getString(R.string.cancel)
                    })
            }
            val text = "显式重试后的文字 🌍 e\u0301"
            writeClip(halo, ClipData.newPlainText("Retry fixture", text))
            instrumentation.runOnMainSync {
                val retry = descendants(halo.window.decorView).filterIsInstance<Button>().single {
                    it.contentDescription?.toString() == halo.getString(R.string.clipboard_read_retry)
                }
                assertFalse("Writing a newer clipboard must not cause a background/listener read", haloMenu(halo).selectionTextKnown)
                assertTrue(retry.performClick())
                assertEquals(text, haloMenu(halo).selectedText)
                assertTrue(haloMenu(halo).selectionTextKnown)
            }
        } finally { finish(halo) }
    }

    @Test fun unavailableClipboardWheelCanBeCancelledWithoutReadingANewerClip() = withClipboardHost { main ->
        assumeTrue(Build.VERSION.SDK_INT >= 28)
        instrumentation.runOnMainSync { main.getSystemService(ClipboardManager::class.java).clearPrimaryClip() }
        val halo = launchHalo()
        try {
            awaitWindowFocus(halo)
            writeClip(halo, ClipData.newPlainText("Unrequested replacement", "This text must remain unread"))
            instrumentation.runOnMainSync {
                val menu = haloMenu(halo)
                assertFalse(menu.selectionTextKnown)
                assertEquals("", menu.selectedText)
                val center = descendants(menu).filterIsInstance<Button>().single {
                    it.contentDescription?.toString()?.endsWith(halo.getString(R.string.radial_close_menu)) == true
                }
                center.performClick()
                assertTrue(halo.isFinishing)
                assertTrue(descendants(halo.window.decorView).none { it is RadialMenuView })
            }
        } finally { finish(halo) }
    }

    @Test fun automaticCopySurvivesTemporaryDialogFocusBeyondFourSeconds() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val text = "保留原复制时间的文字 🪁"
        val intent = automaticIntent(main, text, clipPredatesMenu = false)
        val blocker = AtomicReference<Dialog>()
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) {
                if (activity !is ClipboardHaloActivity) return
                blocker.set(Dialog(activity).apply {
                    setContentView(TextView(activity).apply { this.text = "Temporary focus fixture" })
                    show()
                })
            }
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        }
        main.application.registerActivityLifecycleCallbacks(callbacks)
        var halo: ClipboardHaloActivity? = null
        try {
            val request = launchHalo(intent)
            halo = request
            awaitCondition("A real dialog must own focus before the clipboard activity reads") {
                blocker.get()?.window?.decorView?.hasWindowFocus() == true && !request.hasWindowFocus()
            }
            SystemClock.sleep(TelegramCopyPolicy.MAX_EVENT_AGE_MS + 200)
            instrumentation.runOnMainSync {
                assertFalse("An accepted request must wait for the temporary dialog", request.isFinishing)
                assertFalse(haloMenu(request).selectionTextKnown)
                assertEquals("No text may be read while the temporary dialog owns focus", "", haloMenu(request).selectedText)
                assertTrue(descendants(haloMenu(request)).filterIsInstance<Button>().any {
                    it.text.toString() == request.getString(R.string.clipboard_focus_waiting)
                })
                blocker.get().dismiss()
            }
            awaitCondition("Restored focus must consume the original fresh copy") {
                descendants(request.window.decorView).filterIsInstance<RadialMenuView>()
                    .singleOrNull()?.selectedText == text
            }
        } finally {
            main.application.unregisterActivityLifecycleCallbacks(callbacks)
            instrumentation.runOnMainSync { blocker.get()?.dismiss() }
            halo?.let(::finish)
        }
    }

    @Test fun assistedCopyReadsExactUnicodeAndRejectsAnEarlierClipboard() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val selected = "只复制所选：你好 🌍 café e\u0301 & こんにちは\n第二行 👨‍👩‍👧‍👦"
        val fresh = launchHalo(assistedIntent(main, selected, writeDuringAction = true))
        try {
            awaitWindowFocus(fresh)
            instrumentation.runOnMainSync {
                assertEquals(selected, haloMenu(fresh).selectedText)
                assertTrue(haloMenu(fresh).gtaModeEnabled)
            }
        } finally {
            finish(fresh)
        }
        awaitWindowFocus(main)
        // The simulated Copy action did not write; the freshly seeded old clip must be rejected.
        assertRejected(assistedIntent(main, "Earlier clipboard must not impersonate Copy 🪁", writeDuringAction = false))
    }

    @Test fun assistedCopyRequiresConsentAndAnUnexpiredRequest() = withClipboardHost { main ->
        assertRejected(assistedIntent(main, "No consent fixture", writeDuringAction = true))
        awaitWindowFocus(main)
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        val expired = assistedIntent(main, "Expired request fixture", writeDuringAction = true).apply {
            putExtra(ClipboardHaloActivity.EXTRA_EVENT_UPTIME,
                SystemClock.uptimeMillis() - TelegramCopyPolicy.MAX_EVENT_AGE_MS - 1)
        }
        assertRejected(expired)
    }

    @Test fun aNewCopyRequestReplacesABackgroundHaloAndReadsTheNewText() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        withBackgroundHalo(main) { previous, foreground ->
            val selected = "第二次复制：不同的文字 🪁 e\u0301\n新的一行"
            val replacement = launchFreshRequest(assistedIntent(foreground, selected, writeDuringAction = true))
            try {
                assertNotSame(previous, replacement)
                awaitWindowFocus(replacement)
                awaitCondition("The earlier clipboard task must be destroyed") { previous.isDestroyed }
                instrumentation.runOnMainSync {
                    assertEquals(selected, haloMenu(replacement).selectedText)
                }
            } finally { finish(replacement) }
        }
    }

    @Test fun aFailedCopyRequestCannotBringAnEarlierHaloBackToTheForeground() = withClipboardHost { main ->
        fixturePreference("actionhalo_settings", TelegramCopyPolicy.SETTING, true)
        withBackgroundHalo(main) { previous, foreground ->
            val failedCopy = assistedIntent(foreground, "Old clipboard before failed Copy 🧪", writeDuringAction = false)
            val replacement = launchFreshRequest(failedCopy)
            try {
                assertNotSame(previous, replacement)
                awaitCondition("The failed request must reject its clip") {
                    replacement.isFinishing || replacement.isDestroyed
                }
                awaitCondition("The earlier halo must not survive the new request") { previous.isDestroyed }
                awaitWindowFocus(foreground)
                instrumentation.runOnMainSync {
                    assertTrue(descendants(replacement.window.decorView).none { it is RadialMenuView })
                }
            } finally { finish(replacement) }
        }
    }

    @Test fun uriOnlyClipboardDoesNotBecomeHaloText() = withClipboardHost { main ->
        // A raw URI has no text. No provider exists or should be contacted to coerce it to text.
        writeClip(main, ClipData.newRawUri("URI fixture", Uri.parse("content://clipboard.fixture.invalid/item")))
        assertRejected(ClipboardHaloActivity.requestIntent(context))
    }

    @Test fun diagnosticsPageReportCopiesOnlyDiagnosticsAndDoesNotIncludeThePreviousClip() = withClipboardHost(MainActivity.Page.DIAGNOSTICS) { main ->
        val privateMarker = "Private clipboard fixture 🪁 21803"
        writeClip(main, ClipData.newPlainText("Private fixture", privateMarker))
        instrumentation.runOnMainSync {
            val button = descendants(main.window.decorView).filterIsInstance<Button>().single {
                it.text.toString() == main.getString(R.string.health_copy_button)
            }
            assertTrue(button.performClick())
            val report = main.getSystemService(ClipboardManager::class.java).primaryClip
                ?.getItemAt(0)?.text?.toString().orEmpty()
            assertTrue(report.contains("当前服务连接："))
            assertTrue(report.contains("系统启用名单："))
            assertTrue(report.contains("telegram_copy_stage="))
            assertTrue(report.contains("org.telegram.messenger="))
            assertFalse(report.contains(privateMarker))
        }
    }

    private fun automaticIntent(main: MainActivity, text: String, clipPredatesMenu: Boolean): Intent {
        val result = AtomicReference<Intent>()
        instrumentation.runOnMainSync {
            assertTrue(main.hasWindowFocus())
            val menuBeforeCopy = System.currentTimeMillis() - 1_000
            main.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Fixture", text))
            val eventWall = System.currentTimeMillis()
            result.set(ClipboardHaloActivity.requestIntent(context).apply {
                action = ClipboardHaloActivity.ACTION_TELEGRAM_COPY
                putExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE, sourcePackage)
                putExtra(ClipboardHaloActivity.EXTRA_EVENT_UPTIME, SystemClock.uptimeMillis())
                putExtra(ClipboardHaloActivity.EXTRA_EVENT_WALL_TIME, eventWall)
                putExtra(ClipboardHaloActivity.EXTRA_MENU_OPENED_WALL_TIME,
                    if (clipPredatesMenu) eventWall else menuBeforeCopy)
            })
        }
        return result.get()
    }

    private fun assistedIntent(main: MainActivity, text: String, writeDuringAction: Boolean): Intent {
        if (!writeDuringAction) {
            writeClip(main, ClipData.newPlainText("Earlier fixture", text))
            val earlierTimestamp = AtomicReference<Long>()
            instrumentation.runOnMainSync {
                assertTrue(main.hasWindowFocus())
                earlierTimestamp.set(main.getSystemService(ClipboardManager::class.java)
                    .primaryClip!!.description.timestamp)
            }
            // Advance beyond the real system-assigned timestamp on the test thread, not the UI.
            val deadline = SystemClock.uptimeMillis() + 5_000
            while (System.currentTimeMillis() <= earlierTimestamp.get() && SystemClock.uptimeMillis() < deadline) {
                SystemClock.sleep(1)
            }
            assertTrue("Fixture clock must advance past the earlier clip", System.currentTimeMillis() > earlierTimestamp.get())
        }
        val result = AtomicReference<Intent>()
        instrumentation.runOnMainSync {
            assertTrue(main.hasWindowFocus())
            val started = System.currentTimeMillis()
            val uptime = SystemClock.uptimeMillis()
            if (writeDuringAction) {
                main.getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("Assisted Copy fixture", text))
            }
            val finished = System.currentTimeMillis()
            result.set(ClipboardHaloActivity.requestIntent(context).apply {
                action = ClipboardHaloActivity.ACTION_TELEGRAM_COPY_ASSISTED
                putExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE, sourcePackage)
                putExtra(ClipboardHaloActivity.EXTRA_EVENT_UPTIME, uptime)
                putExtra(ClipboardHaloActivity.EXTRA_COPY_STARTED_WALL_TIME, started)
                putExtra(ClipboardHaloActivity.EXTRA_COPY_FINISHED_WALL_TIME, finished)
            })
        }
        return result.get()
    }

    private fun assertRejected(intent: Intent) {
        val activity = launchHalo(intent)
        try {
            awaitCondition("Invalid clipboard entry should finish") { activity.isFinishing || activity.isDestroyed }
            instrumentation.runOnMainSync {
                assertTrue(descendants(activity.window.decorView).none { it is RadialMenuView })
            }
        } finally {
            finish(activity)
        }
    }

    private fun launchHalo(intent: Intent = ClipboardHaloActivity.requestIntent(context)) =
        instrumentation.startActivitySync(intent) as ClipboardHaloActivity

    private fun withBackgroundHalo(main: MainActivity, block: (ClipboardHaloActivity, MainActivity) -> Unit) {
        val previous = launchHalo(assistedIntent(main, "Earlier halo must never be reused 🌍", writeDuringAction = true))
        var foreground: MainActivity? = null
        try {
            awaitWindowFocus(previous)
            // Keep the first halo alive in its separate task, just as switching back to Telegram does.
            foreground = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK)) as MainActivity
            awaitWindowFocus(foreground)
            instrumentation.runOnMainSync { assertFalse(previous.hasWindowFocus()) }
            block(previous, foreground)
        } finally {
            foreground?.let { activity -> instrumentation.runOnMainSync { activity.finishAndRemoveTask() } }
            finish(previous)
        }
    }

    private fun launchFreshRequest(intent: Intent): ClipboardHaloActivity {
        // Unlike startActivitySync, a bounded monitor also fails promptly if Android merely
        // resurfaces the old task without creating an activity for this new request.
        val monitor = instrumentation.addMonitor(ClipboardHaloActivity::class.java.name, null, false)
        return try {
            instrumentation.runOnMainSync { context.startActivity(intent) }
            monitor.waitForActivityWithTimeout(5_000) as? ClipboardHaloActivity
                ?: throw AssertionError("A new clipboard request must create a fresh activity, not resurface an old halo")
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    private fun withClipboardHost(page: MainActivity.Page = MainActivity.Page.HOME, block: (MainActivity) -> Unit) {
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, page)).use { scenario ->
            val reference = AtomicReference<MainActivity>()
            scenario.onActivity { reference.set(it) }
            val main = reference.get()
            awaitWindowFocus(main)
            val originalClip = AtomicReference<ClipData?>()
            scenario.onActivity { originalClip.set(it.getSystemService(ClipboardManager::class.java).primaryClip) }
            try {
                block(main)
            } finally {
                awaitWindowFocus(main)
                scenario.onActivity {
                    val clipboard = it.getSystemService(ClipboardManager::class.java)
                    val clip = originalClip.get()
                    if (clip != null) clipboard.setPrimaryClip(clip)
                    else if (Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
                    else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                }
            }
        }
    }

    private fun writeClip(activity: Activity, clip: ClipData) {
        instrumentation.runOnMainSync {
            assertTrue(activity.hasWindowFocus())
            activity.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        }
    }

    private fun fixturePreference(name: String, key: String, value: Boolean) {
        val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        val location = name to key
        if (!savedPreferences.containsKey(location)) {
            savedPreferences[location] = if (preferences.contains(key)) preferences.getBoolean(key, false) else null
        }
        assertTrue(preferences.edit().putBoolean(key, value).commit())
    }

    private fun finish(activity: Activity) {
        instrumentation.runOnMainSync { activity.finish() }
        instrumentation.waitForIdleSync()
    }

    private fun awaitWindowFocus(activity: Activity) = awaitCondition(
        "Expected ${activity.javaClass.simpleName} to gain window focus"
    ) { activity.hasWindowFocus() }

    private fun awaitCondition(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            instrumentation.waitForIdleSync()
            var satisfied = false
            instrumentation.runOnMainSync { satisfied = condition() }
            if (satisfied) return
            SystemClock.sleep(25)
        } while (SystemClock.uptimeMillis() < deadline)
        fail(message)
    }

    private fun haloMenu(activity: Activity) = descendants(activity.window.decorView)
        .filterIsInstance<RadialMenuView>().single()

    private fun descendants(root: View): List<View> = buildList {
        add(root)
        if (root is ViewGroup) for (index in 0 until root.childCount) addAll(descendants(root.getChildAt(index)))
    }
}
