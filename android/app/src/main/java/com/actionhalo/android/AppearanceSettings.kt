package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.LayerDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView

/** A real, inert wheel keeps settings preview behavior in sync with the action surface. */
internal class AppearanceSettings(private val activity: Activity,
    private val onChanged: () -> Unit = {},
    private val onReset: ((undo: () -> Unit) -> Unit)? = null) {
    private lateinit var gta: Switch
    private lateinit var count: Button
    private lateinit var size: Button
    private lateinit var position: Button
    private lateinit var dim: SeekBar
    private lateinit var dimLabel: TextView
    private lateinit var haptics: Switch
    private lateinit var previewGroup: LinearLayout
    private lateinit var previewBody: TextView
    private lateinit var preview: FrameLayout
    private lateinit var backdrop: View
    private lateinit var status: TextView
    private lateinit var restart: Button
    private var menu: RadialMenuView? = null
    private var refreshing = false

    fun addControls(parent: LinearLayout) {
        parent.addView(HaloUi.label(activity, text(R.string.appearance_title), 11f, HaloUi.accent, true).apply {
            letterSpacing = 0.12f
        })
        parent.space(12)
        val card = HaloUi.column(activity, 18).apply { background = HaloUi.shape(activity, HaloUi.surface) }
        previewGroup = HaloUi.column(activity)
        previewGroup.addView(HaloUi.label(activity, text(R.string.halo_preview_title), 18f, bold = true))
        previewGroup.space(8)
        previewBody = HaloUi.label(activity, text(R.string.halo_preview_body), 13f, HaloUi.secondary)
        previewGroup.addView(previewBody)
        preview = FrameLayout(activity).apply {
            background = HaloUi.shape(activity, Color.rgb(89, 108, 119), 14)
            clipToOutline = true
            addView(HaloUi.label(activity, text(R.string.halo_preview_scene), 21f, Color.rgb(235, 226, 200)).apply {
                gravity = Gravity.CENTER
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, FrameLayout.LayoutParams(-1, -1))
            backdrop = View(activity)
            addView(backdrop, FrameLayout.LayoutParams(-1, -1))
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> scalePreview() }
        }
        previewGroup.space(12)
        previewGroup.addView(preview, LinearLayout.LayoutParams(-1, dp(290)))
        status = HaloUi.label(activity, text(R.string.halo_preview_ready), 13f, HaloUi.secondary).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        previewGroup.addView(status, LinearLayout.LayoutParams(-1, -2))
        restart = HaloUi.button(activity, text(R.string.halo_preview_restart)).apply {
            visibility = View.GONE
            setOnClickListener { refreshPreview() }
        }
        previewGroup.addView(restart, LinearLayout.LayoutParams(-1, -2))
        card.addView(previewGroup, LinearLayout.LayoutParams(-1, -2))
        card.space(16)
        gta = toggle(R.string.gta_mode_title) {
            onChanged()
            HaloAppearance.setGtaModeEnabled(activity, it)
            refresh()
        }
        card.addView(gta, LinearLayout.LayoutParams(-1, -2))
        card.addView(HaloUi.label(activity, text(R.string.gta_mode_body), 14f, HaloUi.secondary))
        count = HaloUi.button(activity, "").apply {
            setOnClickListener {
                val counts = HaloAppearance.ACTION_COUNTS
                AlertDialog.Builder(activity).setTitle(R.string.page_size_title)
                    .setSingleChoiceItems(counts.map { text(R.string.page_size_option, it) }.toTypedArray(),
                        counts.indexOf(HaloAppearance.actionsPerPage(activity))) { dialog, index ->
                        onChanged()
                        HaloAppearance.setActionsPerPage(activity, counts[index]); refresh(); dialog.dismiss()
                    }.setNegativeButton(R.string.cancel, null).show()
            }
        }
        card.addView(count, LinearLayout.LayoutParams(-1, -2))
        size = HaloUi.button(activity, "").apply {
            setOnClickListener {
                AlertDialog.Builder(activity).setTitle(R.string.halo_size_title)
                    .setSingleChoiceItems(activity.resources.getStringArray(R.array.halo_size_names),
                        HaloAppearance.MENU_SIZES.indexOf(HaloAppearance.menuSizeDp(activity))) { dialog, index ->
                        onChanged()
                        HaloAppearance.setMenuSizeDp(activity, HaloAppearance.MENU_SIZES[index]); refresh(); dialog.dismiss()
                    }.setNegativeButton(R.string.cancel, null).show()
            }
        }
        card.addView(size, LinearLayout.LayoutParams(-1, -2))
        position = HaloUi.button(activity, "").apply {
            setOnClickListener {
                AlertDialog.Builder(activity).setTitle(R.string.halo_position_title)
                    .setSingleChoiceItems(activity.resources.getStringArray(R.array.halo_position_names),
                        HaloAppearance.initialPosition(activity).ordinal) { dialog, index ->
                        onChanged()
                        HaloAppearance.setInitialPosition(activity, HaloAppearance.InitialPosition.entries[index])
                        refresh(); dialog.dismiss()
                    }.setNegativeButton(R.string.cancel, null).show()
            }
        }
        card.addView(position, LinearLayout.LayoutParams(-1, -2))
        card.addView(HaloUi.label(activity, text(R.string.halo_position_body), 13f, HaloUi.secondary))
        card.space(16)
        dimLabel = HaloUi.label(activity, "")
        card.addView(dimLabel)
        dim = SeekBar(activity).apply {
            max = 80
            contentDescription = text(R.string.halo_dim_title)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {
                    dimLabel.text = text(R.string.halo_dim_current, value)
                    if (fromUser && !refreshing) {
                        onChanged()
                        HaloAppearance.setDimPercent(activity, value)
                        refreshBackdrop()
                    }
                }
                override fun onStartTrackingTouch(bar: SeekBar) = Unit
                override fun onStopTrackingTouch(bar: SeekBar) = Unit
            })
        }
        card.addView(dim, LinearLayout.LayoutParams(-1, dp(48)))
        haptics = toggle(R.string.halo_haptics) { onChanged(); HaloAppearance.setHapticsEnabled(activity, it) }
        card.addView(haptics, LinearLayout.LayoutParams(-1, -2))
        card.space(12)
        card.addView(HaloUi.button(activity, text(R.string.halo_reset)).apply {
            setOnClickListener { reset() }
        }, LinearLayout.LayoutParams(-1, -2))
        parent.addView(card)
        parent.space(28)
        refresh()
    }

    /** Pin the same preview above a scrolling settings form, retaining all live callbacks. */
    fun takePinnedPreview(): View {
        (previewGroup.parent as? ViewGroup)?.removeView(previewGroup)
        previewGroup.setPadding(dp(24), dp(8), dp(24), dp(8))
        previewGroup.setBackgroundColor(HaloUi.surface)
        previewBody.visibility = View.GONE
        preview.layoutParams = LinearLayout.LayoutParams(-1,
            dp(minOf(200, (activity.resources.configuration.screenHeightDp / 3).coerceAtLeast(120))))
        (restart.parent as? ViewGroup)?.removeView(restart)
        preview.addView(restart, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        return previewGroup
    }

    fun refresh() {
        if (!::preview.isInitialized) return
        refreshing = true
        gta.isChecked = HaloAppearance.isGtaModeEnabled(activity)
        haptics.isChecked = HaloAppearance.hapticsEnabled(activity)
        count.text = text(R.string.page_size_current, HaloAppearance.actionsPerPage(activity))
        size.text = text(R.string.halo_size_current, activity.resources.getStringArray(R.array.halo_size_names)[
            HaloAppearance.MENU_SIZES.indexOf(HaloAppearance.menuSizeDp(activity))])
        position.text = text(R.string.halo_position_current, activity.resources.getStringArray(R.array.halo_position_names)[
            HaloAppearance.initialPosition(activity).ordinal])
        dim.progress = (HaloAppearance.dimAmount(activity) * 100).toInt()
        dimLabel.text = text(R.string.halo_dim_current, dim.progress)
        refreshing = false
        refreshPreview()
    }

    private fun refreshPreview() {
        menu?.let(preview::removeView)
        menu = RadialMenuView(activity).apply {
            gtaModeEnabled = HaloAppearance.isGtaModeEnabled(activity)
            selectedText = "https://example.com"
            setActions(ActionStore(activity).actions())
            onActionSelected = {
                status.text = text(R.string.halo_preview_selected, it.title)
                beginInteractionSession()
            }
            onDismiss = {
                visibility = View.INVISIBLE
                status.text = text(R.string.halo_preview_dismissed)
                restart.visibility = View.VISIBLE
            }
        }
        val size = dp(HaloAppearance.menuSizeDp(activity))
        preview.addView(menu, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
        status.text = text(R.string.halo_preview_ready)
        restart.visibility = View.GONE
        refreshBackdrop()
        scalePreview()
    }

    private fun scalePreview() {
        val wheel = menu ?: return
        if (preview.width <= 0 || preview.height <= 0) return
        val scale = minOf(preview.width, preview.height).toFloat() / dp(HaloAppearance.MENU_SIZES.last())
        wheel.scaleX = scale
        wheel.scaleY = scale
        val room = (preview.width - wheel.layoutParams.width * scale) / 2f
        wheel.translationX = when (HaloAppearance.initialPosition(activity)) {
            HaloAppearance.InitialPosition.AUTO -> 0f
            HaloAppearance.InitialPosition.LEFT -> -room
            HaloAppearance.InitialPosition.RIGHT -> room
        }
    }

    private fun refreshBackdrop() {
        val shade = ColorDrawable(Color.argb((255 * HaloAppearance.dimAmount(activity)).toInt(), 0, 0, 0))
        backdrop.background = if (HaloAppearance.isGtaModeEnabled(activity))
            LayerDrawable(arrayOf(shade, HaloAppearance.gtaBackdrop(activity))) else shade
    }

    private fun reset() {
        onChanged()
        val prefs = activity.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        val saved = prefs.all.filterKeys(HaloAppearance::isAppearanceKey)
        HaloAppearance.reset(activity)
        refresh()
        onReset?.invoke {
            val edit = prefs.edit()
            prefs.all.keys.filter(HaloAppearance::isAppearanceKey).forEach(edit::remove)
            saved.forEach { (key, value) -> when (value) {
                is Boolean -> edit.putBoolean(key, value)
                is Int -> edit.putInt(key, value)
                is String -> edit.putString(key, value)
            } }
            edit.apply()
            refresh()
        }
    }

    private fun toggle(label: Int, changed: (Boolean) -> Unit) = Switch(activity).apply {
        text = text(label)
        textSize = 16f
        setTextColor(HaloUi.text)
        minHeight = dp(48)
        setOnCheckedChangeListener { _, enabled -> if (!refreshing) changed(enabled) }
    }
    private fun text(id: Int, vararg args: Any) = activity.getString(id, *args)
    private fun dp(value: Int) = HaloUi.dp(activity, value)
    private fun LinearLayout.space(value: Int) { addView(View(activity), LinearLayout.LayoutParams(1, dp(value))) }
}
