package com.actionhalo.android

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.actionhalo.android.AppRulesStore.Profile
import com.actionhalo.android.AppRulesStore.TriggerMode
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream

@RunWith(AndroidJUnit4::class)
class DisabledAppsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val names = setOf("halo_actions", HaloAppearance.SETTINGS_NAME, AppRulesStore.PREFERENCES, "action_destinations")
    private val context = object : ContextWrapper(instrumentation.targetContext) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(if (name in names) "disabled_apps_test_$name" else name, mode)
    }
    private val rulesPreferences get() = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE)
    private val first = "org.example.disabledfirst"
    private val second = "org.example.disabledsecond"
    private val third = "org.example.disabledthird"

    @Before fun setUp() = clear()
    @After fun tearDown() = clear()
    private fun clear() {
        names.forEach { assertTrue(context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()) }
    }

    @Test fun disablingAppsBlocksBothAutomaticEntriesAndPreservesCustomActionOrder() {
        val store = AppRulesStore(context)
        val actions = listOf("google", "copy", "neodb_book")
        store.setProfile(first, Profile(TriggerMode.AUTO, actions))
        store.setDisabledPackages(setOf(first, second))

        assertEquals(setOf(first, second), AppRulesStore(context).disabledPackages())
        assertEquals(Profile(TriggerMode.OFF, actions), store.profile(first))
        assertEquals(Profile(TriggerMode.OFF), store.profile(second))
        listOf(first, second).forEach { packageName ->
            listOf(false, true).forEach { global ->
                assertFalse(store.allowsAutomatic(packageName, global))
                assertFalse(store.allowsButton(packageName, global))
            }
        }
        assertEquals(actions, store.actionsFor(first, ActionStore(context).allActions()).map { it.id })
        assertTrue("A package with a similar name must not inherit the restriction", store.allowsAutomatic("$first.other", true))
        assertTrue(store.allowsAutomatic(third, true))
    }

    @Test fun removingDisabledAppsRestoresGlobalTriggerAndKeepsOtherProfilesUntouched() {
        val store = AppRulesStore(context)
        val custom = listOf("copy", "google")
        store.setProfile(first, Profile(TriggerMode.OFF, custom))
        store.setProfile(second, Profile(TriggerMode.OFF))
        store.setProfile(third, Profile(TriggerMode.AUTO, emptyList()))
        val buttonPackage = "org.example.button"
        store.setProfile(buttonPackage, Profile(TriggerMode.BUTTON, listOf("google", "copy")))

        store.setDisabledPackages(emptySet())

        assertTrue(store.disabledPackages().isEmpty())
        assertEquals(Profile(TriggerMode.DEFAULT, custom), store.profile(first))
        assertEquals(Profile(), store.profile(second))
        assertFalse("An empty default profile should be removed", second in store.packages())
        assertEquals(Profile(TriggerMode.AUTO, emptyList()), store.profile(third))
        assertEquals(Profile(TriggerMode.BUTTON, listOf("google", "copy")), store.profile(buttonPackage))
        assertFalse(store.allowsAutomatic(first, false))
        assertTrue(store.allowsAutomatic(first, true))
    }

    @Test fun changingDisabledListIsOneObservableUpdateAndKeepsUnrelatedPreferences() {
        val store = AppRulesStore(context)
        store.setProfile(first, Profile(TriggerMode.OFF))
        store.setProfile(second, Profile(TriggerMode.BUTTON))
        assertTrue(rulesPreferences.edit().putLong("pause_until_wall", 1234L).commit())
        val observed = mutableListOf<Set<String>>()
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == AppRulesStore.PROFILES) observed += AppRulesStore(context).disabledPackages()
        }
        instrumentation.runOnMainSync {
            rulesPreferences.registerOnSharedPreferenceChangeListener(listener)
            try { store.setDisabledPackages(setOf(second, third)) }
            finally { rulesPreferences.unregisterOnSharedPreferenceChangeListener(listener) }
        }

        assertEquals(listOf(setOf(second, third)), observed)
        assertEquals(Profile(), store.profile(first))
        assertEquals(1234L, rulesPreferences.getLong("pause_until_wall", 0L))
    }

    @Test fun invalidPackagesNeverPartiallyApplyTheDraft() {
        val store = AppRulesStore(context)
        store.setProfile(first, Profile(TriggerMode.OFF, listOf("copy")))
        val original = rulesPreferences.all.toMap()
        listOf("", "single", "bad package", "org..bad", "org.2bad", " org.example.bad", "org.example.bad\n",
            "org." + "a".repeat(252)).forEach { invalid ->
            rejects { store.setDisabledPackages(linkedSetOf(second, invalid)) }
            assertEquals(original, rulesPreferences.all.toMap())
        }
    }

    @Test fun limitCountsAllProfilesAndReplacementCanReuseARemovedDefaultSlot() {
        val store = AppRulesStore(context)
        val initial = (0 until 200).map { "org.example.app$it" }.toSet()
        store.setDisabledPackages(initial)
        assertEquals(initial, store.disabledPackages())
        val saved = rulesPreferences.all.toMap()
        rejects { store.setDisabledPackages(initial + first) }
        assertEquals(saved, rulesPreferences.all.toMap())

        val replacement = initial - "org.example.app0" + first
        store.setDisabledPackages(replacement)
        assertEquals(replacement, store.disabledPackages())
        assertEquals(200, store.packages().size)

        store.setDisabledPackages(emptySet())
        val profiles = JSONObject().apply {
            initial.forEach { put(it, JSONObject().put("trigger", "AUTO")) }
        }
        assertTrue(rulesPreferences.edit().putString(AppRulesStore.PROFILES, profiles.toString()).commit())
        val fullAutoProfiles = rulesPreferences.all.toMap()
        rejects { store.setDisabledPackages(setOf(first)) }
        assertEquals(fullAutoProfiles, rulesPreferences.all.toMap())
        store.setDisabledPackages(setOf("org.example.app0"))
        assertEquals(200, store.packages().size)
        assertEquals(TriggerMode.AUTO, store.triggerMode("org.example.app1"))
    }

    @Test fun customProfileRetainedOnEnableStillCountsTowardTheLimit() {
        val store = AppRulesStore(context)
        val initial = (0 until 200).map { "org.example.app$it" }.toSet()
        store.setDisabledPackages(initial)
        store.setProfile("org.example.app0", Profile(TriggerMode.OFF, listOf("custom:temporarily-deleted", "copy")))
        val original = rulesPreferences.all.toMap()
        rejects { store.setDisabledPackages(initial - "org.example.app0" + first) }
        assertEquals(original, rulesPreferences.all.toMap())

        store.setDisabledPackages(initial - "org.example.app0")
        assertEquals(Profile(TriggerMode.DEFAULT, listOf("custom:temporarily-deleted", "copy")), store.profile("org.example.app0"))
        assertEquals(200, store.packages().size)
    }

    @Test fun existingBackupRoundTripRetainsDisabledAppsAndTheirCustomActions() {
        val actions = ActionStore(context)
        val custom = actions.addCustom("Fixture search", "https://example.com/?q={text}", "search")
        val store = AppRulesStore(context)
        val order = listOf(custom.id, "copy", "google")
        store.setProfile(first, Profile(TriggerMode.AUTO, order))
        store.setProfile(third, Profile(TriggerMode.BUTTON))
        store.setDisabledPackages(setOf(first, second))
        val backup = ConfigurationBackup(context)
        val encoded = backup.export()
        assertEquals("OFF", JSONObject(encoded).getJSONObject("appRules").getJSONObject(first).getString("trigger"))
        assertTrue(rulesPreferences.edit().clear().commit())
        actions.reset()

        backup.restore(backup.read(ByteArrayInputStream(encoded.toByteArray(Charsets.UTF_8))))

        val restored = AppRulesStore(context)
        assertEquals(setOf(first, second), restored.disabledPackages())
        assertEquals(Profile(TriggerMode.OFF, order), restored.profile(first))
        assertEquals(Profile(TriggerMode.BUTTON), restored.profile(third))
        assertEquals(order, restored.actionsFor(first, ActionStore(context).allActions()).map { it.id })
    }

    private fun rejects(block: () -> Unit) {
        try { block(); fail("An invalid disabled-app draft must be rejected") }
        catch (_: IllegalArgumentException) { }
    }
}
