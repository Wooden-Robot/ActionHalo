package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.WindowManager
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.Toast

/** A single list for disabling automatic entry in source apps, backed by existing app rules. */
internal class DisabledAppsSettings(private val activity: Activity) {
    fun show(onSaved: () -> Unit = {}): AlertDialog {
        return showDraft(null, onSaved)
    }

    internal fun showDraft(draft: Bundle?, onSaved: () -> Unit = {}): AlertDialog {
        val store = AppRulesStore(activity)
        val selected = (draft?.getStringArrayList("selected") ?: store.disabledPackages().toList()).toMutableSet()
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val installed = activity.packageManager.queryIntentActivities(query, 0)
            .map { it.activityInfo.packageName }.filter { it != activity.packageName }
        val names = (installed + store.packages() + selected).distinct().associateWith { pkg ->
            try {
                @Suppress("DEPRECATION")
                activity.packageManager.getApplicationLabel(activity.packageManager.getApplicationInfo(pkg, 0)).toString()
            } catch (_: android.content.pm.PackageManager.NameNotFoundException) { pkg }
        }
        val packages = names.keys.sortedWith(compareBy<String> { it !in selected }
            .thenBy { names.getValue(it).lowercase() }.thenBy { it })
        val labels = AppChoiceLabels(activity)
        val form = HaloUi.column(activity, 16).apply { isFocusableInTouchMode = true }
        form.addView(HaloUi.label(activity, activity.getString(R.string.disabled_apps_hint), 14f, HaloUi.secondary))
        val search = EditText(activity).apply {
            tag = "disabled_apps_search"
            hint = activity.getString(R.string.disabled_apps_search)
            contentDescription = hint
            setSingleLine()
        }
        form.addView(search)
        val onlySelected = Switch(activity).apply {
            tag = "disabled_apps_only_selected"
            text = activity.getString(R.string.app_rules_only_selected)
            setTextColor(HaloUi.text)
            minHeight = HaloUi.dp(activity, 48)
            isChecked = draft?.getBoolean("onlySelected") ?: false
        }
        form.addView(onlySelected)
        val count = HaloUi.label(activity, "", 13f, HaloUi.secondary)
        form.addView(count)
        val list = HaloUi.column(activity)
        form.addView(ScrollView(activity).apply { addView(list) }, LinearLayout.LayoutParams(-1,
            HaloUi.dp(activity, minOf(300, (activity.resources.configuration.screenHeightDp / 3).coerceAtLeast(100)))))
        form.addView(HaloUi.label(activity, activity.getString(R.string.disabled_apps_restore_hint), 12f, HaloUi.secondary))
        val status = HaloUi.label(activity, "", 13f, HaloUi.accent).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        form.addView(status)
        fun updateCount() { count.text = activity.getString(R.string.disabled_apps_count, selected.size) }
        val rows = mutableMapOf<String, CheckBox>()
        fun render() {
            list.removeAllViews()
            val filter = search.text.toString().trim()
            val matches = packages.filter { (!onlySelected.isChecked || it in selected) &&
                (it.contains(filter, true) || names.getValue(it).contains(filter, true)) }
            matches.forEach { pkg ->
                list.addView(rows.getOrPut(pkg) { CheckBox(activity).apply {
                    tag = pkg
                    labels.bind(this, pkg, names.getValue(pkg))
                    isChecked = pkg in selected
                    setOnCheckedChangeListener { _, checked ->
                        if (checked) selected.add(pkg) else selected.remove(pkg)
                        status.text = ""
                        updateCount()
                        if (onlySelected.isChecked && !checked) list.post { render() }
                    }
                } })
            }
            if (matches.isEmpty()) list.addView(HaloUi.label(activity,
                activity.getString(R.string.disabled_apps_no_apps), 14f, HaloUi.secondary))
            updateCount()
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = render()
            override fun afterTextChanged(s: Editable?) = Unit
        })
        onlySelected.setOnCheckedChangeListener { _, _ -> render() }
        search.setText(draft?.getString("query").orEmpty())
        render()
        val dialog = AlertDialog.Builder(activity).setTitle(R.string.disabled_apps_title)
            .setView(ScrollView(activity).apply { addView(form) })
            .setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.save, null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try { store.setDisabledPackages(selected) }
                catch (_: IllegalArgumentException) {
                    status.setText(R.string.disabled_apps_invalid)
                    return@setOnClickListener
                }
                onSaved()
                Toast.makeText(activity, R.string.app_rules_saved, Toast.LENGTH_SHORT).show()
                dialog.dismiss()
            }
            form.requestFocus()
        }
        dialog.show()
        AppSettingsDrafts.track(activity, dialog, "disabled") { Bundle().apply {
            putStringArrayList("selected", ArrayList(selected))
            putString("query", search.text.toString())
            putBoolean("onlySelected", onlySelected.isChecked)
        } }
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        return dialog
    }
}
