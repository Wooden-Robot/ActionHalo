package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import java.util.WeakHashMap

/** Activity state only: configuration drafts never contain selected text or clipboard contents. */
internal object AppSettingsDrafts {
    private const val KEY = "app_settings_dialog_drafts"
    private data class Entry(val dialog: AlertDialog, val kind: String, val snapshot: () -> Bundle)
    private val entries = WeakHashMap<Activity, MutableList<Entry>>()

    fun track(activity: Activity, dialog: AlertDialog, kind: String, onDismiss: () -> Unit = {}, snapshot: () -> Bundle) {
        val entry = Entry(dialog, kind, snapshot)
        entries.getOrPut(activity) { mutableListOf() }.add(entry)
        dialog.setOnDismissListener { entries[activity]?.remove(entry); onDismiss() }
    }

    fun save(activity: Activity, state: Bundle) {
        state.putParcelableArrayList(KEY, ArrayList(entries[activity].orEmpty()
            .filter { it.dialog.isShowing }.map { entry -> entry.snapshot().apply { putString("kind", entry.kind) } }))
    }

    @Suppress("DEPRECATION")
    fun restore(activity: Activity, state: Bundle?) {
        state?.getParcelableArrayList<Bundle>(KEY).orEmpty().forEach { draft ->
            when (draft.getString("kind")) {
                "disabled" -> DisabledAppsSettings(activity).showDraft(draft)
                "scope" -> ActionStore(activity).allActions().find { it.id == draft.getString("action") }
                    ?.let { ActionAppScopeSettings(activity).showDraft(it, draft) }
                "profiles" -> AppRulesSettings(activity).showProfiles(draft)
                "profile" -> AppRulesSettings(activity).restoreProfile(draft)
            }
        }
    }

    fun release(activity: Activity) {
        entries.remove(activity).orEmpty().toList().asReversed().forEach { it.dialog.dismiss() }
    }

    internal fun dialogs(activity: Activity): List<AlertDialog> = entries[activity].orEmpty().map { it.dialog }
}
