package com.actionhalo.android

import android.content.ComponentName
import android.content.Context
import android.os.SystemClock
import android.service.quicksettings.TileService
import org.json.JSONArray
import org.json.JSONObject

/** Configuration only: source package names and action IDs, never selection or clipboard contents. */
internal class AppRulesStore(private val context: Context) {
    enum class TriggerMode { DEFAULT, AUTO, BUTTON, OFF }
    data class Profile(val trigger: TriggerMode = TriggerMode.DEFAULT, val actions: List<String>? = null)
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun packages(): List<String> = profiles().keys().asSequence().toList().sorted()
    fun disabledPackages(): Set<String> {
        val profiles = profiles()
        return profiles.keys().asSequence()
            .filter { profiles.optJSONObject(it)?.optString("trigger") == TriggerMode.OFF.name }.toSet()
    }

    /** Update the blacklist together, keeping each app's independent action order. */
    fun setDisabledPackages(packages: Set<String>) {
        require(packages.size <= 200 && packages.all(::isValidPackageName))
        val profiles = profiles()
        profiles.keys().asSequence().toList().forEach { pkg ->
            val profile = profiles.optJSONObject(pkg) ?: return@forEach
            if (profile.optString("trigger") == TriggerMode.OFF.name && pkg !in packages) {
                if (!profile.has("actions") || profile.isNull("actions")) profiles.remove(pkg)
                else profile.put("trigger", TriggerMode.DEFAULT.name)
            }
        }
        packages.forEach { pkg ->
            val profile = profiles.optJSONObject(pkg) ?: JSONObject()
            profiles.put(pkg, profile.put("trigger", TriggerMode.OFF.name))
        }
        require(profiles.length() <= 200)
        preferences.edit().putString(PROFILES, profiles.toString()).apply()
    }

    fun profile(packageName: String?): Profile {
        val item = packageName?.let { profiles().optJSONObject(it) } ?: return Profile()
        val trigger = TriggerMode.entries.find { it.name == item.optString("trigger") } ?: TriggerMode.DEFAULT
        val actions = item.optJSONArray("actions")?.let { array ->
            List(array.length()) { array.optString(it) }.filter { it.isNotBlank() }.distinct()
        }
        return Profile(trigger, actions)
    }
    fun triggerMode(packageName: String?): TriggerMode = profile(packageName).trigger
    fun setProfile(packageName: String, profile: Profile) {
        require(isValidPackageName(packageName))
        val profiles = profiles()
        if (profile == Profile()) profiles.remove(packageName)
        else profiles.put(packageName, JSONObject().apply {
            put("trigger", profile.trigger.name)
            profile.actions?.let { put("actions", JSONArray(it.distinct())) }
        })
        preferences.edit().putString(PROFILES, profiles.toString()).apply()
    }
    fun remove(packageName: String) { setProfile(packageName, Profile()) }

    fun actionsFor(packageName: String?, allActions: List<HaloAction>): List<HaloAction> {
        val store = ActionStore(context)
        val ids = profile(packageName).actions ?: store.actions().map { it.id }
        val catalog = allActions.associateBy { it.id }
        return ids.mapNotNull(catalog::get).filter { store.isAllowedInApp(it.id, packageName) }
    }
    fun allowsAutomatic(packageName: String?, globalEnabled: Boolean): Boolean =
        !isPaused() && !isVisitPaused(packageName) && appPauseRemainingMillis(packageName) == 0L && when (triggerMode(packageName)) {
            TriggerMode.DEFAULT -> globalEnabled
            TriggerMode.AUTO -> true
            TriggerMode.BUTTON, TriggerMode.OFF -> false
        }
    fun allowsButton(packageName: String?, globalEnabled: Boolean): Boolean =
        !isPaused() && !isVisitPaused(packageName) && appPauseRemainingMillis(packageName) == 0L && when (triggerMode(packageName)) {
            TriggerMode.OFF -> false
            TriggerMode.DEFAULT -> globalEnabled
            TriggerMode.AUTO, TriggerMode.BUTTON -> true
        }

    /** Temporary per-app pauses are runtime state; configuration export deliberately excludes them. */
    fun pauseAppFor(packageName: String, durationMillis: Long) {
        require(isValidPackageName(packageName) && durationMillis in 1..MAX_PAUSE)
        val saved = appPauses()
        saved.keys().asSequence().toList().filter { appPauseRemainingMillis(it) == 0L }.forEach(saved::remove)
        require(saved.length() < 200 || saved.has(packageName))
        val now = SystemClock.elapsedRealtime()
        saved.put(packageName, JSONObject().put("wall", System.currentTimeMillis() + durationMillis)
            .put("elapsed", now + durationMillis).put("started", now))
        preferences.edit().putString(APP_PAUSES, saved.toString()).apply()
    }

    fun appPauseRemainingMillis(packageName: String?): Long {
        val value = packageName?.let { appPauses().optJSONObject(it) } ?: return 0L
        val now = SystemClock.elapsedRealtime()
        val wall = value.optLong("wall") - System.currentTimeMillis()
        val elapsed = value.optLong("elapsed") - now
        return (if (now < value.optLong("started")) wall else minOf(wall, elapsed)).coerceIn(0L, MAX_PAUSE)
    }

    fun pausedPackages(): Set<String> = appPauses().keys().asSequence()
        .filter { appPauseRemainingMillis(it) > 0L }.toSet() + visitPauses.keys

    fun pauseAppVisit(packageName: String, sourceWindowId: Int) {
        require(isValidPackageName(packageName) && sourceWindowId >= 0)
        visitPauses[packageName] = sourceWindowId
    }

    fun isVisitPaused(packageName: String?): Boolean = packageName in visitPauses

    fun refreshVisitPauses(sourceStillPresent: (Int) -> Boolean) {
        visitPauses.entries.removeAll { !sourceStillPresent(it.value) }
    }

    fun resumeApp(packageName: String) {
        visitPauses.remove(packageName)
        val saved = appPauses().apply { remove(packageName) }
        preferences.edit().putString(APP_PAUSES, saved.toString()).apply()
    }

    private fun appPauses(): JSONObject = try { JSONObject(preferences.getString(APP_PAUSES, "{}") ?: "{}") }
        catch (_: Exception) { JSONObject() }

    fun pauseRemainingMillis(): Long {
        val wall = preferences.getLong(PAUSE_WALL, 0L) - System.currentTimeMillis()
        val started = preferences.getLong(PAUSE_STARTED, 0L)
        val now = SystemClock.elapsedRealtime()
        val elapsed = preferences.getLong(PAUSE_ELAPSED, 0L) - now
        // A reboot resets elapsedRealtime; use the bounded wall deadline only in that case.
        return if (now < started) wall.coerceIn(0L, MAX_PAUSE) else minOf(wall, elapsed).coerceIn(0L, MAX_PAUSE)
    }
    fun isPaused(): Boolean = pauseRemainingMillis() > 0L
    fun pauseFor(durationMillis: Long) {
        require(durationMillis in 1..MAX_PAUSE)
        val now = SystemClock.elapsedRealtime()
        preferences.edit().putLong(PAUSE_WALL, System.currentTimeMillis() + durationMillis)
            .putLong(PAUSE_ELAPSED, now + durationMillis).putLong(PAUSE_STARTED, now).apply()
        refreshTile()
    }
    fun resume() {
        preferences.edit().remove(PAUSE_WALL).remove(PAUSE_ELAPSED).remove(PAUSE_STARTED).apply()
        refreshTile()
    }
    private fun refreshTile() {
        try { TileService.requestListeningState(context, ComponentName(context, PauseTileService::class.java)) }
        catch (_: RuntimeException) { /* The tile refreshes from persisted state when opened. */ }
    }
    private fun profiles(): JSONObject = try { JSONObject(preferences.getString(PROFILES, "{}") ?: "{}") }
        catch (_: Exception) { JSONObject() }

    companion object {
        private val visitPauses = mutableMapOf<String, Int>()
        fun clearVisitPauses() { visitPauses.clear() }
        const val PREFERENCES = "app_rules"
        const val PROFILES = "profiles"
        const val TEN_MINUTES = 600_000L
        const val ONE_HOUR = 3_600_000L
        private const val MAX_PAUSE = ONE_HOUR
        private const val APP_PAUSES = "temporary_app_pauses"
        private const val PAUSE_WALL = "pause_until_wall"
        private const val PAUSE_ELAPSED = "pause_until_elapsed"
        private const val PAUSE_STARTED = "pause_started_elapsed"
        fun isValidPackageName(value: String): Boolean = value.length in 3..255 &&
            value.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+"))
        fun normalizeProfiles(encoded: String, knownActionIds: Set<String>): String {
            try {
                val source = JSONObject(encoded)
                require(source.length() <= 200)
                val normalized = JSONObject()
                source.keys().forEach { pkg ->
                    require(isValidPackageName(pkg))
                    val profile = source.getJSONObject(pkg)
                    require(profile.keys().asSequence().all { it in setOf("trigger", "actions") })
                    val rawMode = if (profile.has("trigger")) profile.get("trigger") else "DEFAULT"
                    require(rawMode is String)
                    val mode = TriggerMode.valueOf(rawMode)
                    val actions = if (!profile.has("actions") || profile.isNull("actions")) null else {
                        val items = profile.getJSONArray("actions")
                        require(items.length() <= 200)
                        List(items.length()) { index ->
                            val id = items.get(index)
                            require(id is String && id in knownActionIds)
                            id
                        }.also { require(it.distinct().size == it.size) }
                    }
                    normalized.put(pkg, JSONObject().apply {
                        put("trigger", mode.name)
                        actions?.let { put("actions", JSONArray(it)) }
                    })
                }
                return normalized.toString()
            } catch (failure: Exception) {
                throw IllegalArgumentException("Invalid app rules", failure)
            }
        }
    }
}
