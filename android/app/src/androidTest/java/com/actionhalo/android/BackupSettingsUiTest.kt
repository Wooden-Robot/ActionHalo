package com.actionhalo.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

class BackupSettingsUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val names = setOf("halo_actions", HaloAppearance.SETTINGS_NAME, "app_rules", "action_destinations")
    private var previous = emptyMap<String, Map<String, *>>()
    private val directory = File(context.filesDir, "configuration-backup")
    private var previousFiles = emptyMap<String, ByteArray>()
    private val input = File(context.cacheDir, "configuration-import-ui-fixture.json")

    @Before fun save() {
        previous = names.associateWith { context.getSharedPreferences(it, Context.MODE_PRIVATE).all.toMap() }
        names.forEach { assertTrue(context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()) }
        previousFiles = directory.listFiles()?.filter { it.isFile }?.associate { it.name to it.readBytes() }.orEmpty()
        directory.deleteRecursively()
    }

    @After fun restore() {
        previous.forEach { (name, values) ->
            val edit = context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear()
            values.forEach { (key, value) -> edit.restore(key, value) }
            assertTrue(edit.commit())
        }
        directory.deleteRecursively()
        if (previousFiles.isNotEmpty()) {
            directory.mkdirs()
            previousFiles.forEach { (name, bytes) -> File(directory, name).writeBytes(bytes) }
        }
        input.delete()
    }

    @Test fun pendingPreviewSurvivesActivityRecreationAndImportCanBeRestoredAfterwards() {
        val actions = ActionStore(context)
        val engine = ConfigurationBackup(context)
        val original = JSONObject(engine.export())
        actions.editAction("google", "Imported search fixture", "https://imported.example/?q={text}")
        input.writeText(engine.export())
        engine.restore(original)
        ActivityScenario.launch(BackupSettingsActivity::class.java).use { scenario ->
            deliverFile(scenario)
            awaitPreview(scenario)
            scenario.onActivity { activity ->
                assertTrue(dialogText(dialog(activity)).contains("Imported search fixture"))
                assertTrue(engine.changes(original).isEmpty)
            }
            scenario.recreate()
            awaitPreview(scenario)
            scenario.onActivity { activity ->
                val restored = dialog(activity)
                assertTrue(dialogText(restored).contains("Imported search fixture"))
                assertTrue(engine.changes(original).isEmpty)
                restored.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            assertTrue(engine.changes(original).isEmpty)
            assertFalse(engine.hasPrevious())
            deliverFile(scenario)
            awaitPreview(scenario)
            scenario.onActivity { dialog(it).getButton(AlertDialog.BUTTON_POSITIVE).performClick() }
            await { ActionStore(context).allActions().any { it.title == "Imported search fixture" } }
            awaitIdle(scenario)
            scenario.recreate()
            scenario.onActivity { activity ->
                val restore = descendants(activity.window.decorView).filterIsInstance<Button>().single {
                    it.text.toString() == context.getString(R.string.backup_ux_restore_previous)
                }
                assertTrue(restore.isEnabled)
                assertTrue(restore.performClick())
            }
            awaitPreview(scenario)
            scenario.onActivity { dialog(it).getButton(AlertDialog.BUTTON_POSITIVE).performClick() }
            await { engine.changes(original).isEmpty }
            awaitIdle(scenario)
            assertTrue(engine.hasPrevious())
        }
    }

    private fun deliverFile(scenario: ActivityScenario<BackupSettingsActivity>) {
        scenario.onActivity { activity ->
            BackupSettingsActivity::class.java.getDeclaredMethod("onActivityResult", Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType, Intent::class.java).apply { isAccessible = true }
                .invoke(activity, 702, Activity.RESULT_OK, Intent().setData(Uri.fromFile(input)))
        }
    }
    private fun dialog(activity: BackupSettingsActivity) = BackupSettingsActivity::class.java
        .getDeclaredField("confirmation").apply { isAccessible = true }.get(activity) as AlertDialog
    private fun awaitPreview(scenario: ActivityScenario<BackupSettingsActivity>) = await {
        var showing = false
        scenario.onActivity { activity ->
            showing = (BackupSettingsActivity::class.java.getDeclaredField("confirmation").apply { isAccessible = true }
                .get(activity) as? AlertDialog)?.isShowing == true
        }
        showing
    }
    private fun awaitIdle(scenario: ActivityScenario<BackupSettingsActivity>) = await {
        var idle = false
        scenario.onActivity { activity ->
            idle = BackupSettingsActivity::class.java.getDeclaredField("work").apply { isAccessible = true }.get(activity) == null
        }
        idle
    }
    private fun await(predicate: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (!predicate() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20)
        assertTrue("Backup operation did not complete", predicate())
        instrumentation.waitForIdleSync()
    }
    private fun dialogText(dialog: AlertDialog) = descendants(dialog.window!!.decorView).filterIsInstance<TextView>()
        .joinToString("\n") { it.text.toString() }
    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) repeat(view.childCount) { addAll(descendants(view.getChildAt(it))) }
    }
    private fun SharedPreferences.Editor.restore(key: String, value: Any?) {
        when (value) {
            is String -> putString(key, value)
            is Boolean -> putBoolean(key, value)
            is Int -> putInt(key, value)
            is Long -> putLong(key, value)
            is Float -> putFloat(key, value)
            is Set<*> -> putStringSet(key, value.filterIsInstance<String>().toSet())
        }
    }
}
