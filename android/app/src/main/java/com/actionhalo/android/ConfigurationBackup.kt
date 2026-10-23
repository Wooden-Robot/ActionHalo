package com.actionhalo.android

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.UUID

/** Only user configuration crosses this boundary; permissions and runtime state stay on this phone. */
internal class ConfigurationBackup(private val context: Context) {
    private val store = ActionStore(context, initializeDefaults = false)
    private val settings = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
    private val rules = context.getSharedPreferences("app_rules", Context.MODE_PRIVATE)
    private val localDirectory get() = File(context.filesDir, "configuration-backup")

    data class Changes(val addedActions: List<String>, val modifiedActions: List<String>, val removedActions: List<String>,
        val newlyDisabledApps: List<String>, val enabledAgainApps: List<String>, val changedAppRules: List<String>,
        val changedDestinations: List<String>, val appearanceCount: Int, val orderChanged: Boolean) {
        val isEmpty get() = addedActions.isEmpty() && modifiedActions.isEmpty() && removedActions.isEmpty() &&
            newlyDisabledApps.isEmpty() && enabledAgainApps.isEmpty() && changedAppRules.isEmpty() &&
            changedDestinations.isEmpty() && appearanceCount == 0 && !orderChanged
    }

    fun changes(document: JSONObject): Changes {
        val incoming = validate(document)
        val current = JSONObject(export())
        val before = current.getJSONObject("actions")
        val after = incoming.getJSONObject("actions")
        val beforeIds = store.snapshotActionIds(before)
        val afterIds = store.snapshotActionIds(after)
        fun actionItems(value: JSONObject) = listOf("custom", "edits").flatMap { key ->
            value.getJSONArray(key).let { array -> List(array.length()) { array.getJSONObject(it) } }
        }.associateBy { it.getString("id") }
        val oldItems = actionItems(before)
        val newItems = actionItems(after)
        val fallbackNames = store.allActions().associate { it.id to it.title }
        fun name(id: String, items: Map<String, JSONObject>) = items[id]?.getString("title") ?: store.defaultTitle(id) ?: fallbackNames[id] ?: id
        val modified = (beforeIds intersect afterIds).filter { id ->
            !sameJson(oldItems[id], newItems[id]) || before.getJSONObject("enabled").opt(id) != after.getJSONObject("enabled").opt(id) ||
                !sameJson(before.optJSONObject("appScopes")?.opt(id), after.optJSONObject("appScopes")?.opt(id))
        }
        val oldRules = current.getJSONObject("appRules")
        val newRules = incoming.getJSONObject("appRules")
        fun disabled(value: JSONObject) = value.keys().asSequence().filter {
            value.getJSONObject(it).optString("trigger") == AppRulesStore.TriggerMode.OFF.name
        }.toSet()
        val oldDisabled = disabled(oldRules)
        val newDisabled = disabled(newRules)
        fun changedKeys(a: JSONObject, b: JSONObject) = (a.keys().asSequence().toSet() + b.keys().asSequence().toSet())
            .filter { !sameJson(a.opt(it), b.opt(it)) }.sorted()
        return Changes((afterIds - beforeIds).map { name(it, newItems) }, modified.map { name(it, newItems) },
            (beforeIds - afterIds).map { name(it, oldItems) }, (newDisabled - oldDisabled).sorted(), (oldDisabled - newDisabled).sorted(),
            changedKeys(oldRules, newRules), changedKeys(current.getJSONObject("destinations"), incoming.getJSONObject("destinations"))
                .map { name(it, newItems) },
            changedKeys(current.getJSONObject("appearance"), incoming.getJSONObject("appearance")).size,
            !sameJson(before.getJSONArray("order"), after.getJSONArray("order")))
    }

    fun preview(document: JSONObject): String {
        val changes = changes(document)
        if (changes.isEmpty) return context.getString(R.string.backup_ux_no_changes)
        val sections = mutableListOf<String>()
        fun append(title: Int, values: List<String>) {
            if (values.isNotEmpty()) sections += context.getString(title, values.size) + "\n" + values.joinToString("\n") { "• $it" }
        }
        fun appName(pkg: String): String = try {
            @Suppress("DEPRECATION")
            context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(pkg, 0)).toString()
                .takeIf { it.isNotBlank() && it != pkg }?.let { "$it ($pkg)" } ?: pkg
        } catch (_: android.content.pm.PackageManager.NameNotFoundException) { pkg }
        append(R.string.backup_ux_added_actions, changes.addedActions)
        append(R.string.backup_ux_modified_actions, changes.modifiedActions)
        append(R.string.backup_ux_removed_actions, changes.removedActions)
        append(R.string.backup_ux_disabled_apps, changes.newlyDisabledApps.map(::appName))
        append(R.string.backup_ux_enabled_apps, changes.enabledAgainApps.map(::appName))
        val oldRules = JSONObject(export()).getJSONObject("appRules")
        val newRules = document.getJSONObject("appRules")
        fun trigger(profile: JSONObject?): String = context.getString(when (profile?.optString("trigger")) {
            "AUTO" -> R.string.app_rules_auto
            "BUTTON" -> R.string.app_rules_button
            "OFF" -> R.string.app_rules_off
            else -> R.string.app_rules_default
        })
        append(R.string.backup_ux_app_rules, changes.changedAppRules.map { pkg ->
            val old = oldRules.optJSONObject(pkg)
            val new = newRules.optJSONObject(pkg)
            val lines = mutableListOf<String>()
            if (trigger(old) != trigger(new)) lines += context.getString(R.string.backup_ux_rule_change,
                appName(pkg), trigger(old), trigger(new))
            if (!sameJson(old?.opt("actions"), new?.opt("actions"))) lines += context.getString(R.string.backup_ux_rule_actions, appName(pkg))
            lines.ifEmpty { listOf(appName(pkg)) }.joinToString("\n")
        })
        append(R.string.backup_ux_destinations, changes.changedDestinations)
        if (changes.appearanceCount > 0) sections += context.getString(R.string.backup_ux_appearance, changes.appearanceCount)
        if (changes.orderChanged) sections += context.getString(R.string.backup_ux_order)
        return sections.joinToString("\n\n")
    }

    /** An import cannot touch preferences until its previous configuration is safely on disk. */
    fun restoreWithUndo(document: JSONObject) = synchronized(IMPORT_LOCK) {
        val checked = read(document.toString().byteInputStream(StandardCharsets.UTF_8))
        val previous = export()
        writeLocal("before-import.json", previous)
        try { restore(checked) }
        catch (failure: Exception) {
            runCatching { restore(JSONObject(previous)) }.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
    }

    fun hasPrevious(): Boolean = File(localDirectory, "before-import.json").exists() ||
        File(localDirectory, "before-import.json.bak").exists()
    fun previous(): JSONObject = readLocal("before-import.json")
    fun restorePrevious() = synchronized(IMPORT_LOCK) { restore(previous()) }

    fun stageImport(document: JSONObject): String {
        val checked = read(document.toString().byteInputStream(StandardCharsets.UTF_8))
        discardExpiredPendingImports()
        val token = UUID.randomUUID().toString()
        writeLocal("pending-$token.json", checked.toString())
        return token
    }

    fun pendingImport(token: String): JSONObject = readLocal(pendingFileName(token))
    fun discardPendingImport(token: String) { AtomicFile(File(localDirectory, pendingFileName(token))).delete() }

    private fun discardExpiredPendingImports() {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        localDirectory.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { file ->
            val baseName = file.name.removeSuffix(".bak").removeSuffix(".new")
            if (baseName.startsWith("pending-") && baseName.endsWith(".json")) {
                val token = baseName.removePrefix("pending-").removeSuffix(".json")
                runCatching { discardPendingImport(token) }
            }
        }
    }

    private fun pendingFileName(token: String): String {
        require(UUID.fromString(token).toString() == token)
        return "pending-$token.json"
    }

    private fun readLocal(name: String): JSONObject = AtomicFile(File(localDirectory, name)).openRead().use(::read)

    private fun writeLocal(name: String, encoded: String) {
        val bytes = encoded.toByteArray(StandardCharsets.UTF_8)
        // Validate the exact bytes which will be recoverable after a process restart.
        read(bytes.inputStream())
        check(localDirectory.isDirectory || localDirectory.mkdirs()) { "Cannot create local backup directory" }
        val file = AtomicFile(File(localDirectory, name))
        val output = file.startWrite()
        try { output.write(bytes); file.finishWrite(output) }
        catch (failure: Exception) { file.failWrite(output); throw failure }
        check(sameJson(readLocal(name), read(bytes.inputStream()))) { "Local backup was not saved" }
    }

    private fun sameJson(a: Any?, b: Any?): Boolean = when {
        a is JSONObject && b is JSONObject -> {
            val keys = a.keys().asSequence().toSet()
            keys == b.keys().asSequence().toSet() && keys.all { sameJson(a.opt(it), b.opt(it)) }
        }
        a is JSONArray && b is JSONArray -> a.length() == b.length() && (0 until a.length()).all { sameJson(a.opt(it), b.opt(it)) }
        else -> a == b
    }

    fun export(): String {
        val actions = store.snapshot()
        val ids = store.snapshotActionIds(actions)
        val profiles = JSONObject(rules.getString("profiles", "{}") ?: "{}")
        profiles.keys().forEach { packageName ->
            val profile = profiles.getJSONObject(packageName)
            profile.optJSONArray("actions")?.let { ordered ->
                profile.put("actions", JSONArray((0 until ordered.length()).map { ordered.getString(it) }.filter { it in ids }))
            }
        }
        val destinations = ActionDestinations(context).snapshot()
        destinations.keys().asSequence().toList().filterNot { it in ids }.forEach(destinations::remove)
        return JSONObject().apply {
            put("format", FORMAT)
            put("version", VERSION)
            put("actions", actions)
            put("appearance", JSONObject().apply {
                APPEARANCE_KEYS.forEach { key -> settings.all[key]?.let { put(key, it) } }
            })
            put("appRules", profiles)
            put("destinations", destinations)
        }.let { validate(it).toString(2) }.also {
            require(it.toByteArray(StandardCharsets.UTF_8).size <= MAX_BYTES)
        }
    }

    fun read(input: InputStream): JSONObject {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_BYTES) { "Backup is too large" }
            output.write(buffer, 0, count)
        }
        val text = StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(output.toByteArray())).toString()
        val parser = JSONTokener(text)
        val document = parser.nextValue() as? JSONObject ?: throw IllegalArgumentException("Invalid backup")
        require(parser.nextClean() == '\u0000') { "Trailing backup data" }
        return validate(document)
    }

    fun validate(document: JSONObject): JSONObject {
        require(document.keys().asSequence().toSet() == setOf(
            "format", "version", "actions", "appearance", "appRules", "destinations"))
        require(document.opt("format") == FORMAT && document.opt("version") is Int && document.optInt("version") == VERSION)
        val importedActions = document.opt("actions") as? JSONObject ?: throw IllegalArgumentException("Invalid actions")
        val custom = importedActions.opt("custom") as? JSONArray ?: throw IllegalArgumentException("Invalid custom actions")
        require(custom.length() <= MAX_CUSTOM_ACTIONS)
        repeat(custom.length()) { index ->
            val id = (custom.opt(index) as? JSONObject)?.opt("id") as? String
                ?: throw IllegalArgumentException("Invalid custom action ID")
            require(id.startsWith("custom:") && id.length in 8..128 && id.none { it.isWhitespace() || it.isISOControl() })
        }
        val edits = importedActions.opt("edits") as? JSONArray ?: throw IllegalArgumentException("Invalid built-in edits")
        require(edits.length() <= store.allActions().count { !it.id.startsWith("custom:") })
        val actions = store.validateSnapshot(importedActions)
        val appearance = document.opt("appearance") as? JSONObject ?: throw IllegalArgumentException("Invalid appearance")
        require(appearance.keys().asSequence().all { key ->
            when (key) {
                HaloAppearance.GTA_MODE_KEY, HaloAppearance.HAPTICS_KEY, HaloAppearance.KEEP_AFTER_COPY_KEY -> appearance.opt(key) is Boolean
                HaloAppearance.ACTIONS_PER_PAGE_KEY -> appearance.opt(key) is Int && appearance.optInt(key) in HaloAppearance.ACTION_COUNTS
                HaloAppearance.MENU_SIZE_KEY -> appearance.opt(key) is Int && appearance.optInt(key) in HaloAppearance.MENU_SIZES
                HaloAppearance.DIM_KEY -> appearance.opt(key) is Int && appearance.optInt(key) in 0..80
                HaloAppearance.INITIAL_POSITION_KEY -> appearance.opt(key) is String &&
                    HaloAppearance.InitialPosition.entries.any { it.name == appearance.optString(key) }
                else -> false
            }
        })
        val ids = store.snapshotActionIds(actions)
        val profiles = document.opt("appRules") as? JSONObject ?: throw IllegalArgumentException("Invalid app rules")
        val normalizedProfiles = AppRulesStore.normalizeProfiles(profiles.toString(), ids)
        val destinations = ActionDestinations(context).validateSnapshot(document.opt("destinations") as? JSONObject
            ?: throw IllegalArgumentException("Invalid destinations"), ids)
        return JSONObject(document.toString()).apply {
            put("actions", actions)
            put("appRules", JSONObject(normalizedProfiles))
            put("destinations", destinations)
        }
    }

    fun restore(document: JSONObject) {
        val validated = validate(document)
        // Every section is checked before the first preference edit, including references to imported actions.
        store.restoreSnapshot(validated.getJSONObject("actions"))
        settings.edit().apply {
            APPEARANCE_KEYS.forEach { remove(it) }
            val appearance = validated.getJSONObject("appearance")
            appearance.keys().forEach { key ->
                when (val value = appearance.get(key)) {
                    is Boolean -> putBoolean(key, value)
                    is Int -> putInt(key, value)
                    is String -> putString(key, value)
                }
            }
        }.apply()
        rules.edit().putString("profiles", validated.getJSONObject("appRules").toString()).apply()
        ActionDestinations(context).restoreSnapshot(validated.getJSONObject("destinations"))
    }

    companion object {
        const val MAX_BYTES = 1024 * 1024
        private const val MAX_CUSTOM_ACTIONS = 200
        private const val FORMAT = "ActionHalo"
        private const val VERSION = 1
        private val IMPORT_LOCK = Any()
        private val APPEARANCE_KEYS = setOf(HaloAppearance.GTA_MODE_KEY, HaloAppearance.ACTIONS_PER_PAGE_KEY,
            HaloAppearance.MENU_SIZE_KEY, HaloAppearance.DIM_KEY, HaloAppearance.HAPTICS_KEY, HaloAppearance.INITIAL_POSITION_KEY, HaloAppearance.KEEP_AFTER_COPY_KEY)
    }
}
