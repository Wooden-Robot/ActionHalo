package com.actionhalo.android

import android.content.Context

/** Explains the same configuration used by AppRulesStore.actionsFor without changing runtime rules. */
internal class AppRulePresentation(private val context: Context) {
    data class Hidden(val action: HaloAction, val reason: Int)
    data class Result(val trigger: Int, val available: List<HaloAction>, val hidden: List<Hidden>)

    fun triggerFor(packageName: String, profile: AppRulesStore.Profile = AppRulesStore(context).profile(packageName)): Int {
        val rules = AppRulesStore(context)
        val settings = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        val consent = settings.getBoolean("accessibility_consent", false)
        val automatic = settings.getBoolean("auto_popup_enabled", false)
        val menu = settings.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false) ||
            (TelegramCopyPolicy.supportsPackage(packageName) && settings.getBoolean(TelegramCopyPolicy.SETTING, false))
        return when {
            profile.trigger == AppRulesStore.TriggerMode.OFF -> R.string.app_rules_effective_off
            rules.isPaused() -> R.string.app_rules_effective_paused
            rules.appPauseRemainingMillis(packageName) > 0 || rules.isVisitPaused(packageName) -> R.string.source_app_paused
            (consent && (profile.trigger == AppRulesStore.TriggerMode.AUTO ||
                (profile.trigger == AppRulesStore.TriggerMode.DEFAULT && automatic))) ||
                (menu && profile.trigger != AppRulesStore.TriggerMode.BUTTON) -> R.string.app_rules_effective_auto
            menu || (consent && profile.trigger == AppRulesStore.TriggerMode.BUTTON) -> R.string.app_rules_effective_button
            !consent -> R.string.app_rules_effective_consent
            else -> R.string.app_rules_effective_manual
        }
    }

    fun describe(packageName: String, profile: AppRulesStore.Profile = AppRulesStore(context).profile(packageName)): Result {
        val actions = ActionStore(context)
        val catalog = actions.allActions()
        val selected = profile.actions ?: actions.actions().map { it.id }
        val available = selected.mapNotNull { id -> catalog.find { it.id == id } }
            .filter { actions.isAllowedInApp(it.id, packageName) }
        val hidden = catalog.filterNot { candidate -> available.any { it.id == candidate.id } }.map { action ->
            Hidden(action, when {
                !actions.isAllowedInApp(action.id, packageName) -> R.string.app_rules_hidden_scope
                profile.actions != null -> R.string.app_rules_hidden_custom
                else -> R.string.app_rules_hidden_global
            })
        }
        return Result(triggerFor(packageName, profile), available, hidden)
    }
}
