package com.actionhalo.android

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

internal object HaloUi {
    val background = Color.rgb(16, 19, 25)
    val surface = Color.rgb(27, 32, 41)
    val text = Color.rgb(247, 241, 234)
    val secondary = Color.rgb(169, 176, 188)
    val accent = Color.rgb(255, 161, 107)

    /** AccessibilityService window contexts can otherwise keep the system language. */
    fun localizedContext(context: Context): Context {
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            val locales = context.getSystemService(android.app.LocaleManager::class.java).applicationLocales
            if (!locales.isEmpty) {
                return context.createConfigurationContext(android.content.res.Configuration(context.resources.configuration).apply {
                    setLocales(locales)
                })
            }
        }
        return context
    }

    fun dp(context: Context, value: Int) = (value * context.resources.displayMetrics.density).toInt()

    fun shape(context: Context, color: Int, radius: Int = 20): GradientDrawable =
        GradientDrawable().apply { setColor(color); cornerRadius = dp(context, radius).toFloat() }

    fun label(context: Context, value: String, size: Float = 16f, color: Int = text, bold: Boolean = false) =
        TextView(context).apply {
            this.text = value
            textSize = size
            setTextColor(color)
            if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setLineSpacing(dp(context, 3).toFloat(), 1f)
        }

    fun button(context: Context, value: String, primary: Boolean = false) = Button(context).apply {
        text = value
        textSize = 15f
        isAllCaps = false
        setTextColor(if (primary) HaloUi.background else accent)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        minHeight = dp(context, 52)
        background = RippleDrawable(
            ColorStateList.valueOf(0x33FFFFFF),
            shape(context, if (primary) accent else surface, 14), null
        )
        setPadding(dp(context, 16), dp(context, 8), dp(context, 16), dp(context, 8))
    }

    fun column(context: Context, padding: Int = 0) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        val p = dp(context, padding)
        setPadding(p, p, p, p)
    }

    fun applyInsets(activity: Activity, root: View) {
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            activity.window.setDecorFitsSystemWindows(false)
            root.setOnApplyWindowInsetsListener { view, insets ->
                val bounds = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                view.setPadding(bounds.left, bounds.top, bounds.right, bounds.bottom)
                insets
            }
        } else {
            root.fitsSystemWindows = true
        }
        root.requestApplyInsets()
    }
}
