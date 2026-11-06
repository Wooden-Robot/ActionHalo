package com.actionhalo.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Stores action configuration only. Selected or shared text is never persisted. */
class ActionStore(private val context: Context, initializeDefaults: Boolean = true) {
    enum class AppScopeMode { ALL, ONLY, EXCEPT }
    data class AppScope(val mode: AppScopeMode = AppScopeMode.ALL, val packages: List<String> = emptyList())
    private val preferences = context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE)

    init {
        // Adding a built-in on upgrade must not displace a user's existing eighth action.
        if (initializeDefaults && !preferences.contains(enabledKey("douban"))) {
            val existingEnabled = allActions().count {
                it.id != "douban" && preferences.getBoolean(enabledKey(it.id), defaultEnabled(it.id))
            }
            preferences.edit().putBoolean(enabledKey("douban"), existingEnabled < LEGACY_ACTION_LIMIT).apply()
        }
    }

    internal fun defaultTitle(id: String): String? = defaults().find { it.id == id }?.title

    fun allActions(): List<HaloAction> {
        val edits = builtinEdits().associateBy { it.id }
        val actions = (defaults().map { edits[it.id]?.copy(symbol = it.symbol) ?: it } + customActions())
            .associateBy { it.id }.toMutableMap()
        return savedOrder().mapNotNull { actions.remove(it) } + actions.values
    }

    fun actions(): List<HaloAction> = allActions()
        .filter { preferences.getBoolean(enabledKey(it.id), defaultEnabled(it.id)) }

    fun isEnabled(id: String): Boolean = actions().any { it.id == id }

    fun setEnabled(id: String, enabled: Boolean) {
        require(allActions().any { it.id == id }) { context.getString(R.string.action_unknown) }
        preferences.edit().putBoolean(enabledKey(id), enabled).apply()
    }

    fun setAllEnabled(enabled: Boolean) {
        preferences.edit().apply {
            allActions().forEach { putBoolean(enabledKey(it.id), enabled) }
        }.apply()
    }

    internal fun appScope(id: String): AppScope = try {
        appScopes().optJSONObject(id)?.let(::decodeAppScope) ?: AppScope()
    } catch (_: Exception) { AppScope() }

    internal fun setAppScope(id: String, scope: AppScope) {
        val ids = allActions().map { it.id }.toSet()
        require(isAppScopeActionId(id, ids)) { context.getString(R.string.action_unknown) }
        val encoded = encodeAppScope(scope)
        decodeAppScope(encoded)
        val scopes = appScopes()
        scopes.keys().asSequence().toList().filterNot { it in ids }.forEach(scopes::remove)
        if (scope.mode == AppScopeMode.ALL) scopes.remove(id) else scopes.put(id, encoded)
        preferences.edit().putString(APP_SCOPES, scopes.toString()).apply()
    }

    internal fun isAllowedInApp(id: String, packageName: String?): Boolean {
        val scope = appScope(id)
        return when (scope.mode) {
            AppScopeMode.ALL -> true
            AppScopeMode.ONLY -> packageName != null && packageName in scope.packages
            AppScopeMode.EXCEPT -> packageName == null || packageName !in scope.packages
        }
    }

    fun reset() {
        preferences.edit().clear().apply()
    }

    /** Configuration only, also used for short-lived in-memory undo. */
    internal fun snapshot(): JSONObject = JSONObject().apply {
        put("custom", JSONArray(encodeActions(customActions())))
        put("edits", JSONArray(encodeActions(builtinEdits())))
        put("order", JSONArray(allActions().map { it.id }))
        put("enabled", JSONObject().apply {
            allActions().forEach { put(it.id, preferences.getBoolean(enabledKey(it.id), defaultEnabled(it.id))) }
        })
        put("appScopes", appScopes())
    }

    internal fun snapshotActionIds(value: JSONObject): Set<String> =
        defaults().map { it.id }.toSet() + value.getJSONArray("custom").let { actions ->
            (0 until actions.length()).map { actions.getJSONObject(it).getString("id") }
        }

    internal fun validateSnapshot(value: JSONObject): JSONObject {
        require(value.keys().asSequence().toSet().let {
            it.containsAll(setOf("custom", "edits", "order", "enabled")) &&
                it.all { key -> key in setOf("custom", "edits", "order", "enabled", "appScopes") }
        })
        val result = JSONObject(value.toString())
        fun validateActions(key: String, acceptsId: (String) -> Boolean) {
            val array = result.opt(key) as? JSONArray ?: throw IllegalArgumentException("Invalid actions")
            val ids = mutableSetOf<String>()
            repeat(array.length()) { index ->
                val action = array.opt(index) as? JSONObject ?: throw IllegalArgumentException("Invalid action")
                require(action.keys().asSequence().toSet().let {
                    it.containsAll(setOf("id", "title", "template")) && it.all { field -> field in setOf("id", "title", "template", "icon") }
                })
                val id = action.opt("id") as? String ?: throw IllegalArgumentException("Invalid ID")
                val title = action.opt("title") as? String ?: throw IllegalArgumentException("Invalid title")
                val template = action.opt("template") as? String ?: throw IllegalArgumentException("Invalid URL")
                require(acceptsId(id) && ids.add(id))
                require(title.isNotBlank())
                require(ActionUrls.validateTemplate(template))
                require(!action.has("icon") || action.isNull("icon") ||
                    (action.opt("icon") as? String) in ActionIcons.options.keys)
            }
        }
        validateActions("custom") { it.startsWith("custom:") }
        validateActions("edits") { it in EDITABLE_BUILTINS }
        val ids = snapshotActionIds(result)
        val order = result.opt("order") as? JSONArray ?: throw IllegalArgumentException("Invalid order")
        require(order.length() <= ids.size)
        val orderedIds = mutableSetOf<String>()
        repeat(order.length()) { index ->
            val id = order.opt(index) as? String ?: throw IllegalArgumentException("Invalid order ID")
            require(id in ids && orderedIds.add(id))
        }
        val enabled = result.opt("enabled") as? JSONObject ?: throw IllegalArgumentException("Invalid enabled actions")
        require(enabled.keys().asSequence().all { it in ids && enabled.opt(it) is Boolean })
        val customIds = ids.filter { it.startsWith("custom:") }
        require(customIds.all { it in orderedIds && enabled.has(it) })
        val scopes = if (!result.has("appScopes")) JSONObject() else
            result.opt("appScopes") as? JSONObject ?: throw IllegalArgumentException("Invalid app scopes")
        require(scopes.length() <= ids.size)
        val normalizedScopes = JSONObject()
        scopes.keys().forEach { id ->
            require(isAppScopeActionId(id, ids))
            val encoded = scopes.opt(id) as? JSONObject ?: throw IllegalArgumentException("Invalid app scope")
            val scope = decodeAppScope(encoded)
            if (scope.mode != AppScopeMode.ALL) normalizedScopes.put(id, encodeAppScope(scope))
        }
        result.put("appScopes", normalizedScopes)
        return result
    }

    internal fun restoreSnapshot(value: JSONObject) {
        val validated = validateSnapshot(value)
        preferences.edit().apply {
            clear()
            putString(CUSTOM_ACTIONS, validated.getJSONArray("custom").toString())
            putString(BUILTIN_EDITS, validated.getJSONArray("edits").toString())
            putString(ACTION_ORDER, validated.getJSONArray("order").toString())
            putString(APP_SCOPES, validated.getJSONObject("appScopes").toString())
            val enabled = validated.getJSONObject("enabled")
            enabled.keys().forEach { putBoolean(enabledKey(it), enabled.getBoolean(it)) }
        }.apply()
    }

    fun canEdit(action: HaloAction): Boolean = action.id.startsWith("custom:") || action.id in EDITABLE_BUILTINS

    fun templateForEditing(action: HaloAction): String = action.template ?: when (action.type) {
        ActionType.DOUBAN_SEARCH, ActionType.DOUBAN_BOOK_SEARCH, ActionType.DOUBAN_MOVIE_SEARCH ->
            DoubanSearch.webTemplate(action.type)
        else -> ""
    }

    fun move(id: String, offset: Int): Boolean {
        require(offset == -1 || offset == 1) { "Move offset must be -1 or 1" }
        return moveTo(id, allActions().indexOfFirst { it.id == id } + offset)
    }

    /** The target is the final index in the full catalog, including disabled actions. */
    fun moveTo(id: String, targetIndex: Int): Boolean {
        val actions = allActions().toMutableList()
        val source = actions.indexOfFirst { it.id == id }
        if (source < 0 || targetIndex !in actions.indices || source == targetIndex) return false
        val action = actions.removeAt(source)
        actions.add(targetIndex, action)
        preferences.edit().putString(ACTION_ORDER, encodeOrder(actions)).apply()
        return true
    }

    /** Additional enabled actions appear on the next page instead of replacing existing actions. */
    fun addCustom(title: String, template: String, icon: String? = null): HaloAction {
        val action = editedAction(
            HaloAction("custom:${UUID.randomUUID()}", title, "↗", ActionType.URL), title, template, icon,
        )
        preferences.edit()
            .putString(CUSTOM_ACTIONS, encodeActions(customActions() + action))
            .putBoolean(enabledKey(action.id), true)
            .apply()
        return action
    }

    fun editAction(id: String, title: String, template: String, icon: String? = null): HaloAction {
        val original = allActions().find { it.id == id }
        require(original != null && canEdit(original)) { context.getString(R.string.action_unknown) }
        val action = editedAction(original, title, template, icon)
        val custom = id.startsWith("custom:")
        val saved = if (custom) customActions() else builtinEdits()
        val updated = if (saved.any { it.id == id }) saved.map { if (it.id == id) action else it }
            else saved + action
        preferences.edit()
            .putString(if (custom) CUSTOM_ACTIONS else BUILTIN_EDITS,
                encodeActions(updated))
            .apply()
        return action
    }

    fun deleteCustom(id: String): Boolean {
        val custom = customActions()
        if (custom.none { it.id == id }) return false
        preferences.edit()
            .putString(CUSTOM_ACTIONS, encodeActions(custom.filterNot { it.id == id }))
            .putString(ACTION_ORDER, encodeOrder(allActions().filterNot { it.id == id }))
            .putString(APP_SCOPES, appScopes().apply { remove(id) }.toString())
            .remove(enabledKey(id))
            .apply()
        return true
    }

    private fun defaults() = listOf(
        HaloAction("copy", context.getString(R.string.action_copy), "⧉", ActionType.COPY),
        HaloAction("google", context.getString(R.string.action_google), "G", ActionType.URL,
            "https://www.google.com/search?q={text}"),
        HaloAction("translate", context.getString(R.string.action_translate), "文", ActionType.URL,
            "https://translate.google.com/?sl=auto&tl=${context.getString(R.string.action_translation_target)}&text={text}&op=translate"),
        HaloAction("open_url", context.getString(R.string.action_open_url), "↗", ActionType.OPEN_URL),
        HaloAction("share", context.getString(R.string.action_share), "⋯", ActionType.SHARE),
        HaloAction("baidu", context.getString(R.string.action_baidu), "百", ActionType.URL,
            "https://www.baidu.com/s?wd={text}"),
        HaloAction("douban", context.getString(R.string.action_douban), "豆", ActionType.DOUBAN_SEARCH),
        HaloAction("douban_book", context.getString(R.string.action_douban_book), "书", ActionType.DOUBAN_BOOK_SEARCH),
        HaloAction("douban_movie", context.getString(R.string.action_douban_movie), "影", ActionType.DOUBAN_MOVIE_SEARCH),
        HaloAction("neodb", context.getString(R.string.action_neodb), "N", ActionType.URL,
            "https://neodb.social/search/?q={text}"),
        HaloAction("neodb_book", context.getString(R.string.action_neodb_book), "阅", ActionType.URL,
            "https://neodb.social/search/?q={text}&c=book"),
        HaloAction("github", context.getString(R.string.action_github), "GH", ActionType.URL,
            "https://github.com/search?q={text}"),
        HaloAction("telegram", context.getString(R.string.action_telegram), "➤", ActionType.TELEGRAM_SEARCH),
        HaloAction("edit_text", context.getString(R.string.action_edit_text), "✎", ActionType.EDIT_TEXT),
    )

    private fun customActions() = storedActions(CUSTOM_ACTIONS) { it.startsWith("custom:") }

    private fun builtinEdits() = storedActions(BUILTIN_EDITS) { it in EDITABLE_BUILTINS }

    private fun storedActions(key: String, acceptsId: (String) -> Boolean): List<HaloAction> {
        return try {
            val encoded = preferences.getString(key, null) ?: return emptyList()
            val array = JSONArray(encoded)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val id = item.optString("id")
                    val title = item.optString("title")
                    val template = item.optString("template")
                    if (!acceptsId(id) || title.isBlank() ||
                        !ActionUrls.validateTemplate(template) || any { it.id == id }
                    ) continue
                    val icon = item.optString("icon").takeIf { it in ActionIcons.options.keys }
                    add(HaloAction(id, title, "↗", ActionType.URL, template, icon))
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun editedAction(action: HaloAction, title: String, template: String, icon: String?): HaloAction {
        val cleanTitle = title.trim()
        val cleanTemplate = template.trim()
        require(cleanTitle.isNotEmpty()) { context.getString(R.string.action_title_required) }
        require(ActionUrls.validateTemplate(cleanTemplate)) {
            context.getString(R.string.action_invalid_template)
        }
        require(icon == null || icon in ActionIcons.options.keys) { context.getString(R.string.action_unknown) }
        return action.copy(title = cleanTitle, type = ActionType.URL, template = cleanTemplate, icon = icon)
    }

    private fun savedOrder(): List<String> = try {
        val array = JSONArray(preferences.getString(ACTION_ORDER, "[]"))
        List(array.length()) { array.optString(it) }
    } catch (_: Exception) {
        emptyList()
    }

    private fun appScopes(): JSONObject = try {
        JSONObject(preferences.getString(APP_SCOPES, "{}") ?: "{}")
    } catch (_: Exception) { JSONObject() }

    private fun encodeAppScope(scope: AppScope): JSONObject = JSONObject()
        .put("mode", scope.mode.name).put("packages", JSONArray(scope.packages))

    private fun isAppScopeActionId(id: String, knownIds: Set<String>): Boolean = id in knownIds &&
        id.length <= 128 && (!id.startsWith("custom:") || id.length >= 8) &&
        id.none { it.isWhitespace() || it.isISOControl() }

    private fun decodeAppScope(value: JSONObject): AppScope {
        require(value.keys().asSequence().toSet() == setOf("mode", "packages"))
        val name = value.opt("mode") as? String ?: throw IllegalArgumentException("Invalid app scope mode")
        val mode = AppScopeMode.valueOf(name)
        val items = value.opt("packages") as? JSONArray ?: throw IllegalArgumentException("Invalid app scope packages")
        require(items.length() <= MAX_SCOPE_PACKAGES)
        val packages = List(items.length()) { index ->
            val pkg = items.opt(index) as? String ?: throw IllegalArgumentException("Invalid app scope package")
            require(AppRulesStore.isValidPackageName(pkg))
            pkg
        }
        require(packages.distinct().size == packages.size)
        require(if (mode == AppScopeMode.ALL) packages.isEmpty() else packages.isNotEmpty())
        return AppScope(mode, packages)
    }

    private fun encodeOrder(actions: List<HaloAction>): String = JSONArray(actions.map { it.id }).toString()

    private fun encodeActions(actions: List<HaloAction>): String = JSONArray().apply {
        actions.forEach { action ->
            put(JSONObject().apply {
                put("id", action.id)
                put("title", action.title)
                put("template", action.template)
                put("icon", action.icon)
            })
        }
    }.toString()

    private fun enabledKey(id: String) = "enabled_$id"
    private fun defaultEnabled(id: String) = id !in OPTIONAL_SEARCHES

    companion object {
        private const val LEGACY_ACTION_LIMIT = 8
        private val OPTIONAL_SEARCHES = setOf("douban_book", "douban_movie", "neodb", "neodb_book", "github", "telegram", "edit_text")
        private const val CUSTOM_ACTIONS = "custom_actions"
        private const val ACTION_ORDER = "action_order"
        private const val BUILTIN_EDITS = "builtin_edits"
        private const val APP_SCOPES = "app_scopes"
        private const val MAX_SCOPE_PACKAGES = 200
        private val EDITABLE_BUILTINS = setOf("google", "baidu", "douban_book", "douban_movie", "neodb", "neodb_book", "github")
    }
}
