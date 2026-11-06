package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.app.StatusBarManager
import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.DragEvent
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.ArrayAdapter
import android.widget.Toast
import android.widget.EditText
import android.widget.Switch
import android.widget.AdapterView
import android.widget.TextView

internal class AppRulesSettings(private val activity: Activity) {
    private val store = AppRulesStore(activity)
    private val actions = ActionStore(activity)
    private val handler = Handler(Looper.getMainLooper())
    private fun text(id: Int) = activity.getString(id)
    private fun button(label: String) = HaloUi.button(activity, label)

    fun addControls(parent: LinearLayout) {
        parent.addView(button(text(R.string.disabled_apps_title)).apply {
            setOnClickListener { DisabledAppsSettings(activity).show() }
        })
        parent.addView(HaloUi.label(activity, text(R.string.disabled_apps_hint), 14f, HaloUi.secondary))
        val group = HaloUi.column(activity, 16)
        group.background = HaloUi.shape(activity, HaloUi.surface)
        group.addView(HaloUi.label(activity, text(R.string.pause_title), 20f, bold = true))
        val status = HaloUi.label(activity, "", color = HaloUi.secondary)
        group.addView(status)
        lateinit var refresh: Runnable
        refresh = Runnable {
            val remaining = store.pauseRemainingMillis()
            status.text = if (remaining > 0) activity.getString(R.string.pause_remaining, (remaining + 59_999) / 60_000)
                else text(R.string.pause_ready)
            handler.removeCallbacks(refresh)
            if (remaining > 0 && group.isAttachedToWindow) handler.postDelayed(refresh, minOf(remaining + 50, 60_000))
        }
        listOf(R.string.pause_ten_minutes to AppRulesStore.TEN_MINUTES, R.string.pause_one_hour to AppRulesStore.ONE_HOUR,
            R.string.pause_resume to 0L).forEach { (label, duration) ->
            group.addView(button(text(label)).apply { setOnClickListener {
                if (duration == 0L) store.resume() else store.pauseFor(duration)
                refresh.run()
            } })
        }
        group.addView(button(text(R.string.pause_add_tile)).apply { setOnClickListener { addTile() } })
        group.addOnAttachStateChangeListener(object : android.view.View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: android.view.View) = refresh.run()
            override fun onViewDetachedFromWindow(view: android.view.View) { handler.removeCallbacks(refresh) }
        })
        refresh.run()
        parent.addView(group)
        parent.addView(button(text(R.string.app_rules_hub_title)).apply { setOnClickListener { showProfiles() } })
        parent.addView(HaloUi.label(activity, text(R.string.app_rules_hub_hint), 14f, HaloUi.secondary))
    }

    private fun addTile() {
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                activity.getSystemService(StatusBarManager::class.java).requestAddTileService(
                    ComponentName(activity, PauseTileService::class.java), text(R.string.pause_tile_label),
                    Icon.createWithResource(activity, R.drawable.ic_clipboard_halo), activity.mainExecutor,
                ) { result ->
                    if (result != StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED &&
                        result != StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) {
                        Toast.makeText(activity, R.string.pause_tile_manual, Toast.LENGTH_LONG).show()
                    }
                }
            } catch (_: RuntimeException) {
                Toast.makeText(activity, R.string.pause_tile_manual, Toast.LENGTH_LONG).show()
            }
        } else Toast.makeText(activity, R.string.pause_tile_manual, Toast.LENGTH_LONG).show()
    }

    fun showProfiles(draft: Bundle? = null): AlertDialog {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val installed = activity.packageManager.queryIntentActivities(intent, 0).map { it.activityInfo.packageName }
        var configured = (store.packages() + store.pausedPackages()).toSet()
        val scopePackages = actions.allActions().flatMap { actions.appScope(it.id).packages }
        val names = (installed + configured + scopePackages).distinct().filter { it != activity.packageName }
            .associateWith(::label)
        val packages = names.keys.sortedWith(compareBy<String> { it !in configured }
            .thenBy { names.getValue(it).lowercase() }.thenBy { it })
        val column = HaloUi.column(activity, 16)
        column.addView(HaloUi.label(activity, text(R.string.app_rules_hub_hint), 14f, HaloUi.secondary))
        val summary = HaloUi.label(activity, disabledSummary(activity), 13f, HaloUi.accent)
        column.addView(summary)
        val disabledButton = button(text(R.string.disabled_apps_title))
        column.addView(disabledButton)
        val search = EditText(activity).apply {
            tag = "app_rules_search"
            hint = text(R.string.disabled_apps_search)
            contentDescription = hint
            setSingleLine()
        }
        column.addView(search)
        val onlyConfigured = Switch(activity).apply {
            tag = "app_rules_only_configured"
            text = this@AppRulesSettings.text(R.string.app_rules_only_configured)
            setTextColor(HaloUi.text)
            minHeight = HaloUi.dp(activity, 48)
            isChecked = draft?.getBoolean("onlyConfigured") ?: false
        }
        column.addView(onlyConfigured)
        val list = HaloUi.column(activity)
        column.addView(list)
        val labels = AppChoiceLabels(activity)
        val rows = mutableMapOf<String, View>()
        lateinit var dialog: AlertDialog
        fun render() {
            configured = (store.packages() + store.pausedPackages()).toSet()
            summary.text = disabledSummary(activity)
            list.removeAllViews()
            val filter = search.text.toString().trim()
            val matches = packages.filter { (!onlyConfigured.isChecked || it in configured || it in scopePackages) &&
                (it.contains(filter, true) || names.getValue(it).contains(filter, true)) }
            matches.forEach { pkg ->
                list.addView(rows.getOrPut(pkg) {
                    HaloUi.column(activity, 8).apply {
                        tag = pkg
                        addView(HaloUi.label(activity, "").also { labels.bind(it, pkg, names.getValue(pkg)) })
                        addView(HaloUi.label(activity, text(AppRulePresentation(activity).triggerFor(pkg)), 13f, HaloUi.secondary))
                        isFocusable = true
                        setOnClickListener { dialog.dismiss(); editProfile(pkg) }
                    }
                })
            }
            if (matches.isEmpty()) list.addView(HaloUi.label(activity, text(R.string.disabled_apps_no_apps), 14f, HaloUi.secondary))
        }
        disabledButton.setOnClickListener { DisabledAppsSettings(activity).show { rows.clear(); render() } }
        search.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = render()
            override fun afterTextChanged(s: Editable?) = Unit
        })
        onlyConfigured.setOnCheckedChangeListener { _, _ -> render() }
        search.setText(draft?.getString("query").orEmpty())
        render()
        dialog = AlertDialog.Builder(activity).setTitle(R.string.app_rules_hub_title)
            .setView(ScrollView(activity).apply { addView(column) })
            .setNegativeButton(android.R.string.cancel, null).create()
        dialog.show()
        dialog.window?.decorView?.viewTreeObserver?.addOnWindowFocusChangeListener { focused ->
            if (focused) { rows.clear(); render() }
        }
        AppSettingsDrafts.track(activity, dialog, "profiles") { Bundle().apply {
            putString("query", search.text.toString())
            putBoolean("onlyConfigured", onlyConfigured.isChecked)
        } }
        column.isFocusableInTouchMode = true
        column.requestFocus()
        return dialog
    }

    private fun label(pkg: String): String = try {
        @Suppress("DEPRECATION")
        activity.packageManager.getApplicationLabel(activity.packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: android.content.pm.PackageManager.NameNotFoundException) { pkg }

    private fun editProfile(pkg: String) = editProfile(pkg, null)

    internal fun restoreProfile(draft: Bundle) {
        draft.getString("package")?.takeIf(AppRulesStore::isValidPackageName)?.let { editProfile(it, draft) }
    }

    private fun editProfile(pkg: String, draft: Bundle?) {
        val original = store.profile(pkg)
        var selected = if (draft == null) original.actions else draft.getStringArrayList("actions")
        var childSnapshot: (() -> Bundle)? = null
        var childDialog: AlertDialog? = null
        val column = HaloUi.column(activity, 16)
        column.addView(HaloUi.label(activity, pkg, 13f, HaloUi.secondary))
        var refreshPause: (() -> Unit)? = null
        if (store.appPauseRemainingMillis(pkg) > 0 || store.isVisitPaused(pkg)) {
            column.addView(button(text(R.string.source_resume_app)).apply {
                setOnClickListener { store.resumeApp(pkg); visibility = View.GONE; refreshPause?.invoke() }
            })
        }
        column.addView(HaloUi.label(activity, text(R.string.app_rules_trigger)))
        val mode = Spinner(activity).apply {
            adapter = ArrayAdapter(activity, android.R.layout.simple_spinner_dropdown_item,
                listOf(R.string.app_rules_default, R.string.app_rules_auto, R.string.app_rules_button, R.string.app_rules_off).map(::text))
            tag = "app_rules_trigger_mode"
            setSelection(draft?.getInt("mode") ?: original.trigger.ordinal)
        }
        column.addView(mode)
        val actionButton = button("")
        val preview = HaloUi.column(activity, 8)
        fun updateLabel() {
            actionButton.text = selected?.let { activity.getString(R.string.app_rules_actions_count, it.size) }
                ?: text(R.string.app_rules_actions_global)
            preview.removeAllViews()
            val profile = AppRulesStore.Profile(AppRulesStore.TriggerMode.entries[mode.selectedItemPosition], selected)
            val result = AppRulePresentation(activity).describe(pkg, profile)
            preview.addView(HaloUi.label(activity, text(R.string.app_rules_draft_preview), 15f, bold = true))
            preview.addView(HaloUi.label(activity, text(result.trigger), 14f, HaloUi.accent))
            preview.addView(HaloUi.label(activity, text(R.string.app_rules_effective_note), 12f, HaloUi.secondary))
            preview.addView(HaloUi.label(activity, activity.getString(R.string.app_rules_available_actions,
                result.available.size, result.available.joinToString("、") { it.title }.ifEmpty { text(R.string.app_rules_no_actions) }), 14f))
            if (result.hidden.isNotEmpty()) {
                preview.addView(HaloUi.label(activity, text(R.string.app_rules_hidden_actions), 14f, bold = true))
                result.hidden.forEach { hidden ->
                    preview.addView(HaloUi.label(activity, activity.getString(hidden.reason, hidden.action.title), 13f, HaloUi.secondary))
                    if (hidden.reason == R.string.app_rules_hidden_scope) {
                        preview.addView(button(text(R.string.app_rules_edit_scope)).apply {
                            setOnClickListener { ActionAppScopeSettings(activity).show(hidden.action) { updateLabel() } }
                        })
                    }
                }
            }
        }
        refreshPause = ::updateLabel
        updateLabel()
        fun openActions(restored: Bundle? = null) {
            childDialog = chooseActions(selected, restored, { childSnapshot = it }) { selected = it; updateLabel() }
        }
        actionButton.setOnClickListener { openActions() }
        column.addView(actionButton)
        column.addView(HaloUi.label(activity, text(R.string.app_rules_consent_hint), 13f, HaloUi.secondary))
        column.addView(preview)
        mode.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) = updateLabel()
            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        val dialog = AlertDialog.Builder(activity).setTitle(label(pkg)).setView(ScrollView(activity).apply { addView(column) })
            .setPositiveButton(android.R.string.ok) { _, _ ->
                store.setProfile(pkg, AppRulesStore.Profile(AppRulesStore.TriggerMode.entries[mode.selectedItemPosition], selected))
                Toast.makeText(activity, R.string.app_rules_saved, Toast.LENGTH_SHORT).show()
            }.setNeutralButton(R.string.app_rules_remove) { _, _ -> store.remove(pkg) }
            .setNegativeButton(android.R.string.cancel, null).show()
        AppSettingsDrafts.track(activity, dialog, "profile", onDismiss = { childDialog?.dismiss() }) { Bundle().apply {
            putString("package", pkg)
            putInt("mode", mode.selectedItemPosition)
            selected?.let { putStringArrayList("actions", ArrayList(it)) }
            childSnapshot?.let { putBundle("child", it()) }
        } }
        dialog.window?.decorView?.viewTreeObserver?.addOnWindowFocusChangeListener { focused -> if (focused) updateLabel() }
        draft?.getBundle("child")?.let(::openActions)
    }

    private fun chooseActions(current: List<String>?, draft: Bundle?, setSnapshot: ((() -> Bundle)?) -> Unit,
        save: (List<String>?) -> Unit): AlertDialog {
        val catalog = actions.allActions()
        val selected = (draft?.getStringArrayList("selected") ?: current ?: actions.actions().map { it.id })
            .filter { id -> catalog.any { it.id == id } }.toMutableList()
        val draftOrder = draft?.getStringArrayList("order")?.filter { id -> catalog.any { it.id == id } } ?: selected
        val ordered = draftOrder + catalog.map { it.id }.filterNot { it in draftOrder }
        val order = ordered.toMutableList()
        val content = HaloUi.column(activity, 12)
        val useGlobal = CheckBox(activity).apply {
            text = this@AppRulesSettings.text(R.string.app_rules_actions_global)
            setTextColor(HaloUi.text)
            isChecked = draft?.getBoolean("global") ?: (current == null)
        }
        content.addView(useGlobal)
        content.addView(HaloUi.label(activity, text(R.string.app_rules_order_hint), 13f, HaloUi.secondary))
        val list = HaloUi.column(activity)
        content.addView(list)
        val scroll = ScrollView(activity).apply { addView(content) }
        var dragged: View? = null
        var dragX = 0f
        var dragY = 0f
        var scrollDirection = 0
        fun dragPosition(): Pair<Float, Float> {
            val listOrigin = IntArray(2).also(list::getLocationOnScreen)
            val scrollOrigin = IntArray(2).also(scroll::getLocationOnScreen)
            return Pair(dragX + scrollOrigin[0] - listOrigin[0], dragY + scrollOrigin[1] - listOrigin[1])
        }
        fun previewDrag() {
            val row = dragged ?: return
            val (_, y) = dragPosition()
            val otherRows = (0 until list.childCount).map(list::getChildAt).filterNot { it === row }
            val target = otherRows.indexOfFirst { y < it.top + it.height / 2f }.let { if (it < 0) otherRows.size else it }
            if (target != list.indexOfChild(row)) { list.removeView(row); list.addView(row, target) }
        }
        val autoScroll = object : Runnable {
            override fun run() {
                if (dragged == null || scrollDirection == 0) return
                scroll.scrollBy(0, HaloUi.dp(activity, 8) * scrollDirection)
                previewDrag()
                scroll.postOnAnimation(this)
            }
        }
        fun startDrag(row: View): Boolean {
            if (useGlobal.isChecked || dragged != null) return false
            dragged = row
            if (!row.startDragAndDrop(ClipData.newPlainText("ActionHalo profile action", row.tag as String),
                    View.DragShadowBuilder(row), row, 0)) {
                dragged = null
                return false
            }
            row.alpha = 0.4f
            row.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            return true
        }
        fun render() {
            list.removeAllViews()
            order.forEachIndexed { index, id ->
                val action = catalog.first { it.id == id }
                val row = LinearLayout(activity).apply {
                    gravity = Gravity.CENTER_VERTICAL
                    tag = id
                    setOnLongClickListener { startDrag(this) }
                }
                row.addView(CheckBox(activity).apply {
                    text = action.title
                    setTextColor(HaloUi.text)
                    isChecked = id in selected
                    isEnabled = !useGlobal.isChecked
                    setOnLongClickListener { startDrag(row) }
                    setOnCheckedChangeListener { _, checked -> if (checked) selected.add(id) else selected.remove(id) }
                }, LinearLayout.LayoutParams(0, -2, 1f))
                listOf(-1 to "↑", 1 to "↓").forEach { (offset, glyph) ->
                    row.addView(button(glyph).apply {
                        contentDescription = activity.getString(if (offset < 0) R.string.app_rules_move_up else R.string.app_rules_move_down, action.title)
                        isEnabled = !useGlobal.isChecked && index + offset in order.indices
                        setOnLongClickListener { startDrag(row) }
                        setOnClickListener { order.removeAt(index); order.add(index + offset, id); render() }
                    }, LinearLayout.LayoutParams(HaloUi.dp(activity, 52), -2))
                }
                list.addView(row)
            }
        }
        scroll.setOnDragListener { _, event ->
            val row = dragged
            if (row == null || event.localState !== row) return@setOnDragListener false
            when (event.action) {
                DragEvent.ACTION_DRAG_STARTED -> return@setOnDragListener true
                DragEvent.ACTION_DRAG_LOCATION -> {
                    dragX = event.x
                    dragY = event.y
                    previewDrag()
                    val edge = HaloUi.dp(activity, 48)
                    val direction = when { dragY < edge -> -1; dragY > scroll.height - edge -> 1; else -> 0 }
                    if (direction != scrollDirection) {
                        scroll.removeCallbacks(autoScroll)
                        scrollDirection = direction
                        if (direction != 0) scroll.postOnAnimation(autoScroll)
                    }
                }
                DragEvent.ACTION_DROP -> {
                    scroll.removeCallbacks(autoScroll)
                    scrollDirection = 0
                    dragX = event.x
                    dragY = event.y
                    val (x, y) = dragPosition()
                    if (x !in 0f..list.width.toFloat() || y !in 0f..list.height.toFloat()) return@setOnDragListener false
                    previewDrag()
                    order.clear()
                    order.addAll((0 until list.childCount).map { list.getChildAt(it).tag as String })
                }
                DragEvent.ACTION_DRAG_EXITED -> { scroll.removeCallbacks(autoScroll); scrollDirection = 0 }
                DragEvent.ACTION_DRAG_ENDED -> {
                    scroll.removeCallbacks(autoScroll)
                    scrollDirection = 0
                    dragged = null
                    render()
                }
            }
            true
        }
        useGlobal.setOnCheckedChangeListener { _, _ -> render() }
        render()
        setSnapshot { Bundle().apply {
            putStringArrayList("selected", ArrayList(selected))
            putStringArrayList("order", ArrayList(order))
            putBoolean("global", useGlobal.isChecked)
        } }
        val dialog = AlertDialog.Builder(activity).setTitle(R.string.app_rules_actions_title)
            .setView(scroll)
            .setPositiveButton(android.R.string.ok) { _, _ -> save(if (useGlobal.isChecked) null else order.filter { it in selected }) }
            .setNegativeButton(android.R.string.cancel, null).show()
        dialog.setOnDismissListener {
                scroll.removeCallbacks(autoScroll)
                if (dragged != null) scroll.cancelDragAndDrop()
                dragged = null
                setSnapshot(null)
            }
        return dialog
    }

    companion object {
        fun disabledSummary(context: Context): String = context.getString(R.string.app_rules_disabled_summary,
            AppRulesStore(context).disabledPackages().size)
    }
}
