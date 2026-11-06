package com.actionhalo.android

import android.app.AlertDialog
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.actionhalo.android.AppRulesStore.Profile
import com.actionhalo.android.AppRulesStore.TriggerMode
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DisabledAppsUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext
    private val preferenceNames = listOf("halo_actions", HaloAppearance.SETTINGS_NAME, AppRulesStore.PREFERENCES)
    private var previous: Map<String, Map<String, *>> = emptyMap()
    private val first = "org.example.disabledfirst"
    private val second = "org.example.disabledsecond"

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

    @Test fun existingOffRulesAppearCheckedEvenForAppsNoLongerInstalled() {
        val store = AppRulesStore(context)
        store.setProfile(first, Profile(TriggerMode.OFF, listOf("google", "copy")))
        store.setProfile(second, Profile(TriggerMode.BUTTON))
        withActivity { scenario ->
            val dialog = openDialog(scenario)
            scenario.onActivity {
                try {
                    assertTrue(checkbox(dialog, first).isChecked)
                    assertFalse(checkbox(dialog, second).isChecked)
                } finally { dialog.dismiss() }
            }
        }
    }

    @Test fun cancellingTheDraftDoesNotChangeExistingTriggerRules() {
        val store = AppRulesStore(context)
        val original = Profile(TriggerMode.OFF, listOf("google", "copy"))
        store.setProfile(first, original)
        store.setProfile(second, Profile(TriggerMode.AUTO))
        withActivity { scenario ->
            val dialog = openDialog(scenario)
            scenario.onActivity {
                checkbox(dialog, first).isChecked = false
                checkbox(dialog, second).isChecked = true
                assertEquals(setOf(first), store.disabledPackages())
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertFalse(dialog.isShowing)
                assertEquals(original, store.profile(first))
                assertEquals(Profile(TriggerMode.AUTO), store.profile(second))
            }
        }
    }

    @Test fun searchingKeepsHiddenSelectionsAndSavesTheWholeDraft() {
        val store = AppRulesStore(context)
        store.setProfile(first, Profile(TriggerMode.OFF))
        store.setProfile(second, Profile(TriggerMode.BUTTON))
        withActivity { scenario ->
            val dialog = openDialog(scenario)
            scenario.onActivity {
                val search = search(dialog)
                search.setText(second)
                assertEquals(listOf(second), listedPackages(dialog))
                checkbox(dialog, second).isChecked = true
                search.setText("no.such.disabled.fixture")
                assertTrue(listedPackages(dialog).isEmpty())
                assertEquals(setOf(first), store.disabledPackages())
                search.setText(first)
                assertTrue(checkbox(dialog, first).isChecked)
                search.setText(second)
                assertTrue(checkbox(dialog, second).isChecked)
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertFalse(dialog.isShowing)
                assertEquals(setOf(first, second), store.disabledPackages())
            }
            scenario.recreate()
            val restored = openDialog(scenario)
            scenario.onActivity {
                try {
                    assertTrue(checkbox(restored, first).isChecked)
                    assertTrue(checkbox(restored, second).isChecked)
                } finally { restored.dismiss() }
            }
        }
    }

    @Test fun uncheckingRestoresTheGlobalTriggerWithoutLosingCustomActionOrder() {
        val store = AppRulesStore(context)
        val actions = listOf("google", "copy")
        store.setProfile(first, Profile(TriggerMode.OFF, actions))
        store.setProfile(second, Profile(TriggerMode.BUTTON, listOf("copy")))
        withActivity { scenario ->
            val dialog = openDialog(scenario)
            scenario.onActivity {
                checkbox(dialog, first).isChecked = false
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
                assertFalse(dialog.isShowing)
                assertTrue(store.disabledPackages().isEmpty())
                assertEquals(Profile(TriggerMode.DEFAULT, actions), store.profile(first))
                assertEquals(Profile(TriggerMode.BUTTON, listOf("copy")), store.profile(second))
                assertFalse(store.allowsAutomatic(first, false))
                assertTrue(store.allowsAutomatic(first, true))
            }
        }
    }

    @Test fun appRulesHubAndItsDisabledAppsEntryAreAvailableOnHomeAndTriggerSettings() {
        listOf(MainActivity.Page.HOME, MainActivity.Page.TRIGGERS).forEach { page ->
            ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, page)).use { scenario ->
                scenario.onActivity { activity ->
                    val entry = descendants(activity.window.decorView).filterIsInstance<Button>()
                        .single { it.text.toString().startsWith(context.getString(R.string.app_rules_hub_title)) }
                    assertTrue(entry.isEnabled)
                    assertTrue(entry.hasOnClickListeners())
                    entry.performClick()
                    val hub = AppSettingsDrafts.dialogs(activity).last()
                    val disabled = descendants(hub.window!!.decorView).filterIsInstance<Button>()
                        .single { it.text.toString() == context.getString(R.string.disabled_apps_title) }
                    assertTrue(disabled.hasOnClickListeners())
                    hub.dismiss()
                }
            }
        }
    }

    private fun withActivity(block: (ActivityScenario<MainActivity>) -> Unit) {
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.HOME)).use(block)
    }
    private fun openDialog(scenario: ActivityScenario<MainActivity>): AlertDialog {
        lateinit var dialog: AlertDialog
        scenario.onActivity { activity -> dialog = DisabledAppsSettings(activity).show() }
        instrumentation.waitForIdleSync()
        return dialog
    }
    private fun checkbox(dialog: AlertDialog, packageName: String) =
        descendants(dialog.window!!.decorView).filterIsInstance<CheckBox>().single { it.tag == packageName }
    private fun listedPackages(dialog: AlertDialog) =
        descendants(dialog.window!!.decorView).filterIsInstance<CheckBox>().map { it.tag as String }
    private fun search(dialog: AlertDialog) =
        descendants(dialog.window!!.decorView).filterIsInstance<EditText>().single { it.tag == "disabled_apps_search" }
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
