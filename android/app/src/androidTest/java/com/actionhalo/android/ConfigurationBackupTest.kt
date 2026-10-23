package com.actionhalo.android

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream

@RunWith(AndroidJUnit4::class)
class ConfigurationBackupTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val names = setOf("halo_actions", HaloAppearance.SETTINGS_NAME, "app_rules", "action_destinations")
    private val context = object : ContextWrapper(target) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(if (name in names) "backup_test_$name" else name, mode)
    }
    private fun preferences(name: String) = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun savedState() = names.associateWith { preferences(it).all.toMap() }

    @Before fun setUp() { clear() }
    @After fun tearDown() { clear() }
    private fun clear() { names.forEach { assertTrue(preferences(it).edit().clear().commit()) } }

    @Test fun roundTripRestoresActionsAppearanceAppRulesAndDestinationsButKeepsLocalPermissionState() {
        val store = ActionStore(context)
        val custom = store.addCustom("My books", "https://books.example/?q={text}", "book")
        store.moveTo(custom.id, 0)
        store.setEnabled("google", false)
        store.editAction("douban_movie", "Films", "https://films.example/?q={text}", "film")
        val expectedActions = store.allActions()
        val expectedEnabled = store.actions()
        preferences(HaloAppearance.SETTINGS_NAME).edit()
            .putInt(HaloAppearance.ACTIONS_PER_PAGE_KEY, 12)
            .putInt(HaloAppearance.MENU_SIZE_KEY, 360)
            .putInt(HaloAppearance.DIM_KEY, 36)
            .putBoolean(HaloAppearance.GTA_MODE_KEY, false)
            .putBoolean(HaloAppearance.HAPTICS_KEY, false)
            .putString("halo_initial_position", "LEFT")
            .putBoolean("accessibility_consent", true)
            .putBoolean("auto_popup_enabled", true)
            .putString("diagnostic_fixture", "private-runtime-data").commit()
        val profile = JSONObject().put("org.example.reader", JSONObject().put("trigger", "BUTTON")
            .put("actions", JSONArray().put(custom.id).put("copy")))
        preferences("app_rules").edit().putString("profiles", profile.toString())
            .putLong("pause_until_wall", 1234L).commit()
        val routes = JSONObject().put(custom.id, "package:org.example.browser").put("douban", "web")
        preferences("action_destinations").edit().putString("routes", routes.toString()).commit()

        val backup = ConfigurationBackup(context)
        val encoded = backup.export()
        listOf("accessibility_consent", "auto_popup_enabled", "diagnostic_fixture", "private-runtime-data", "pause_until_wall")
            .forEach { assertFalse(encoded.contains(it)) }
        store.reset()
        preferences(HaloAppearance.SETTINGS_NAME).edit().clear().putBoolean("accessibility_consent", false)
            .putBoolean("auto_popup_enabled", false).commit()
        preferences("app_rules").edit().clear().putLong("pause_until_wall", 9999L).commit()
        preferences("action_destinations").edit().clear().commit()
        backup.restore(backup.read(ByteArrayInputStream(encoded.toByteArray(Charsets.UTF_8))))

        assertEquals(expectedActions, ActionStore(context).allActions())
        assertEquals(expectedEnabled, ActionStore(context).actions())
        assertEquals(12, HaloAppearance.actionsPerPage(context))
        assertEquals(360, HaloAppearance.menuSizeDp(context))
        assertEquals(0.36f, HaloAppearance.dimAmount(context), 0.001f)
        assertFalse(HaloAppearance.isGtaModeEnabled(context))
        assertFalse(HaloAppearance.hapticsEnabled(context))
        assertEquals("LEFT", preferences(HaloAppearance.SETTINGS_NAME).getString("halo_initial_position", null))
        assertFalse(preferences(HaloAppearance.SETTINGS_NAME).getBoolean("accessibility_consent", true))
        assertFalse(preferences(HaloAppearance.SETTINGS_NAME).getBoolean("auto_popup_enabled", true))
        assertEquals(9999L, preferences("app_rules").getLong("pause_until_wall", 0))
        assertEquals(profile.toString(), preferences("app_rules").getString("profiles", null))
        assertEquals(routes.toString(), preferences("action_destinations").getString("routes", null))
    }

    @Test fun malformedSectionsNeverChangeAnyPreferences() {
        val store = ActionStore(context)
        store.addCustom("Saved", "https://saved.example/?q={text}")
        preferences(HaloAppearance.SETTINGS_NAME).edit().putBoolean("accessibility_consent", true).commit()
        preferences("app_rules").edit().putLong("pause_until_wall", 456L).commit()
        val backup = ConfigurationBackup(context)
        val encoded = backup.export()
        val original = savedState()
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("version", "1") },
            { it.put("unexpected", true) },
            { it.getJSONObject("appearance").put("accessibility_consent", true) },
            { it.getJSONObject("appearance").put(HaloAppearance.ACTIONS_PER_PAGE_KEY, 7) },
            { it.getJSONObject("appearance").put(HaloAppearance.DIM_KEY, "40") },
            { it.getJSONObject("appearance").put("halo_initial_position", "MIDDLE") },
            { it.getJSONObject("actions").getJSONArray("custom").getJSONObject(0).put("template", "javascript:{text}") },
            { it.getJSONObject("actions").getJSONArray("custom").getJSONObject(0).put("icon", 123) },
            { it.getJSONObject("actions").getJSONObject("enabled").put("copy", "true") },
            { it.getJSONObject("actions").getJSONArray("order").put("missing") },
            { it.getJSONObject("actions").getJSONArray("order").put("copy") },
            { it.getJSONObject("destinations").put("copy", "javascript:alert(1)") },
            { it.getJSONObject("destinations").put("missing", "web") },
            { it.getJSONObject("appRules").put("org.example.reader", JSONObject().put("trigger", "INVALID")) },
            { it.getJSONObject("appRules").put("org.example.reader", JSONObject().put("trigger", "AUTO").put("actions", JSONArray().put("missing"))) },
        )
        mutations.forEach { mutate ->
            val invalid = JSONObject(encoded).also(mutate)
            rejects { backup.restore(invalid) }
            assertEquals(original, savedState())
        }
    }

    @Test fun oversizedTrailingInvalidUtf8AndEmptyFilesAreRejectedWithoutInitializingPreferences() {
        val backup = ConfigurationBackup(context)
        val original = savedState()
        val files = listOf(ByteArray(0), "{} trailing".toByteArray(), byteArrayOf(0xc3.toByte(), 0x28),
            ByteArray(ConfigurationBackup.MAX_BYTES + 1) { ' '.code.toByte() })
        files.forEach { bytes ->
            rejects { backup.read(ByteArrayInputStream(bytes)) }
            assertEquals(original, savedState())
        }
    }

    @Test fun hostileActionIdsAndExcessiveCatalogsAreRejectedBeforeAnyPreferenceWrite() {
        val store = ActionStore(context)
        store.addCustom("Saved", "https://saved.example/?q={text}")
        preferences(HaloAppearance.SETTINGS_NAME).edit().putBoolean("accessibility_consent", true).commit()
        val backup = ConfigurationBackup(context)
        val encoded = backup.export()
        val original = savedState()
        val invalidIds = listOf("custom:", "custom:" + "x".repeat(122), "custom:line\nfeed",
            "custom:null\u0000key", "custom:two words", "custom:del\u007fkey")
        invalidIds.forEach { id ->
            val invalid = JSONObject(encoded)
            val actions = invalid.getJSONObject("actions")
            val previousId = actions.getJSONArray("custom").getJSONObject(0).getString("id")
            actions.getJSONArray("custom").getJSONObject(0).put("id", id)
            val order = actions.getJSONArray("order")
            repeat(order.length()) { if (order.getString(it) == previousId) order.put(it, id) }
            val enabled = actions.getJSONObject("enabled")
            enabled.remove(previousId)
            enabled.put(id, true)
            rejects { backup.restore(invalid) }
            assertEquals(original, savedState())
        }
        val excessive = JSONObject(encoded)
        val actions = excessive.getJSONObject("actions")
        repeat(200) { index ->
            val id = "custom:hostile-$index"
            actions.getJSONArray("custom").put(JSONObject().put("id", id).put("title", "Fixture $index")
                .put("template", "https://example.com/?q={text}"))
            actions.getJSONArray("order").put(id)
            actions.getJSONObject("enabled").put(id, true)
        }
        assertEquals(201, actions.getJSONArray("custom").length())
        assertTrue(excessive.toString().toByteArray().size < ConfigurationBackup.MAX_BYTES)
        rejects { backup.restore(excessive) }
        assertEquals(original, savedState())
        actions.getJSONArray("custom").remove(200)
        actions.getJSONArray("order").let { it.remove(it.length() - 1) }
        actions.getJSONObject("enabled").remove("custom:hostile-199")
        assertEquals(200, backup.validate(excessive).getJSONObject("actions").getJSONArray("custom").length())
        assertEquals(original, savedState())

        val excessiveEdits = JSONObject(encoded)
        repeat(store.allActions().count { !it.id.startsWith("custom:") } + 1) {
            excessiveEdits.getJSONObject("actions").getJSONArray("edits").put(JSONObject()
                .put("id", "google").put("title", "Fixture").put("template", "https://example.com/?q={text}"))
        }
        rejects { backup.restore(excessiveEdits) }
        assertEquals(original, savedState())
    }

    @Test fun actionSnapshotsUndoDeletionBulkDisableAndResetWithStableIdsAndOrder() {
        val store = ActionStore(context)
        val custom = store.addCustom("Undo search", "https://undo.example/?q={text}", "book")
        store.setEnabled("google", false)
        store.moveTo(custom.id, 0)
        val before = store.snapshot()
        val actions = store.allActions()
        val enabled = store.actions()
        assertTrue(store.deleteCustom(custom.id))
        store.restoreSnapshot(before)
        assertEquals(actions, store.allActions())
        assertEquals(enabled, store.actions())
        store.setAllEnabled(false)
        assertTrue(store.actions().isEmpty())
        store.restoreSnapshot(before)
        assertEquals(enabled, store.actions())
        store.reset()
        assertFalse(store.allActions().any { it.id == custom.id })
        store.restoreSnapshot(before)
        assertEquals(actions, store.allActions())
        assertEquals(enabled, store.actions())
    }

    @Test fun exportingAfterDeletionDropsStaleReferencesWithoutChangingUndoableLocalRules() {
        val store = ActionStore(context)
        val custom = store.addCustom("Temporary", "https://search.example/?q={text}")
        val original = store.snapshot()
        val profile = JSONObject().put("org.example.reader", JSONObject().put("trigger", "AUTO")
            .put("actions", JSONArray().put(custom.id).put("copy"))).toString()
        preferences("app_rules").edit().putString("profiles", profile).commit()
        val routes = JSONObject().put(custom.id, "web").put("google", "web").toString()
        preferences("action_destinations").edit().putString("routes", routes).commit()
        store.deleteCustom(custom.id)
        val exported = JSONObject(ConfigurationBackup(context).export())
        assertEquals(listOf("copy"), exported.getJSONObject("appRules").getJSONObject("org.example.reader")
            .getJSONArray("actions").let { array -> List(array.length()) { array.getString(it) } })
        assertFalse(exported.getJSONObject("destinations").has(custom.id))
        assertEquals(profile, preferences("app_rules").getString("profiles", null))
        assertEquals(routes, preferences("action_destinations").getString("routes", null))
        store.restoreSnapshot(original)
        assertTrue(JSONObject(ConfigurationBackup(context).export()).getJSONObject("destinations").has(custom.id))
    }

    private fun rejects(operation: () -> Unit) {
        try { operation(); fail("Invalid backup must be rejected") }
        catch (_: Exception) { }
    }
}
