package com.actionhalo.android

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class AndroidUpdateCheckerTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val preferences = context.getSharedPreferences(AndroidUpdateChecker.PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val checkers = mutableListOf<AndroidUpdateChecker>()
    private var previousDay: String? = null

    @Before fun isolate() {
        previousDay = preferences.getString(AndroidUpdateChecker.LAST_AUTOMATIC_CHECK_DAY, null)
        assertTrue(preferences.edit().remove(AndroidUpdateChecker.LAST_AUTOMATIC_CHECK_DAY).commit())
    }

    @After fun restore() {
        instrumentation.runOnMainSync { checkers.forEach { it.close() } }
        assertTrue(preferences.edit().putString(AndroidUpdateChecker.LAST_AUTOMATIC_CHECK_DAY, previousDay).commit())
    }

    @Test fun launchChecksOncePerLocalDayAcrossRecreationAndYearBoundary() {
        val requests = AtomicInteger()
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
            lateinit var checker: AndroidUpdateChecker
            val today = LocalDate.of(2026, 12, 31)
            scenario.onActivity { activity ->
                checker = newChecker(activity) { requests.incrementAndGet(); Response("[]") }
                assertTrue(checker.checkOnLaunch(today))
                assertFalse(checker.checkOnLaunch(today))
            }
            awaitUi { requests.get() == 1 }
            scenario.onActivity { checker.close() }
            scenario.recreate()
            scenario.onActivity { activity ->
                checker = newChecker(activity) { requests.incrementAndGet(); Response("[]") }
                assertFalse("A new Activity must preserve today's limit", checker.checkOnLaunch(today))
                assertTrue(checker.checkOnLaunch(today.plusDays(1)))
                assertFalse(checker.checkOnLaunch(today.plusDays(1)))
            }
            awaitUi { requests.get() == 2 }
            assertEquals("2027-01-01", preferences.getString(AndroidUpdateChecker.LAST_AUTOMATIC_CHECK_DAY, null))
        }
    }

    @Test fun offlineLaunchStaysQuietAndManualChecksStillRetryOnTheSameDay() {
        val requests = AtomicInteger()
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
            lateinit var checker: AndroidUpdateChecker
            lateinit var notice: Button
            lateinit var manual: Button
            lateinit var download: Button
            scenario.onActivity { activity ->
                checker = newChecker(activity) {
                    if (requests.incrementAndGet() == 1) throw IOException("Offline fixture")
                    Response(releases("99.0.0"))
                }
                val card = LinearLayout(activity)
                checker.addStartupNotice(card)
                notice = card.getChildAt(0) as Button
                checker.addControls(card)
                manual = card.getChildAt(2) as Button
                download = card.getChildAt(3) as Button
                assertTrue(checker.checkOnLaunch())
            }
            awaitUi { requests.get() == 1 }
            scenario.onActivity {
                assertFalse(checker.checkOnLaunch())
                manual.performClick()
            }
            awaitUi { requests.get() == 2 && manual.isEnabled && download.visibility == View.VISIBLE }
            scenario.onActivity {
                assertEquals("Automatic failures must not show an update notice", View.GONE, notice.visibility)
                manual.performClick()
            }
            awaitUi { requests.get() == 3 && manual.isEnabled }
        }
    }

    @Test fun newReleaseShowsAnExplicitDownloadButtonWithoutLaunchingTheBrowserAutomatically() {
        val opened = AtomicReference<Intent?>()
        val monitor = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
                if (intent.action != Intent.ACTION_VIEW) return null
                opened.set(Intent(intent))
                return Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
                lateinit var notice: Button
                scenario.onActivity { activity ->
                    val checker = newChecker(activity) { Response(releases("99.0.0")) }
                    val card = LinearLayout(activity)
                    checker.addStartupNotice(card)
                    notice = card.getChildAt(0) as Button
                    assertTrue(checker.checkOnLaunch())
                }
                awaitUi { notice.visibility == View.VISIBLE }
                scenario.onActivity { activity ->
                    assertEquals(activity.getString(R.string.update_available, "99.0.0"), notice.text.toString())
                    assertNull(opened.get())
                    notice.performClick()
                }
                assertEquals(downloadUrl("99.0.0"), opened.get()?.dataString)
            }
        } finally { instrumentation.removeMonitor(monitor) }
    }

    private fun newChecker(activity: Activity, connection: () -> HttpURLConnection): AndroidUpdateChecker =
        AndroidUpdateChecker(activity, connection).also { checkers += it }

    private fun awaitUi(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            var complete = false
            instrumentation.runOnMainSync { complete = condition() }
            if (complete) return
            SystemClock.sleep(10)
        }
        fail("The update check must complete")
    }

    private fun downloadUrl(version: String): String {
        val channel = if (BuildConfig.DEBUG) "debug" else "release"
        return "https://github.com/Wooden-Robot/ActionHalo/releases/download/android-v$version/ActionHalo-$version-$channel.apk"
    }

    private fun releases(version: String): String = JSONArray().put(JSONObject().apply {
        put("tag_name", "android-v$version")
        put("draft", false); put("prerelease", false)
        put("assets", JSONArray().put(JSONObject().apply {
            put("name", downloadUrl(version).substringAfterLast('/'))
            put("size", 1_024); put("state", "uploaded")
            put("browser_download_url", downloadUrl(version))
        }))
    }).toString()

    private class Response(private val body: String) : HttpURLConnection(URL(AndroidReleaseCatalog.API_URL)) {
        override fun getResponseCode() = 200
        override fun getInputStream() = ByteArrayInputStream(body.toByteArray(Charsets.UTF_8))
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
    }
}
