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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Inspect outgoing requests without launching, signing in to, or contacting another app. */
@RunWith(AndroidJUnit4::class)
class SearchActionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val selected = "三体 🚀 &query=other#fragment + %2F"
    private val telegram = HaloAction("telegram", "Telegram", "T", ActionType.TELEGRAM_SEARCH)
    private val fixturePreferences = "search_action_test_fixture"

    @After fun clearFixturePreferences() {
        instrumentation.targetContext.getSharedPreferences(fixturePreferences, Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @Test fun telegramReceivesOnlyAnExplicitSearchUriWithTheExactSelectedText() {
        val context = RecordingContext(instrumentation.targetContext)
        instrumentation.runOnMainSync {
            assertTrue(ActionExecutor.execute(context, telegram, selected))
            assertEquals(1, context.launches.size)
            assertTelegramIntent(context.launches.single(), TelegramSearch.packages.first())
        }
    }

    @Test fun missingFirstTelegramPackageTriesTheSecondOfficialPackage() {
        assertSecondPackage(ActivityNotFoundException("Fixture: first package unavailable"))
    }

    @Test fun blockedFirstTelegramPackageTriesTheSecondOfficialPackage() {
        assertSecondPackage(SecurityException("Fixture: first package denied"))
    }

    @Test fun unavailableTelegramReturnsFailureWithoutWebOrMessageFallback() {
        val context = RecordingContext(instrumentation.targetContext) {
            throw ActivityNotFoundException("Fixture: both official packages unavailable")
        }
        instrumentation.runOnMainSync {
            assertFalse(ActionExecutor.execute(context, telegram, selected))
            assertEquals(TelegramSearch.packages, context.launches.map { it.`package` })
            context.launches.zip(TelegramSearch.packages).forEach { (intent, packageName) ->
                assertTelegramIntent(intent, packageName)
            }
        }
    }

    @Test fun emptySelectionDoesNotLaunchAnApp() {
        val context = RecordingContext(instrumentation.targetContext)
        instrumentation.runOnMainSync {
            assertFalse(ActionExecutor.execute(context, telegram, " \n "))
            assertTrue(context.launches.isEmpty())
        }
    }

    @Test fun catalogSearchesKeepTheirFixedDestinationAndEncodeOnlyTheQuery() {
        val storeContext = object : ContextWrapper(instrumentation.targetContext) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                baseContext.getSharedPreferences(fixturePreferences, mode)
        }
        storeContext.getSharedPreferences("halo_actions", Context.MODE_PRIVATE).edit().clear().commit()
        val actions = ActionStore(storeContext).allActions().associateBy { it.id }
        val routes = listOf(
            Route("neodb", "neodb.social", "/search/", "q"),
            Route("neodb_book", "neodb.social", "/search/", "q", mapOf("c" to "book")),
            Route("github", "github.com", "/search", "q"),
        )
        instrumentation.runOnMainSync {
            routes.forEach { route ->
                val action = requireNotNull(actions[route.id]) { "Missing built-in ${route.id}" }
                assertEquals(ActionType.URL, action.type)
                val context = RecordingContext(instrumentation.targetContext)
                assertTrue(ActionExecutor.execute(context, action, selected))
                val intent = context.launches.single()
                val uri = requireNotNull(intent.data)
                assertEquals(Intent.ACTION_VIEW, intent.action)
                assertEquals(null, intent.`package`)
                assertEquals("https", uri.scheme)
                assertEquals(route.host, uri.host)
                assertEquals(route.path, uri.path)
                assertEquals(null, uri.fragment)
                assertEquals(selected, uri.getQueryParameter(route.queryName))
                assertEquals(setOf(route.queryName) + route.fixedParameters.keys, uri.queryParameterNames)
                route.fixedParameters.forEach { (key, value) -> assertEquals(value, uri.getQueryParameter(key)) }
            }
        }
    }

    private fun assertSecondPackage(failure: RuntimeException) {
        val context = RecordingContext(instrumentation.targetContext) { intent ->
            if (intent.`package` == TelegramSearch.packages.first()) throw failure
        }
        instrumentation.runOnMainSync {
            assertTrue(ActionExecutor.execute(context, telegram, selected))
            assertEquals(TelegramSearch.packages, context.launches.map { it.`package` })
            context.launches.zip(TelegramSearch.packages).forEach { (intent, packageName) ->
                assertTelegramIntent(intent, packageName)
            }
        }
    }

    private fun assertTelegramIntent(intent: Intent, packageName: String) {
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals(packageName, intent.`package`)
        assertEquals("tg", intent.data?.scheme)
        assertEquals("search", intent.data?.host)
        assertEquals(setOf("query"), intent.data?.queryParameterNames)
        assertEquals(selected, intent.data?.getQueryParameter("query"))
        assertTrue(intent.extras == null || intent.extras!!.isEmpty)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    private data class Route(
        val id: String,
        val host: String,
        val path: String,
        val queryName: String,
        val fixedParameters: Map<String, String> = emptyMap(),
    )

    private class RecordingContext(
        base: Context,
        private val onLaunch: (Intent) -> Unit = {},
    ) : ContextWrapper(base) {
        val launches = mutableListOf<Intent>()

        override fun startActivity(intent: Intent) {
            launches += Intent(intent)
            onLaunch(intent)
        }

        override fun getSystemService(name: String): Any? {
            check(name != Context.CLIPBOARD_SERVICE) { "Search must not access the clipboard" }
            return super.getSystemService(name)
        }
    }
}
