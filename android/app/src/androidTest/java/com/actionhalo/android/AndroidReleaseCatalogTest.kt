package com.actionhalo.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AndroidReleaseCatalogTest {
    @Test fun liveUpdateCheckCompletesUsingThePublicRepository() {
        org.junit.Assume.assumeTrue(androidx.test.platform.app.InstrumentationRegistry.getArguments()
            .getString("android_updates_network") == "true")
        assertDisposableEmulator()
        val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        androidx.test.core.app.ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ABOUT)).use { scenario ->
            lateinit var check: android.widget.Button
            scenario.onActivity { activity ->
                check = descendants(activity.window.decorView).filterIsInstance<android.widget.Button>()
                    .single { it.text.toString() == activity.getString(R.string.update_check) }
                check.performClick()
                assertFalse(check.isEnabled)
            }
            var complete = false
            val deadline = android.os.SystemClock.uptimeMillis() + 45_000
            while (!complete && android.os.SystemClock.uptimeMillis() < deadline) {
                scenario.onActivity { complete = check.isEnabled }
                if (!complete) android.os.SystemClock.sleep(30)
            }
            assertTrue("The real HTTPS request must complete", complete)
            scenario.onActivity { activity ->
                assertFalse(descendants(activity.window.decorView).filterIsInstance<android.widget.TextView>()
                    .any { it.text.toString() == activity.getString(R.string.update_failed) })
            }
        }
    }

    private fun descendants(view: android.view.View): List<android.view.View> = listOf(view) + if (view is android.view.ViewGroup)
        (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()

    private fun release(version: String, channel: String = "debug", draft: Boolean = false, prerelease: Boolean = false,
        url: String? = null, name: String = "ActionHalo-$version-$channel.apk") = JSONObject().apply {
        put("draft", draft); put("prerelease", prerelease); put("body", "Fixed selection and translation")
        put("assets", JSONArray().put(JSONObject().apply {
            put("name", name); put("size", 1_024); put("state", "uploaded")
            put("browser_download_url", url ?: "https://github.com/Wooden-Robot/ActionHalo/releases/download/android-v$version/$name")
        }))
    }

    @Test fun selectsNumericAndroidVersionsAndKeepsSigningChannelsSeparate() {
        val json = JSONArray().put(release("0.9.9")).put(release("0.10.0"))
            .put(release("1.0.0", "release")).put(release("9.0.0", draft = true))
            .put(release("8.0.0", prerelease = true)).put(release("7.0.0", name = "ActionHalo.dmg")).toString()
        assertEquals("0.10.0", AndroidReleaseCatalog.latest(json, true)?.version)
        assertEquals("1.0.0", AndroidReleaseCatalog.latest(json, false)?.version)
        assertNull(AndroidReleaseCatalog.latest(JSONArray().put(release("7.0.0", name = "ActionHalo.dmg")).toString(), true))
    }

    @Test fun rejectsForeignAndAmbiguousDownloadLocations() {
        val filename = "ActionHalo-0.8.1-debug.apk"
        listOf(
            "http://github.com/Wooden-Robot/ActionHalo/releases/download/v0.8.1/$filename",
            "https://github.com.evil.example/Wooden-Robot/ActionHalo/releases/download/v0.8.1/$filename",
            "https://github.com/Other/ActionHalo/releases/download/v0.8.1/$filename",
            "https://user@github.com/Wooden-Robot/ActionHalo/releases/download/v0.8.1/$filename",
            "https://github.com:444/Wooden-Robot/ActionHalo/releases/download/v0.8.1/$filename",
            "https://github.com/Wooden-Robot/ActionHalo/releases/download/v0.8.1/$filename?redirect=x",
            "https://github.com/Wooden-Robot/ActionHalo/releases/download/../../Other/$filename",
        ).forEach { url -> assertNull(url, AndroidReleaseCatalog.latest(JSONArray().put(release("0.8.1", url = url)).toString(), true)) }
    }
}
