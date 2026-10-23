package com.actionhalo.android

import android.view.View
import android.widget.ScrollView
import android.widget.TextView

/** Explicit controls for the verified source app, inside the existing wheel window. */
internal object SourceAppControls {
    fun bind(menu: RadialMenuView, packageName: String?, sourceWindowId: Int? = null, close: () -> Unit) {
        val pkg = packageName?.takeIf { it != menu.context.packageName && AppRulesStore.isValidPackageName(it) } ?: return
        menu.onSourceAppOptions = {
            val context = menu.context
            val rules = AppRulesStore(context)
            val column = HaloUi.column(context, 16).apply { background = HaloUi.shape(context, HaloUi.surface) }
            val name = try {
                context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(pkg, 0)).toString()
            } catch (_: android.content.pm.PackageManager.NameNotFoundException) { pkg }
            column.addView(TextView(context).also { AppChoiceLabels(context).bind(it, pkg, name) })
            fun choice(label: Int, tagValue: String, action: () -> Unit) {
                column.addView(HaloUi.button(context, context.getString(label)).apply {
                    tag = tagValue
                    setOnClickListener {
                        try { action() }
                        catch (_: IllegalArgumentException) { android.widget.Toast.makeText(context, R.string.disabled_apps_invalid, android.widget.Toast.LENGTH_SHORT).show() }
                    }
                })
            }
            if (sourceWindowId != null && sourceWindowId >= 0) {
                choice(R.string.source_pause_visit, "source_pause_visit") { rules.pauseAppVisit(pkg, sourceWindowId); close() }
            } else choice(R.string.source_close_selection, "source_close_selection", close)
            choice(R.string.source_pause_app, "source_pause_app") {
                rules.pauseAppFor(pkg, AppRulesStore.TEN_MINUTES)
                close()
            }
            choice(R.string.source_disable_app, "source_disable_app") {
                rules.setDisabledPackages(rules.disabledPackages() + pkg)
                close()
            }
            choice(R.string.source_back, "source_back") { menu.hideInlinePanel() }
            menu.showInlinePanel(ScrollView(context).apply { addView(column) })
        }
    }
}
