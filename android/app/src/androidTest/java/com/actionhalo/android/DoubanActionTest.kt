package com.actionhalo.android

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercise launch and fallback decisions without installing or contacting a third-party app. */
@RunWith(AndroidJUnit4::class)
class DoubanActionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val selected = "三体 🌍 &q=other&t=movie#fragment + %2F"
    private val fixturePreferences = "douban_action_test_fixture"

    @After fun clearFixturePreferences() {
        instrumentation.targetContext.getSharedPreferences(fixturePreferences, Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @Test fun installedAppReceivesOneExplicitPackageSearchIntent() {
        instrumentation.runOnMainSync {
            catalogActions().filter { it.type == ActionType.DOUBAN_SEARCH }.forEach { action ->
                val context = RecordingContext(instrumentation.targetContext)
                assertTrue(ActionExecutor.execute(context, action, selected))
                assertEquals(1, context.launches.size)
                val launched = context.launches.single()
                assertEquals(Intent.ACTION_VIEW, launched.action)
                assertEquals("com.douban.frodo", launched.`package`)
                assertEquals("douban", launched.data?.scheme)
                assertEquals("douban.com", launched.data?.host)
                assertEquals("/search/result", launched.data?.path)
                assertEquals(selected, launched.data?.getQueryParameter("q"))
                assertEquals(setOf("q"), launched.data?.queryParameterNames)
                assertEquals(null, launched.data?.fragment)
                assertTrue(launched.extras == null || launched.extras!!.isEmpty)
                assertTrue(launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
            }
        }
    }

    @Test fun missingDoubanAppFallsBackToOfficialWebSearch() {
        assertWebFallback(ActivityNotFoundException("Fixture: app unavailable"))
    }

    @Test fun blockedDoubanAppFallsBackToOfficialWebSearch() {
        assertWebFallback(SecurityException("Fixture: native launch denied"))
    }

    @Test fun bookAndMovieOpenClassifiedWebSearchWithoutTryingNativeApp() {
        instrumentation.runOnMainSync {
            catalogActions().filter { it.type != ActionType.DOUBAN_SEARCH }.forEach { action ->
                listOf(null, ActivityNotFoundException("Fixture: app unavailable"),
                    SecurityException("Fixture: native launch denied")).forEach { nativeFailure ->
                    val context = RecordingContext(instrumentation.targetContext, nativeFailure)
                    assertTrue(ActionExecutor.execute(context, action, selected))
                    assertEquals(1, context.launches.size)
                    val launched = context.launches.single()
                    val category = if (action.type == ActionType.DOUBAN_BOOK_SEARCH) "book" else "movie"
                    assertEquals(Intent.ACTION_VIEW, launched.action)
                    assertEquals(null, launched.`package`)
                    assertEquals("https", launched.data?.scheme)
                    assertEquals("search.douban.com", launched.data?.host)
                    assertEquals("/$category/subject_search", launched.data?.path)
                    assertEquals(selected, launched.data?.getQueryParameter("search_text"))
                    assertEquals(setOf("search_text"), launched.data?.queryParameterNames)
                    assertEquals(null, launched.data?.fragment)
                    assertTrue(launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
                }
            }
        }
    }

    private fun assertWebFallback(failure: RuntimeException) {
        instrumentation.runOnMainSync {
            catalogActions().filter { it.type == ActionType.DOUBAN_SEARCH }.forEach { action ->
                val context = RecordingContext(instrumentation.targetContext, failure)
                assertTrue(ActionExecutor.execute(context, action, selected))
                assertEquals(2, context.launches.size)
                assertEquals("com.douban.frodo", context.launches.first().`package`)
                assertEquals(selected, context.launches.first().data?.getQueryParameter("q"))
                val fallback = context.launches.last()
                assertEquals(Intent.ACTION_VIEW, fallback.action)
                assertEquals(null, fallback.`package`)
                assertEquals("https", fallback.data?.scheme)
                assertEquals("m.douban.com", fallback.data?.host)
                assertEquals("/search/", fallback.data?.path)
                assertEquals(selected, fallback.data?.getQueryParameter("query"))
                assertEquals(setOf("query"), fallback.data?.queryParameterNames)
                assertEquals(null, fallback.data?.fragment)
            }
        }
    }

    private fun catalogActions(): List<HaloAction> {
        val context = object : ContextWrapper(instrumentation.targetContext) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                baseContext.getSharedPreferences(fixturePreferences, mode)
        }
        val catalog = ActionStore(context).allActions().associateBy { it.id }
        return listOf("douban" to ActionType.DOUBAN_SEARCH,
            "douban_book" to ActionType.DOUBAN_BOOK_SEARCH,
            "douban_movie" to ActionType.DOUBAN_MOVIE_SEARCH).map { (id, type) ->
            requireNotNull(catalog[id]).also { assertEquals(type, it.type) }
        }
    }

    private class RecordingContext(base: Context, private val nativeFailure: RuntimeException? = null) : ContextWrapper(base) {
        val launches = mutableListOf<Intent>()

        override fun startActivity(intent: Intent) {
            launches += Intent(intent)
            if (intent.`package` == DoubanSearch.PACKAGE_NAME && nativeFailure != null) throw nativeFailure
        }

        override fun getSystemService(name: String): Any? {
            check(name != Context.CLIPBOARD_SERVICE) { "Douban search must not access the clipboard" }
            return super.getSystemService(name)
        }
    }
}
