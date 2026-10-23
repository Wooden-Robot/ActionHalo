package com.actionhalo.android

import android.content.Context
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class AppRulesStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val rulesPrefs = context.getSharedPreferences(AppRulesStore.PREFERENCES, Context.MODE_PRIVATE)
    private val actionPrefs = context.getSharedPreferences("halo_actions", Context.MODE_PRIVATE)
    private lateinit var oldRules: Map<String, *>
    private lateinit var oldActions: Map<String, *>
    @Before fun isolate() {
        oldRules = rulesPrefs.all.toMap()
        oldActions = actionPrefs.all.toMap()
        assertTrue(rulesPrefs.edit().clear().commit())
        assertTrue(actionPrefs.edit().clear().commit())
    }
    @After fun restore() {
        listOf(rulesPrefs to oldRules, actionPrefs to oldActions).forEach { (prefs, saved) ->
            val edit = prefs.edit().clear()
            saved.forEach { (key, value) -> when (value) {
                is String -> edit.putString(key, value)
                is Long -> edit.putLong(key, value)
                is Int -> edit.putInt(key, value)
                is Boolean -> edit.putBoolean(key, value)
                is Float -> edit.putFloat(key, value)
            } }
            assertTrue(edit.commit())
        }
    }

    @Test fun customActionsResolveFullCatalogAndKeepTheirOrderWhenGlobalActionsChange() {
        val store = AppRulesStore(context)
        val actions = ActionStore(context)
        actions.setEnabled("google", false)
        store.setProfile("com.example.reader", AppRulesStore.Profile(actions = listOf("google", "copy", "neodb_book")))
        assertEquals(listOf("google", "copy", "neodb_book"), store.actionsFor("com.example.reader", actions.allActions()).map { it.id })
        actions.moveTo("copy", actions.allActions().lastIndex)
        assertEquals(listOf("google", "copy", "neodb_book"), store.actionsFor("com.example.reader", actions.allActions()).map { it.id })
        assertEquals(actions.actions(), store.actionsFor("com.example.other", actions.allActions()))
        store.setProfile("com.example.empty", AppRulesStore.Profile(actions = emptyList()))
        assertTrue(store.actionsFor("com.example.empty", actions.allActions()).isEmpty())
        store.remove("com.example.reader")
        assertEquals(actions.actions(), store.actionsFor("com.example.reader", actions.allActions()))
    }

    @Test fun modesRespectGlobalDefaultsAndPauseOverridesEveryAutomaticEntry() {
        val store = AppRulesStore(context)
        val pkg = "com.example.source"
        assertFalse(store.allowsAutomatic(pkg, false))
        assertTrue(store.allowsAutomatic(pkg, true))
        store.setProfile(pkg, AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO))
        assertTrue(store.allowsAutomatic(pkg, false))
        store.setProfile(pkg, AppRulesStore.Profile(AppRulesStore.TriggerMode.BUTTON))
        assertFalse(store.allowsAutomatic(pkg, true))
        assertTrue(store.allowsButton(pkg, false))
        store.setProfile(pkg, AppRulesStore.Profile(AppRulesStore.TriggerMode.OFF))
        assertFalse(store.allowsAutomatic(pkg, true))
        assertFalse(store.allowsButton(pkg, true))
        store.setProfile(pkg, AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO))
        store.pauseFor(AppRulesStore.TEN_MINUTES)
        assertTrue(AppRulesStore(context).isPaused())
        assertFalse(store.allowsAutomatic(pkg, true))
        assertFalse(store.allowsButton(pkg, true))
        store.resume()
        assertFalse(store.isPaused())
        assertTrue(store.allowsAutomatic(pkg, false))
    }

    @Test fun pauseExpiresAndDoesNotPersistAsAnIndefiniteBlock() {
        val store = AppRulesStore(context)
        store.pauseFor(AppRulesStore.ONE_HOUR)
        assertTrue(store.pauseRemainingMillis() in 3_590_000L..AppRulesStore.ONE_HOUR)
        assertTrue(rulesPrefs.edit().putLong("pause_until_elapsed", SystemClock.elapsedRealtime() - 1L).commit())
        assertFalse(store.isPaused())
        assertEquals(AppRulesStore.TriggerMode.DEFAULT, store.triggerMode("com.example.source"))
        try { store.pauseFor(AppRulesStore.ONE_HOUR + 1); fail("Unbounded pauses must be rejected") } catch (_: IllegalArgumentException) { }
    }

    @Test fun importedRulesRejectUnknownFieldsBadTypesAndInvalidDestinations() {
        val ids = ActionStore(context).allActions().map { it.id }.toSet()
        val accepted = AppRulesStore.normalizeProfiles("""{"com.example.source":{"trigger":"BUTTON","actions":["copy","google"]}}""", ids)
        assertEquals("BUTTON", JSONObject(accepted).getJSONObject("com.example.source").getString("trigger"))
        listOf(
            """{"bad package":{"trigger":"AUTO"}}""",
            """{"com.example.source":{"trigger":3}}""",
            """{"com.example.source":{"trigger":"UNKNOWN"}}""",
            """{"com.example.source":{"actions":["missing"]}}""",
            """{"com.example.source":{"actions":["copy","copy"]}}""",
            """{"com.example.source":{"actions":[3]}}""",
            """{"com.example.source":{"secret":"text"}}""",
        ).forEach { json ->
            try { AppRulesStore.normalizeProfiles(json, ids); fail("Invalid rules must be rejected: $json") }
            catch (_: IllegalArgumentException) { }
        }
        assertTrue(rulesPrefs.edit().putString(AppRulesStore.PROFILES, "broken JSON").commit())
        assertEquals(AppRulesStore.Profile(), AppRulesStore(context).profile("com.example.source"))
    }
}
