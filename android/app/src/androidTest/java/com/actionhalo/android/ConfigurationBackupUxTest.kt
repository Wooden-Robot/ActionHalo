package com.actionhalo.android

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

class ConfigurationBackupUxTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(target.cacheDir, "configuration-backup-ux-test")
    private val names = setOf("halo_actions", HaloAppearance.SETTINGS_NAME, "app_rules", "action_destinations")
    private val context = object : ContextWrapper(target) {
        override fun getFilesDir(): File = directory
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(if (name in names) "backup_ux_test_$name" else name, mode)
    }
    private fun state() = names.associateWith { context.getSharedPreferences(it, Context.MODE_PRIVATE).all.toMap() }
    @Before fun before() = clear()
    @After fun after() = clear()
    private fun clear() {
        names.forEach { assertTrue(context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()) }
        directory.deleteRecursively()
    }

    @Test fun previewNamesExactActionAndAppChangesWithoutWritingConfiguration() {
        val actions = ActionStore(context)
        val removed = actions.addCustom("Remove me", "https://old.example/?q={text}")
        val rules = AppRulesStore(context)
        rules.setProfile("org.example.old", AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
        val backup = ConfigurationBackup(context)
        val original = JSONObject(backup.export())
        actions.deleteCustom(removed.id)
        actions.addCustom("Add me", "https://new.example/?q={text}")
        actions.editAction("google", "Changed search", "https://newsearch.example/?q={text}", null)
        actions.setEnabled("copy", false)
        actions.moveTo("share", 0)
        rules.setDisabledPackages(setOf("org.example.new"))
        ActionDestinations(context).setRoute("google", "web")
        HaloAppearance.setGtaModeEnabled(context, false)
        val imported = JSONObject(backup.export())
        backup.restore(original)
        val before = state()
        val changes = backup.changes(imported)
        assertEquals(listOf("Add me"), changes.addedActions)
        assertEquals(listOf("Remove me"), changes.removedActions)
        assertTrue(changes.modifiedActions.contains("Changed search"))
        assertTrue(changes.modifiedActions.contains(context.getString(R.string.action_copy)))
        assertEquals(listOf("org.example.new"), changes.newlyDisabledApps)
        assertEquals(listOf("org.example.old"), changes.enabledAgainApps)
        assertEquals(setOf("org.example.new", "org.example.old"), changes.changedAppRules.toSet())
        assertEquals(listOf("Changed search"), changes.changedDestinations)
        assertEquals(1, changes.appearanceCount)
        assertTrue(changes.orderChanged)
        assertTrue(backup.preview(imported).contains("org.example.new"))
        assertTrue(backup.preview(imported).contains("Add me"))
        assertEquals(before, state())
        assertFalse(directory.exists())
        assertTrue(backup.changes(original).isEmpty)
        backup.restore(imported)
        val reverted = backup.changes(original)
        assertTrue(reverted.modifiedActions.contains(context.getString(R.string.action_google)))
        assertFalse(reverted.modifiedActions.contains("Changed search"))
    }

    @Test fun importKeepsOneValidatedLocalConfigurationAcrossNewInstancesAndRestoresIt() {
        val actions = ActionStore(context)
        actions.addCustom("Original", "https://original.example/?q={text}")
        val backup = ConfigurationBackup(context)
        val original = JSONObject(backup.export())
        actions.addCustom("Imported", "https://imported.example/?q={text}")
        val imported = JSONObject(backup.export())
        backup.restore(original)
        val settings = context.getSharedPreferences(HaloAppearance.SETTINGS_NAME, Context.MODE_PRIVATE)
        settings.edit().putBoolean("accessibility_consent", true).putString("private_runtime_fixture", "never-export-this").commit()
        AppRulesStore(context).pauseFor(AppRulesStore.TEN_MINUTES)
        val pause = AppRulesStore(context).pauseRemainingMillis()
        backup.restoreWithUndo(imported)
        assertTrue(ConfigurationBackup(context).hasPrevious())
        assertTrue(ActionStore(context).allActions().any { it.title == "Imported" })
        val saved = ConfigurationBackup(context).previous().toString()
        assertFalse(saved.contains("never-export-this"))
        assertFalse(saved.contains("accessibility_consent"))
        assertFalse(saved.contains("pause_until"))
        ConfigurationBackup(context).restorePrevious()
        assertTrue(ConfigurationBackup(context).changes(original).isEmpty)
        assertTrue(settings.getBoolean("accessibility_consent", false))
        assertEquals("never-export-this", settings.getString("private_runtime_fixture", null))
        assertTrue(AppRulesStore(context).pauseRemainingMillis() in 1..pause)
        assertTrue(ConfigurationBackup(context).hasPrevious())
    }

    @Test fun invalidImportsAndUnwritableRecoveryFilesNeverReplaceCurrentSettings() {
        val actions = ActionStore(context)
        actions.addCustom("Current", "https://current.example/?q={text}")
        val backup = ConfigurationBackup(context)
        val imported = JSONObject(backup.export())
        val before = state()
        rejects { backup.restoreWithUndo(JSONObject(imported.toString()).put("version", 900)) }
        assertEquals(before, state())
        assertFalse(backup.hasPrevious())
        directory.mkdirs()
        val blocked = File(directory, "blocked").apply { writeText("not a directory") }
        val blockedContext = object : ContextWrapper(context) { override fun getFilesDir(): File = blocked }
        rejects { ConfigurationBackup(blockedContext).restoreWithUndo(imported) }
        assertEquals(before, state())
    }

    @Test fun pendingImportSurvivesRecreationAndRejectsCorruptOrOversizedLocalFiles() {
        val backup = ConfigurationBackup(context)
        val imported = JSONObject(backup.export())
        val before = state()
        val token = backup.stageImport(imported)
        assertTrue(ConfigurationBackup(context).changes(ConfigurationBackup(context).pendingImport(token)).isEmpty)
        assertEquals(before, state())
        rejects { backup.pendingImport("../../outside") }
        val pending = File(directory, "configuration-backup/pending-$token.json")
        pending.writeBytes(ByteArray(ConfigurationBackup.MAX_BYTES + 1) { ' '.code.toByte() })
        rejects { ConfigurationBackup(context).pendingImport(token) }
        assertEquals(before, state())
        backup.discardPendingImport(token)
        assertFalse(pending.exists())
        backup.restoreWithUndo(imported)
        val staleToken = backup.stageImport(imported)
        val stale = File(directory, "configuration-backup/pending-$staleToken.json")
        assertTrue(stale.setLastModified(System.currentTimeMillis() - 48L * 60 * 60 * 1000))
        val freshToken = backup.stageImport(imported)
        assertFalse(stale.exists())
        assertTrue(backup.hasPrevious())
        backup.discardPendingImport(freshToken)
        val beforeCorruption = state()
        File(directory, "configuration-backup/before-import.json").writeText("{}")
        rejects { backup.restorePrevious() }
        assertEquals(beforeCorruption, state())
    }

    private fun rejects(operation: () -> Unit) {
        var failure: Exception? = null
        try { operation() } catch (caught: Exception) { failure = caught }
        assertNotNull("The invalid operation must fail before settings change", failure)
    }
}
