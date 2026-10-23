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
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.Switch
import android.widget.Toast

/** The draft stays local until Save; apps missing on this phone remain editable by package name. */
internal class ActionAppScopeSettings(private val activity: Activity) {
    fun show(action: HaloAction, onSaved: () -> Unit = {}): AlertDialog {
        return showDraft(action, null, onSaved)
    }

    internal fun showDraft(action: HaloAction, draft: Bundle?, onSaved: () -> Unit = {}): AlertDialog {
        val store = ActionStore(activity)
        val original = store.appScope(action.id)
        var mode = ActionStore.AppScopeMode.entries.find { it.name == draft?.getString("mode") } ?: original.mode
        val selected = (draft?.getStringArrayList("selected") ?: original.packages).toMutableSet()
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val installed = activity.packageManager.queryIntentActivities(query, 0)
            .map { it.activityInfo.packageName }.filter { it != activity.packageName }.distinct()
        val names = (installed + original.packages + selected).distinct().associateWith { pkg ->
            try {
                @Suppress("DEPRECATION")
                activity.packageManager.getApplicationLabel(activity.packageManager.getApplicationInfo(pkg, 0)).toString()
            } catch (_: android.content.pm.PackageManager.NameNotFoundException) { pkg }
        }
        val packages = names.keys.sortedWith(compareBy<String> { names.getValue(it).lowercase() }.thenBy { it })
        val labels = AppChoiceLabels(activity)
        val form = HaloUi.column(activity, 16)
        form.isFocusableInTouchMode = true
        form.addView(HaloUi.label(activity, activity.getString(R.string.action_scope_hint), 13f, HaloUi.secondary))
        val modes = RadioGroup(activity)
        val modeLabels = listOf(R.string.action_scope_all, R.string.action_scope_only, R.string.action_scope_except)
        ActionStore.AppScopeMode.entries.forEach { option ->
            modes.addView(RadioButton(activity).apply {
                id = View.generateViewId()
                tag = option.name
                text = activity.getString(modeLabels[option.ordinal])
                setTextColor(HaloUi.text)
                minHeight = HaloUi.dp(activity, 48)
                isChecked = mode == option
            })
        }
        form.addView(modes)
        val picker = HaloUi.column(activity)
        val search = EditText(activity).apply {
            tag = "app_scope_search"
            hint = activity.getString(R.string.action_scope_search)
            contentDescription = hint
            setSingleLine()
        }
        picker.addView(search)
        val onlySelected = Switch(activity).apply {
            tag = "app_scope_only_selected"
            text = activity.getString(R.string.app_rules_only_selected)
            setTextColor(HaloUi.text)
            minHeight = HaloUi.dp(activity, 48)
            isChecked = draft?.getBoolean("onlySelected") ?: false
        }
        picker.addView(onlySelected)
        val count = HaloUi.label(activity, "", 13f, HaloUi.secondary)
        picker.addView(count)
        val list = HaloUi.column(activity)
        picker.addView(ScrollView(activity).apply { addView(list) }, LinearLayout.LayoutParams(-1,
            HaloUi.dp(activity, minOf(240, (activity.resources.configuration.screenHeightDp / 3).coerceAtLeast(100)))))
        form.addView(picker)
        val status = HaloUi.label(activity, "", 13f, HaloUi.accent).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        form.addView(status)
        fun updateCount() { count.text = activity.getString(R.string.action_scope_count, selected.size) }
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
                activity.getString(R.string.action_scope_no_apps), 14f, HaloUi.secondary))
            updateCount()
        }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = render()
            override fun afterTextChanged(s: Editable?) = Unit
        })
        onlySelected.setOnCheckedChangeListener { _, _ -> render() }
        search.setText(draft?.getString("query").orEmpty())
        modes.setOnCheckedChangeListener { group, id ->
            mode = ActionStore.AppScopeMode.valueOf(group.findViewById<RadioButton>(id).tag as String)
            picker.visibility = if (mode == ActionStore.AppScopeMode.ALL) View.GONE else View.VISIBLE
            status.text = ""
        }
        picker.visibility = if (mode == ActionStore.AppScopeMode.ALL) View.GONE else View.VISIBLE
        render()
        val dialog = AlertDialog.Builder(activity)
            .setTitle(activity.getString(R.string.action_scope_title, action.title))
            .setView(ScrollView(activity).apply { addView(form) }).setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.save, null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (mode != ActionStore.AppScopeMode.ALL && selected.isEmpty()) {
                    status.setText(R.string.action_scope_select_app)
                    return@setOnClickListener
                }
                val scope = ActionStore.AppScope(mode,
                    if (mode == ActionStore.AppScopeMode.ALL) emptyList() else selected.sorted())
                try { store.setAppScope(action.id, scope) }
                catch (_: IllegalArgumentException) {
                    status.setText(R.string.action_scope_invalid)
                    return@setOnClickListener
                }
                if (scope != original) onSaved()
                Toast.makeText(activity, R.string.app_rules_saved, Toast.LENGTH_SHORT).show()
                dialog.dismiss()
            }
            form.requestFocus()
        }
        dialog.show()
        AppSettingsDrafts.track(activity, dialog, "scope") { Bundle().apply {
            putString("action", action.id)
            putString("mode", mode.name)
            putStringArrayList("selected", ArrayList(selected))
            putString("query", search.text.toString())
            putBoolean("onlySelected", onlySelected.isChecked)
        } }
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        return dialog
    }
}
