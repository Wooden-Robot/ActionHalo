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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Persisted management operations must preserve the IDs and choices used by the radial menu. */
@RunWith(AndroidJUnit4::class)
class ActionManagementTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val fixturePreferences = "action_management_test_fixture"
    private val preferences: SharedPreferences
        get() = instrumentation.targetContext.getSharedPreferences(fixturePreferences, Context.MODE_PRIVATE)
    private val context: Context = object : ContextWrapper(instrumentation.targetContext) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            if (name == "halo_actions") preferences else super.getSharedPreferences(name, mode)
    }

    @Before fun resetFixture() {
        assertTrue(preferences.edit().clear().commit())
    }

    @After fun clearFixture() {
        assertTrue(preferences.edit().clear().commit())
    }

    @Test fun translationUsesTheWebsiteAndRetainsItsSavedPositionAndEnabledState() {
        val store = ActionStore(context)
        store.setEnabled("translate", false)
        assertTrue(store.moveTo("translate", 0))
        val reloaded = ActionStore(context)
        assertEquals("translate", reloaded.allActions().first().id)
        assertFalse(reloaded.isEnabled("translate"))
        reloaded.setEnabled("translate", true)
        val action = ActionStore(context).actions().first()
        assertEquals(ActionType.URL, action.type)
        val selected = "你好 🌍 &text=other#fragment + %2F"
        val launched = execute(action, selected)
        assertEquals("translate.google.com", launched.data?.host)
        assertEquals("auto", launched.data?.getQueryParameter("sl"))
        assertEquals(context.getString(R.string.action_translation_target), launched.data?.getQueryParameter("tl"))
        assertEquals("translate", launched.data?.getQueryParameter("op"))
        assertEquals(selected, launched.data?.getQueryParameter("text"))
        assertEquals(setOf("sl", "tl", "text", "op"), launched.data?.queryParameterNames)
        assertNull(launched.data?.fragment)
        assertNull(launched.component)
    }

    @Test fun movingAcrossBuiltInsAndDisabledActionsPersistsTheFullCatalogOrder() {
        val store = ActionStore(context)
        val original = store.allActions().map { it.id }
        val custom = store.addCustom("Fixture search", "https://example.com/?q={text}", "book")
        store.setEnabled("google", false)
        store.setEnabled("douban_book", true)
        val enabled = store.actions().map { it.id }.toSet()
        repeat(original.size) { assertTrue(store.move(custom.id, -1)) }
        assertTrue(store.move("google", -1))

        val expected = listOf(custom.id, "google", "copy") + original.drop(2)
        val reloaded = ActionStore(context)
        assertEquals(expected, reloaded.allActions().map { it.id })
        assertEquals(expected.filter { it in enabled }, reloaded.actions().map { it.id })
        assertFalse(reloaded.isEnabled("google"))
        assertTrue(reloaded.isEnabled(custom.id))
        assertTrue(reloaded.isEnabled("douban_book"))
        assertFalse(reloaded.move(custom.id, -1))
        assertFalse(reloaded.move(expected.last(), 1))
        assertFalse(reloaded.move("missing", 1))
        assertEquals(expected, ActionStore(context).allActions().map { it.id })
    }

    @Test fun movingToAFinalIndexCrossesTheCatalogAndPreservesDisabledAndCustomActions() {
        val store = ActionStore(context)
        val original = store.allActions().map { it.id }
        val custom = store.addCustom("Dragged search", "https://example.com/?q={text}", "book")
        store.setEnabled("google", false)
        store.setEnabled("douban_book", true)
        val enabled = store.actions().map { it.id }.toSet()
        val lastIndex = original.size

        assertTrue(store.moveTo(custom.id, 0))
        assertEquals(listOf(custom.id) + original, ActionStore(context).allActions().map { it.id })
        assertTrue(store.moveTo("google", lastIndex))
        assertEquals(listOf(custom.id) + original.filterNot { it == "google" } + "google",
            ActionStore(context).allActions().map { it.id })
        assertTrue(store.moveTo(custom.id, lastIndex))

        val expected = original.filterNot { it == "google" } + "google" + custom.id
        val reloaded = ActionStore(context)
        assertEquals(expected, reloaded.allActions().map { it.id })
        assertEquals(expected.filter { it in enabled }, reloaded.actions().map { it.id })
        assertFalse(reloaded.isEnabled("google"))
        assertTrue(reloaded.isEnabled("douban_book"))
        assertTrue(reloaded.isEnabled(custom.id))
    }

    @Test fun invalidAndUnchangedDragDestinationsDoNotWritePreferences() {
        val store = ActionStore(context)
        val custom = store.addCustom("Unmoved search", "https://example.com/?q={text}")
        store.setEnabled(custom.id, false)
        val actions = store.allActions()
        val savedPreferences = preferences.all.toMap()
        assertFalse(preferences.contains("action_order"))

        assertFalse(store.moveTo("missing", 0))
        listOf(-1, actions.size, Int.MIN_VALUE, Int.MAX_VALUE).forEach {
            assertFalse(store.moveTo(custom.id, it))
        }
        assertFalse(store.moveTo(actions.first().id, 0))
        assertFalse(store.moveTo(custom.id, actions.lastIndex))

        assertEquals(savedPreferences, preferences.all)
        assertEquals(actions, ActionStore(context).allActions())
        assertFalse(ActionStore(context).isEnabled(custom.id))
    }

    @Test fun editingADisabledCustomActionKeepsItsPositionAndExecutesTheNewUrlWhenEnabled() {
        val store = ActionStore(context)
        val custom = store.addCustom("Old name", "https://old.example/?q={text}")
        store.addCustom("Other search", "https://other.example/?q={text}", "globe")
        assertTrue(store.move(custom.id, -1))
        assertTrue(store.move(custom.id, -1))
        store.setEnabled(custom.id, false)
        val order = store.allActions().map { it.id }
        val edited = store.editAction(custom.id, "  New movie search  ",
            "  https://new.example/movies?q={text}&kind=film  ", "film")

        val reloaded = ActionStore(context)
        val persisted = reloaded.allActions().single { it.id == custom.id }
        assertTrue(reloaded.canEdit(persisted))
        assertEquals(edited, persisted)
        assertEquals("New movie search", persisted.title)
        assertEquals("https://new.example/movies?q={text}&kind=film", persisted.template)
        assertEquals("film", persisted.icon)
        assertEquals(R.drawable.ic_action_film, ActionIcons.resource(persisted))
        assertEquals(order, reloaded.allActions().map { it.id })
        assertFalse(reloaded.isEnabled(custom.id))
        assertFalse(reloaded.actions().any { it.id == custom.id })

        reloaded.setEnabled(custom.id, true)
        val selected = "三体 🌍 &q=other#fragment + %2F"
        val launched = execute(ActionStore(context).actions().single { it.id == custom.id }, selected)
        assertEquals("new.example", launched.data?.host)
        assertEquals("/movies", launched.data?.path)
        assertEquals(selected, launched.data?.getQueryParameter("q"))
        assertEquals("film", launched.data?.getQueryParameter("kind"))
        assertEquals(setOf("q", "kind"), launched.data?.queryParameterNames)
        assertNull(launched.data?.fragment)
    }

    @Test fun editingABuiltInMovieSearchOverridesOnlyThatActionAndLaunchesTheEditedWebsite() {
        val store = ActionStore(context)
        val original = store.allActions()
        val editable = setOf("google", "baidu", "douban_book", "douban_movie", "neodb", "neodb_book", "github")
        assertEquals(editable, original.filter { store.canEdit(it) }.map { it.id }.toSet())
        original.filter { it.id in editable }.forEach {
            assertTrue(ActionUrls.validateTemplate(requireNotNull(store.templateForEditing(it))))
        }
        val movie = original.single { it.id == "douban_movie" }
        store.setEnabled(movie.id, true)
        store.editAction(movie.id, "My movie site", "https://movies.example/find?term={text}", "search")

        val reloaded = ActionStore(context)
        assertEquals(original.map { it.id }, reloaded.allActions().map { it.id })
        assertEquals(original.filterNot { it.id == movie.id }, reloaded.allActions().filterNot { it.id == movie.id })
        val edited = reloaded.actions().single { it.id == movie.id }
        assertEquals(ActionType.URL, edited.type)
        assertEquals("My movie site", edited.title)
        assertEquals("search", edited.icon)
        assertTrue(reloaded.canEdit(edited))
        assertEquals(ActionType.DOUBAN_SEARCH, reloaded.allActions().single { it.id == "douban" }.type)
        assertEquals(ActionType.DOUBAN_BOOK_SEARCH, reloaded.allActions().single { it.id == "douban_book" }.type)
        val selected = "电影 &term=changed#fragment"
        val launched = execute(edited, selected)
        assertEquals("movies.example", launched.data?.host)
        assertEquals("/find", launched.data?.path)
        assertEquals(setOf("term"), launched.data?.queryParameterNames)
        assertEquals(selected, launched.data?.getQueryParameter("term"))
        assertNull(launched.`package`)
    }

    @Test fun legacyCustomDataAndDamagedOrderRetainKnownActionsAndAppendNewOnes() {
        val legacyId = "custom:legacy"
        val legacy = JSONObject().put("id", legacyId).put("title", "Legacy search")
            .put("template", "https://legacy.example/?q={text}")
        assertTrue(preferences.edit().putString("custom_actions", JSONArray().put(legacy).toString())
            .putBoolean("enabled_$legacyId", false).commit())
        val upgraded = ActionStore(context)
        val original = upgraded.allActions().map { it.id }
        assertEquals(legacyId, original.last())
        assertNull(upgraded.allActions().last().icon)
        assertFalse(upgraded.isEnabled(legacyId))
        upgraded.editAction(legacyId, "Edited legacy search", "https://legacy.example/find?q={text}")
        assertEquals(original, ActionStore(context).allActions().map { it.id })
        assertEquals("Edited legacy search", ActionStore(context).allActions().last().title)
        assertFalse(ActionStore(context).isEnabled(legacyId))

        assertTrue(preferences.edit().putString("action_order", "broken-json").commit())
        assertEquals(original, ActionStore(context).allActions().map { it.id })
        val damaged = JSONArray().put("google").put(legacyId).put("google").put("unknown")
            .put(42).put("copy")
        assertTrue(preferences.edit().putString("action_order", damaged.toString()).commit())
        val recovered = ActionStore(context)
        val expected = listOf("google", legacyId, "copy") + original.filterNot {
            it == "google" || it == legacyId || it == "copy"
        }
        assertEquals(expected, recovered.allActions().map { it.id })
        val appended = recovered.addCustom("New search", "https://new.example/?q={text}", "earth")
        assertEquals(expected + appended.id, ActionStore(context).allActions().map { it.id })
        assertTrue(recovered.move(legacyId, -1))
        assertTrue(recovered.deleteCustom(legacyId))
        val final = ActionStore(context)
        assertEquals(expected.filterNot { it == legacyId } + appended.id, final.allActions().map { it.id })
        assertFalse(preferences.contains("enabled_$legacyId"))
        val savedOrder = JSONArray(preferences.getString("action_order", "[]"))
        assertFalse((0 until savedOrder.length()).any { savedOrder.optString(it) == legacyId })
        assertFalse(final.deleteCustom(legacyId))
        assertFalse(final.deleteCustom("copy"))
    }

    @Test fun invalidEditsAndAddsLeaveExistingConfigurationUntouched() {
        val store = ActionStore(context)
        val custom = store.addCustom("Saved search", "https://saved.example/?q={text}", "book")
        store.setEnabled(custom.id, false)
        assertTrue(store.move(custom.id, -1))
        val savedPreferences = preferences.all.toMap()
        val savedActions = store.allActions()
        val savedEnabled = store.actions()
        val validTemplate = "https://valid.example/?q={text}"

        rejects { store.editAction(custom.id, " \n ", validTemplate, "book") }
        listOf("javascript:alert('{text}')", "https://{text}.example/", "https://valid.example/no-placeholder")
            .forEach { template -> rejects { store.editAction(custom.id, "Invalid", template, "book") } }
        rejects { store.editAction(custom.id, "Invalid icon", validTemplate, "unknown-icon") }
        rejects { store.editAction("copy", "Changed copy", validTemplate, "book") }
        rejects { store.editAction("missing", "Missing", validTemplate, "book") }
        rejects { store.addCustom(" ", validTemplate, "book") }
        rejects { store.addCustom("Invalid", "douban://douban.com/search?q={text}", "book") }
        rejects { store.addCustom("Invalid", validTemplate, "unknown-icon") }

        assertEquals(savedPreferences, preferences.all)
        assertEquals(savedActions, ActionStore(context).allActions())
        assertEquals(savedEnabled, ActionStore(context).actions())
    }

    private fun execute(action: HaloAction, selected: String): Intent {
        val recording = object : ContextWrapper(instrumentation.targetContext) {
            val launches = mutableListOf<Intent>()
            override fun startActivity(intent: Intent) { launches += Intent(intent) }
            override fun getSystemService(name: String): Any? {
                check(name != Context.CLIPBOARD_SERVICE) { "Editing a search must not read the clipboard" }
                return super.getSystemService(name)
            }
        }
        instrumentation.runOnMainSync { assertTrue(ActionExecutor.execute(recording, action, selected)) }
        val launched = recording.launches.single()
        assertEquals(Intent.ACTION_VIEW, launched.action)
        assertEquals("https", launched.data?.scheme)
        assertTrue(launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        return launched
    }

    private fun rejects(operation: () -> Unit) {
        try {
            operation()
            fail("Invalid action configuration must be rejected")
        } catch (_: IllegalArgumentException) {
            // Validation must complete before any existing preference is written.
        }
    }
}
