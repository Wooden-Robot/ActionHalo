package com.actionhalo.android

import android.app.AlertDialog
import android.content.Context
import android.content.SharedPreferences
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.EditText
import android.widget.RadioButton
import android.widget.Spinner
import android.widget.Switch
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppRulesExperienceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val names = listOf("halo_actions", HaloAppearance.SETTINGS_NAME, AppRulesStore.PREFERENCES)
    private lateinit var previous: Map<String, Map<String, *>>
    private val first = "com.example.firstdraft"
    private val second = "com.example.seconddraft"

    @Before fun isolate() {
        previous = names.associateWith { prefs(it).all.toMap() }
        names.forEach { assertTrue(prefs(it).edit().clear().commit()) }
    }
    @After fun restore() {
        previous.forEach { (name, values) -> prefs(name).edit().clear().apply {
            values.forEach { (key, value) -> when (value) {
                is String -> putString(key, value)
                is Boolean -> putBoolean(key, value)
                is Long -> putLong(key, value)
                is Int -> putInt(key, value)
                is Float -> putFloat(key, value)
                is Set<*> -> putStringSet(key, value.filterIsInstance<String>().toSet())
            } }
            assertTrue(commit())
        } }
    }

    @Test fun descriptionsUseTheRuntimeActionOrderAndExplainScopeAndGlobalExclusions() {
        val actions = ActionStore(context)
        actions.setAllEnabled(false)
        listOf("copy", "google").forEach { actions.setEnabled(it, true) }
        actions.setAppScope("google", ActionStore.AppScope(ActionStore.AppScopeMode.EXCEPT, listOf(first)))
        val rules = AppRulesStore(context)
        val result = AppRulePresentation(context).describe(first)
        assertEquals(rules.actionsFor(first, actions.allActions()).map { it.id }, result.available.map { it.id })
        assertEquals(R.string.app_rules_hidden_scope, result.hidden.single { it.action.id == "google" }.reason)
        assertEquals(R.string.app_rules_hidden_global, result.hidden.single { it.action.id == "share" }.reason)
        val custom = AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF, listOf("share", "copy", "google"))
        rules.setProfile(first, custom)
        val off = AppRulePresentation(context).describe(first)
        assertEquals(R.string.app_rules_effective_off, off.trigger)
        assertEquals(listOf("share", "copy"), off.available.map { it.id })
        assertEquals(R.string.app_rules_hidden_custom, off.hidden.single { it.action.id == "translate" }.reason)
        rules.pauseFor(AppRulesStore.TEN_MINUTES)
        assertEquals(R.string.app_rules_effective_off, AppRulePresentation(context).describe(first).trigger)
        assertEquals(R.string.app_rules_effective_paused, AppRulePresentation(context).describe(second).trigger)
    }

    @Test fun disabledAppsDraftAndFilterSurviveRecreationWithoutSavingUntilConfirmed() {
        val rules = AppRulesStore(context)
        rules.setProfile(first, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
        rules.setProfile(second, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.HOME)).use { scenario ->
            scenario.onActivity { activity ->
                val dialog = DisabledAppsSettings(activity).show()
                edit(dialog, "disabled_apps_search").setText(second)
                check(dialog, second).isChecked = true
                switch(dialog, "disabled_apps_only_selected").isChecked = true
            }
            assertEquals(setOf(first), rules.disabledPackages())
            scenario.recreate()
            scenario.onActivity { activity ->
                val dialog = AppSettingsDrafts.dialogs(activity).last()
                assertEquals(second, edit(dialog, "disabled_apps_search").text.toString())
                assertTrue(switch(dialog, "disabled_apps_only_selected").isChecked)
                assertTrue(check(dialog, second).isChecked)
                assertEquals(setOf(first), rules.disabledPackages())
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
            }
            assertEquals(setOf(first, second), rules.disabledPackages())
        }
    }

    @Test fun scopeDraftRestoresItsModeAndSelectionAndCancelKeepsOriginalScope() {
        val actions = ActionStore(context)
        val original = ActionStore.AppScope(ActionStore.AppScopeMode.EXCEPT, listOf(first, second))
        actions.setAppScope("google", original)
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.ACTIONS)).use { scenario ->
            scenario.onActivity { activity ->
                val dialog = ActionAppScopeSettings(activity).show(actions.allActions().single { it.id == "google" })
                descendants(dialog.window!!.decorView).filterIsInstance<RadioButton>().single { it.tag == "ONLY" }.performClick()
                check(dialog, second).isChecked = false
                switch(dialog, "app_scope_only_selected").isChecked = true
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val dialog = AppSettingsDrafts.dialogs(activity).last()
                assertTrue(descendants(dialog.window!!.decorView).filterIsInstance<RadioButton>().single { it.tag == "ONLY" }.isChecked)
                assertTrue(check(dialog, first).isChecked)
                assertFalse(descendants(dialog.window!!.decorView).any { it.tag == second })
                assertEquals(original, actions.appScope("google"))
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            assertEquals(original, actions.appScope("google"))
        }
    }

    @Test fun ruleHubSearchAndUnsavedTriggerModeSurviveRecreation() {
        val rules = AppRulesStore(context)
        rules.setProfile(first, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON, listOf("copy")))
        ActivityScenario.launch<MainActivity>(MainActivity.pageIntent(context, MainActivity.Page.HOME)).use { scenario ->
            scenario.onActivity { activity ->
                val hub = AppRulesSettings(activity).showProfiles()
                edit(hub, "app_rules_search").setText(first)
                switch(hub, "app_rules_only_configured").isChecked = true
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val hub = AppSettingsDrafts.dialogs(activity).last()
                assertEquals(first, edit(hub, "app_rules_search").text.toString())
                assertTrue(switch(hub, "app_rules_only_configured").isChecked)
                descendants(hub.window!!.decorView).single { it.tag == first }.performClick()
                val profile = AppSettingsDrafts.dialogs(activity).last()
                descendants(profile.window!!.decorView).filterIsInstance<Spinner>().single().setSelection(AppRulesStore.TriggerMode.OFF.ordinal)
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                val profile = AppSettingsDrafts.dialogs(activity).last()
                assertEquals(AppRulesStore.TriggerMode.OFF.ordinal,
                    descendants(profile.window!!.decorView).filterIsInstance<Spinner>().single().selectedItemPosition)
                assertEquals(AppRulesStore.TriggerMode.BUTTON, rules.triggerMode(first))
                profile.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
            }
            instrumentation.waitForIdleSync()
            assertEquals(AppRulesStore.TriggerMode.OFF, rules.triggerMode(first))
            assertEquals(listOf("copy"), rules.profile(first).actions)
        }
    }

    private fun edit(dialog: AlertDialog, tag: String) = descendants(dialog.window!!.decorView).filterIsInstance<EditText>().single { it.tag == tag }
    private fun check(dialog: AlertDialog, tag: String) = descendants(dialog.window!!.decorView).filterIsInstance<CheckBox>().single { it.tag == tag }
    private fun switch(dialog: AlertDialog, tag: String) = descendants(dialog.window!!.decorView).filterIsInstance<Switch>().single { it.tag == tag }
    private fun prefs(name: String): SharedPreferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun descendants(view: View): List<View> = buildList {
        add(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) addAll(descendants(view.getChildAt(index)))
    }
}
