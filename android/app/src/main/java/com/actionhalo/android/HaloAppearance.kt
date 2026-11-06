package com.actionhalo.android

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.os.Build
import android.view.View
import android.view.WindowManager
import java.util.function.Consumer
import kotlin.math.hypot

/** Saved appearance settings shared by every radial menu entry. */
internal object HaloAppearance {
    const val SETTINGS_NAME = "actionhalo_settings"
    const val GTA_MODE_KEY = "gta_mode_enabled"
    const val ACTIONS_PER_PAGE_KEY = "actions_per_page"
    const val DEFAULT_ACTIONS_PER_PAGE = 8
    val ACTION_COUNTS = listOf(6, 8, 12, 16)
    const val GTA_DIM_AMOUNT = 0.58f
    const val STANDARD_DIM_AMOUNT = 0.42f
    const val MENU_SIZE_DP = 400
    const val MENU_SIZE_KEY = "menu_size_dp"
    const val DIM_KEY = "backdrop_dim_percent"
    const val HAPTICS_KEY = "halo_haptics_enabled"
    const val INITIAL_POSITION_KEY = "halo_initial_position"
    const val KEEP_AFTER_COPY_KEY = "keep_menu_after_copy"
    const val COPY_SESSION_MS = 30_000L

    fun keepAfterCopy(context: Context, action: HaloAction): Boolean = action.type == ActionType.COPY &&
        (preferences(context).all[KEEP_AFTER_COPY_KEY] as? Boolean ?: false)
    enum class InitialPosition { AUTO, LEFT, RIGHT }
    val MENU_SIZES = listOf(320, 360, 400, 440, 480)

    fun initialPosition(context: Context): InitialPosition = InitialPosition.entries.firstOrNull {
        it.name == preferences(context).all[INITIAL_POSITION_KEY]
    } ?: InitialPosition.AUTO

    fun setInitialPosition(context: Context, position: InitialPosition) {
        preferences(context).edit().putString(INITIAL_POSITION_KEY, position.name).apply()
    }

    fun menuSizeDp(context: Context): Int =
        (preferences(context).all[MENU_SIZE_KEY] as? Int)?.takeIf { it in MENU_SIZES } ?: MENU_SIZE_DP

    fun setMenuSizeDp(context: Context, size: Int) {
        require(size in MENU_SIZES)
        preferences(context).edit().putInt(MENU_SIZE_KEY, size).apply()
    }

    fun dimAmount(context: Context, standardDefault: Float = STANDARD_DIM_AMOUNT): Float =
        (preferences(context).all[DIM_KEY] as? Int)?.takeIf { it in 0..80 }?.div(100f)
            ?: if (isGtaModeEnabled(context)) GTA_DIM_AMOUNT else standardDefault

    fun setDimPercent(context: Context, percent: Int) {
        require(percent in 0..80)
        preferences(context).edit().putInt(DIM_KEY, percent).apply()
    }

    fun hapticsEnabled(context: Context): Boolean =
        preferences(context).all[HAPTICS_KEY] as? Boolean ?: true

    fun setHapticsEnabled(context: Context, enabled: Boolean) {
        preferences(context).edit().putBoolean(HAPTICS_KEY, enabled).apply()
    }

    fun reset(context: Context) {
        preferences(context).edit().remove(GTA_MODE_KEY).remove(ACTIONS_PER_PAGE_KEY)
            .remove(MENU_SIZE_KEY).remove(DIM_KEY).remove(HAPTICS_KEY).remove(INITIAL_POSITION_KEY).apply()
    }

    fun isAppearanceKey(key: String?): Boolean = key in setOf(
        GTA_MODE_KEY, ACTIONS_PER_PAGE_KEY, MENU_SIZE_KEY, DIM_KEY, HAPTICS_KEY, INITIAL_POSITION_KEY, KEEP_AFTER_COPY_KEY,
    )

    private fun preferences(context: Context) = context.getSharedPreferences(SETTINGS_NAME, Context.MODE_PRIVATE)

    fun isGtaModeEnabled(context: Context): Boolean =
        context.getSharedPreferences(SETTINGS_NAME, Context.MODE_PRIVATE).getBoolean(GTA_MODE_KEY, true)

    fun setGtaModeEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(SETTINGS_NAME, Context.MODE_PRIVATE)
            .edit().putBoolean(GTA_MODE_KEY, enabled).apply()
    }

    fun actionsPerPage(context: Context): Int {
        val saved = context.getSharedPreferences(SETTINGS_NAME, Context.MODE_PRIVATE)
            .all[ACTIONS_PER_PAGE_KEY] as? Int
        return saved?.takeIf { it in ACTION_COUNTS } ?: DEFAULT_ACTIONS_PER_PAGE
    }

    fun setActionsPerPage(context: Context, value: Int) {
        require(value in ACTION_COUNTS) { "Unsupported action count: $value" }
        context.getSharedPreferences(SETTINGS_NAME, Context.MODE_PRIVATE)
            .edit().putInt(ACTIONS_PER_PAGE_KEY, value).apply()
    }

    /** Bind native blur and its fallback to the lifetime of either an Activity or an overlay. */
    fun bindBackdrop(root: View, params: WindowManager.LayoutParams,
        updateWindow: (WindowManager.LayoutParams) -> Unit) {
        val context = root.context
        val gtaMode = isGtaModeEnabled(context)
        val savedDim = params.dimAmount
        fun update(blursEnabled: Boolean) {
            val blurred = gtaMode && Build.VERSION.SDK_INT >= 31 && blursEnabled
            if (Build.VERSION.SDK_INT >= 31) {
                params.flags = if (blurred) params.flags or WindowManager.LayoutParams.FLAG_BLUR_BEHIND
                    else params.flags and WindowManager.LayoutParams.FLAG_BLUR_BEHIND.inv()
                params.blurBehindRadius = if (blurred) HaloUi.dp(context, 28) else 0
            }
            params.dimAmount = savedDim * if (blurred) 0.55f else 1f
            root.background = if (gtaMode) gtaBackdrop(context, blurred) else null
            if (root.isAttachedToWindow) updateWindow(params)
        }
        // shortcut: Android 8–11 keep the shaded fallback; native cross-window blur starts at 12.
        if (!gtaMode || Build.VERSION.SDK_INT < 31) {
            update(false)
            return
        }
        val manager = context.getSystemService(WindowManager::class.java)
        val listener = Consumer<Boolean> { enabled ->
            if (root.isAttachedToWindow) update(enabled)
        }
        update(manager.isCrossWindowBlurEnabled)
        root.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) {
                manager.addCrossWindowBlurEnabledListener(listener)
            }
            override fun onViewDetachedFromWindow(view: View) {
                manager.removeCrossWindowBlurEnabledListener(listener)
            }
        })
        if (root.isAttachedToWindow) manager.addCrossWindowBlurEnabledListener(listener)
    }

    /** Native blur supplies the soft scene; these layers add the weapon wheel's muted haze. */
    fun gtaBackdrop(context: Context, blurred: Boolean = false): LayerDrawable {
        val metrics = context.resources.displayMetrics
        val strength = dimAmount(context) / GTA_DIM_AMOUNT
        val haze = ColorDrawable(Color.argb(((if (blurred) 32 else 18) * strength).toInt(), 146, 158, 152))
        val edgeAlpha = if (blurred) 80 else 140
        val vertical = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(
            Color.argb((edgeAlpha * strength).toInt(), 0, 0, 0), Color.TRANSPARENT,
            Color.argb((edgeAlpha * strength).toInt(), 0, 0, 0)))
        val vignette = GradientDrawable().apply {
            gradientType = GradientDrawable.RADIAL_GRADIENT
            colors = intArrayOf(Color.TRANSPARENT, Color.argb((16 * strength).toInt(), 0, 0, 0),
                Color.argb(((if (blurred) 64 else 112) * strength).toInt(), 0, 0, 0))
            setGradientCenter(0.5f, 0.5f)
            gradientRadius = (hypot(metrics.widthPixels.toDouble(), metrics.heightPixels.toDouble()) / 2.0)
                .toFloat().coerceAtLeast(1f)
        }
        return LayerDrawable(arrayOf(haze, vertical, vignette))
    }
}
