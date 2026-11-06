package com.actionhalo.android

import android.content.Context
import android.content.pm.PackageManager

/** Process-local counters and fixed categories only. Never retains labels, clips or chat text. */
internal object TelegramCopyDiagnostics {
    enum class Stage(val message: Int) {
        WAITING(R.string.copy_probe_waiting),
        INITIAL_MENU_SHOWN(R.string.selection_menu_helper_shown),
        HELPER_SHOWN(R.string.copy_probe_helper_shown),
        HELPER_TAPPED(R.string.copy_probe_helper_tapped),
        DIRECT_HALO_SHOWN(R.string.copy_direct_shown),
        DIRECT_ACTION_TAPPED(R.string.copy_direct_tapped),
        OVERLAY_REQUESTED(R.string.copy_overlay_requested),
        OVERLAY_FOCUSED(R.string.copy_probe_focused),
        SOURCE_CLOSED(R.string.copy_source_closed),
        OVERLAY_WAITING_FOCUS(R.string.copy_overlay_waiting),
        CLIP_UNAVAILABLE(R.string.copy_clip_unavailable),
        ACTION_REQUESTED(R.string.copy_action_requested),
        ACTION_DISPATCHED(R.string.copy_action_completed),
        ACTION_FAILED(R.string.copy_action_failed),
        COPY_ACTION_FAILED(R.string.telegram_copy_assist_failed),
        UNSUPPORTED_CONTROL(R.string.copy_probe_control),
        NOT_COPY(R.string.copy_probe_label),
        STALE_EVENT(R.string.copy_probe_stale),
        MENU_NOT_SEEN(R.string.copy_probe_window),
        LAUNCH_REQUESTED(R.string.copy_probe_launch),
        LAUNCH_BLOCKED(R.string.copy_probe_blocked),
        FOCUSED(R.string.copy_probe_focused),
        REQUEST_EXPIRED(R.string.copy_probe_expired),
        CLIP_NOT_FRESH(R.string.diagnostic_copy_unconfirmed),
        NO_TEXT(R.string.clipboard_no_text),
        NO_ACTIONS(R.string.no_actions),
        SHOWN(R.string.diagnostic_copy_shown),
    }

    var updatedAt: Long = 0L
        private set
    var clicks = 0
        private set
    var copyClicks = 0
        private set
    var stage = Stage.WAITING
        private set
    private val stages = ArrayDeque<Stage>()

    fun received() { clicks++ }
    fun recognized() { copyClicks++ }
    fun record(value: Stage) {
        stage = value
        updatedAt = System.nanoTime()
        if (stages.lastOrNull() != value) {
            stages.addLast(value)
            while (stages.size > 8) stages.removeFirst()
        }
    }
    fun reset() {
        updatedAt = 0L
        clicks = 0
        copyClicks = 0
        stage = Stage.WAITING
        stages.clear()
    }

    fun summary(context: Context): String = context.getString(R.string.copy_probe_summary,
        clicks, copyClicks, context.getString(stage.message))

    fun report(context: Context): String = buildString {
        val settings = context.getSharedPreferences("actionhalo_settings", Context.MODE_PRIVATE)
        for (key in listOf("auto_popup_enabled", "accessibility_consent", TelegramCopyPolicy.SETTING,
                TelegramCopyPolicy.STANDARD_MENU_SETTING)) {
            appendLine("$key=${settings.getBoolean(key, false)}")
        }
        appendLine("telegram_clicks=$clicks")
        appendLine("telegram_copy_clicks=$copyClicks")
        appendLine("telegram_copy_stage=${stage.name}")
        appendLine("telegram_recent_stages=" + stages.joinToString(">") { it.name })
        appendLine("copy_stages_scope=telegram_and_authorized_standard_selection_menus")
        appendLine("standard_menu_policy=same_package_child_window_and_android_floating_popup_container")
        for (packageName in listOf("org.telegram.messenger", "org.telegram.messenger.web")) {
            val version = try {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(packageName, 0).versionName
                    ?.filterNot { it.isISOControl() }?.take(80) ?: "unknown"
            } catch (_: PackageManager.NameNotFoundException) {
                "not_installed"
            } catch (_: RuntimeException) {
                "unknown"
            }
            appendLine("$packageName=$version")
        }
    }
}
