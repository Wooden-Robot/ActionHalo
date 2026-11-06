package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

class BackupSettingsActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var undo: Button
    private lateinit var export: Button
    private lateinit var importButton: Button
    private val backup by lazy { ConfigurationBackup(applicationContext) }
    private var work: Work? = null
    private var pendingToken: String? = null
    private var previewingPrevious = false
    private var confirmation: AlertDialog? = null

    private data class Prepared(val token: String, val document: JSONObject)
    private class Work(val code: Int) {
        var result: Result<Prepared?>? = null
        var listener: (() -> Unit)? = null
        var abandoned = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = HaloUi.column(this, 24)
        content.addView(HaloUi.button(this, getString(R.string.page_back)).apply { setOnClickListener { finish() } })
        content.addView(HaloUi.label(this, getString(R.string.backup_title), 28f, bold = true))
        content.addView(HaloUi.label(this, getString(R.string.backup_description), 15f, HaloUi.secondary))
        export = HaloUi.button(this, getString(R.string.backup_export)).apply {
            setOnClickListener { chooseFile(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/json"
                putExtra(Intent.EXTRA_TITLE, "ActionHalo-settings.json")
            }, EXPORT) }
        }
        content.addView(export, LinearLayout.LayoutParams(-1, -2))
        importButton = HaloUi.button(this, getString(R.string.backup_import)).apply {
            setOnClickListener { chooseFile(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream"))
            }, IMPORT) }
        }
        content.addView(importButton, LinearLayout.LayoutParams(-1, -2))
        undo = HaloUi.button(this, getString(R.string.backup_ux_restore_previous)).apply {
            setOnClickListener { runTask(PREVIEW_UNDO) { Prepared("", backup.previous()) } }
        }
        content.addView(undo, LinearLayout.LayoutParams(-1, -2))
        content.addView(HaloUi.label(this, getString(R.string.backup_ux_local_copy), 14f, HaloUi.secondary))
        status = HaloUi.label(this, savedInstanceState?.getString(STATUS).orEmpty(), 15f, HaloUi.secondary).apply {
            accessibilityLiveRegion = android.view.View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        content.addView(status)
        val scroll = ScrollView(this).apply { setBackgroundColor(HaloUi.background); addView(content) }
        setContentView(scroll)
        HaloUi.applyInsets(this, scroll)
        pendingToken = savedInstanceState?.getString(PENDING)
        previewingPrevious = savedInstanceState?.getBoolean(PREVIOUS_PREVIEW) ?: false
        work = lastNonConfigurationInstance as? Work
        val retained = work
        if (retained != null) {
            attach(retained)
            if (retained.result != null) deliver(retained)
        } else if (previewingPrevious) runTask(PREVIEW_UNDO) { Prepared("", backup.previous()) }
        else pendingToken?.let { token -> runTask(PREVIEW_IMPORT) { Prepared(token, backup.pendingImport(token)) } }
        updateControls()
    }

    @Deprecated("Retains only an in-flight file operation, not an Activity or selected text")
    override fun onRetainNonConfigurationInstance(): Any? = work

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        pendingToken?.let { outState.putString(PENDING, it) }
        outState.putBoolean(PREVIOUS_PREVIEW, previewingPrevious)
        outState.putString(STATUS, status.text.toString())
    }

    override fun onDestroy() {
        work?.listener = null
        if (isFinishing) {
            work?.abandoned = true
            pendingToken?.let { runCatching { backup.discardPendingImport(it) } }
        }
        confirmation?.dismiss()
        super.onDestroy()
    }

    private fun updateControls() {
        val idle = work == null
        export.isEnabled = idle
        importButton.isEnabled = idle
        undo.isEnabled = idle && backup.hasPrevious()
    }

    private fun chooseFile(intent: Intent, code: Int) {
        try { startActivityForResult(intent, code) }
        catch (_: ActivityNotFoundException) { status.setText(R.string.backup_picker_unavailable) }
    }

    @Deprecated("Platform result API is retained for Android 8 without an extra dependency")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK || requestCode !in setOf(EXPORT, IMPORT)) return
        val uri = data?.data ?: return
        val resolver = applicationContext.contentResolver
        val engine = backup
        runTask(requestCode) {
            if (requestCode == EXPORT) {
                val encoded = engine.export().toByteArray(Charsets.UTF_8)
                requireNotNull(resolver.openOutputStream(uri, "wt")).use { it.write(encoded) }
                null
            } else {
                val document = requireNotNull(resolver.openInputStream(uri)).use { engine.read(it) }
                Prepared(engine.stageImport(document), document)
            }
        }
    }

    private fun runTask(code: Int, operation: () -> Prepared?) {
        if (work != null) return
        val task = Work(code)
        work = task
        status.setText(R.string.backup_working)
        attach(task)
        updateControls()
        val engine = backup
        Thread({
            val result = runCatching(operation)
            Handler(Looper.getMainLooper()).post {
                task.result = result
                if (task.abandoned) result.getOrNull()?.token?.takeIf { it.isNotEmpty() }?.let {
                    runCatching { engine.discardPendingImport(it) }
                } else task.listener?.invoke()
            }
        }, "ActionHalo-settings-backup").start()
    }

    private fun attach(task: Work) { task.listener = { if (!isDestroyed && !isFinishing) deliver(task) } }

    private fun deliver(task: Work) {
        val result = task.result ?: return
        if (task !== work) return
        task.listener = null
        work = null
        result.fold(onSuccess = { prepared ->
            when {
                prepared != null -> {
                    pendingToken = prepared.token.takeIf { it.isNotEmpty() }
                    status.text = ""
                    confirmImport(prepared.document, task.code == PREVIEW_UNDO)
                }
                task.code == EXPORT -> status.setText(R.string.backup_exported)
                task.code == RESTORE_UNDO -> status.setText(R.string.backup_ux_restored_previous)
                else -> status.setText(R.string.backup_imported)
            }
        }, onFailure = {
            status.setText(when (task.code) {
                EXPORT -> R.string.backup_export_failed
                RESTORE_UNDO, PREVIEW_UNDO -> R.string.backup_ux_restore_failed
                APPLY_IMPORT -> R.string.backup_ux_apply_failed
                else -> R.string.backup_import_failed
            })
        })
        updateControls()
    }

    private fun confirmImport(document: JSONObject, restoringPrevious: Boolean = false) {
        previewingPrevious = restoringPrevious
        val preview = runCatching { backup.preview(document) }.getOrElse {
            status.setText(R.string.backup_import_failed)
            return
        }
        val column = HaloUi.column(this, 20)
        column.addView(HaloUi.label(this, preview, 15f))
        column.addView(HaloUi.label(this, getString(if (restoringPrevious) R.string.backup_ux_restore_hint
            else R.string.backup_ux_preview_hint), 14f, HaloUi.secondary))
        fun discard() {
            pendingToken?.let { runCatching { backup.discardPendingImport(it) } }
            pendingToken = null
            previewingPrevious = false
        }
        confirmation = AlertDialog.Builder(this)
            .setTitle(if (restoringPrevious) R.string.backup_ux_restore_title else R.string.backup_ux_preview_title)
            .setView(ScrollView(this).apply { addView(column) })
            .setNegativeButton(android.R.string.cancel) { _, _ -> discard() }
            .setOnCancelListener { discard() }
            .setPositiveButton(if (restoringPrevious) R.string.backup_ux_restore_previous else R.string.backup_replace) { _, _ ->
                val token = pendingToken
                pendingToken = null
                previewingPrevious = false
                val engine = backup
                runTask(if (restoringPrevious) RESTORE_UNDO else APPLY_IMPORT) {
                    if (restoringPrevious) engine.restorePrevious() else engine.restoreWithUndo(document)
                    token?.let(engine::discardPendingImport)
                    null
                }
            }.show()
    }

    companion object {
        private const val EXPORT = 701
        private const val IMPORT = 702
        private const val PREVIEW_IMPORT = 703
        private const val APPLY_IMPORT = 704
        private const val PREVIEW_UNDO = 705
        private const val RESTORE_UNDO = 706
        private const val PENDING = "pending_import_token"
        private const val STATUS = "backup_status"
        private const val PREVIOUS_PREVIEW = "previous_configuration_preview"
    }
}
