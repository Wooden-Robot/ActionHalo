package com.actionhalo.android

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class AndroidUpdateCheckerTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val preferences = context.getSharedPreferences(AndroidUpdateChecker.PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val checkers = mutableListOf<AndroidUpdateChecker>()
    private var previous: Map<String, String?> = emptyMap()

    @Before fun isolate() {
        previous = listOf(AndroidUpdateChecker.LAST_AUTOMATIC_CHECK_DAY, AndroidUpdateChecker.CACHED_RELEASE)
            .associateWith { preferences.getString(it, null) }
        assertTrue(preferences.edit().apply { previous.keys.forEach(::remove) }.commit())
    }

    @After fun restore() {
        instrumentation.runOnMainSync { checkers.forEach { it.close() } }
        assertTrue(preferences.edit().apply { previous.forEach { (key, value) -> putString(key, value) } }.commit())
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
                    when (requests.incrementAndGet()) {
                        1 -> throw IOException("Offline fixture")
                        2 -> Response(releases("99.0.0"))
                        else -> Response("[]")
                    }
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
                assertNotNull(preferences.getString(AndroidUpdateChecker.CACHED_RELEASE, null))
                manual.performClick()
            }
            awaitUi { requests.get() == 3 && manual.isEnabled }
            scenario.onActivity {
                assertNull("A successful check without a newer release clears stale notices",
                    preferences.getString(AndroidUpdateChecker.CACHED_RELEASE, null))
                assertEquals(View.GONE, download.visibility)
            }
        }
    }

    @Test fun newReleaseNoticeSurvivesRecreationWithoutAnotherRequestOrAutomaticDownload() {
        val opened = AtomicReference<Intent?>()
        val requests = AtomicInteger()
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
                lateinit var checker: AndroidUpdateChecker
                scenario.onActivity { activity ->
                    checker = newChecker(activity) { requests.incrementAndGet(); Response(releases("99.0.0")) }
                    val card = LinearLayout(activity)
                    checker.addStartupNotice(card)
                    notice = card.getChildAt(0) as Button
                    assertTrue(checker.checkOnLaunch())
                }
                awaitUi { notice.visibility == View.VISIBLE }
                scenario.onActivity { activity ->
                    assertEquals(activity.getString(R.string.update_available, "99.0.0"), notice.text.toString())
                    assertNull(opened.get())
                    checker.close()
                }
                scenario.recreate()
                scenario.onActivity { activity ->
                    checker = newChecker(activity) { requests.incrementAndGet(); Response("[]") }
                    val card = LinearLayout(activity)
                    checker.addStartupNotice(card)
                    notice = card.getChildAt(0) as Button
                    assertFalse(checker.checkOnLaunch())
                    assertEquals(View.VISIBLE, notice.visibility)
                    assertEquals(activity.getString(R.string.update_available, "99.0.0"), notice.text.toString())
                    assertEquals(1, requests.get())
                    assertNull(opened.get())
                    notice.performClick()
                }
                assertEquals(downloadUrl("99.0.0"), opened.get()?.dataString)
            }
        } finally { instrumentation.removeMonitor(monitor) }
    }

    @Test fun returningHomeRefreshesTheNoticeAfterManualChecksWithoutAnotherRequest() {
        preferences.edit().putString(AndroidUpdateChecker.LAST_AUTOMATIC_CHECK_DAY, LocalDate.now().toString()).commit()
        val requests = AtomicInteger()
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
            lateinit var homeChecker: AndroidUpdateChecker
            lateinit var notice: Button
            lateinit var manual: Button
            scenario.onActivity { activity ->
                homeChecker = newChecker(activity) { fail("Returning home must honor today's request limit"); Response("[]") }
                val homeCard = LinearLayout(activity)
                homeChecker.addStartupNotice(homeCard)
                notice = homeCard.getChildAt(0) as Button
                val aboutCard = LinearLayout(activity)
                newChecker(activity) {
                    Response(if (requests.incrementAndGet() == 1) releases("99.0.0") else "[]")
                }.addControls(aboutCard)
                manual = aboutCard.getChildAt(1) as Button
                assertEquals(View.GONE, notice.visibility)
                manual.performClick()
            }
            awaitUi { requests.get() == 1 && manual.isEnabled }
            scenario.onActivity {
                assertFalse(homeChecker.checkOnLaunch())
                assertEquals(View.VISIBLE, notice.visibility)
                manual.performClick()
            }
            awaitUi { requests.get() == 2 && manual.isEnabled }
            scenario.onActivity {
                assertFalse(homeChecker.checkOnLaunch())
                assertEquals(View.GONE, notice.visibility)
            }
        }
    }

    @Test fun cachedNoticesRejectInvalidVersionsForeignUrlsAndInstalledReleases() {
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
            scenario.onActivity { activity ->
                val checker = newChecker(activity) { fail("Cached notices must not fetch releases"); Response("[]") }
                listOf(
                    "99.0.0" to "https://evil.example/update.apk",
                    "invalid" to downloadUrl("99.0.0"),
                    "99.0.0" to downloadUrl("98.0.0"),
                    "99.0.0" to downloadUrl("99.0.0").replace(
                        if (BuildConfig.DEBUG) "-debug.apk" else "-release.apk",
                        if (BuildConfig.DEBUG) "-release.apk" else "-debug.apk"),
                    BuildConfig.VERSION_NAME to downloadUrl(BuildConfig.VERSION_NAME),
                ).forEach { (version, url) ->
                    preferences.edit().putString(AndroidUpdateChecker.CACHED_RELEASE,
                        JSONObject().put("version", version).put("downloadUrl", url).toString()).apply()
                    val card = LinearLayout(activity)
                    checker.addStartupNotice(card)
                    assertEquals("$version / $url", View.GONE, card.getChildAt(0).visibility)
                }
                preferences.edit().putString(AndroidUpdateChecker.CACHED_RELEASE, "not json").apply()
                val card = LinearLayout(activity)
                checker.addStartupNotice(card)
                assertEquals(View.GONE, card.getChildAt(0).visibility)
            }
        }
    }

    @Test fun olderAutomaticSuccessCannotReplaceANewerManualRelease() =
        verifyDelayedAutomaticResult(newerResponse = releases("100.0.0"), expectedVersion = "100.0.0")

    @Test fun olderAutomaticSuccessCannotReviveAManuallyWithdrawnRelease() =
        verifyDelayedAutomaticResult(newerResponse = "[]", expectedVersion = null)

    @Test fun newerManualFailureStillAllowsAnEarlierAutomaticSuccess() =
        verifyDelayedAutomaticResult(newerResponse = null, expectedVersion = "99.0.0")

    private fun verifyDelayedAutomaticResult(newerResponse: String?, expectedVersion: String?) {
        assertTrue(preferences.edit().putString(AndroidUpdateChecker.CACHED_RELEASE,
            JSONObject().put("version", "98.0.0").put("downloadUrl", downloadUrl("98.0.0")).toString()).commit())
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val requests = AtomicInteger()
        try {
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
                lateinit var homeChecker: AndroidUpdateChecker
                lateinit var notice: Button
                lateinit var manual: Button
                lateinit var manualStatus: TextView
                scenario.onActivity { activity ->
                    homeChecker = newChecker(activity) {
                        requests.incrementAndGet()
                        Response(releases("99.0.0")) {
                            started.countDown()
                            check(release.await(10, TimeUnit.SECONDS))
                        }
                    }
                    val homeCard = LinearLayout(activity)
                    homeChecker.addStartupNotice(homeCard)
                    notice = homeCard.getChildAt(0) as Button
                    val aboutCard = LinearLayout(activity)
                    newChecker(activity) {
                        requests.incrementAndGet()
                        if (newerResponse == null) throw IOException("Newer manual failure fixture")
                        Response(newerResponse)
                    }.addControls(aboutCard)
                    manualStatus = aboutCard.getChildAt(0) as TextView
                    manual = aboutCard.getChildAt(1) as Button
                    assertTrue(homeChecker.checkOnLaunch())
                }
                assertTrue("The older request must be in flight first", started.await(5, TimeUnit.SECONDS))
                scenario.onActivity { assertTrue(manual.performClick()) }
                awaitUi { requests.get() == 2 && manual.isEnabled }
                val expectedManualStatus = when {
                    newerResponse == null -> context.getString(R.string.update_failed)
                    expectedVersion == null -> context.getString(R.string.update_no_android_release)
                    else -> context.getString(R.string.update_available, expectedVersion)
                }
                scenario.onActivity {
                    assertEquals(expectedManualStatus, manualStatus.text.toString())
                    assertEquals(context.getString(R.string.update_available, "98.0.0"), notice.text.toString())
                }

                release.countDown()
                awaitUi {
                    if (expectedVersion == null) notice.visibility == View.GONE
                    else notice.text.toString() == context.getString(R.string.update_available, expectedVersion)
                }
                scenario.onActivity {
                    val cached = preferences.getString(AndroidUpdateChecker.CACHED_RELEASE, null)
                    if (expectedVersion == null) assertNull(cached)
                    else assertEquals(expectedVersion, JSONObject(checkNotNull(cached)).getString("version"))
                    assertEquals(expectedManualStatus, manualStatus.text.toString())
                    assertFalse("Refreshing the current notice must preserve the daily limit", homeChecker.checkOnLaunch())
                    assertEquals(2, requests.get())
                }
            }
        } finally { release.countDown() }
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

    private class Response(private val body: String, private val beforeResponse: () -> Unit = {}) :
        HttpURLConnection(URL(AndroidReleaseCatalog.API_URL)) {
        override fun getResponseCode(): Int { beforeResponse(); return 200 }
        override fun getInputStream() = ByteArrayInputStream(body.toByteArray(Charsets.UTF_8))
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
    }
}
