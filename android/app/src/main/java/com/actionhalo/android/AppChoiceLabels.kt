package com.actionhalo.android

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.drawable.Drawable
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.TextView

/** Dialog-scoped icons avoid repeated package lookups while filtering the same list. */
internal class AppChoiceLabels(private val context: Context) {
    private val icons = mutableMapOf<String, Drawable>()

    fun bind(view: TextView, packageName: String?, name: String) {
        val displayName = name.takeIf { it.isNotBlank() } ?: packageName.orEmpty()
        view.text = if (packageName == null || displayName == packageName) displayName else {
            SpannableString("$displayName\n$packageName").apply {
                setSpan(ForegroundColorSpan(HaloUi.secondary), displayName.length + 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(RelativeSizeSpan(0.8f), displayName.length + 1, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        view.textSize = 16f
        view.setTextColor(HaloUi.text)
        view.gravity = Gravity.CENTER_VERTICAL
        view.minHeight = HaloUi.dp(context, 64)
        val vertical = HaloUi.dp(context, 8)
        // CheckedTextView's resolved padding already includes its checkmark; do not add it again on reuse.
        val horizontal = HaloUi.dp(context, 16)
        view.setPaddingRelative(horizontal, vertical, horizontal, vertical)
        val icon = packageName?.let { pkg ->
            val cached = icons.getOrPut(pkg) {
                try { context.packageManager.getApplicationIcon(pkg) }
                catch (_: PackageManager.NameNotFoundException) { context.packageManager.defaultActivityIcon }
            }
            (cached.constantState?.newDrawable(context.resources) ?: cached).mutate().apply {
                val size = HaloUi.dp(context, 36)
                setBounds(0, 0, size, size)
            }
        }
        view.compoundDrawablePadding = HaloUi.dp(context, 12)
        view.setCompoundDrawablesRelative(icon, null, null, null)
    }

    fun adapter(items: List<Pair<String?, String>>, layout: Int): ArrayAdapter<String> =
        object : ArrayAdapter<String>(context, layout, items.map { it.second }) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View =
                super.getView(position, convertView, parent).also { view ->
                    // Older system list layouts use a fixed height that clips two-line app labels.
                    view.layoutParams?.let { params ->
                        params.height = ViewGroup.LayoutParams.WRAP_CONTENT
                        view.layoutParams = params
                    }
                    val (pkg, name) = items[position]
                    bind(view as TextView, pkg, name)
                }
        }
}
