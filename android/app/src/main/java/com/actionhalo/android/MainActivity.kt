package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.app.StatusBarManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.DragEvent
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {
    internal enum class Page(val title: Int) {
        HOME(R.string.app_name), ACTIONS(R.string.page_actions), APPEARANCE(R.string.page_appearance),
        TRIGGERS(R.string.page_triggers), DIAGNOSTICS(R.string.page_diagnostics), ABOUT(R.string.page_about),
    }
    private val page by lazy { Page.entries.find { it.name == intent.getStringExtra(EXTRA_PAGE) } ?: Page.HOME }
    private var updateChecker: AndroidUpdateChecker? = null
    private fun openPage(page: Page) = startActivity(pageIntent(this, page))

    companion object {
        private const val EXTRA_PAGE = "com.actionhalo.android.SETTINGS_PAGE"
        internal fun pageIntent(context: android.content.Context, page: Page): Intent =
            Intent(context, MainActivity::class.java).putExtra(EXTRA_PAGE, page.name)
    }
    private val settings by lazy { getSharedPreferences("actionhalo_settings", MODE_PRIVATE) }
    private val store by lazy { ActionStore(this) }
    private lateinit var autoSwitch: Switch
    private lateinit var autoStatus: TextView
    private lateinit var telegramCopySwitch: Switch
    private lateinit var telegramCopyStatus: TextView
    private lateinit var standardMenuSwitch: Switch
    private lateinit var standardMenuStatus: TextView
    private lateinit var settingsButton: View
    private lateinit var scroll: ScrollView
    private lateinit var actionList: LinearLayout
    private var draggedActionRow: View? = null
    private var dragX = 0f
    private var dragY = 0f
    private var dragScrollDirection = 0
    private val dragScroll = object : Runnable {
        override fun run() {
            if (draggedActionRow == null || dragScrollDirection == 0) return
            scroll.scrollBy(0, dp(8) * dragScrollDirection)
            previewActionDrag()
            scroll.postOnAnimation(this)
        }
    }
    private var appearanceSettings: AppearanceSettings? = null
    private var recoveryButton: Button? = null
    private var appRulesSummary: Button? = null
    private var actionQuery = ""
    private var actionSearch: EditText? = null
    private var adviceTitle: TextView? = null
    private var adviceBody: TextView? = null
    private var adviceAction: Button? = null
    private var pauseButton: Button? = null
    private var editorDialog: AlertDialog? = null
    private var editorDraft: (() -> Bundle)? = null
    private lateinit var undoButton: Button
    private var undoAction: (() -> Unit)? = null
    private val clearUndo = Runnable { undoAction = null; if (::undoButton.isInitialized) undoButton.visibility = View.GONE }
    private val refreshHome = object : Runnable {
        override fun run() { updateMode(); if (page == Page.HOME) scroll.postDelayed(this, 30_000) }
    }
    private lateinit var diagnosticStatus: TextView
    private lateinit var copyDiagnosticStatus: TextView
    private lateinit var serviceHealthStatus: TextView
    private var updatingMode = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN)
        actionQuery = savedInstanceState?.getString("action_query").orEmpty()
        val oldModels = java.io.File(noBackupFilesDir, "com.google.mlkit.translate.models")
        if (oldModels.exists()) Thread({ oldModels.deleteRecursively() }, "ActionHalo-model-cleanup").start()
        scroll = ScrollView(this).apply {
            setBackgroundColor(HaloUi.background)
            isFillViewport = true
            isFocusableInTouchMode = true
            descendantFocusability = ViewGroup.FOCUS_BEFORE_DESCENDANTS
            clipToPadding = false
        }
        val content = HaloUi.column(this, 24)
        scroll.addView(content, android.widget.FrameLayout.LayoutParams(-1, -2))
        val brand = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        brand.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_launcher)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(dp(42), dp(42)))
        brand.addView(HaloUi.label(this, getString(R.string.app_name), 21f, bold = true))
        content.addView(brand)
        if (page != Page.HOME) {
            content.addView(HaloUi.button(this, getString(R.string.page_back)).apply {
                setOnClickListener { finish() }
            })
            content.addSpace(12)
            content.addView(HaloUi.label(this, getString(page.title), 28f, bold = true))
            content.addSpace(24)
        }
        if (page == Page.HOME) buildHome(content, savedInstanceState)
        if (page == Page.TRIGGERS) buildTriggers(content)
        if (page == Page.APPEARANCE) buildAppearance(content)
        if (page == Page.DIAGNOSTICS) buildDiagnostics(content)
        if (page == Page.ACTIONS) buildActions(content)
        if (page == Page.ABOUT) buildAbout(content)
        content.addSpace(30)
        content.addView(HaloUi.label(this, getString(R.string.privacy_footer), 12f, HaloUi.secondary).apply {
            gravity = Gravity.CENTER
        })
        content.addSpace(12)
        val container = android.widget.FrameLayout(this).apply { setBackgroundColor(HaloUi.background) }
        val pinnedAppearance = appearanceSettings != null
        val body = if (pinnedAppearance) LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(requireNotNull(appearanceSettings).takePinnedPreview(), LinearLayout.LayoutParams(-1, -2))
            addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        } else scroll
        container.addView(body, android.widget.FrameLayout.LayoutParams(-1, -1))
        undoButton = HaloUi.button(this, getString(R.string.undo_change), true).apply {
            visibility = View.GONE
            setOnClickListener {
                val action = undoAction
                clearUndo.run()
                action?.invoke()
                if (::actionList.isInitialized) renderActions()
            }
        }
        container.addView(undoButton, android.widget.FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply {
            leftMargin = dp(24); rightMargin = dp(24); bottomMargin = dp(24)
        })
        scroll.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            val params = undoButton.layoutParams as android.widget.FrameLayout.LayoutParams
            val bottom = (if (pinnedAppearance) 0 else scroll.paddingBottom) + dp(16)
            if (params.bottomMargin != bottom) {
                params.bottomMargin = bottom; undoButton.layoutParams = params
            }
        }
        setContentView(container)
        scroll.requestFocus()
        HaloUi.applyInsets(this, if (pinnedAppearance) container else scroll)
        if (::actionList.isInitialized) renderActions()
        AppSettingsDrafts.restore(this, savedInstanceState)
        savedInstanceState?.getBundle("action_editor")?.let { draft ->
            val id = draft.getString("id")
            val action = store.allActions().firstOrNull { it.id == id }
            if (id == null || action != null) showActionEditor(action, draft)
        }
    }

    private fun buildHome(content: LinearLayout, savedInstanceState: Bundle?) {
        content.addSpace(12)
        updateChecker = AndroidUpdateChecker(this).also { it.addStartupNotice(content) }
        val statusCard = card()
        autoSwitch = Switch(this).apply {
            text = getString(R.string.auto_title)
            setTextColor(HaloUi.text)
            textSize = 17f
            minHeight = dp(48)
            setOnCheckedChangeListener { _, checked -> if (!updatingMode) changeAutomaticMode(checked) }
        }
        statusCard.addView(autoSwitch)
        autoStatus = HaloUi.label(this, "", 14f, HaloUi.secondary)
        statusCard.addView(autoStatus)
        recoveryButton = HaloUi.button(this, "").also { statusCard.addView(it, LinearLayout.LayoutParams(-1, -2)) }
        val daily = LinearLayout(this)
        listOf(Page.ACTIONS, Page.APPEARANCE).forEach { destination ->
            daily.addView(HaloUi.button(this, getString(destination.title)).apply {
                setOnClickListener { openPage(destination) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }
        statusCard.addView(daily)
        appRulesSummary = HaloUi.button(this, "").apply {
            setOnClickListener { AppRulesSettings(this@MainActivity).showProfiles() }
        }.also { statusCard.addView(it, LinearLayout.LayoutParams(-1, -2)) }
        pauseButton = HaloUi.button(this, getString(R.string.pause_ten_minutes)).apply {
            setOnClickListener {
                val rules = AppRulesStore(this@MainActivity)
                if (rules.isPaused()) rules.resume() else rules.pauseFor(AppRulesStore.TEN_MINUTES)
                updateMode()
            }
        }.also { statusCard.addView(it, LinearLayout.LayoutParams(-1, -2)) }
        statusCard.addView(HaloUi.button(this, getString(R.string.clipboard_use_text)).apply {
            setOnClickListener { startActivity(ClipboardHaloActivity.requestIntent(this@MainActivity)) }
        }, LinearLayout.LayoutParams(-1, -2))
        content.addView(statusCard)
        content.addSpace(16)
        val navigation = card()
        listOf(Page.TRIGGERS, Page.DIAGNOSTICS, Page.ABOUT).forEach { destination ->
            navigation.addView(HaloUi.button(this, getString(destination.title)).apply {
                setOnClickListener { openPage(destination) }
            }, LinearLayout.LayoutParams(-1, -2))
        }
        navigation.addView(HaloUi.button(this, getString(R.string.backup_title)).apply {
            setOnClickListener { startActivity(Intent(this@MainActivity, BackupSettingsActivity::class.java)) }
        }, LinearLayout.LayoutParams(-1, -2))
        content.addView(navigation)
        content.addSpace(16)
        buildDemo(content, savedInstanceState)
    }

    private fun buildDemo(content: LinearLayout, savedInstanceState: Bundle?) {
        val demoCard = card()
        val demoToggle = HaloUi.button(this, getString(R.string.try_title)).apply {
            tag = "demo_toggle"
            setOnClickListener {
                val expand = demoCard.visibility != View.VISIBLE
                demoCard.visibility = if (expand) View.VISIBLE else View.GONE
                settings.edit().putBoolean("demo_expanded", expand).apply()
            }
        }
        content.addView(demoToggle)
        demoCard.visibility = if (settings.getBoolean("demo_expanded",
            !settings.getBoolean("accessibility_consent", false))) View.VISIBLE else View.GONE
        val editor = EditText(this).apply {
            id = View.generateViewId()
            setText(savedInstanceState?.getString("demo_text") ?: getString(R.string.sample_text))
            hint = getString(R.string.sample_hint)
            contentDescription = getString(R.string.sample_hint)
            setTextColor(HaloUi.text)
            setHintTextColor(HaloUi.secondary)
            textSize = 18f
            minLines = 2
            maxLines = 5
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            backgroundTintList = ColorStateList.valueOf(HaloUi.accent)
        }
        demoEditor = editor
        demoCard.addView(editor, LinearLayout.LayoutParams(-1, -2))
        demoCard.addSpace(12)
        demoCard.addView(HaloUi.button(this, getString(R.string.show_halo), true).apply {
            setOnClickListener {
                if (IncomingText.isUsable(editor.text)) {
                    settings.edit().putBoolean("demo_expanded", false).apply()
                    demoCard.visibility = View.GONE
                    startActivity(Intent(this@MainActivity, HaloActivity::class.java)
                        .putExtra(HaloActivity.EXTRA_DEMO_TEXT, editor.text.toString()))
                } else toast(if (editor.length() > IncomingText.MAX_LENGTH) R.string.text_too_long else R.string.empty_text)
            }
        }, LinearLayout.LayoutParams(-1, -2))
        demoCard.addSpace(12)
        demoCard.addView(HaloUi.label(this, getString(R.string.gesture_hint), 12f, HaloUi.secondary))
        content.addView(demoCard)
        content.addSpace(28)

    }

    private fun buildTriggers(content: LinearLayout) {
        content.addSection(R.string.access_title)
        val access = card()
        access.addView(HaloUi.label(this, getString(R.string.manual_title), 17f, bold = true))
        access.addSpace(8)
        access.addView(HaloUi.label(this, getString(R.string.manual_body), 14f, HaloUi.secondary))
        access.addSpace(20)
        autoSwitch = Switch(this).apply {
            text = getString(R.string.auto_title)
            setTextColor(HaloUi.text)
            textSize = 16f
            minHeight = dp(48)
            setOnCheckedChangeListener { _, enabled -> if (!updatingMode) changeAutomaticMode(enabled) }
        }
        access.addView(autoSwitch, LinearLayout.LayoutParams(-1, -2))
        autoStatus = HaloUi.label(this, "", 12f, HaloUi.secondary)
        access.addView(autoStatus)
        access.addSpace(8)
        access.addView(HaloUi.label(this, getString(R.string.selection_adjustment_hint), 12f, HaloUi.secondary))
        access.addSpace(10)
        settingsButton = HaloUi.button(this, getString(R.string.access_settings)).apply {
            setOnClickListener { openAccessibilitySettings() }
        }
        access.addView(settingsButton, LinearLayout.LayoutParams(-1, -2))
        access.addSpace(12)
        content.addView(access)
        content.addSection(R.string.clipboard_entry_title)
        val clipboard = card()
        telegramCopySwitch = Switch(this).apply {
            text = getString(R.string.telegram_copy_popup_title)
            setTextColor(HaloUi.text)
            textSize = 16f
            minHeight = dp(48)
            setOnCheckedChangeListener { _, enabled -> if (!updatingMode) changeTelegramCopyMode(enabled) }
        }
        clipboard.addView(telegramCopySwitch, LinearLayout.LayoutParams(-1, -2))
        telegramCopyStatus = HaloUi.label(this, "", 12f, HaloUi.secondary)
        clipboard.addView(telegramCopyStatus)
        clipboard.addSpace(16)
        standardMenuSwitch = Switch(this).apply {
            text = getString(R.string.standard_menu_title)
            setTextColor(HaloUi.text)
            textSize = 16f
            minHeight = dp(48)
            setOnCheckedChangeListener { _, enabled ->
                if (!updatingMode) changeMenuMode(enabled, TelegramCopyPolicy.STANDARD_MENU_SETTING,
                    R.string.standard_menu_consent_title, R.string.standard_menu_consent_body)
            }
        }
        clipboard.addView(standardMenuSwitch, LinearLayout.LayoutParams(-1, -2))
        standardMenuStatus = HaloUi.label(this, "", 12f, HaloUi.secondary)
        clipboard.addView(standardMenuStatus)
        clipboard.addSpace(8)
        clipboard.addView(HaloUi.label(this, getString(R.string.standard_menu_body), 14f, HaloUi.secondary))
        clipboard.addSpace(8)
        clipboard.addView(HaloUi.label(this, getString(R.string.clipboard_entry_body), 14f, HaloUi.secondary))
        clipboard.addSpace(16)
        clipboard.addView(HaloUi.button(this, getString(R.string.clipboard_add_tile)).apply {
            setOnClickListener { addClipboardTile() }
        }, LinearLayout.LayoutParams(-1, -2))
        clipboard.addSpace(8)
        clipboard.addView(HaloUi.button(this, getString(R.string.clipboard_use_text)).apply {
            setOnClickListener { startActivity(ClipboardHaloActivity.requestIntent(this@MainActivity)) }
        }, LinearLayout.LayoutParams(-1, -2))
        content.addView(clipboard)
        content.addSpace(28)

        val copySession = card()
        copySession.addView(Switch(this).apply {
            text = getString(R.string.keep_copy_menu_title)
            setTextColor(HaloUi.text)
            textSize = 17f
            minHeight = dp(52)
            isChecked = settings.getBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, false)
            setOnCheckedChangeListener { _, checked -> settings.edit().putBoolean(HaloAppearance.KEEP_AFTER_COPY_KEY, checked).apply() }
        })
        copySession.addView(HaloUi.label(this, getString(R.string.keep_copy_menu_body), 13f, HaloUi.secondary))
        content.addView(copySession)
        content.addSpace(16)
        AppRulesSettings(this).addControls(content)
    }

    private fun buildAppearance(content: LinearLayout) {
        appearanceSettings = AppearanceSettings(this, onReset = { undo -> showUndo(undo) }, onChanged = { clearUndo.run() }).also { it.addControls(content) }
    }

    private fun buildDiagnostics(content: LinearLayout) {
        content.addSection(R.string.page_diagnostics)
        val advice = card()
        adviceTitle = HaloUi.label(this, "", 20f, bold = true).also { advice.addView(it) }
        adviceBody = HaloUi.label(this, "", 14f, HaloUi.secondary).also { advice.addView(it) }
        adviceAction = HaloUi.button(this, "").also { advice.addView(it, LinearLayout.LayoutParams(-1, -2)) }
        content.addView(advice)
        content.addSpace(16)
        val access = card()
        copyDiagnosticStatus = HaloUi.label(this, "", 12f, HaloUi.secondary)
        access.addView(copyDiagnosticStatus)
        access.addSpace(12)
        access.addView(HaloUi.button(this, getString(R.string.diagnostic_test)).apply {
            setOnClickListener { testOverlay() }
        }, LinearLayout.LayoutParams(-1, -2))
        access.addSpace(8)
        diagnosticStatus = HaloUi.label(this, "", 12f, HaloUi.secondary)
        access.addView(diagnosticStatus)
        access.addSpace(8)
        access.addView(HaloUi.label(this, getString(R.string.diagnostic_test_hint), 12f, HaloUi.secondary))
        access.addSpace(16)
        serviceHealthStatus = HaloUi.label(this, "", 12f, HaloUi.secondary)
        access.addView(serviceHealthStatus)
        access.addSpace(8)
        access.addView(HaloUi.button(this, getString(R.string.background_help_button)).apply {
            setOnClickListener { showBackgroundHelp() }
        }, LinearLayout.LayoutParams(-1, -2))
        access.addSpace(8)
        access.addView(HaloUi.button(this, getString(R.string.health_copy_button)).apply {
            setOnClickListener { copyTroubleshootingReport() }
        }, LinearLayout.LayoutParams(-1, -2))
        access.addSpace(8)
        access.addView(HaloUi.label(this, getString(R.string.health_copy_description), 12f, HaloUi.secondary))
        content.addView(access)
        content.addSpace(28)

    }

    private fun testOverlay() {
        if (!SelectionAccessibilityService.checkOverlay()) toast(when {
            !SelectionAccessibilityService.isConnected() -> R.string.diagnostic_test_unavailable
            SelectionDiagnostics.result == SelectionDiagnostics.Result.BLOCKED -> R.string.diagnostic_blocked
            SelectionDiagnostics.result == SelectionDiagnostics.Result.NO_ACTIONS -> R.string.no_actions
            else -> R.string.diagnostic_test_unavailable
        })
        updateMode()
    }

    private fun buildActions(content: LinearLayout) {
        val advanced = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
        content.addView(HaloUi.button(this, getString(R.string.settings_more_actions)).apply {
            setOnClickListener { advanced.visibility = if (advanced.visibility == View.VISIBLE) View.GONE else View.VISIBLE }
        })
        advanced.addView(HaloUi.button(this, getString(R.string.actions_disable_all)).apply {
            setOnClickListener { changeActionsWithUndo { store.setAllEnabled(false) } }
        })
        advanced.addView(HaloUi.button(this, getString(R.string.actions_reset_all)).apply {
            setOnClickListener {
                AlertDialog.Builder(this@MainActivity).setTitle(R.string.actions_reset_all)
                    .setMessage(R.string.actions_reset_confirm).setNegativeButton(R.string.cancel, null)
                    .setPositiveButton(android.R.string.ok) { _, _ -> changeActionsWithUndo { store.reset() } }.show()
            }
        })
        content.addView(advanced)
        content.addSection(R.string.actions_title)
        actionSearch = EditText(this).apply {
            tag = "action_search"
            hint = getString(R.string.action_search_hint)
            contentDescription = hint
            setSingleLine()
            setTextColor(HaloUi.text)
            setHintTextColor(HaloUi.secondary)
            setText(actionQuery)
            addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun afterTextChanged(s: android.text.Editable?) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    actionQuery = s?.toString().orEmpty()
                    if (::actionList.isInitialized) renderActions()
                }
            })
        }.also { content.addView(it) }
        content.addView(HaloUi.label(this, getString(R.string.actions_body), 13f, HaloUi.secondary))
        content.addSpace(12)
        actionList = card()
        scroll.setOnDragListener { _, event -> handleActionDrag(event) }
        content.addView(actionList)
        content.addSpace(12)
        content.addView(HaloUi.button(this, getString(R.string.add_action)).apply {
            setOnClickListener { showActionEditor() }
        }, LinearLayout.LayoutParams(-1, -2))
    }

    private fun buildAbout(content: LinearLayout) {
        val about = card()
        about.addView(HaloUi.label(this, getString(R.string.update_installed, BuildConfig.VERSION_NAME), 20f, bold = true))
        about.addSpace(12)
        updateChecker = AndroidUpdateChecker(this).also { it.addControls(about) }
        content.addView(about)
        content.addSpace(16)
        val privacy = card()
        privacy.addView(HaloUi.label(this, getString(R.string.privacy_title), 20f, bold = true))
        privacy.addView(HaloUi.label(this, getString(R.string.privacy_description), 14f, HaloUi.secondary))
        content.addView(privacy)
    }

    private lateinit var demoEditor: EditText
    override fun onSaveInstanceState(outState: Bundle) {
        if (::demoEditor.isInitialized) outState.putString("demo_text", demoEditor.text.toString())
        outState.putString("action_query", actionQuery)
        editorDraft?.invoke()?.let { outState.putBundle("action_editor", it) }
        AppSettingsDrafts.save(this, outState)
        super.onSaveInstanceState(outState)
    }

    override fun onResume() {
        super.onResume()
        if (page == Page.HOME) updateChecker?.checkOnLaunch()
        updateMode()
        appearanceSettings?.refresh()
        if (::actionList.isInitialized) renderActions()
        scroll.removeCallbacks(refreshHome)
        if (page == Page.HOME) scroll.postDelayed(refreshHome, 30_000)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && ::scroll.isInitialized) {
            updateMode()
            if (::actionList.isInitialized && draggedActionRow == null) renderActions()
        }
    }

    override fun onPause() {
        clearUndo.run()
        scroll.removeCallbacks(refreshHome)
        super.onPause()
    }

    override fun onDestroy() {
        scroll.removeCallbacks(clearUndo)
        scroll.removeCallbacks(refreshHome)
        undoAction = null
        updateChecker?.close()
        scroll.removeCallbacks(dragScroll)
        draggedActionRow = null
        editorDialog?.dismiss()
        editorDialog = null
        editorDraft = null
        AppSettingsDrafts.release(this)
        super.onDestroy()
    }

    private fun updateMode() {
        val enabled = settings.getBoolean("auto_popup_enabled", false) && settings.getBoolean("accessibility_consent", false)
        val telegramCopyEnabled = settings.getBoolean("telegram_copy_popup_enabled", false)
        val standardMenuEnabled = settings.getBoolean(TelegramCopyPolicy.STANDARD_MENU_SETTING, false)
        val rules = AppRulesStore(this)
        val hasAppRules = settings.getBoolean("accessibility_consent", false) && rules.packages().any {
            rules.triggerMode(it) in setOf(AppRulesStore.TriggerMode.AUTO, AppRulesStore.TriggerMode.BUTTON)
        }
        val needsAccessibility = enabled || telegramCopyEnabled || standardMenuEnabled || hasAppRules
        val paused = rules.isPaused()
        appRulesSummary?.text = getString(R.string.home_app_rules_summary, getString(R.string.app_rules_hub_title), AppRulesSettings.disabledSummary(this))
        pauseButton?.setText(if (paused) R.string.pause_resume else R.string.pause_ten_minutes)
        val connected = SelectionAccessibilityService.isConnected()
        val health = AccessibilityHealthDiagnostics.snapshot(this, connected)
        val hasAccessibility = health.configured ?: health.managerListed ?: connected
        updatingMode = true
        if (::autoSwitch.isInitialized) autoSwitch.isChecked = enabled
        if (::telegramCopySwitch.isInitialized) telegramCopySwitch.isChecked = telegramCopyEnabled
        if (::standardMenuSwitch.isInitialized) standardMenuSwitch.isChecked = standardMenuEnabled
        updatingMode = false
        recoveryButton?.apply {
            visibility = if (paused || !needsAccessibility || !hasAccessibility || !connected) View.VISIBLE else View.GONE
            text = getString(when {
                paused -> R.string.pause_resume
                !needsAccessibility -> R.string.home_enable
                !hasAccessibility -> R.string.home_authorize
                else -> R.string.home_reconnect
            })
            setOnClickListener {
                when {
                    paused -> { rules.resume(); updateMode() }
                    !needsAccessibility -> changeAutomaticMode(true)
                    !hasAccessibility -> openAccessibilitySettings()
                    else -> AlertDialog.Builder(this@MainActivity).setTitle(R.string.home_reconnect)
                        .setMessage(R.string.home_reconnect_body)
                        .setPositiveButton(R.string.background_app_settings) { _, _ ->
                            openSystemSettings(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        }.setNeutralButton(R.string.access_settings) { _, _ -> openAccessibilitySettings() }
                        .setNegativeButton(R.string.cancel, null).show()
                }
            }
        }
        if (::autoStatus.isInitialized) autoStatus.setText(when {
            !needsAccessibility -> R.string.auto_off
            !hasAccessibility -> R.string.auto_waiting
            !connected -> R.string.auto_disconnected
            !enabled && hasAppRules -> R.string.app_rules_active
            !enabled && standardMenuEnabled -> R.string.standard_menu_ready
            !enabled -> R.string.telegram_copy_popup_ready
            else -> R.string.auto_connected
        })
        if (::autoStatus.isInitialized && paused) autoStatus.text = getString(R.string.pause_remaining,
            (rules.pauseRemainingMillis() + 59_999) / 60_000)
        if (::telegramCopyStatus.isInitialized) telegramCopyStatus.setText(when {
            !telegramCopyEnabled -> R.string.telegram_copy_popup_off
            !hasAccessibility -> R.string.auto_waiting
            !connected -> R.string.auto_disconnected
            else -> R.string.telegram_copy_popup_ready
        })
        if (::standardMenuStatus.isInitialized) standardMenuStatus.setText(when {
            !standardMenuEnabled -> R.string.standard_menu_off
            !hasAccessibility -> R.string.auto_waiting
            !connected -> R.string.auto_disconnected
            else -> R.string.standard_menu_ready
        })
        adviceTitle?.let {
            val advice = DiagnosticAdvice.resolve(needsAccessibility, hasAccessibility, connected, paused,
                store.actions().isNotEmpty() || rules.packages().any { rules.actionsFor(it, store.allActions()).isNotEmpty() }, SelectionDiagnostics.result, TelegramCopyDiagnostics.stage,
                TelegramCopyDiagnostics.updatedAt > SelectionDiagnostics.updatedAt)
            it.setText(advice.title)
            adviceBody?.setText(advice.body)
            adviceAction?.apply {
                setText(advice.action.label)
                setOnClickListener {
                    when (advice.action) {
                        DiagnosticAdvice.Action.AUTHORIZE -> openAccessibilitySettings()
                        DiagnosticAdvice.Action.BACKGROUND -> showBackgroundHelp()
                        DiagnosticAdvice.Action.RULES -> AppRulesSettings(this@MainActivity).showProfiles()
                        DiagnosticAdvice.Action.ACTIONS -> openPage(Page.ACTIONS)
                        DiagnosticAdvice.Action.TRIGGERS -> openPage(Page.TRIGGERS)
                        DiagnosticAdvice.Action.RESUME -> { rules.resume(); updateMode() }
                        DiagnosticAdvice.Action.TEST -> testOverlay()
                    }
                }
            }
        }
        if (::copyDiagnosticStatus.isInitialized) copyDiagnosticStatus.text = TelegramCopyDiagnostics.summary(this)
        if (::serviceHealthStatus.isInitialized) serviceHealthStatus.text = AccessibilityHealthDiagnostics.renderStatus(this, health)
        if (::diagnosticStatus.isInitialized) {
            fun rangeLabel(range: Pair<Int, Int>?): String = when {
                range == null -> "—"
                range.first < 0 || range.second < 0 -> getString(R.string.diagnostic_range_unavailable)
                else -> "${range.first}:${range.second}"
            }
            diagnosticStatus.text = getString(R.string.diagnostic_summary,
                SelectionDiagnostics.selectionEvents, getString(SelectionDiagnostics.result.message)) + "\n" +
                getString(R.string.diagnostic_ranges, SelectionDiagnostics.nonemptyEventRanges,
                    SelectionDiagnostics.nonemptyNodeRanges, rangeLabel(SelectionDiagnostics.eventRange),
                    rangeLabel(SelectionDiagnostics.nodeRange))
        }
        if (::settingsButton.isInitialized) settingsButton.visibility = if (needsAccessibility) View.VISIBLE else View.GONE
    }

    private fun accessibilityEnabled(): Boolean {
        val health = AccessibilityHealthDiagnostics.snapshot(this, SelectionAccessibilityService.isConnected())
        return health.configured ?: health.managerListed ?: health.connected
    }

    private fun changeAutomaticMode(enabled: Boolean) {
        if (!enabled) {
            settings.edit().putBoolean("auto_popup_enabled", false).apply()
            updateMode()
            return
        }
        if (!settings.getBoolean("accessibility_consent", false)) {
            updateMode()
            AlertDialog.Builder(this)
                .setTitle(R.string.consent_title)
                .setMessage(R.string.consent_body)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.consent_accept) { _, _ ->
                    settings.edit().putBoolean("accessibility_consent", true).putBoolean("auto_popup_enabled", true).apply()
                    updateMode()
                    if (!accessibilityEnabled()) openAccessibilitySettings()
                }.show()
        } else {
            settings.edit().putBoolean("auto_popup_enabled", true).apply()
            updateMode()
            if (!accessibilityEnabled()) openAccessibilitySettings()
        }
    }

    private fun openAccessibilitySettings() {
        if (!accessibilityEnabled()) {
            openSystemSettings(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            return
        }
        // Opening the overview can revoke access on the reported vivo device.
        // An already enabled service does not need another trip through authorization.
        AlertDialog.Builder(this)
            .setTitle(R.string.access_already_enabled_title)
            .setMessage(R.string.access_already_enabled_body)
            .setPositiveButton(R.string.access_overview) { _, _ ->
                openSystemSettings(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun showBackgroundHelp() {
        AlertDialog.Builder(this)
            .setTitle(R.string.background_help_title)
            .setMessage(R.string.background_help_body)
            .setPositiveButton(R.string.background_app_settings) { _, _ ->
                openSystemSettings(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")))
            }
            .setNeutralButton(R.string.background_battery_settings) { _, _ ->
                openSystemSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun openSystemSettings(intent: Intent) {
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            toast(R.string.settings_unavailable)
        } catch (_: SecurityException) {
            toast(R.string.settings_unavailable)
        }
    }

    private fun copyTroubleshootingReport() {
        val report = AccessibilityHealthDiagnostics.renderReport(AccessibilityHealthDiagnostics.snapshot(this,
            SelectionAccessibilityService.isConnected())) +
            "\n" + TelegramCopyDiagnostics.report(this)
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("ActionHalo diagnostics", report))
        toast(R.string.health_copy_done)
        updateMode()
    }

    private fun changeTelegramCopyMode(enabled: Boolean) {
        changeMenuMode(enabled, TelegramCopyPolicy.SETTING,
            R.string.telegram_copy_consent_title, R.string.telegram_copy_consent_body)
    }

    private fun changeMenuMode(enabled: Boolean, key: String, title: Int, body: Int) {
        if (!enabled) {
            settings.edit().putBoolean(key, false).apply()
            updateMode()
            return
        }
        updateMode()
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(body)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.consent_accept) { _, _ ->
                settings.edit().putBoolean(key, true).apply()
                updateMode()
                if (!accessibilityEnabled()) openAccessibilitySettings()
            }.show()
    }

    private fun addClipboardTile() {
        if (Build.VERSION.SDK_INT < 33) {
            showClipboardTileGuide()
            return
        }
        val statusBar = getSystemService(StatusBarManager::class.java)
        if (statusBar == null) {
            showClipboardTileGuide()
            return
        }
        try {
            statusBar.requestAddTileService(
                ComponentName(this, ClipboardTileService::class.java),
                getString(R.string.clipboard_tile_label),
                Icon.createWithResource(this, R.drawable.ic_clipboard_halo),
                mainExecutor
            ) { result ->
                when (result) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> toast(R.string.clipboard_tile_added)
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> toast(R.string.clipboard_tile_already_added)
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> toast(R.string.clipboard_tile_not_added)
                    else -> if (!isFinishing && !isDestroyed) showClipboardTileGuide()
                }
            }
        } catch (_: RuntimeException) {
            showClipboardTileGuide()
        }
    }

    private fun showClipboardTileGuide() {
        AlertDialog.Builder(this)
            .setTitle(R.string.clipboard_tile_manual_title)
            .setMessage(getString(R.string.clipboard_tile_manual_body, getString(R.string.clipboard_tile_label)))
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    private fun showUndo(action: () -> Unit) {
        scroll.removeCallbacks(clearUndo)
        undoAction = action
        undoButton.visibility = View.VISIBLE
        scroll.postDelayed(clearUndo, 15_000)
    }

    private fun changeActionsWithUndo(change: () -> Unit) {
        val before = store.snapshot()
        change()
        renderActions()
        showUndo { store.restoreSnapshot(before) }
    }

    private fun renderActions() {
        actionList.removeAllViews()
        val actions = store.allActions()
        val matches = actions.withIndex().filter { (_, action) -> action.title.contains(actionQuery.trim(), true) ||
            action.template.orEmpty().contains(actionQuery.trim(), true) }
        if (matches.isEmpty()) actionList.addView(HaloUi.label(this, getString(R.string.action_search_empty), 14f, HaloUi.secondary))
        matches.forEach { (index, action) ->
            val row = android.widget.RelativeLayout(this).apply {
                gravity = Gravity.CENTER_VERTICAL
                tag = action.id
                setOnLongClickListener { startActionDrag(this) }
            }
            val toggle = Switch(this).apply {
                id = View.generateViewId()
                text = action.title
                val icon = getDrawable(ActionIcons.resource(action))?.mutate()?.apply {
                    setTint(HaloUi.text)
                    setBounds(0, 0, dp(22), dp(22))
                }
                setCompoundDrawablesRelative(icon, null, null, null)
                compoundDrawablePadding = dp(12)
                setTextColor(HaloUi.text)
                textSize = 15f
                minHeight = dp(56)
                isChecked = store.isEnabled(action.id)
                setOnLongClickListener { startActionDrag(row) }
                setOnCheckedChangeListener { button, checked ->
                    try { clearUndo.run(); store.setEnabled(action.id, checked) }
                    catch (_: IllegalArgumentException) {
                        button.isChecked = false
                        toast(R.string.action_unknown)
                    }
                }
            }
            row.addView(toggle, android.widget.RelativeLayout.LayoutParams(-1, -2).apply { marginEnd = dp(48) })
            row.addView(HaloUi.label(this, actionSummary(action), 12f, HaloUi.secondary).apply {
                setPadding(dp(34), 0, 0, dp(12))
                setOnLongClickListener { startActionDrag(row) }
            }, android.widget.RelativeLayout.LayoutParams(-1, -2).apply { addRule(android.widget.RelativeLayout.BELOW, toggle.id); marginEnd = dp(48) })
            row.addView(HaloUi.button(this, "⋮").apply {
                contentDescription = getString(R.string.action_manage_description, action.title)
                background = null
                textSize = 24f
                minimumWidth = 0
                minWidth = 0
                setPadding(0, 0, 0, 0)
                setOnLongClickListener { startActionDrag(row) }
                setOnClickListener { showActionMenu(this, action, index, actions.size) }
            }, android.widget.RelativeLayout.LayoutParams(dp(48), dp(48)).apply {
                addRule(android.widget.RelativeLayout.ALIGN_PARENT_END)
            })
            actionList.addView(row)
        }
    }

    private fun startActionDrag(row: View): Boolean {
        if (actionQuery.isNotBlank()) { toast(R.string.action_search_drag_hint); return false }
        if (draggedActionRow != null) return false
        draggedActionRow = row
        if (!row.startDragAndDrop(ClipData.newPlainText("ActionHalo action", row.tag as String),
                View.DragShadowBuilder(row), row, 0)) {
            draggedActionRow = null
            return false
        }
        row.alpha = 0.4f
        row.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        return true
    }

    private fun handleActionDrag(event: DragEvent): Boolean {
        val row = draggedActionRow ?: return false
        if (event.localState !== row) return false
        when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> return true
            DragEvent.ACTION_DRAG_LOCATION -> {
                dragX = event.x
                dragY = event.y
                previewActionDrag()
                val direction = when {
                    dragY < scroll.paddingTop + dp(48) -> -1
                    dragY > scroll.height - scroll.paddingBottom - dp(48) -> 1
                    else -> 0
                }
                if (direction != dragScrollDirection) {
                    scroll.removeCallbacks(dragScroll)
                    dragScrollDirection = direction
                    if (direction != 0) scroll.postOnAnimation(dragScroll)
                }
            }
            DragEvent.ACTION_DROP -> {
                scroll.removeCallbacks(dragScroll)
                dragScrollDirection = 0
                dragX = event.x
                dragY = event.y
                val (x, y) = actionDragPosition()
                if (x !in 0f..actionList.width.toFloat() || y !in 0f..actionList.height.toFloat()) return false
                previewActionDrag()
                clearUndo.run()
                store.moveTo(row.tag as String, actionList.indexOfChild(row))
            }
            DragEvent.ACTION_DRAG_EXITED -> {
                scroll.removeCallbacks(dragScroll)
                dragScrollDirection = 0
            }
            DragEvent.ACTION_DRAG_ENDED -> {
                scroll.removeCallbacks(dragScroll)
                dragScrollDirection = 0
                draggedActionRow = null
                renderActions()
            }
        }
        return true
    }

    private fun actionDragPosition(): Pair<Float, Float> {
        val listLocation = IntArray(2)
        val scrollLocation = IntArray(2)
        actionList.getLocationOnScreen(listLocation)
        scroll.getLocationOnScreen(scrollLocation)
        return Pair(dragX + scrollLocation[0] - listLocation[0], dragY + scrollLocation[1] - listLocation[1])
    }

    private fun previewActionDrag() {
        val row = draggedActionRow ?: return
        val (_, y) = actionDragPosition()
        val remaining = (0 until actionList.childCount).map(actionList::getChildAt).filterNot { it === row }
        val target = remaining.indexOfFirst { row ->
            // Aim at the named action; adding a summary must not move its drop boundary below the toggle.
            val primaryHeight = (row as? ViewGroup)?.getChildAt(0)?.height ?: row.height
            y < row.top + primaryHeight / 2f
        }.let { if (it < 0) remaining.size else it }
        if (target != actionList.indexOfChild(row)) {
            actionList.removeView(row)
            actionList.addView(row, target)
        }
    }

    private fun showActionMenu(anchor: View, action: HaloAction, index: Int, count: Int) {
        PopupMenu(this, anchor).apply {
            menu.add(0, 1, 0, R.string.action_move_up).isEnabled = index > 0
            menu.add(0, 2, 1, R.string.action_move_down).isEnabled = index + 1 < count
            if (store.canEdit(action)) {
                menu.add(0, 3, 2, R.string.edit_action)
                menu.add(0, 7, 6, R.string.action_duplicate)
            }
            if (ActionDestinations.supports(action)) menu.add(0, 5, 4, R.string.destination_menu)
            menu.add(0, 6, 5, R.string.action_scope_menu)
            if (action.id.startsWith("custom:")) menu.add(0, 4, 3, R.string.delete)
            setOnMenuItemClickListener { item ->
                when (item.itemId) {
                    1, 2 -> { clearUndo.run(); store.move(action.id, if (item.itemId == 1) -1 else 1); renderActions() }
                    3 -> showActionEditor(action)
                    7 -> showActionEditor(restored = Bundle().apply {
                        putString("name", getString(R.string.action_duplicate_name, action.title))
                        putString("url", store.templateForEditing(action))
                        putString("icon", ActionIcons.key(action))
                        putString("copy_source", action.id)
                    })
                    5 -> ActionDestinations(this@MainActivity).choose(this@MainActivity, action) { renderActions() }
                    6 -> ActionAppScopeSettings(this@MainActivity).show(action) { clearUndo.run(); renderActions() }
                    4 -> AlertDialog.Builder(this@MainActivity)
                        .setTitle(getString(R.string.remove_title, action.title))
                        .setNegativeButton(R.string.cancel, null)
                        .setPositiveButton(R.string.delete) { _, _ -> changeActionsWithUndo { store.deleteCustom(action.id) } }
                        .show()
                }
                true
            }
        }.show()
    }

    private fun actionSummary(action: HaloAction): String {
        val scope = store.appScope(action.id)
        fun appName(pkg: String): String = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (_: android.content.pm.PackageManager.NameNotFoundException) { pkg }
        val scopeLabel = when (scope.mode) {
            ActionStore.AppScopeMode.ALL -> getString(R.string.summary_all_apps)
            ActionStore.AppScopeMode.ONLY -> getString(R.string.summary_only_apps, scope.packages.joinToString("、", limit = 2) { appName(it) })
            ActionStore.AppScopeMode.EXCEPT -> getString(R.string.summary_except_apps, scope.packages.joinToString("、", limit = 2) { appName(it) })
        }
        val route = ActionDestinations(this).route(action.id)
        val destination = when {
            !ActionDestinations.supports(action) -> null
            route == null -> getString(R.string.destination_default)
            route == "web" -> getString(R.string.summary_web)
            else -> appName(route.removePrefix("package:"))
        }
        return listOfNotNull(scopeLabel, destination).joinToString(" · ")
    }

    private fun showActionEditor(action: HaloAction? = null, restored: Bundle? = null) {
        val form = HaloUi.column(this, 24)
        val name = EditText(this).apply {
            tag = "action_editor_name"
            hint = getString(R.string.name_hint)
            contentDescription = hint
            setText(restored?.getString("name") ?: action?.title.orEmpty())
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS
            maxLines = 1
        }
        val url = EditText(this).apply {
            tag = "action_editor_url"
            hint = getString(R.string.url_hint)
            contentDescription = getString(R.string.custom_help)
            setText(restored?.getString("url") ?: action?.let(store::templateForEditing).orEmpty())
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            textSize = 14f
            maxLines = 3
        }
        form.addView(name)
        form.addSpace(12)
        form.addView(url)
        form.addSpace(12)
        form.addView(HaloUi.label(this, getString(R.string.custom_help), 13f, HaloUi.secondary))
        form.addSpace(12)
        form.addView(HaloUi.label(this, getString(R.string.action_icon_label), 13f, HaloUi.secondary))
        val iconKeys = ActionIcons.options.keys.toList()
        val iconPicker = Spinner(this).apply {
            contentDescription = getString(R.string.action_icon_label)
            adapter = object : ArrayAdapter<String>(this@MainActivity, android.R.layout.simple_spinner_item,
                resources.getStringArray(R.array.action_icon_names)) {
                init { setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }

                private fun withIcon(view: View, position: Int): View = (view as TextView).apply {
                    val icon = getDrawable(ActionIcons.options.getValue(iconKeys[position]))?.mutate()?.apply {
                        setTint(HaloUi.text)
                        setBounds(0, 0, dp(22), dp(22))
                    }
                    setCompoundDrawablesRelative(icon, null, null, null)
                    compoundDrawablePadding = dp(12)
                }

                override fun getView(position: Int, convertView: View?, parent: ViewGroup): View =
                    withIcon(super.getView(position, convertView, parent), position)

                override fun getDropDownView(position: Int, convertView: View?, parent: ViewGroup): View =
                    withIcon(super.getDropDownView(position, convertView, parent), position)
            }
            setSelection(iconKeys.indexOf(restored?.getString("icon") ?: action?.let(ActionIcons::key) ?: "link").coerceAtLeast(0))
        }
        form.addView(iconPicker, LinearLayout.LayoutParams(-1, dp(48)))
        form.addSpace(12)
        val sample = EditText(this).apply {
            tag = "action_editor_sample"
            filters = arrayOf(android.text.InputFilter.LengthFilter(IncomingText.MAX_LENGTH))
            hint = getString(R.string.action_test_sample)
            contentDescription = hint
            setText(restored?.getString("sample") ?: "ActionHalo")
            setSingleLine()
        }
        form.addView(sample)
        val testResult = HaloUi.label(this, "", 13f, HaloUi.secondary).apply { setTextIsSelectable(true) }
        val openTest = HaloUi.button(this, getString(R.string.action_test_open)).apply { visibility = View.GONE }
        fun testUrl(): String? {
            testResult.text = ""
            openTest.visibility = View.GONE
            sample.error = null
            if (!IncomingText.isUsable(sample.text)) { sample.error = getString(R.string.empty_text); return null }
            val built = ActionUrls.build(url.text.toString(), sample.text.toString())
            if (built == null) url.error = getString(R.string.custom_invalid)
            else { url.error = null; testResult.text = built; openTest.visibility = View.VISIBLE }
            return built
        }
        val resetTest = object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun afterTextChanged(s: android.text.Editable?) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                testResult.text = ""
                openTest.visibility = View.GONE
            }
        }
        url.addTextChangedListener(resetTest)
        sample.addTextChangedListener(resetTest)
        form.addView(HaloUi.button(this, getString(R.string.action_test_preview)).apply { setOnClickListener { testUrl() } })
        form.addView(testResult)
        form.addView(openTest)
        openTest.setOnClickListener {
            val target = testUrl() ?: return@setOnClickListener
            try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(target))) }
            catch (_: ActivityNotFoundException) { toast(R.string.action_no_app) }
            catch (_: SecurityException) { toast(R.string.action_not_allowed) }
        }

        val editorScroll = ScrollView(this).apply { addView(form) }
        val dialog = AlertDialog.Builder(this).setTitle(if (action == null) R.string.custom_title else R.string.edit_action).setView(editorScroll)
            .setNegativeButton(R.string.cancel, null).setPositiveButton(R.string.save, null).create()
        editorDialog = dialog
        editorDraft = { Bundle().apply {
            putString("id", action?.id)
            putString("name", name.text.toString())
            putString("url", url.text.toString())
            putString("icon", iconKeys[iconPicker.selectedItemPosition])
            putString("sample", sample.text.toString())
            putString("copy_source", restored?.getString("copy_source"))
        } }
        dialog.setOnDismissListener { if (editorDialog === dialog) { editorDialog = null; editorDraft = null } }
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val icon = iconKeys[iconPicker.selectedItemPosition]
                    clearUndo.run()
                    if (action == null) {
                        val created = store.addCustom(name.text.toString(), url.text.toString(), icon)
                        restored?.getString("copy_source")?.let { source ->
                            if (store.allActions().any { it.id == source }) {
                                store.setEnabled(created.id, store.isEnabled(source))
                                store.setAppScope(created.id, store.appScope(source))
                                ActionDestinations(this@MainActivity).route(source)?.let { ActionDestinations(this@MainActivity).setRoute(created.id, it) }
                            }
                        }
                    } else store.editAction(action.id, name.text.toString(), url.text.toString(), icon)
                    renderActions()
                    toast(if (action == null) R.string.custom_saved else R.string.custom_updated)
                    dialog.dismiss()
                } catch (_: IllegalArgumentException) {
                    if (name.text.isNullOrBlank()) name.error = getString(R.string.action_title_required)
                    else url.error = getString(R.string.custom_invalid)
                }
            }
        }
        dialog.show()
    }

    private fun card() = HaloUi.column(this, 18).apply { background = HaloUi.shape(this@MainActivity, HaloUi.surface) }
    private fun dp(value: Int) = HaloUi.dp(this, value)
    private fun LinearLayout.addSpace(value: Int) { addView(View(this@MainActivity), LinearLayout.LayoutParams(1, dp(value))) }
    private fun LinearLayout.addSection(id: Int) {
        addView(HaloUi.label(this@MainActivity, getString(id), 11f, HaloUi.accent, true).apply { letterSpacing = 0.12f })
        addSpace(12)
    }
    private fun toast(id: Int) { Toast.makeText(this, id, Toast.LENGTH_SHORT).show() }
}
