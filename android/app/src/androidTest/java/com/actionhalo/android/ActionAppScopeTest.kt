package com.actionhalo.android

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ActionAppScopeTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val names = setOf("halo_actions", AppRulesStore.PREFERENCES, HaloAppearance.SETTINGS_NAME, "action_destinations")
    private val context = object : ContextWrapper(target) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(if (name in names) "app_scope_test_$name" else name, mode)
    }
    private fun preferences(name: String) = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun state() = names.associateWith { preferences(it).all.toMap() }
    @Before fun setUp() = clear()
    @After fun tearDown() = clear()
    private fun clear() { names.forEach { assertTrue(preferences(it).edit().clear().commit()) } }

    @Test fun defaultScopeKeepsExistingActionsAndSettingDoesNotChangeTheConfigurationList() {
        val store = ActionStore(context)
        val original = store.actions()
        assertEquals(ActionStore.AppScope(), store.appScope("copy"))
        assertTrue(store.isAllowedInApp("copy", null))
        assertTrue(store.isAllowedInApp("copy", "com.example.reader"))
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader")))
        assertEquals(original, store.actions())
        store.setAppScope("copy", ActionStore.AppScope())
        assertEquals(ActionStore.AppScope(), ActionStore(context).appScope("copy"))
        assertFalse(store.snapshot().getJSONObject("appScopes").has("copy"))
    }

    @Test fun onlyModeRequiresAKnownExactSourcePackage() {
        val store = ActionStore(context)
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.ONLY,
            listOf("com.example.reader", "org.telegram.messenger")))
        assertTrue(store.isAllowedInApp("copy", "com.example.reader"))
        assertTrue(ActionStore(context).isAllowedInApp("copy", "org.telegram.messenger"))
        listOf(null, "", "COM.EXAMPLE.READER", " com.example.reader", "com.example.reader.web", "com.example.other")
            .forEach { assertFalse("Unexpected allowed source: $it", store.isAllowedInApp("copy", it)) }
    }

    @Test fun exceptModeExcludesOnlyExactKnownPackagesAndAllowsUnknownSources() {
        val store = ActionStore(context)
        store.setAppScope("google", ActionStore.AppScope(ActionStore.AppScopeMode.EXCEPT, listOf("com.example.reader")))
        assertFalse(store.isAllowedInApp("google", "com.example.reader"))
        assertTrue(store.isAllowedInApp("google", null))
        assertTrue(store.isAllowedInApp("google", "com.example.other"))
        assertTrue(store.isAllowedInApp("google", "com.example.reader.web"))
    }

    @Test fun sourceProfilesCannotBypassScopesAndAllowedActionsKeepTheirOrder() {
        val store = ActionStore(context)
        val rules = AppRulesStore(context)
        store.setEnabled("google", false)
        store.setAppScope("google", ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.allowed")))
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.EXCEPT, listOf("com.example.blocked")))
        val profile = AppRulesStore.Profile(actions = listOf("share", "google", "copy", "baidu"))
        rules.setProfile("com.example.blocked", profile)
        rules.setProfile("com.example.allowed", profile)
        assertEquals(listOf("share", "baidu"), rules.actionsFor("com.example.blocked", store.allActions()).map { it.id })
        assertEquals(listOf("share", "google", "copy", "baidu"), rules.actionsFor("com.example.allowed", store.allActions()).map { it.id })
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.allowed")))
        assertFalse(rules.actionsFor(null, store.allActions()).any { it.id == "copy" })
        assertTrue(store.actions().any { it.id == "copy" })
    }

    @Test fun executionRechecksAChangedScopeBeforeLaunchingAnAlreadyObtainedAction() {
        val store = ActionStore(context)
        val action = store.allActions().single { it.id == "google" }
        val launches = mutableListOf<Intent>()
        val recording = object : ContextWrapper(context) {
            override fun startActivity(intent: Intent) { launches.add(Intent(intent)) }
        }
        val selected = "三体 🚀 &q=other#fragment + %2F"
        val failures = mutableListOf<Int>()
        store.setAppScope(action.id, ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader")))
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            assertFalse(ActionExecutor.execute(recording, action, selected, failures::add))
            assertFalse(ActionExecutor.execute(recording, action, selected, failures::add, "com.example.other"))
            assertTrue(launches.isEmpty())
            assertEquals(listOf(R.string.action_scope_blocked, R.string.action_scope_blocked), failures)
            failures.clear()
            assertTrue(ActionExecutor.execute(recording, action, selected, failures::add, "com.example.reader"))
        }
        assertTrue(failures.isEmpty())
        val intent = launches.single()
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals(ActionUrls.build(requireNotNull(action.template), selected), intent.dataString)
        assertEquals(selected, intent.data?.getQueryParameter("q"))
        assertEquals(setOf("q"), intent.data?.queryParameterNames)
        assertNull(intent.data?.fragment)
    }

    @Test fun snapshotsPreserveScopesAcrossDeleteUndoResetAndOldFormatRestore() {
        val store = ActionStore(context)
        val custom = store.addCustom("Books", "https://example.com/?q={text}")
        val scope = ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader"))
        store.setAppScope(custom.id, scope)
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.EXCEPT, listOf("com.example.chat")))
        val snapshot = store.snapshot()
        assertTrue(store.deleteCustom(custom.id))
        assertFalse(store.snapshot().getJSONObject("appScopes").has(custom.id))
        store.restoreSnapshot(snapshot)
        assertEquals(scope, store.appScope(custom.id))
        assertTrue(store.allActions().any { it.id == custom.id })
        store.reset()
        assertEquals(0, store.snapshot().getJSONObject("appScopes").length())
        store.restoreSnapshot(snapshot)
        assertEquals(scope, store.appScope(custom.id))
        val oldSnapshot = JSONObject(snapshot.toString()).apply { remove("appScopes") }
        store.restoreSnapshot(oldSnapshot)
        assertEquals(ActionStore.AppScope(), store.appScope(custom.id))
        assertEquals(ActionStore.AppScope(), store.appScope("copy"))
    }

    @Test fun backupRoundTripIncludesScopesWithoutChangingTheBackupVersion() {
        val store = ActionStore(context)
        val scope = ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader"))
        store.setAppScope("copy", scope)
        val backup = ConfigurationBackup(context)
        val encoded = JSONObject(backup.export())
        assertEquals(1, encoded.getInt("version"))
        store.reset()
        backup.restore(encoded)
        assertEquals(scope, ActionStore(context).appScope("copy"))
        encoded.getJSONObject("actions").remove("appScopes")
        backup.restore(encoded)
        assertEquals(ActionStore.AppScope(), ActionStore(context).appScope("copy"))
    }

    @Test fun invalidScopeEditsNeverChangeSavedConfiguration() {
        val store = ActionStore(context)
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader")))
        val original = state()
        val invalid = listOf(
            ActionStore.AppScope(ActionStore.AppScopeMode.ONLY),
            ActionStore.AppScope(ActionStore.AppScopeMode.EXCEPT),
            ActionStore.AppScope(ActionStore.AppScopeMode.ALL, listOf("com.example.reader")),
            ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader", "com.example.reader")),
            ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader ")),
            ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("invalid")),
            ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example." + "x".repeat(255))),
            ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, List(201) { "com.example.app$it" }),
        )
        invalid.forEach { scope ->
            rejects { store.setAppScope("copy", scope) }
            assertEquals(original, state())
        }
        rejects { store.setAppScope("missing", ActionStore.AppScope()) }
        assertEquals(original, state())
    }

    @Test fun invalidImportedScopesAreRejectedBeforeWritingAnyPreferences() {
        val store = ActionStore(context)
        store.setAppScope("copy", ActionStore.AppScope(ActionStore.AppScopeMode.ONLY, listOf("com.example.reader")))
        preferences(HaloAppearance.SETTINGS_NAME).edit().putBoolean(HaloAppearance.HAPTICS_KEY, true)
            .putBoolean("accessibility_consent", true).commit()
        AppRulesStore(context).setProfile("com.example.reader", AppRulesStore.Profile(AppRulesStore.TriggerMode.AUTO))
        ActionDestinations(context).setRoute("google", "web")
        val snapshot = store.snapshot().toString()
        val backup = ConfigurationBackup(context)
        val backupDocument = JSONObject(backup.export()).apply {
            getJSONObject("appearance").put(HaloAppearance.HAPTICS_KEY, false)
            getJSONObject("appRules").getJSONObject("com.example.reader").put("trigger", "OFF")
            getJSONObject("destinations").put("google", "package:com.example.browser")
        }.toString()
        val original = state()
        val mutations: List<(JSONObject) -> Unit> = listOf(
            { it.put("appScopes", JSONObject.NULL) },
            { it.put("appScopes", JSONArray()) },
            { it.getJSONObject("appScopes").put("missing", scopeJson()) },
            { it.getJSONObject("appScopes").put("copy", true) },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("mode", 3) },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("mode", "INVALID") },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("extra", true) },
            { it.getJSONObject("appScopes").getJSONObject("copy").remove("packages") },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("packages", "com.example.reader") },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("packages", JSONArray().put(3)) },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("packages", JSONArray().put("com.example.reader").put("com.example.reader")) },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("packages", JSONArray().put("invalid package")) },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("packages", JSONArray()) },
            { it.getJSONObject("appScopes").getJSONObject("copy").put("packages", JSONArray(List(201) { i -> "com.example.app$i" })) },
        )
        mutations.forEach { mutate ->
            val invalid = JSONObject(snapshot).also(mutate)
            rejects { store.restoreSnapshot(invalid) }
            assertEquals(original, state())
            val invalidBackup = JSONObject(backupDocument).put("actions", invalid)
            rejects { backup.restore(invalidBackup) }
            assertEquals(original, state())
        }
    }

    private fun scopeJson() = JSONObject().put("mode", "ONLY").put("packages", JSONArray().put("com.example.reader"))
    private fun rejects(block: () -> Unit) {
        try { block(); fail("Invalid app scope must be rejected") } catch (_: IllegalArgumentException) { }
    }
}
