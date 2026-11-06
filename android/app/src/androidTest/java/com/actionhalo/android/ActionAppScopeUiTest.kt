package com.actionhalo.android

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.RadioButton
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.actionhalo.android.ActionStore.AppScope
import com.actionhalo.android.ActionStore.AppScopeMode
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ActionAppScopeUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val preferenceNames = listOf("halo_actions", HaloAppearance.SETTINGS_NAME, AppRulesStore.PREFERENCES)
    private var previous: Map<String, Map<String, *>> = emptyMap()
    private val firstPackage = "org.example.scopefirst"
    private val secondPackage = "org.example.scopesecond"

    @Before fun isolateSettings() {
        previous = preferenceNames.associateWith { preferences(it).all.toMap() }
        preferenceNames.forEach { assertTrue(preferences(it).edit().clear().commit()) }
    }

    @After fun restoreSettings() {
        previous.forEach { (name, values) ->
            val editor = preferences(name).edit().clear()
            values.forEach { (key, value) -> editor.restore(key, value) }
            assertTrue(editor.commit())
        }
    }

    @Test fun cancellingChangesKeepsTheSavedModeAndPackages() {
        val store = ActionStore(context)
        val original = AppScope(AppScopeMode.EXCEPT, listOf(firstPackage, secondPackage))
        store.setAppScope("google", original)
        var saved = 0
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            val dialog = openDialog(scenario, store) { saved++ }
            scenario.onActivity {
                mode(dialog, AppScopeMode.ONLY).performClick()
                checkbox(dialog, firstPackage).isChecked = false
                assertEquals(original, store.appScope("google"))
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity { assertFalse(dialog.isShowing) }
            assertEquals(original, store.appScope("google"))
            assertEquals(0, saved)
        }
    }

    @Test fun onlyModeWithNoSelectedAppsCannotSaveOrCloseTheDialog() {
        val store = ActionStore(context)
        var saved = 0
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            val dialog = openDialog(scenario, store) { saved++ }
            scenario.onActivity {
                try {
                    mode(dialog, AppScopeMode.ONLY).performClick()
                    assertTrue(descendants(dialog.window!!.decorView).filterIsInstance<CheckBox>().none { it.isChecked })
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                    assertTrue("The user must be able to correct an empty Only selection", dialog.isShowing)
                    assertTrue(descendants(dialog.window!!.decorView).filterIsInstance<TextView>().any {
                        it.text.toString() == context.getString(R.string.action_scope_select_app)
                    })
                    assertEquals(AppScope(), store.appScope("google"))
                    assertEquals(0, saved)
                } finally { dialog.dismiss() }
            }
        }
    }

    @Test fun savingPersistsTheSelectedAppsAndAllModeClearsTheRestriction() {
        val store = ActionStore(context)
        store.setAppScope("google", AppScope(AppScopeMode.EXCEPT, listOf(firstPackage, secondPackage)))
        var saved = 0
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            val dialog = openDialog(scenario, store) { saved++ }
            scenario.onActivity {
                mode(dialog, AppScopeMode.ONLY).performClick()
                checkbox(dialog, secondPackage).isChecked = false
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertEquals(AppScope(AppScopeMode.ONLY, listOf(firstPackage)), store.appScope("google"))
                assertEquals(1, saved)
                assertFalse(dialog.isShowing)
            }
            scenario.recreate()
            val restored = openDialog(scenario, store) { saved++ }
            scenario.onActivity {
                assertTrue(mode(restored, AppScopeMode.ONLY).isChecked)
                assertTrue(checkbox(restored, firstPackage).isChecked)
                mode(restored, AppScopeMode.ALL).performClick()
                restored.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertEquals(AppScope(), store.appScope("google"))
                assertTrue(store.isAllowedInApp("google", null))
                assertTrue(store.isAllowedInApp("google", secondPackage))
                assertEquals(2, saved)
                assertFalse(restored.isShowing)
            }
        }
    }

    @Test fun searchingPreservesHiddenSelectionsAndDraftChangesUntilSave() {
        val store = ActionStore(context)
        val original = AppScope(AppScopeMode.ONLY, listOf(firstPackage, secondPackage))
        store.setAppScope("google", original)
        var saved = 0
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            val dialog = openDialog(scenario, store) { saved++ }
            scenario.onActivity {
                val search = descendants(dialog.window!!.decorView).filterIsInstance<EditText>()
                    .single { it.tag == "app_scope_search" }
                search.setText(firstPackage)
                assertEquals(listOf(firstPackage), listedPackages(dialog))
                assertTrue(checkbox(dialog, firstPackage).isChecked)
                checkbox(dialog, firstPackage).isChecked = false
                search.setText("no.such.scope.package")
                assertTrue(listedPackages(dialog).isEmpty())
                assertEquals(original, store.appScope("google"))
                assertEquals(0, saved)
                search.setText(secondPackage)
                assertTrue("Filtering another app must retain its previous selection", checkbox(dialog, secondPackage).isChecked)
                search.setText("")
                assertFalse(checkbox(dialog, firstPackage).isChecked)
                assertTrue(checkbox(dialog, secondPackage).isChecked)
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertEquals(AppScope(AppScopeMode.ONLY, listOf(secondPackage)), store.appScope("google"))
                assertEquals(1, saved)
            }
        }
    }

    @Test fun sharedTextWithUnknownSourceHidesOnlyActionsAndIgnoresClaimedSourceExtras() {
        val store = ActionStore(context)
        store.setAllEnabled(false)
        listOf("copy", "google", "share").forEach { store.setEnabled(it, true) }
        store.setAppScope("google", AppScope(AppScopeMode.ONLY, listOf(firstPackage)))
        store.setAppScope("share", AppScope(AppScopeMode.EXCEPT, listOf(firstPackage)))
        val incoming = Intent(context, HaloActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, "Unknown-source scope fixture")
            putExtra(Intent.EXTRA_REFERRER, Uri.parse("android-app://$firstPackage"))
            putExtra(EditTextActivity.EXTRA_SOURCE_PACKAGE, firstPackage)
        }
        ActivityScenario.launch<HaloActivity>(incoming).use { scenario -> scenario.onActivity { activity ->
            assertNull(activity.callingActivity)
            val menu = descendants(activity.window.decorView).filterIsInstance<RadialMenuView>().single()
            val catalog = store.allActions().associateBy { it.id }
            val actionTitles = catalog.values.map { it.title }.toSet()
            val displayed = descendants(menu).filterIsInstance<Button>().mapNotNull {
                it.contentDescription?.toString()?.takeIf(actionTitles::contains)
            }
            assertEquals(listOf("copy", "share").map { catalog.getValue(it).title }, displayed)
            assertEquals("Unknown-source scope fixture", menu.selectedText)
        } }
    }

    private fun openDialog(scenario: ActivityScenario<MainActivity>, store: ActionStore, onSaved: () -> Unit): AlertDialog {
        lateinit var dialog: AlertDialog
        scenario.onActivity { activity ->
            dialog = ActionAppScopeSettings(activity).show(store.allActions().single { it.id == "google" }, onSaved)
        }
        instrumentation.waitForIdleSync()
        return dialog
    }
    private fun mode(dialog: AlertDialog, mode: AppScopeMode) =
        descendants(dialog.window!!.decorView).filterIsInstance<RadioButton>().single { it.tag == mode.name }
    private fun checkbox(dialog: AlertDialog, packageName: String) =
        descendants(dialog.window!!.decorView).filterIsInstance<CheckBox>().single { it.tag == packageName }
    private fun listedPackages(dialog: AlertDialog) =
        descendants(dialog.window!!.decorView).filterIsInstance<CheckBox>().map { it.tag as String }
    private fun preferences(name: String) = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) addAll(descendants(view.getChildAt(index)))
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
