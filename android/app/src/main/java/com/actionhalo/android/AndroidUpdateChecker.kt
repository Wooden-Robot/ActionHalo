package com.actionhalo.android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.widget.LinearLayout
import android.widget.Button
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.time.LocalDate
import java.util.concurrent.Executors

internal data class AndroidRelease(val version: String, val notes: String, val downloadUrl: String)

internal object AndroidReleaseCatalog {
    const val RELEASES_URL = "https://github.com/Wooden-Robot/ActionHalo/releases"
    const val API_URL = "https://api.github.com/repos/Wooden-Robot/ActionHalo/releases?per_page=100"

    fun latest(json: String, debug: Boolean): AndroidRelease? {
        val releases = JSONArray(json)
        val channel = if (debug) "debug" else "release"
        val filename = Regex("ActionHalo-([0-9]+\\.[0-9]+\\.[0-9]+)-$channel\\.apk")
        val candidates = mutableListOf<AndroidRelease>()
        for (index in 0 until minOf(releases.length(), 100)) {
            val release = releases.optJSONObject(index) ?: continue
            if (release.optBoolean("draft") || release.optBoolean("prerelease")) continue
            val tag = release.optString("tag_name")
            if (!tag.startsWith("android-v")) continue
            val releaseVersion = tag.removePrefix("android-v")
            if (AndroidVersion.parse(releaseVersion) == null) continue
            val assets = release.optJSONArray("assets") ?: continue
            for (assetIndex in 0 until assets.length()) {
                val asset = assets.optJSONObject(assetIndex) ?: continue
                val name = asset.optString("name")
                val version = filename.matchEntire(name)?.groupValues?.get(1) ?: continue
                if (version != releaseVersion || asset.optString("state") != "uploaded" || asset.optLong("size") <= 0) continue
                val url = asset.optString("browser_download_url")
                val uri = try { URI(url) } catch (_: Exception) { continue }
                val path = uri.path ?: continue
                val downloadPath = path.removePrefix("/Wooden-Robot/ActionHalo/releases/download/").split('/')
                if (uri.scheme != "https" || uri.host != "github.com" || uri.userInfo != null || uri.port != -1 ||
                    uri.query != null || uri.fragment != null ||
                    !path.startsWith("/Wooden-Robot/ActionHalo/releases/download/") ||
                    uri.normalize().path != path || downloadPath.size != 2 || downloadPath[0] != tag || downloadPath[1] != name) continue
                candidates += AndroidRelease(version, release.optString("body").take(8_000), url)
            }
        }
        return candidates.maxByOrNull { AndroidVersion.parse(it.version)!! }
    }
}

/** Checks once per local day on launch, or on demand; downloads remain explicit. */
internal class AndroidUpdateChecker(
    private val activity: Activity,
    private val openConnection: () -> HttpURLConnection = {
        URL(AndroidReleaseCatalog.API_URL).openConnection() as HttpURLConnection
    }
) : AutoCloseable {
    companion object {
        const val PREFERENCES_NAME = "android_updates"
        const val LAST_AUTOMATIC_CHECK_DAY = "last_automatic_check_day"
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val preferences = activity.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private var startupNotice: Button? = null
    @Volatile private var closed = false
    @Volatile private var connection: HttpURLConnection? = null

    fun addStartupNotice(card: LinearLayout) {
        startupNotice = HaloUi.button(activity, "", true).apply { visibility = android.view.View.GONE }
            .also { card.addView(it, LinearLayout.LayoutParams(-1, -2)) }
    }

    fun checkOnLaunch(day: LocalDate = LocalDate.now()): Boolean {
        if (closed || preferences.getString(LAST_AUTOMATIC_CHECK_DAY, null) == day.toString()) return false
        // Count attempts so offline launches and activity recreation cannot keep retrying.
        preferences.edit().putString(LAST_AUTOMATIC_CHECK_DAY, day.toString()).apply()
        checkForUpdates { outcome ->
            val release = outcome.getOrNull() ?: return@checkForUpdates
            if (!isNewer(release)) return@checkForUpdates
            startupNotice?.apply {
                text = activity.getString(R.string.update_available, release.version)
                visibility = android.view.View.VISIBLE
                setOnClickListener { open(release.downloadUrl, this) }
            }
        }
        return true
    }

    fun addControls(card: LinearLayout) {
        val status = HaloUi.label(activity, activity.getString(R.string.update_description), 14f, HaloUi.secondary)
        val check = HaloUi.button(activity, activity.getString(R.string.update_check), true)
        val download = HaloUi.button(activity, activity.getString(R.string.update_download)).apply { visibility = android.view.View.GONE }
        card.addView(status)
        card.addView(check, LinearLayout.LayoutParams(-1, -2))
        card.addView(download, LinearLayout.LayoutParams(-1, -2))
        card.addView(HaloUi.button(activity, activity.getString(R.string.update_releases)).apply {
            setOnClickListener { open(AndroidReleaseCatalog.RELEASES_URL, status) }
        }, LinearLayout.LayoutParams(-1, -2))
        check.setOnClickListener {
            check.isEnabled = false
            download.visibility = android.view.View.GONE
            status.setText(R.string.update_checking)
            checkForUpdates { outcome ->
                check.isEnabled = true
                outcome.fold(onSuccess = { release ->
                    when {
                        release == null -> status.setText(R.string.update_no_android_release)
                        !isNewer(release) -> status.setText(R.string.update_current)
                        else -> {
                            status.text = activity.getString(R.string.update_available, release.version) +
                                if (release.notes.isBlank()) "" else "\n\n${release.notes}"
                            download.visibility = android.view.View.VISIBLE
                            download.setOnClickListener { open(release.downloadUrl, status) }
                        }
                    }
                }, onFailure = { status.setText(R.string.update_failed) })
            }
        }
    }

    private fun isNewer(release: AndroidRelease): Boolean =
        AndroidVersion.parse(release.version)!! > AndroidVersion.parse(BuildConfig.VERSION_NAME)!!

    private fun checkForUpdates(completion: (Result<AndroidRelease?>) -> Unit) {
        if (closed) return
        worker.execute {
            val outcome = runCatching { AndroidReleaseCatalog.latest(fetch(), BuildConfig.DEBUG) }
            main.post {
                if (!closed && !activity.isDestroyed && !activity.isFinishing) completion(outcome)
            }
        }
    }

    private fun fetch(): String {
        val request = openConnection()
        connection = request
        try {
            request.connectTimeout = 10_000
            request.readTimeout = 15_000
            request.instanceFollowRedirects = false
            request.setRequestProperty("Accept", "application/vnd.github+json")
            request.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            request.setRequestProperty("User-Agent", "ActionHalo-Android/${BuildConfig.VERSION_NAME}")
            check(request.responseCode == 200)
            return request.inputStream.use { stream ->
                val bytes = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8_192)
                while (true) {
                    if (closed || Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException()
                    val count = stream.read(buffer)
                    if (count == -1) break
                    check(bytes.size() + count <= 2 * 1024 * 1024)
                    bytes.write(buffer, 0, count)
                }
                bytes.toString("UTF-8")
            }
        } finally {
            request.disconnect()
            connection = null
        }
    }

    private fun open(url: String, status: android.widget.TextView) {
        try { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
        catch (_: ActivityNotFoundException) { status.setText(R.string.action_no_app) }
        catch (_: SecurityException) { status.setText(R.string.action_no_app) }
    }

    override fun close() {
        closed = true
        connection?.disconnect()
        worker.shutdownNow()
        main.removeCallbacksAndMessages(null)
    }
}
