package com.actionhalo.android

import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView

/** Explicit editing stays in this in-memory session and never changes the source app's text. */
class EditTextActivity : HaloActivity() {
    companion object { internal const val EXTRA_SOURCE_PACKAGE = "com.actionhalo.android.SOURCE_PACKAGE" }
    override val sourcePackage: String? get() = intent.getStringExtra(EXTRA_SOURCE_PACKAGE)
    private var editor: EditText? = null
    private var editedText: String? = null
    private var choosing = false
    private data class State(val text: String, val choosing: Boolean)

    override fun receiveText() {
        val restored = lastNonConfigurationInstance as? State
        val text = restored?.text ?: intent.getStringExtra(EXTRA_DEMO_TEXT).orEmpty()
        if (!IncomingText.isUsable(text)) { finish(); return }
        if (restored?.choosing == true) { choose(text); return }
        val root = ScrollView(this).apply { setBackgroundColor(HaloUi.background); isFillViewport = true }
        val column = HaloUi.column(this, 24)
        column.addView(HaloUi.label(this, getString(R.string.action_edit_text), 24f, bold = true))
        column.addView(HaloUi.label(this, getString(R.string.edit_text_hint), 14f, HaloUi.secondary))
        val input = EditText(this).apply {
            id = View.generateViewId()
            isSaveEnabled = false
            setText(text)
            setTextColor(HaloUi.text)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 4
            maxLines = 12
            contentDescription = getString(R.string.action_edit_text)
        }
        editor = input
        column.addView(input, LinearLayout.LayoutParams(-1, -2))
        column.addView(HaloUi.button(this, getString(R.string.edit_text_continue), true).apply {
            setOnClickListener {
                val value = input.text.toString()
                if (!IncomingText.isUsable(value)) {
                    input.error = getString(if (value.length > IncomingText.MAX_LENGTH) R.string.text_too_long else R.string.empty_text)
                } else choose(value)
            }
        })
        column.addView(HaloUi.button(this, getString(R.string.cancel)).apply { setOnClickListener { finish() } })
        root.addView(column)
        setContentView(root)
        HaloUi.applyInsets(this, root)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        if (android.os.Build.VERSION.SDK_INT >= 30) root.setOnApplyWindowInsetsListener { view, insets ->
            val safe = insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout() or android.view.WindowInsets.Type.ime())
            view.setPadding(safe.left, safe.top, safe.right, safe.bottom); insets
        }
    }

    private fun choose(text: String) {
        getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(editor?.windowToken, 0)
        editedText = text
        choosing = true
        editor = null
        showHalo(text)
    }

    override fun onRetainNonConfigurationInstance(): Any = State(editor?.text?.toString() ?: editedText.orEmpty(), choosing)

    override fun onDestroy() {
        editor?.text?.clear()
        editor = null
        editedText = null
        super.onDestroy()
    }
}
