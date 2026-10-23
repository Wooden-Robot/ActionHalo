package com.actionhalo.android

import java.net.URI
import java.net.URLDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class DoubanSearchTest {
    @Test fun appRoutePreservesChineseAndEmojiWithOneEncodingPass() {
        assertEquals(
            "douban://douban.com/search/result?q=%E4%B8%89%E4%BD%93%20%F0%9F%8C%8D",
            DoubanSearch.appUri("三体 🌍"),
        )
        assertEquals("com.douban.frodo", DoubanSearch.PACKAGE_NAME)
    }

    @Test fun untrustedQueryCannotChangeTheDestinationOrAddParameters() {
        val selected = "Inception&q=other&uri=javascript:alert(1)#fragment?x=1 + %2F"
        val uri = URI(DoubanSearch.appUri(selected))
        assertEquals("douban", uri.scheme)
        assertEquals("douban.com", uri.host)
        assertEquals("/search/result", uri.path)
        assertEquals(null, uri.fragment)
        assertFalse(uri.rawQuery.contains('&'))
        assertEquals(selected, URLDecoder.decode(uri.rawQuery.removePrefix("q="), "UTF-8"))
    }

    @Test fun webFallbackUsesTheOfficialQueryParameterAndSameSelectedText() {
        val selected = "三体 🌍 &a=1%20"
        val uri = URI(DoubanSearch.webUrl(selected))
        assertEquals("https", uri.scheme)
        assertEquals("m.douban.com", uri.host)
        assertEquals("/search/", uri.path)
        assertEquals(selected, URLDecoder.decode(uri.rawQuery.removePrefix("query="), "UTF-8"))
        assertEquals(
            DoubanSearch.appUri(selected).substringAfter("?q="),
            uri.rawQuery.removePrefix("query="),
        )
    }

    @Test fun nativeSupportDoesNotEnableCustomSchemesInUserTemplates() {
        assertFalse(ActionUrls.validateTemplate("douban://douban.com/search/result?q={text}"))
        assertFalse(ActionUrls.validateTemplate("intent://search/{text}"))
    }

    @Test fun categoryFallbacksPreserveTheBookOrMovieRouteAndEncodeOnlyTheQuery() {
        val selected = "三体 🚀 &t=other&search_text=other#fragment + %2F"
        for ((type, category) in listOf(ActionType.DOUBAN_BOOK_SEARCH to "book", ActionType.DOUBAN_MOVIE_SEARCH to "movie")) {
            val uri = URI(DoubanSearch.webUrl(selected, type))
            assertEquals("https", uri.scheme)
            assertEquals("search.douban.com", uri.host)
            assertEquals("/$category/subject_search", uri.path)
            assertEquals(null, uri.fragment)
            assertFalse(uri.rawQuery.contains('&'))
            assertEquals(selected, URLDecoder.decode(uri.rawQuery.removePrefix("search_text="), "UTF-8"))
            assertEquals(DoubanSearch.appUri(selected).substringAfter("?q="),
                uri.rawQuery.removePrefix("search_text="))
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun unrelatedActionCannotSelectADoubanRoute() {
        DoubanSearch.webUrl("三体", ActionType.URL)
    }
}
