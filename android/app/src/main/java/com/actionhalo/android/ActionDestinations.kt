package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.Toast
import org.json.JSONObject
import java.util.UUID

/** Explicit user choices only; no app usage or selected text is stored. */
internal class ActionDestinations(private val context: Context) {
    internal class RouteLimitException : IllegalArgumentException()
    private val preferences = context.getSharedPreferences("action_destinations", Context.MODE_PRIVATE)
    fun route(id: String): String? = snapshot().optString(id).takeIf { it.isNotEmpty() }

    fun setRoute(id: String, route: String?) {
        val ids = ActionStore(context).allActions().map { it.id }.toSet()
        restoreSnapshot(validatedRoutes(id, route, ids))
    }

    internal fun validateAdditionalRoute(route: String) {
        val id = "custom:${UUID.randomUUID()}"
        val ids = ActionStore(context).allActions().map { it.id }.toSet() + id
        validatedRoutes(id, route, ids)
    }

    private fun validatedRoutes(id: String, route: String?, ids: Set<String>): JSONObject {
        val saved = snapshot()
        saved.keys().asSequence().toList().filterNot { it in ids }.forEach(saved::remove)
        if (route == null) saved.remove(id) else saved.put(id, route)
        return validateSnapshot(saved, ids)
    }

    internal fun snapshot(): JSONObject = try {
        JSONObject(preferences.getString("routes", "{}") ?: "{}")
    } catch (_: Exception) { JSONObject() }

    internal fun validateSnapshot(value: JSONObject, actionIds: Set<String>): JSONObject {
        if (value.length() > MAX_ROUTES) throw RouteLimitException()
        val clean = JSONObject()
        for (id in value.keys()) {
            val route = value.get(id)
            require(id in actionIds && route is String && (route == "web" ||
                (route.startsWith("package:") && validPackage(route.removePrefix("package:")))))
            clean.put(id, route)
        }
        return clean
    }

    internal fun restoreSnapshot(value: JSONObject) {
        preferences.edit().putString("routes", value.toString()).apply()
    }

    fun choose(activity: Activity, action: HaloAction, onSaved: () -> Unit = {}) {
        val choices = linkedMapOf<String?, String>(null to context.getString(R.string.destination_default))
        val web = ActionExecutor.webUrl(action, "example.com")
        if (web != null) choices["web"] = context.getString(R.string.destination_web)
        val probes = buildList {
            if (web != null) add(Intent(Intent.ACTION_VIEW, Uri.parse(web)))
            if (action.type == ActionType.DOUBAN_SEARCH) add(Intent(Intent.ACTION_VIEW, Uri.parse(DoubanSearch.appUri("example"))))
            if (action.type == ActionType.TELEGRAM_SEARCH) add(Intent(Intent.ACTION_VIEW, Uri.parse(TelegramSearch.appUri("example"))))
        }
        probes.forEach { probe ->
            val apps = try {
                @Suppress("DEPRECATION")
                context.packageManager.queryIntentActivities(probe, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
            } catch (failure: Exception) {
                Toast.makeText(activity, ActionExecutor.launchFailureMessage(failure) ?: throw failure, Toast.LENGTH_LONG).show()
                return
            }
            apps.forEach { info ->
                val pkg = info.activityInfo.packageName
                if (pkg != context.packageName && (action.type != ActionType.TELEGRAM_SEARCH || pkg in TelegramSearch.packages)) {
                    choices["package:$pkg"] = context.packageManager.getApplicationLabel(info.activityInfo.applicationInfo).toString()
                }
            }
        }
        val saved = route(action.id)
        if (saved != null && saved !in choices) choices[saved] = context.getString(R.string.destination_unavailable, saved.removePrefix("package:"))
        val keys = choices.keys.toList()
        val labels = AppChoiceLabels(activity).adapter(choices.map { (key, name) ->
            key?.takeIf { it.startsWith("package:") }?.removePrefix("package:") to name
        }, android.R.layout.simple_list_item_single_choice)
        val status = HaloUi.label(activity, "", 13f, HaloUi.accent).apply {
            tag = "destination_save_error"
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            setPadding(HaloUi.dp(activity, 20), HaloUi.dp(activity, 8), HaloUi.dp(activity, 20), HaloUi.dp(activity, 8))
        }
        AlertDialog.Builder(activity).setTitle(context.getString(R.string.destination_title, action.title))
            .setView(status)
            .setSingleChoiceItems(labels, keys.indexOf(saved)) { dialog, index ->
                try { setRoute(action.id, keys[index]) }
                catch (failure: IllegalArgumentException) {
                    (dialog as AlertDialog).listView.setItemChecked(keys.indexOf(route(action.id)).coerceAtLeast(0), true)
                    status.text = if (failure is RouteLimitException) context.getString(R.string.destination_limit_reached, MAX_ROUTES)
                        else context.getString(R.string.destination_save_failed)
                    status.visibility = View.VISIBLE
                    return@setSingleChoiceItems
                }
                onSaved()
                dialog.dismiss()
            }.setNegativeButton(R.string.cancel, null).show()
    }

    companion object {
        internal const val MAX_ROUTES = 512
        fun supports(action: HaloAction) = action.type !in setOf(ActionType.COPY, ActionType.SHARE, ActionType.EDIT_TEXT)
        internal fun validPackage(value: String) = value.length in 3..255 &&
            Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+").matches(value)
    }
}
