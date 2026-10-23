package com.actionhalo.android

/** Fixed categories only; guidance never reads clipboard text, nodes, or app history. */
internal object DiagnosticAdvice {
    enum class Action(val label: Int) {
        AUTHORIZE(R.string.access_settings), BACKGROUND(R.string.background_help_button),
        RULES(R.string.app_rules_hub_title), ACTIONS(R.string.page_actions), TRIGGERS(R.string.page_triggers),
        RESUME(R.string.pause_resume), TEST(R.string.diagnostic_test),
    }
    data class Advice(val title: Int, val body: Int, val action: Action)

    fun resolve(requested: Boolean, authorized: Boolean, connected: Boolean, paused: Boolean, hasActions: Boolean,
        selection: SelectionDiagnostics.Result, copy: TelegramCopyDiagnostics.Stage, copyIsLatest: Boolean): Advice {
        if (!requested) return Advice(R.string.advice_off_title, R.string.advice_off_body, Action.TRIGGERS)
        if (!authorized) return Advice(R.string.advice_permission_title, R.string.advice_permission_body, Action.AUTHORIZE)
        if (!connected) return Advice(R.string.advice_disconnected_title, R.string.advice_disconnected_body, Action.BACKGROUND)
        if (paused) return Advice(R.string.advice_paused_title, R.string.advice_paused_body, Action.RESUME)
        if (!hasActions) return Advice(R.string.no_actions, R.string.advice_actions_body, Action.ACTIONS)
        if (selection == SelectionDiagnostics.Result.NO_ACTIONS) return Advice(R.string.advice_app_actions_title, R.string.advice_app_actions_body, Action.RULES)
        if (copyIsLatest) when (copy) {
            TelegramCopyDiagnostics.Stage.OVERLAY_WAITING_FOCUS, TelegramCopyDiagnostics.Stage.CLIP_UNAVAILABLE ->
                return Advice(R.string.advice_focus_title, R.string.advice_focus_body, Action.TEST)
            TelegramCopyDiagnostics.Stage.COPY_ACTION_FAILED, TelegramCopyDiagnostics.Stage.REQUEST_EXPIRED,
            TelegramCopyDiagnostics.Stage.CLIP_NOT_FRESH, TelegramCopyDiagnostics.Stage.SOURCE_CLOSED, TelegramCopyDiagnostics.Stage.NO_TEXT ->
                return Advice(R.string.advice_reselect_title, R.string.advice_reselect_body, Action.TRIGGERS)
            TelegramCopyDiagnostics.Stage.ACTION_FAILED ->
                return Advice(R.string.advice_action_failed_title, R.string.advice_action_failed_body, Action.ACTIONS)
            TelegramCopyDiagnostics.Stage.DIRECT_HALO_SHOWN, TelegramCopyDiagnostics.Stage.ACTION_DISPATCHED ->
                return Advice(R.string.advice_ready_title, R.string.advice_ready_body, Action.TEST)
            else -> Unit
        }
        return when (selection) {
            SelectionDiagnostics.Result.APP_DISABLED -> Advice(R.string.advice_app_disabled_title, R.string.advice_app_disabled_body, Action.RULES)
            SelectionDiagnostics.Result.APP_PAUSED -> Advice(R.string.advice_app_paused_title, R.string.advice_app_paused_body, Action.RULES)
            SelectionDiagnostics.Result.INITIAL_SELECTION -> Advice(R.string.advice_initial_title, R.string.advice_initial_body, Action.TEST)
            SelectionDiagnostics.Result.FILTERED -> Advice(R.string.advice_filtered_title, R.string.advice_filtered_body, Action.TRIGGERS)
            SelectionDiagnostics.Result.NO_SOURCE, SelectionDiagnostics.Result.NO_TEXT, SelectionDiagnostics.Result.NO_RANGE ->
                Advice(R.string.advice_source_title, R.string.advice_source_body, Action.TRIGGERS)
            SelectionDiagnostics.Result.BLOCKED -> Advice(R.string.advice_window_title, R.string.advice_window_body, Action.BACKGROUND)
            SelectionDiagnostics.Result.STALE, SelectionDiagnostics.Result.WINDOW_CHANGED, SelectionDiagnostics.Result.COPY_UNCONFIRMED ->
                Advice(R.string.advice_reselect_title, R.string.advice_reselect_body, Action.TRIGGERS)
            SelectionDiagnostics.Result.SHOWN, SelectionDiagnostics.Result.COPY_SHOWN ->
                Advice(R.string.advice_ready_title, R.string.advice_ready_body, Action.TEST)
            SelectionDiagnostics.Result.TEST_SHOWN -> Advice(R.string.advice_test_title, R.string.advice_test_body, Action.TRIGGERS)
            else -> Advice(R.string.advice_waiting_title, R.string.advice_waiting_body, Action.TEST)
        }
    }
}
